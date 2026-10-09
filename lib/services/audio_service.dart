import 'dart:async';
import 'dart:io';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:vinyl/core/utils/edit_queue.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/services/stream_cache_service.dart';
import 'package:logger/logger.dart';

final _logger = Logger();

/// What to do with the music when another app's audio starts or stops.
enum InterruptionAction {
  /// Nothing to do (including: another app's audio ended — we do NOT resume).
  none,

  /// Pause and stay paused until the user presses play.
  pause,

  /// Lower the volume while the other app speaks over us.
  duck,

  /// Bring the volume back after ducking.
  unduck,
}

/// The app's interruption policy, kept separate from the platform so it can be
/// tested. Music pauses when another app starts playing, and stays paused when
/// that app stops: the user decides when to play again.
InterruptionAction interruptionActionFor(AudioInterruptionEvent event) {
  if (event.begin) {
    switch (event.type) {
      case AudioInterruptionType.duck:
        return InterruptionAction.duck;
      case AudioInterruptionType.pause:
      case AudioInterruptionType.unknown:
        return InterruptionAction.pause;
    }
  }
  return event.type == AudioInterruptionType.duck
      ? InterruptionAction.unduck
      : InterruptionAction.none;
}

class AudioPlayerService {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  AudioPlayer? _audioPlayer;
  double? _volumeBeforeDuck;

  factory AudioPlayerService() => _instance;

  AudioPlayerService._internal();

  AudioPlayer get player {
    if (_audioPlayer == null) {
      // just_audio's own interruption handling resumes playback by itself when
      // the other app stops. We want the opposite (stay paused), so it is
      // turned off and handled in _listenToInterruptions instead.
      _audioPlayer = AudioPlayer(handleInterruptions: false);
      _setupAudioPlayer();
      _listenToInterruptions();
    }
    return _audioPlayer!;
  }

  void _setupAudioPlayer() {
    _audioPlayer?.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace st) {
      _logger.e('Audio player playback error: $e');
    });
  }

  Future<void> _listenToInterruptions() async {
    try {
      final session = await AudioSession.instance;
      session.interruptionEventStream.listen((event) {
        final player = _audioPlayer;
        if (player == null) return;
        switch (interruptionActionFor(event)) {
          case InterruptionAction.pause:
            if (player.playing) unawaited(player.pause());
            break;
          case InterruptionAction.duck:
            _volumeBeforeDuck ??= player.volume;
            unawaited(player.setVolume(_volumeBeforeDuck! * 0.3));
            break;
          case InterruptionAction.unduck:
            final restore = _volumeBeforeDuck;
            _volumeBeforeDuck = null;
            if (restore != null) unawaited(player.setVolume(restore));
            break;
          case InterruptionAction.none:
            break;
        }
      });
      // Headphones unplugged / Bluetooth disconnected: pause, don't blast
      // the music out of the speaker.
      session.becomingNoisyEventStream.listen((_) {
        final player = _audioPlayer;
        if (player != null && player.playing) unawaited(player.pause());
      });
    } catch (e) {
      _logger.w('AudioPlayerService: could not listen for audio interruptions: $e');
    }
  }

  Uri? _parseArtUri(String? artPath) {
    if (artPath == null || artPath.trim().isEmpty) return null;
    var trimmed = artPath.trim();
    if (trimmed.startsWith('mediastore://')) return null;
    if (trimmed.startsWith('http://')) {
      trimmed = 'https://${trimmed.substring(7)}';
    }
    if (trimmed.startsWith('https://')) {
      return Uri.tryParse(trimmed);
    }
    final cleanPath = trimmed.startsWith('file://') ? Uri.parse(trimmed).toFilePath() : trimmed;
    return Uri.file(cleanPath);
  }

  AudioSource _buildAudioSource(Song song) {
    MediaItem? mediaItem;
    try {
      mediaItem = MediaItem(
        id: song.id.toString(),
        album: song.album,
        title: song.title,
        artist: song.artist,
        artUri: _parseArtUri(song.albumArt),
      );
    } catch (e) {
      _logger.w('Error building MediaItem tag: $e');
    }

    final path = song.filePath.trim();
    if (path.isEmpty) {
      throw ArgumentError('Cannot create audio source for song with empty filePath: "${song.title}"');
    }
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final cachedPath = StreamCacheService.instance.getCachedFilePath(song.id);
      if (cachedPath != null && File(cachedPath).existsSync()) {
        _logger.i('AudioPlayerService: Playing from stream cache: ${song.title} ($cachedPath)');
        return AudioSource.uri(
          Uri.file(cachedPath),
          tag: mediaItem,
        );
      }
      return AudioSource.uri(
        Uri.parse(path),
        tag: mediaItem,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      );
    } else if (path.startsWith('asset://') || path.startsWith('assets/')) {
      final assetPath = path.replaceFirst('asset://', '');
      return AudioSource.uri(
        Uri.parse('asset:///$assetPath'),
        tag: mediaItem,
      );
    } else {
      final cleanPath = path.startsWith('file://') ? Uri.parse(path).toFilePath() : path;
      return AudioSource.uri(
        Uri.file(cleanPath),
        tag: mediaItem,
      );
    }
  }

  static const int _maxWindowSize = 25;

  (List<Song>, int) _buildWindowWithIndex(List<Song> queue, int activeIndex) {
    if (queue.isEmpty) return (<Song>[], 0);
    if (queue.length <= _maxWindowSize) {
      final safeIndex = activeIndex.clamp(0, queue.length - 1);
      return (List<Song>.from(queue), safeIndex);
    }

    final halfWindow = _maxWindowSize ~/ 2;
    final window = <Song>[];
    for (int i = -halfWindow; i <= halfWindow; i++) {
      final index = (activeIndex + i) % queue.length;
      final normalizedIndex = index < 0 ? index + queue.length : index;
      window.add(queue[normalizedIndex]);
    }
    return (window, halfWindow);
  }

  /// just_audio's play() only completes when playback pauses or ends, so it
  /// must not be awaited or callers would stay in "loading" for the whole song.
  void _startPlayback() {
    player.play().catchError((Object e) {
      _logger.w('Playback ended with error: $e');
    });
  }

  Future<void> prepare(Song song) async {
    try {
      final source = _buildAudioSource(song);
      await player.setAudioSource(source);
    } on PlayerInterruptedException {
      _logger.i('Audio loading interrupted by new request.');
    } catch (e) {
      if (e.toString().contains('Loading interrupted')) return;
      _logger.e('Error preparing audio source (${song.filePath}): $e');
    }
  }

  Future<void> play(
    String path, {
    Song? songInfo,
    List<Song>? queue,
    int? initialIndex,
    bool Function()? isCancelled,
  }) async {
    // Loading can take seconds; if the request was cancelled meanwhile (user
    // paused, stopped or picked another song), don't start it anyway.
    void startIfWanted() {
      if (isCancelled?.call() ?? false) return;
      _startPlayback();
    }

    try {
      if (!path.startsWith('http://') && !path.startsWith('https://')) {
        final cleanPath = path.startsWith('file://') ? Uri.parse(path).toFilePath() : path;
        final file = File(cleanPath);
        if (Platform.isAndroid || Platform.isIOS) {
          if (!file.existsSync()) {
            throw Exception('Audio file not found on disk ($cleanPath)');
          }
          if (file.lengthSync() == 0) {
            throw Exception('Audio file is empty or corrupted (0 bytes)');
          }
        }
      }

      final validQueue = queue?.where((s) => s.filePath.trim().isNotEmpty).toList();
      if (validQueue != null && validQueue.isNotEmpty) {
        final activeSong = songInfo ?? validQueue.firstWhere(
          (s) => s.filePath == path,
          orElse: () => validQueue.first,
        );

        final activeIndex = validQueue.indexWhere((s) => s.id == activeSong.id);
        final safeActiveIndex = activeIndex != -1 ? activeIndex : (initialIndex ?? 0).clamp(0, validQueue.length - 1);

        final (window, indexInWindow) = _buildWindowWithIndex(validQueue, safeActiveIndex);
        final audioSources = window.map(_buildAudioSource).toList();

        await player.setAudioSources(audioSources, initialIndex: indexInWindow);
        startIfWanted();
        return;
      }

      AudioSource source;
      if (songInfo != null) {
        source = _buildAudioSource(songInfo);
      } else {
        if (path.startsWith('http://') || path.startsWith('https://')) {
          source = AudioSource.uri(Uri.parse(path));
        } else {
          final cleanPath = path.startsWith('file://') ? Uri.parse(path).toFilePath() : path;
          source = AudioSource.uri(Uri.file(cleanPath));
        }
      }
      await player.setAudioSource(source);
      await player.setLoopMode(LoopMode.off);
      startIfWanted();
    } on PlayerInterruptedException {
      _logger.i('Audio loading interrupted by user/new playback request.');
    } catch (e) {
      if (e.toString().contains('Loading interrupted')) {
        _logger.i('Audio loading interrupted: $e');
        return;
      }
      _logger.e('Error playing audio source ($path): $e');
      rethrow;
    }
  }

  Future<void> playQueue(List<Song> queue, {required int initialIndex}) async {
    final validQueue = queue.where((s) => s.filePath.trim().isNotEmpty).toList();
    if (validQueue.isEmpty) return;
    try {
      final safeIndex = initialIndex.clamp(0, validQueue.length - 1);
      final (window, indexInWindow) = _buildWindowWithIndex(validQueue, safeIndex);
      final audioSources = window.map(_buildAudioSource).toList();
      await player.setAudioSources(audioSources, initialIndex: indexInWindow);
      _startPlayback();
    } on PlayerInterruptedException {
      _logger.i('Queue playback interrupted by new request.');
    } catch (e) {
      if (e.toString().contains('Loading interrupted')) return;
      _logger.e('Error playing audio queue: $e');
      rethrow;
    }
  }

  /// Appends songs to the end of the player's playlist so the player (and the
  /// notification / lock-screen controls) can advance to them.
  /// JioSaavn songs with empty filePath are skipped here — they will be
  /// resolved and appended individually by PlayerBloc once their stream URL
  /// is fetched (see _preResolveNextTrack and _expandQueueInternal).
  Future<void> addSongsToQueue(List<Song> songs) {
    final validSongs = songs.where((s) => s.filePath.trim().isNotEmpty).toList();
    if (validSongs.isEmpty) return Future<void>.value();
    return _playlistEdits.run((_) => _addSongs(validSongs));
  }

  /// Every change to the player's playlist goes through this queue, so two
  /// edits never interleave (see [EditQueue]).
  final EditQueue _playlistEdits = EditQueue();

  Future<void> _addSongs(List<Song> validSongs) async {
    // Nothing loaded yet: the next play() call builds the playlist.
    if (_audioPlayer == null || player.sequence.isEmpty) return;
    try {
      // just_audio 0.10 manages the playlist on the player itself;
      // `player.audioSource` is only the first item, never a concatenation.
      final existingIds = player.sequence.map((s) {
        final tag = s.tag;
        return tag is MediaItem ? tag.id : null;
      }).whereType<String>().toSet();

      final toAdd = validSongs.where((s) => !existingIds.contains(s.id.toString())).toList();
      if (toAdd.isNotEmpty) {
        await player.addAudioSources(toAdd.map(_buildAudioSource).toList());
        _logger.i('AudioPlayerService: Added ${toAdd.length} songs to the player playlist.');
      }
    } catch (e) {
      _logger.w('AudioPlayerService: Error adding songs to queue: $e');
    }
  }

  /// Replaces everything after [current] in the player's playlist with
  /// [upcoming], so natural track changes follow the app's queue order after
  /// "Play Next", removals, reordering or shuffle. The playing item is never
  /// touched, so playback does not restart.
  ///
  /// Syncs run one at a time and only the newest counts: tapping Radio several
  /// times used to start overlapping syncs whose removes and adds interleaved,
  /// leaving songs from several lists in the player that the app's queue did
  /// not know about, so a different song started when the current one ended.
  Future<void> syncUpcoming(Song current, List<Song> upcoming) =>
      _playlistEdits.run((superseded) => _syncUpcoming(current, upcoming, superseded), latestWins: true);

  Future<void> _syncUpcoming(Song current, List<Song> upcoming, bool Function() superseded) async {
    if (_audioPlayer == null) return;
    final sequence = player.sequence;
    final index = player.currentIndex;
    if (sequence.isEmpty || index == null || index >= sequence.length) return;
    final tag = sequence[index].tag;
    // Only sync while the player is actually on the app's current song.
    if (tag is! MediaItem || tag.id != current.id.toString()) return;
    try {
      if (index + 1 < sequence.length) {
        await player.removeAudioSourceRange(index + 1, sequence.length);
      }
      if (superseded()) return; // a newer sync runs next and adds its own list
      final playable = upcoming
          .where((s) => s.filePath.trim().isNotEmpty && s.id != current.id)
          .take(_maxWindowSize)
          .toList();
      if (playable.isNotEmpty) {
        await player.addAudioSources(playable.map(_buildAudioSource).toList());
      }
    } catch (e) {
      _logger.w('AudioPlayerService: Error syncing upcoming songs: $e');
    }
  }

  double get volume => _audioPlayer?.volume ?? 1.0;

  /// Asks Android for audio focus again. When another app (Instagram, a call)
  /// takes focus while we keep "playing", Android 12+ silently mutes our
  /// stream until we hold focus again, leaving the player running with no
  /// sound. Returns false if focus was refused (someone else is still using
  /// audio), in which case playback should be paused rather than left silent.
  Future<bool> ensureAudioFocus() async {
    try {
      final session = await AudioSession.instance;
      return await session.setActive(true);
    } catch (e) {
      _logger.w('AudioPlayerService: could not re-request audio focus: $e');
      return true; // unknown; don't pause on an error
    }
  }

  Future<void> setLoopMode(LoopMode mode) => player.setLoopMode(mode);

  Future<void> pause() => player.pause();

  Future<void> resume() async => _startPlayback();

  Future<void> stop() => player.stop();

  Future<void> seek(Duration position) async {
    try {
      await player.seek(position);
    } on PlayerInterruptedException {
      // Seek interrupted by a subsequent seek - normal during scrubbing or fast tapping
    } catch (e) {
      if (e.toString().contains('Loading interrupted')) return;
      _logger.w('Audio seek warning: $e');
    }
  }

  Future<void> setVolume(double volume) => player.setVolume(volume.clamp(0.0, 1.0));

  Future<void> setSpeed(double speed) => player.setSpeed(speed.clamp(0.5, 2.0));

  Future<void> setPlaybackRate(double rate) => setSpeed(rate);

  Future<void> seekToNext() async {
    if (player.hasNext) {
      await player.seekToNext();
    }
  }

  Future<void> seekToPrevious() async {
    if (player.hasPrevious) {
      await player.seekToPrevious();
    }
  }

  Future<void> seekToIndex(int index) async {
    if (index >= 0 && index < player.sequence.length) {
      await player.seek(Duration.zero, index: index);
    }
  }

  Stream<int?> get currentIndexStream => player.currentIndexStream;

  Stream<Duration> get positionStream => player.positionStream;

  Stream<PlayerState> get playerStateStream => player.playerStateStream;

  Stream<bool> get playingStream => player.playingStream;

  Stream<Duration?> get durationStream => player.durationStream;

  int? get currentIndex => _audioPlayer?.currentIndex;

  Duration get position => _audioPlayer?.position ?? Duration.zero;

  Duration? get duration => _audioPlayer?.duration;

  bool get isPlaying => _audioPlayer?.playing ?? false;

  void dispose() {
    _audioPlayer?.dispose();
    _audioPlayer = null;
  }
}
