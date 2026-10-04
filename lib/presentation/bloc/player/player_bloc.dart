import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:just_audio/just_audio.dart' hide PlayerEvent, PlayerState;
import 'package:just_audio_background/just_audio_background.dart';
import 'package:rxdart/rxdart.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/data/repositories/music_repository.dart';
import 'package:vinyl/services/audio_service.dart';
import 'package:vinyl/services/settings_service.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/core/utils/jiosaavn_decoder.dart';
import 'package:vinyl/core/utils/song_dedupe.dart';
import 'package:vinyl/core/utils/song_origin.dart';
import 'package:vinyl/services/stream_cache_service.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_service.dart';
import 'package:vinyl/services/user_taste_service.dart';

/// Restartable event transformer using RxDart's switchMap to drop superseded play events.
EventTransformer<E> restartable<E>() {
  return (events, mapper) => events.switchMap(mapper);
}

class PlayerBloc extends Bloc<PlayerEvent, PlayerState> {
  final AudioPlayerService _audioService;

  /// Songs in, suggested songs out. Autoplay uses [_suggestions]; Radio uses
  /// [_radioSuggestions], which also adds the credited artists' other songs.
  /// When none is given (tests, or an app without the setup) a standard one is
  /// created on first use.
  final SuggestionService? _suggestionService;
  final SuggestionService? _radioSuggestionService;
  late final SuggestionService _fallbackService = SuggestionService.standard(
    language: () => _streamLanguage,
    tasteBoost: _tasteBoost,
  );
  SuggestionService get _suggestions => _suggestionService ?? _fallbackService;
  SuggestionService get _radioSuggestions => _radioSuggestionService ?? _suggestionService ?? _fallbackService;

  static double _tasteBoost(JioSaavnItem item) =>
      UserTasteService.instance.likeness(item) * SuggestionService.maxTasteBoost;

  /// The songs Autoplay asks suggestions for: up to [_maxAutoplaySeeds] of the
  /// user's own queue, so the queue continues what they have been listening to
  /// rather than a single song.
  ///
  /// In this order: the song the user picked, the song playing now, then the
  /// songs played just before it (nearest first), then any still to come. Songs
  /// that Autoplay itself added are skipped (suggestions of suggestions drift
  /// away from the user's taste).
  static const int _maxAutoplaySeeds = 5;

  List<SeedSong> _autoplaySeeds(Song anchor) {
    final ordered = <Song>[anchor];
    final current = _currentSong;
    if (current != null) ordered.add(current);

    final currentIndex = current == null ? -1 : _queue.indexWhere((s) => s.id == current.id);
    if (currentIndex != -1) {
      ordered.addAll(_queue.sublist(0, currentIndex).reversed); // played before, nearest first
      ordered.addAll(_queue.sublist(currentIndex + 1)); // still to come
    }

    final seen = <int>{};
    final seeds = <SeedSong>[];
    for (final song in ordered) {
      if (song.id != anchor.id && _autoplayIds.contains(song.id)) continue; // not the user's own pick
      if (!seen.add(song.id)) continue;
      seeds.add(SeedSong.fromSong(song));
      if (seeds.length >= _maxAutoplaySeeds) break;
    }
    return seeds;
  }

  /// Starts MetaBrainz's slow lookup for a song that has just begun, so its
  /// answer is ready by the time Autoplay or Radio needs it. Stream songs only:
  /// Library songs continue from the Library.
  void _warmUpSuggestions(Song song) {
    if (_isLibrarySong(song)) return;
    try {
      _suggestions.warmUp(SeedSong.fromSong(song));
    } catch (_) {}
  }

  /// Songs that must not come back as suggestions: the queue and what was
  /// played recently.
  List<SeedSong> _excluded(Iterable<Song> recent) =>
      [..._queue, ...recent].map(SeedSong.fromSong).toList();
  final MusicRepository? _repository;
  final SettingsService? _settingsService;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _currentIndexSubscription;
  StreamSubscription? _playingSubscription;

  Song? _currentSong;
  List<Song> _queue = [];
  List<Song> _originalQueue = []; // Preserved for restoring order after shuffle
  bool _isShuffle = false;
  bool _isRepeat = false;
  bool _autoPlayNext = true;
  String _repeatMode = 'Off';
  bool _isChangingSong = false;
  int _consecutiveFailures = 0;
  int _playGeneration = 0;
  // Generation of the play request that currently owns [_isChangingSong].
  // Only that request may clear the flag, so a stale request can't unlock a
  // newer load, and a request cancelled by pause/stop can't leave it stuck.
  int _changingSongOwner = 0;
  // The song the user last picked themselves (tap in a list, queue jump,
  // radio). Autoplay seeds from it so recommendations stay on what the user
  // chose instead of chaining off its own earlier picks.
  Song? _autoplayAnchor;
  // Songs Autoplay appended after the user's own queue. Kept apart so they
  // are never shuffled in among the user's songs.
  final Set<int> _autoplayIds = {};

  /// True for songs that belong to the Library (imported or downloaded),
  /// false for Stream songs (including ones cached for offline). Autoplay
  /// never mixes the two: Library continues from Library, Stream from Stream.
  static bool _isLibrarySong(Song s) => SongOrigin.isLibrary(s);
  bool _isExpandingQueue = false;
  // Completes when the Autoplay fetch that is running now has finished, so a
  // Next tap at the end of the queue can wait for it instead of giving up.
  Completer<void>? _expansionDone;

  void _showToast(String message) {
    try {
      Fluttertoast.showToast(
        msg: message,
        toastLength: Toast.LENGTH_SHORT,
      );
    } catch (_) {}
  }

  PlayerBloc({
    required AudioPlayerService audioService,
    MusicRepository? repository,
    SettingsService? settingsService,
    SuggestionService? suggestionService,
    SuggestionService? radioSuggestionService,
  })  : _audioService = audioService,
        _repository = repository,
        _settingsService = settingsService,
        _suggestionService = suggestionService,
        _radioSuggestionService = radioSuggestionService ?? suggestionService,
        super(const PlayerInitial()) {
    _isShuffle = settingsService?.shuffleByDefault ?? false;
    _autoPlayNext = settingsService?.autoPlayNext ?? true;
    _repeatMode = settingsService?.repeatMode ?? 'Off';
    _isRepeat = _repeatMode != 'Off';

    on<PlaySongEvent>(_onPlaySong, transformer: restartable());
    on<PlayQueueEvent>(_onPlayQueue, transformer: restartable());
    on<PlaySongAtIndexEvent>(_onPlaySongAtIndex, transformer: restartable());
    on<InsertNextEvent>(_onInsertNext);
    on<AddToQueueEvent>(_onAddToQueue);
    on<AddSongsToQueueEvent>(_onAddSongsToQueue);
    on<RemoveFromQueueEvent>(_onRemoveFromQueue);
    on<ReorderQueueEvent>(_onReorderQueue);
    on<ClearQueueEvent>(_onClearQueue);
    on<PauseEvent>(_onPause);
    on<ResumeEvent>(_onResume);
    on<StopEvent>(_onStop);
    on<SeekEvent>(_onSeek);
    on<SetVolumeEvent>(_onSetVolume);
    on<SetPlaybackRateEvent>(_onSetPlaybackRate);
    on<NextSongEvent>(_onNextSong, transformer: restartable());
    on<PreviousSongEvent>(_onPreviousSong, transformer: restartable());
    on<ToggleShuffleEvent>(_onToggleShuffle);
    on<SetShuffleEvent>(_onSetShuffle);
    on<ToggleRepeatEvent>(_onToggleRepeat);
    on<SetRepeatModeEvent>(_onSetRepeatMode);
    on<SetAutoPlayNextEvent>(_onSetAutoPlayNext);
    on<RestoreLastPlayedEvent>(_onRestoreLastPlayed);
    on<ResyncPlaybackEvent>(_onResyncPlayback);
    on<PositionChangedEvent>(_onPositionChanged);
    on<DurationChangedEvent>(_onDurationChanged);
    on<TrackChangedEvent>(_onTrackChanged);
    on<StartRadioEvent>(_onStartRadio);
    on<AutoExpandQueueEvent>(_onAutoExpandQueue);

    _listenToStreams();
    add(const RestoreLastPlayedEvent());
  }

  void _listenToStreams() {
    _positionSubscription = _audioService.positionStream.listen((pos) {
      add(PositionChangedEvent(pos));
    });

    _durationSubscription = _audioService.durationStream.listen((dur) {
      if (dur != null) {
        add(DurationChangedEvent(dur));
      }
    });

    _currentIndexSubscription = _audioService.currentIndexStream.listen((index) {
      if (index != null && index >= 0 && !_isChangingSong) {
        final sequence = _audioService.player.sequenceState.sequence;
        if (sequence.isNotEmpty && index < sequence.length) {
          final tag = sequence[index].tag;
          if (tag is MediaItem) {
            final songId = int.tryParse(tag.id);
            if (songId != null) {
              if (_currentSong?.id == songId) return;

              final matching = _queue.where((s) => s.id == songId);
              if (matching.isNotEmpty) {
                final newSong = matching.first;
                add(TrackChangedEvent(
                  newSong,
                  sequenceIndex: index,
                  sequenceLength: sequence.length,
                ));
                return;
              }
            }
          }
        }
        // Fallback for tests/mocks: only if sequence is uninitialized but playback is already actively running
        // and index is valid in _queue, and newSong is actually different from _currentSong.
        if (sequence.isEmpty && state is PlayerPlaying && index < _queue.length) {
          final newSong = _queue[index];
          if (_currentSong?.id != newSong.id) {
            add(TrackChangedEvent(
              newSong,
              sequenceIndex: index,
              sequenceLength: _queue.length,
            ));
          }
        }
      }
    });

    _playerStateSubscription = _audioService.playerStateStream.listen((playerState) async {
      final procState = playerState.processingState;
      final isPlaying = playerState.playing;

      // Ignore every intermediate event (including a stale "completed" from the
      // previous source) while a new song is being loaded.
      if (_isChangingSong) return;

      if (procState == ProcessingState.completed) {
        if (_currentSong != null) {
          UserTasteService.instance.onSongCompleted(_currentSong!);
        }
        if (_repeatMode == 'One' && _currentSong != null) {
          add(PlaySongEvent(_currentSong!));
        } else if (_autoPlayNext || _repeatMode == 'All') {
          add(const NextSongEvent());
        } else {
          add(const PauseEvent());
          await _audioService.seek(Duration.zero);
        }
        return;
      }

      if (!isPlaying) {
        if (state is PlayerPlaying || state is PlayerLoading) {
          add(const PauseEvent());
        }
        return;
      }

      if (isPlaying && (state is PlayerPaused || state is PlayerStopped)) {
        add(const ResumeEvent());
      }
    });
  }

  bool _isPlayerOnCurrentSong() {
    if (_currentSong == null) return false;
    final tag = _audioService.player.sequenceState.currentSource?.tag;
    if (tag is MediaItem) {
      return tag.id == _currentSong!.id.toString();
    }
    return true;
  }

  DateTime _lastResumePointSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// Saves the "resume last song" point. Position ticks arrive many times a
  /// second, so writes are throttled; pausing saves immediately.
  void _saveResumePoint(Song song, Duration position, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastResumePointSave) < const Duration(seconds: 5)) return;
    _lastResumePointSave = now;
    _settingsService?.setLastPlayedSongId(song.id);
    _settingsService?.setLastPlayedPositionMs(position.inMilliseconds);
  }

  void _onPositionChanged(PositionChangedEvent event, Emitter<PlayerState> emit) {
    if (_isChangingSong || !_isPlayerOnCurrentSong()) return;

    if (state is PlayerPlaying) {
      final current = state as PlayerPlaying;
      _currentSong = current.song;
      _saveResumePoint(current.song, event.position);
      UserTasteService.instance.onPlaybackProgress(current.song, event.position, current.duration);

      if (!_audioService.isPlaying) {
        emit(PlayerPaused(
          song: current.song,
          position: event.position,
          duration: current.duration,
          isShuffle: _isShuffle,
          isRepeat: _isRepeat,
          repeatMode: _repeatMode,
          queue: List.from(_queue),
        ));
      } else {
        emit(current.copyWith(position: event.position));
      }
    } else if (state is PlayerPaused) {
      final current = state as PlayerPaused;
      _currentSong = current.song;
      _saveResumePoint(current.song, event.position);
      emit(current.copyWith(position: event.position));
    }
  }

  void _onDurationChanged(DurationChangedEvent event, Emitter<PlayerState> emit) {
    if (event.duration <= Duration.zero) return;
    if (_isChangingSong || !_isPlayerOnCurrentSong()) return;

    if (_currentSong != null && _currentSong!.duration != event.duration) {
      _currentSong = _currentSong!.copyWith(duration: event.duration);
      final idx = _queue.indexWhere((s) => s.id == _currentSong!.id);
      if (idx != -1) {
        _queue[idx] = _currentSong!;
      }
      _repository?.updateSong(_currentSong!, notify: false);
    }

    if (state is PlayerPlaying) {
      final current = state as PlayerPlaying;
      emit(current.copyWith(song: _currentSong, duration: event.duration));
    } else if (state is PlayerPaused) {
      final current = state as PlayerPaused;
      emit(current.copyWith(song: _currentSong, duration: event.duration));
    }
  }

  /// Shared internal play method
  Future<void> _playSongInternal(Song song, Emitter<PlayerState> emit) async {
    // Tapping the song that is already playing is a no-op; it must not cancel
    // or unlock anything, so bail out before claiming a generation.
    if (_currentSong?.id == song.id &&
        state is PlayerPlaying &&
        _audioService.player.playing &&
        _audioService.player.processingState != ProcessingState.completed) {
      return;
    }

    final generation = ++_playGeneration;

    final previousSong = _currentSong;

    _isChangingSong = true;
    _changingSongOwner = generation;
    try {
      _currentSong = song;
      emit(PlayerLoading(
        song: song,
        queue: List.from(_queue),
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        repeatMode: _repeatMode,
      ));
      Song songToPlay = song;
      if (songToPlay.filePath.isEmpty && songToPlay.source == 'jiosaavn') {
        try {
          final lookupKey = (songToPlay.mediaId != null && songToPlay.mediaId!.isNotEmpty)
              ? songToPlay.mediaId!
              : songToPlay.id.toString();
          final details = await JioSaavnDecoder.fetchSongDetails(lookupKey);
          if (generation != _playGeneration) return;
          final streamUrl = details?.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(details?.encryptedMediaUrl);
          if (streamUrl != null && streamUrl.isNotEmpty) {
            songToPlay = songToPlay.copyWith(filePath: streamUrl);
            final qIndex = _queue.indexWhere((s) => s.id == songToPlay.id);
            if (qIndex != -1) _queue[qIndex] = songToPlay;
          }
        } catch (_) {}
      }

      if (generation != _playGeneration) return;

      final isRemoteStream = songToPlay.filePath.startsWith('http://') || songToPlay.filePath.startsWith('https://');
      if (isRemoteStream) {
        final cachedPath = StreamCacheService.instance.getCachedFilePath(songToPlay.id);
        if (cachedPath != null && File(cachedPath).existsSync()) {
          songToPlay = songToPlay.copyWith(filePath: cachedPath);
        }
      }

      await _audioService.play(
        songToPlay.filePath,
        songInfo: songToPlay,
        queue: _queue,
        isCancelled: () => generation != _playGeneration,
      );
      if (generation != _playGeneration) return;

      await _updateAudioPlayerRepeatMode();
      if (generation != _playGeneration) return;

      Duration dur = song.duration;
      final playerTag = _audioService.player.sequenceState.currentSource?.tag;
      final playerSongId = (playerTag is MediaItem) ? playerTag.id : null;
      final isPlayerReadyWithSong = (playerSongId == null || playerSongId == song.id.toString()) &&
          _audioService.player.processingState != ProcessingState.loading &&
          _audioService.player.processingState != ProcessingState.idle;

      if (isPlayerReadyWithSong &&
          _audioService.player.duration != null &&
          _audioService.player.duration! > Duration.zero) {
        dur = _audioService.player.duration!;
      }

      final Song activeSong = (dur > Duration.zero && songToPlay.duration != dur)
          ? songToPlay.copyWith(duration: dur)
          : songToPlay;
      _currentSong = activeSong;
      _repository?.updateSong(activeSong, notify: false);
      await _repository?.recordSongPlay(activeSong);
      UserTasteService.instance.onSongStarted(activeSong);
      _warmUpSuggestions(activeSong);

      emit(PlayerPlaying(
        song: activeSong,
        position: Duration.zero,
        duration: dur,
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        repeatMode: _repeatMode,
        queue: _queue,
      ));
      if ((_settingsService?.cacheStreamSongs ?? true) &&
          isRemoteStream &&
          songToPlay.filePath == song.filePath) {
        Future.delayed(const Duration(seconds: 4), () {
          if (_currentSong?.id == activeSong.id) {
            unawaited(StreamCacheService.instance.cacheSong(activeSong));
          }
        });
      }
      _consecutiveFailures = 0;
      _releaseChangingSong(generation);
      _preResolveNextTrack();
    } catch (e) {
      if (generation != _playGeneration ||
          e is PlayerInterruptedException ||
          e.toString().contains('Loading interrupted')) {
        return;
      }
      _consecutiveFailures++;
      debugPrint('Failed to play song (${song.filePath}): $e');
      _showToast('Cannot play "${song.title}". Skipping to next track...');
      emit(PlayerError('Failed to play song: $e'));

      // If queue has other songs and we haven't reached max consecutive error threshold (3)
      if (_queue.length > 1 && _consecutiveFailures < 3 && _consecutiveFailures < _queue.length) {
        final nextSong = _getNextSong(song);
        if (nextSong != null && nextSong.id != song.id && (nextSong.filePath.trim().isNotEmpty || nextSong.source == 'jiosaavn')) {
          await Future.delayed(const Duration(milliseconds: 300));
          if (generation != _playGeneration) return;
          await _playSongInternal(nextSong, emit);
          return;
        }
      }

      // If all tracks in queue failed or queue only has 1 track or hit 3 errors
      _consecutiveFailures = 0;
      _currentSong = previousSong;
      if (_queue.length > 1) {
        _showToast('Unable to play tracks in queue.');
      }
      emit(PlayerPaused(
        song: song,
        position: Duration.zero,
        duration: song.duration,
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        repeatMode: _repeatMode,
        queue: _queue,
      ));
    } finally {
      _releaseChangingSong(generation);
    }
  }

  /// Clears [_isChangingSong] if the request with [generation] still owns it.
  /// A request cancelled by pause/stop (rather than by a newer play) still owns
  /// the flag and must release it, otherwise Next/Previous stay disabled.
  void _releaseChangingSong(int generation) {
    if (_changingSongOwner != generation) return;
    _isChangingSong = false;
  }

  Song? _getNextSong(Song current) {
    final validQueue = _queue.where((s) => s.filePath.trim().isNotEmpty || s.source == 'jiosaavn').toList();
    if (validQueue.isEmpty) return null;
    // With shuffle on, _queue itself is already in shuffled order (see
    // _applyShuffleQueueState / _onPlaySong), so "next" is simply the next
    // entry. Picking a random song here as well repeated songs and pulled
    // Autoplay songs in before the user's own songs had finished.
    final currentIndex = validQueue.indexWhere((s) => s.id == current.id);
    if (currentIndex != -1 && currentIndex < validQueue.length - 1) {
      return validQueue[currentIndex + 1];
    } else if (validQueue.isNotEmpty && (_repeatMode == 'All' || _isRepeat)) {
      return validQueue.first; // Wrap around if repeating all
    }
    return null;
  }

  Future<void> _onPlaySong(PlaySongEvent event, Emitter<PlayerState> emit) async {
    if (event.song.filePath.trim().isEmpty && event.song.source != 'jiosaavn') {
      _showToast('Invalid audio stream URL.');
      return;
    }
    if (event.queue != null && event.queue!.isNotEmpty) {
      final valid = event.queue!.where((s) => s.filePath.trim().isNotEmpty || s.source == 'jiosaavn').toList();
      if (valid.isNotEmpty) {
        _queue = List.from(valid);
        _originalQueue = List.from(valid);
        _autoplayIds.clear();
        if (_isShuffle) {
          // Shuffle order is stored in the queue itself: tapped song first,
          // then the rest in random order, each played exactly once.
          _queue.shuffle();
          _queue.removeWhere((s) => s.id == event.song.id);
          _queue.insert(0, event.song);
        }
      }
    } else if (!_queue.any((s) => s.id == event.song.id)) {
      _queue.add(event.song);
      _originalQueue.add(event.song);
    }
    _consecutiveFailures = 0;
    _autoplayAnchor = event.song;
    await _playSongInternal(event.song, emit);
    add(const AutoExpandQueueEvent());
  }

  Future<void> _onPlayQueue(PlayQueueEvent event, Emitter<PlayerState> emit) async {
    final validSongs = event.queue.where((s) => s.filePath.trim().isNotEmpty || s.source == 'jiosaavn').toList();
    if (validSongs.isEmpty) return;
    _queue = List.from(validSongs);
    _originalQueue = List.from(validSongs);
    _autoplayIds.clear();

    final safeIndex = event.initialIndex.clamp(0, validSongs.length - 1);
    final targetSong = validSongs[safeIndex];

    if (_isShuffle) {
      _queue.shuffle();
      _queue.removeWhere((s) => s.id == targetSong.id);
      _queue.insert(0, targetSong);
    }

    _consecutiveFailures = 0;
    _currentSong = null;
    _autoplayAnchor = targetSong;
    await _playSongInternal(targetSong, emit);
    add(const AutoExpandQueueEvent());
  }

  Future<void> _onPlaySongAtIndex(PlaySongAtIndexEvent event, Emitter<PlayerState> emit) async {
    if (event.index < 0 || event.index >= _queue.length) return;
    _consecutiveFailures = 0;
    _autoplayAnchor = _queue[event.index];
    await _playSongInternal(_queue[event.index], emit);
    add(const AutoExpandQueueEvent());
  }

  Future<void> _onInsertNext(InsertNextEvent event, Emitter<PlayerState> emit) async {
    if (_queue.isEmpty) {
      _queue = [event.song];
      _originalQueue = [event.song];
      await _playSongInternal(event.song, emit);
      return;
    }

    // Remove if already in queue to prevent duplicate confusion. This must
    // happen before locating the current song: removing an earlier entry
    // shifts the current song's index down by one.
    _queue.removeWhere((s) => s.id == event.song.id);
    _originalQueue.removeWhere((s) => s.id == event.song.id);

    int indexAfterCurrent(List<Song> list) {
      final i = _currentSong != null ? list.indexWhere((s) => s.id == _currentSong!.id) : -1;
      return i != -1 ? i + 1 : list.length;
    }

    _queue.insert(indexAfterCurrent(_queue), event.song);
    _originalQueue.insert(indexAfterCurrent(_originalQueue), event.song);

    _emitUpdatedQueueState(emit);
  }

  Future<void> _onAddToQueue(AddToQueueEvent event, Emitter<PlayerState> emit) async {
    if (_queue.isEmpty) {
      _queue = [event.song];
      _originalQueue = [event.song];
      await _playSongInternal(event.song, emit);
      return;
    }

    if (!_queue.any((s) => s.id == event.song.id)) {
      _queue.add(event.song);
      _originalQueue.add(event.song);
    }

    _emitUpdatedQueueState(emit);
  }

  Future<void> _onAddSongsToQueue(AddSongsToQueueEvent event, Emitter<PlayerState> emit) async {
    final validSongs = event.songs.where((s) => s.filePath.trim().isNotEmpty || s.source == 'jiosaavn').toList();
    if (validSongs.isEmpty) return;

    if (_queue.isEmpty) {
      _queue = List.from(validSongs);
      _originalQueue = List.from(validSongs);
      await _playSongInternal(validSongs.first, emit);
      return;
    }

    final existingIds = _queue.map((s) => s.id).toSet();
    final toAdd = validSongs.where((s) => !existingIds.contains(s.id)).toList();
    if (toAdd.isNotEmpty) {
      _queue.addAll(toAdd);
      _originalQueue.addAll(toAdd);
      _emitUpdatedQueueState(emit);
    }
  }

  Future<void> _onRemoveFromQueue(RemoveFromQueueEvent event, Emitter<PlayerState> emit) async {
    if (event.index < 0 || event.index >= _queue.length) return;

    final removedSong = _queue.removeAt(event.index);
    _originalQueue.removeWhere((s) => s.id == removedSong.id);

    if (removedSong.id == _currentSong?.id) {
      if (_queue.isNotEmpty) {
        final nextIndex = event.index.clamp(0, _queue.length - 1);
        await _playSongInternal(_queue[nextIndex], emit);
      } else {
        await _onStop(const StopEvent(), emit);
      }
    } else {
      _emitUpdatedQueueState(emit);
    }
  }

  void _onReorderQueue(ReorderQueueEvent event, Emitter<PlayerState> emit) {
    if (event.oldIndex < 0 || event.oldIndex >= _queue.length) return;
    int newIndex = event.newIndex;
    if (newIndex > event.oldIndex) newIndex -= 1;
    newIndex = newIndex.clamp(0, _queue.length - 1);

    final item = _queue.removeAt(event.oldIndex);
    _queue.insert(newIndex, item);

    _emitUpdatedQueueState(emit);
  }

  void _onClearQueue(ClearQueueEvent event, Emitter<PlayerState> emit) {
    _queue.clear();
    _originalQueue.clear();
    if (_currentSong != null) {
      _queue.add(_currentSong!);
      _originalQueue.add(_currentSong!);
    }
    _emitUpdatedQueueState(emit);
  }

  /// The user's Streaming Language setting, read fresh so a change in
  /// Settings applies to the next Radio / Autoplay fetch.
  String get _streamLanguage {
    final lang = _settingsService?.streamLanguage.trim() ?? '';
    return lang.isNotEmpty ? lang : 'hindi';
  }

  Future<void> _onStartRadio(StartRadioEvent event, Emitter<PlayerState> emit) async {
    final currentSong = _currentSong ?? event.song;
    _showToast('Starting radio for "${currentSong.title}"...');

    try {
      final recent = _repository != null
          ? await _repository.getLastPlayedStreamSongs(limit: 20)
          : <Song>[];
      final suggestions = await _radioSuggestions.suggest(
        [SeedSong.fromSong(currentSong)],
        limit: 25,
        exclude: _excluded(recent),
      );
      List<Song> radioSongs = [for (final s in suggestions) s.toSong()];

      // Fallback to artist search if recommendations are empty
      if (radioSongs.isEmpty && currentSong.artist.trim().isNotEmpty && currentSong.artist != 'Unknown') {
        final artistResults = await JioSaavnDecoder.searchSongs(currentSong.artist.trim());
        radioSongs = artistResults
            .where((item) => item.isSong && item.title.trim().isNotEmpty)
            .map((item) => item.toSong())
            .where((s) =>
                s.filePath.trim().isNotEmpty &&
                s.title.trim().toLowerCase() != currentSong.title.trim().toLowerCase())
            .take(20)
            .toList();
      }

      if (radioSongs.isEmpty) {
        _showToast('Could not find radio tracks for "${currentSong.title}".');
        return;
      }

      // Populate queue with current track followed by radio tracks
      _autoplayAnchor = currentSong;
      _autoplayIds.clear();
      _queue = [currentSong, ...radioSongs];
      _originalQueue = List.from(_queue);

      if (state is! PlayerPlaying && state is! PlayerPaused) {
        await _playSongInternal(currentSong, emit);
      } else {
        _emitUpdatedQueueState(emit);
      }

      _showToast('Radio station started! Added ${radioSongs.length} tracks.');
    } catch (e) {
      debugPrint('Error starting radio: $e');
      _showToast('Failed to start radio.');
    }
  }

  /// Pushes the app queue's upcoming order into the player's playlist, so a
  /// song that ends naturally is followed by the right next song.
  void _syncPlayerUpcoming() {
    final current = _currentSong;
    if (current == null || _isChangingSong) return;
    final index = _queue.indexWhere((s) => s.id == current.id);
    if (index == -1) return;
    unawaited(_audioService.syncUpcoming(current, _queue.sublist(index + 1)));
  }

  /// Emits the new queue and syncs it into the player. Every queue mutation
  /// (play next, add, remove, reorder, clear, shuffle, auto-expand) goes
  /// through here.
  void _emitUpdatedQueueState(Emitter<PlayerState> emit) {
    _syncPlayerUpcoming();
    if (state is PlayerPlaying) {
      emit((state as PlayerPlaying).copyWith(
        queue: List.from(_queue),
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        repeatMode: _repeatMode,
      ));
    } else if (state is PlayerPaused) {
      emit((state as PlayerPaused).copyWith(
        queue: List.from(_queue),
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        repeatMode: _repeatMode,
      ));
    } else if (state is PlayerLoading) {
      final loading = state as PlayerLoading;
      emit(PlayerLoading(
        song: loading.song,
        queue: List.from(_queue),
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        repeatMode: _repeatMode,
      ));
    }
  }

  Future<void> _onPause(PauseEvent event, Emitter<PlayerState> emit) async {
    _playGeneration++;
    final song = (state is PlayerPlaying)
        ? (state as PlayerPlaying).song
        : ((state is PlayerLoading) ? (state as PlayerLoading).song : _currentSong);
    if (song != null) {
      _currentSong = song;
      final pos = _audioService.player.position;
      final dur = _audioService.player.duration ?? song.duration;
      _saveResumePoint(song, pos, force: true);
      emit(PlayerPaused(
        song: song,
        position: pos,
        duration: dur,
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        repeatMode: _repeatMode,
        queue: List.from(_queue),
      ));
    }
    try {
      if (_audioService.isPlaying) {
        await _audioService.pause();
      }
    } catch (e) {
      debugPrint('Error pausing player: $e');
    }
  }

  Future<void> _onResume(ResumeEvent event, Emitter<PlayerState> emit) async {
    final song = (state is PlayerPaused)
        ? (state as PlayerPaused).song
        : ((state is PlayerLoading) ? (state as PlayerLoading).song : _currentSong);
    if (song != null) {
      _currentSong = song;
      await _repository?.recordSongPlay(song);
      final pos = _audioService.player.position;
      final dur = _audioService.player.duration ?? song.duration;
      emit(PlayerPlaying(
        song: song,
        position: pos,
        duration: dur,
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        repeatMode: _repeatMode,
        queue: List.from(_queue),
      ));
    }
    try {
      if (!_audioService.isPlaying) {
        await _audioService.resume();
      }
    } catch (e) {
      debugPrint('Error resuming player: $e');
    }
  }

  Future<void> _onResyncPlayback(ResyncPlaybackEvent event, Emitter<PlayerState> emit) async {
    if (_isChangingSong) return;
    final playerIsPlaying = _audioService.isPlaying;

    if (state is PlayerPlaying && !playerIsPlaying) {
      // Screen says playing, the player was paused (e.g. by an interruption).
      add(const PauseEvent());
      return;
    }
    if (state is PlayerPaused && playerIsPlaying) {
      add(const ResumeEvent());
      return;
    }
    if (state is! PlayerPlaying || !playerIsPlaying) return;

    // Both say "playing". Make sure it is audible: another app may have taken
    // audio focus meanwhile, which leaves the player running but muted.
    final hasFocus = await _audioService.ensureAudioFocus();
    if (!hasFocus) {
      // Someone else is using audio and refused us: pause so the screen
      // shows the truth instead of a silent "playing".
      add(const PauseEvent());
      return;
    }
    final expectedVolume = (state as PlayerPlaying).volume;
    if ((_audioService.volume - expectedVolume).abs() > 0.01) {
      await _audioService.setVolume(expectedVolume);
    }
  }

  Future<void> _onStop(StopEvent event, Emitter<PlayerState> emit) async {
    _playGeneration++;
    try {
      await _audioService.stop();
      emit(const PlayerStopped());
    } catch (e) {
      emit(PlayerError('Failed to stop: $e'));
    }
  }

  Future<void> _onSeek(SeekEvent event, Emitter<PlayerState> emit) async {
    try {
      await _audioService.seek(event.position);
      _settingsService?.setLastPlayedPositionMs(event.position.inMilliseconds);
      if (state is PlayerPlaying) {
        final playing = state as PlayerPlaying;
        emit(playing.copyWith(position: event.position));
      } else if (state is PlayerPaused) {
        final paused = state as PlayerPaused;
        emit(paused.copyWith(position: event.position));
      }
    } catch (e) {
      debugPrint('Non-fatal seek error: $e');
    }
  }

  Future<void> _onRestoreLastPlayed(
      RestoreLastPlayedEvent event, Emitter<PlayerState> emit) async {
    if (_settingsService?.resumeLastSong != true) return;
    final lastId = _settingsService?.lastPlayedSongId;
    if (lastId == null || _repository == null) return;

    // The restore runs concurrently with user actions. If the user starts a
    // song before it finishes, it must not load, seek or overwrite anything.
    final startGeneration = _playGeneration;
    bool superseded() => _playGeneration != startGeneration || state is! PlayerInitial;

    try {
      final allSongs = await _repository.getAllSongs();
      if (superseded()) return;
      final songMatches = allSongs.where((s) => s.id == lastId);
      if (songMatches.isEmpty) return;
      final song = songMatches.first;

      final posMs = _settingsService?.lastPlayedPositionMs ?? 0;
      final pos = Duration(milliseconds: posMs);

      await _audioService.prepare(song);
      if (superseded()) return;
      if (pos > Duration.zero) {
        await _audioService.seek(pos);
        if (superseded()) return;
      }

      _currentSong = song;
      _autoplayAnchor = song;
      _queue = [song];
      _originalQueue = [song];

      emit(PlayerPaused(
        song: song,
        position: pos,
        duration: song.duration,
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        queue: _queue,
      ));
    } catch (_) {}
  }

  Future<void> _onSetVolume(SetVolumeEvent event, Emitter<PlayerState> emit) async {
    try {
      await _audioService.setVolume(event.volume);
      if (state is PlayerPlaying) {
        final playing = state as PlayerPlaying;
        emit(playing.copyWith(volume: event.volume));
      } else if (state is PlayerPaused) {
        final paused = state as PlayerPaused;
        emit(paused.copyWith(volume: event.volume));
      }
    } catch (e) {
      emit(PlayerError('Failed to set volume: $e'));
    }
  }

  Future<void> _onSetPlaybackRate(SetPlaybackRateEvent event, Emitter<PlayerState> emit) async {
    try {
      await _audioService.setPlaybackRate(event.rate);
      if (state is PlayerPlaying) {
        final playing = state as PlayerPlaying;
        emit(playing.copyWith(playbackRate: event.rate));
      } else if (state is PlayerPaused) {
        final paused = state as PlayerPaused;
        emit(paused.copyWith(playbackRate: event.rate));
      }
    } catch (e) {
      emit(PlayerError('Failed to set playback rate: $e'));
    }
  }

  Future<void> _onNextSong(NextSongEvent event, Emitter<PlayerState> emit) async {
    // Not blocked while a song is loading: a new Next cancels the load in
    // progress (see restartable()) and moves on from the song being loaded.
    // Ignoring the tap here used to leave the cancelled load unfinished, so
    // the player stayed on "loading" until the user tapped again.
    if (_queue.isEmpty || _currentSong == null) return;
    if (event.isManualSkip && _currentSong != null) {
      UserTasteService.instance.onSongSkipped(_currentSong!, isManual: true);
    }
    _consecutiveFailures = 0;
    var nextSong = _getNextSong(_currentSong!);
    if (nextSong != null) {
      await _playSongInternal(nextSong, emit);
      add(const AutoExpandQueueEvent());
    } else if (_autoPlayNext && _currentSong != null) {
      // Reached the end of the queue: fetch more songs immediately and continue playback
      final fetchInProgress = _expansionDone;
      if (fetchInProgress != null) {
        // Autoplay is already fetching songs (it starts on the last song).
        // Wait for it instead of treating "nothing queued yet" as the end,
        // which paused the music and made the user tap Next a second time.
        await fetchInProgress.future.timeout(const Duration(seconds: 15), onTimeout: () {});
      } else {
        await _expandQueueInternal(emit, force: true);
      }
      nextSong = _getNextSong(_currentSong!);
      if (nextSong != null) {
        await _playSongInternal(nextSong, emit);
        add(const AutoExpandQueueEvent());
        return;
      }
      add(const PauseEvent());
      await _audioService.seek(Duration.zero);
    } else {
      add(const PauseEvent());
      await _audioService.seek(Duration.zero);
    }
  }

  Future<void> _onPreviousSong(PreviousSongEvent event, Emitter<PlayerState> emit) async {
    if (_queue.isEmpty || _currentSong == null) return; // see _onNextSong
    _consecutiveFailures = 0;

    Song? prevSong;
    final currentIndex = _queue.indexWhere((s) => s.id == _currentSong!.id);
    if (currentIndex > 0) {
      prevSong = _queue[currentIndex - 1];
    } else if (_queue.isNotEmpty) {
      prevSong = _queue.last; // Wrap around
    }

    if (prevSong != null) {
      await _playSongInternal(prevSong, emit);
    }
  }

  void _onToggleShuffle(ToggleShuffleEvent event, Emitter<PlayerState> emit) {
    _isShuffle = !_isShuffle;
    _settingsService?.setShuffleByDefault(_isShuffle);
    _applyShuffleQueueState();
    _emitUpdatedQueueState(emit);
  }

  void _onSetShuffle(SetShuffleEvent event, Emitter<PlayerState> emit) {
    _isShuffle = event.enabled;
    _settingsService?.setShuffleByDefault(_isShuffle);
    _applyShuffleQueueState();
    _emitUpdatedQueueState(emit);
  }

  void _applyShuffleQueueState() {
    // Drop upcoming Autoplay songs so they are never shuffled in among the
    // user's own songs. Autoplay adds fresh ones when the user's queue ends.
    if (_autoplayIds.isNotEmpty) {
      final currentId = _currentSong?.id;
      bool isUpcomingAutoplay(Song s) => s.id != currentId && _autoplayIds.contains(s.id);
      _queue.removeWhere(isUpcomingAutoplay);
      _originalQueue.removeWhere(isUpcomingAutoplay);
      _autoplayIds.removeWhere((id) => id != currentId);
    }
    if (_isShuffle && _queue.isNotEmpty) {
      if (_originalQueue.isEmpty) {
        _originalQueue = List.from(_queue);
      }
      _queue.shuffle();
      if (_currentSong != null) {
        _queue.removeWhere((s) => s.id == _currentSong!.id);
        _queue.insert(0, _currentSong!);
      }
    } else if (!_isShuffle && _originalQueue.isNotEmpty) {
      _queue = List.from(_originalQueue);
    }
  }

  Future<void> _onTrackChanged(TrackChangedEvent event, Emitter<PlayerState> emit) async {
    if (_isChangingSong || _currentSong?.id == event.song.id) return;
    _currentSong = event.song;
    _settingsService?.setLastPlayedSongId(event.song.id);
    _settingsService?.setLastPlayedPositionMs(0);
    _repository?.updateSong(event.song, notify: false);
    await _repository?.recordSongPlay(event.song);
    UserTasteService.instance.onSongStarted(event.song);
    add(const AutoExpandQueueEvent());
    _preResolveNextTrack();

    final dur = event.song.duration;
    if (state is PlayerPlaying) {
      emit((state as PlayerPlaying).copyWith(
        song: event.song,
        position: Duration.zero,
        duration: dur,
      ));
    } else if (state is PlayerPaused) {
      emit((state as PlayerPaused).copyWith(
        song: event.song,
        position: Duration.zero,
        duration: dur,
      ));
    } else {
      emit(PlayerPlaying(
        song: event.song,
        position: Duration.zero,
        duration: dur,
        isShuffle: _isShuffle,
        isRepeat: _isRepeat,
        repeatMode: _repeatMode,
        queue: List.from(_queue),
      ));
    }
  }

  Future<void> _onToggleRepeat(ToggleRepeatEvent event, Emitter<PlayerState> emit) async {
    if (_repeatMode == 'Off') {
      _repeatMode = 'One';
      _isRepeat = true;
    } else if (_repeatMode == 'One') {
      _repeatMode = 'All';
      _isRepeat = true;
    } else {
      _repeatMode = 'Off';
      _isRepeat = false;
    }
    _settingsService?.setRepeatMode(_repeatMode);
    await _updateAudioPlayerRepeatMode();
    if (state is PlayerPlaying) {
      emit((state as PlayerPlaying).copyWith(isRepeat: _isRepeat, repeatMode: _repeatMode));
    } else if (state is PlayerPaused) {
      emit((state as PlayerPaused).copyWith(isRepeat: _isRepeat, repeatMode: _repeatMode));
    }
  }

  Future<void> _onSetRepeatMode(SetRepeatModeEvent event, Emitter<PlayerState> emit) async {
    _repeatMode = event.mode;
    _isRepeat = event.mode != 'Off';
    _settingsService?.setRepeatMode(_repeatMode);
    await _updateAudioPlayerRepeatMode();
    if (state is PlayerPlaying) {
      emit((state as PlayerPlaying).copyWith(isRepeat: _isRepeat, repeatMode: _repeatMode));
    } else if (state is PlayerPaused) {
      emit((state as PlayerPaused).copyWith(isRepeat: _isRepeat, repeatMode: _repeatMode));
    }
  }

  Future<void> _updateAudioPlayerRepeatMode() async {
    try {
      if (_repeatMode == 'One') {
        await _audioService.setLoopMode(LoopMode.one);
      } else if (_repeatMode == 'All') {
        await _audioService.setLoopMode(LoopMode.all);
      } else {
        await _audioService.setLoopMode(LoopMode.off);
      }
    } catch (_) {}
  }

  void _preResolveNextTrack() {
    if (_currentSong == null) return;
    // Resolve the next 3 upcoming tracks in parallel to avoid mid-song buffering
    final currentIndex = _queue.indexWhere((s) => s.id == _currentSong!.id);
    if (currentIndex == -1) return;
    final upcomingIndexes = [
      currentIndex + 1,
      currentIndex + 2,
      currentIndex + 3,
    ].where((i) => i < _queue.length).toList();

    for (final idx in upcomingIndexes) {
      final upcoming = _queue[idx];
      if (upcoming.filePath.isNotEmpty || upcoming.source != 'jiosaavn') continue;
      final lookupKey = (upcoming.mediaId != null && upcoming.mediaId!.isNotEmpty)
          ? upcoming.mediaId!
          : upcoming.id.toString();
      JioSaavnDecoder.fetchSongDetails(lookupKey).then((details) {
        final streamUrl = details?.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(details?.encryptedMediaUrl);
        if (streamUrl != null && streamUrl.isNotEmpty) {
          final qIndex = _queue.indexWhere((s) => s.id == upcoming.id);
          if (qIndex != -1 && _queue[qIndex].filePath.isEmpty) {
            final resolved = _queue[qIndex].copyWith(filePath: streamUrl);
            _queue[qIndex] = resolved;
            _audioService.addSongsToQueue([resolved]);
            debugPrint('PulseIQ: Pre-resolved stream URL for upcoming track "${resolved.title}"');
          }
        }
      }).catchError((_) {});
    }
  }

  void _onSetAutoPlayNext(SetAutoPlayNextEvent event, Emitter<PlayerState> emit) {
    _autoPlayNext = event.autoPlayNext;
  }

  Future<void> _onAutoExpandQueue(
    AutoExpandQueueEvent event,
    Emitter<PlayerState> emit,
  ) async {
    await _expandQueueInternal(emit);
  }

  /// Whether Autoplay may add songs right now.
  bool get _autoplaySimilarAllowed =>
      _autoPlayNext &&
      (_settingsService?.autoplaySimilar ?? true) &&
      // Repeat One replays the song; Repeat All loops the user's own queue.
      _repeatMode == 'Off';

  Future<void> _expandQueueInternal(Emitter<PlayerState> emit, {bool force = false}) async {
    if (!_autoplaySimilarAllowed || _isExpandingQueue) return;
    if (_queue.isEmpty) return;

    final currentId = _currentSong?.id;
    final currentIndex = currentId != null
        ? _queue.indexWhere((s) => s.id == currentId)
        : -1;

    // Only top up once the user's own queue is about to run out (on its
    // last song), so Autoplay never lands in the middle of an album,
    // playlist or folder the user chose. One song of lead time is enough
    // to have the next track ready.
    final remaining = currentIndex != -1 ? (_queue.length - 1 - currentIndex) : 0;
    if (!force && remaining > 0) return;

    _isExpandingQueue = true;
    _expansionDone = Completer<void>();
    try {
      // Seed from the song the user actually chose, not the last queued song.
      // The last song is usually one Autoplay added itself, so seeding from
      // it made each refill a guess based on the previous guess, drifting
      // further from the user's taste every round.
      final seedSong = _autoplayAnchor ?? _currentSong;
      if (seedSong == null) return;

      // Stream ≠ Library: a Library song continues from the Library only
      // (works offline, never a failing stream URL); a Stream song continues
      // from Stream only.
      final recs = _isLibrarySong(seedSong)
          ? await _libraryAutoplaySongs(seedSong)
          : await _streamAutoplaySongs(seedSong);

      if (recs.isNotEmpty) {
        final existingIds = _queue.map((s) => s.id).toSet();
        final existingKeys = _queue.map((s) => s.canonicalKey).toSet();
        final existingTitles = _queue.map((s) => s.title.trim().toLowerCase()).toSet();

        // The same song listed again under another id / title suffix / artist
        // credit must not be queued twice either.
        SongFingerprint fingerprintOf(Song s) => SongFingerprint.of(
              identity: s.canonicalKey,
              title: s.title,
              artist: s.artist,
              durationSecs: s.duration.inSeconds,
            );
        final queueFingerprints = _queue.map(fingerprintOf).toList();

        final newTracks = <Song>[];
        for (final s in recs) {
          if (existingIds.contains(s.id)) continue;
          if (existingKeys.contains(s.canonicalKey)) continue;
          final normTitle = s.title.trim().toLowerCase();
          if (normTitle.isNotEmpty && existingTitles.contains(normTitle)) continue;
          if (!(s.filePath.trim().isNotEmpty || s.source == 'jiosaavn')) continue;
          final fp = fingerprintOf(s);
          if (queueFingerprints.any(fp.isSameSongAs)) continue;
          queueFingerprints.add(fp); // also catches duplicates inside this batch
          newTracks.add(s);
        }

        if (newTracks.isNotEmpty) {
          // Pre-resolve stream URLs for JioSaavn tracks in parallel (up to 6 at once)
          // so they can be appended directly to the player's playlist.
          final resolvedTracks = await _resolveStreamUrls(newTracks);

          // Update in-memory queue with resolved URLs
          for (final resolved in resolvedTracks) {
            final idx = newTracks.indexWhere((s) => s.id == resolved.id);
            if (idx != -1) newTracks[idx] = resolved;
          }

          // Only add tracks that now have a valid filePath to ExoPlayer
          final playableTracks = newTracks.where((s) => s.filePath.trim().isNotEmpty).toList();

          _queue.addAll(newTracks);
          _originalQueue.addAll(newTracks);
          _autoplayIds.addAll(newTracks.map((s) => s.id));

          if (playableTracks.isNotEmpty) {
            await _audioService.addSongsToQueue(playableTracks);
          }
          _emitUpdatedQueueState(emit);
          debugPrint('PulseIQ: Auto-expanded queue with ${newTracks.length} tracks (${playableTracks.length} playable, Total: ${_queue.length})');
        }
      }
    } catch (e) {
      debugPrint('Error expanding playback queue: $e');
    } finally {
      _isExpandingQueue = false;
      final done = _expansionDone;
      _expansionDone = null;
      if (done != null && !done.isCompleted) done.complete();
    }
  }

  /// Devotional / kids songs only follow a song of the same kind.
  static bool _sameContentKind(Song seed, Song candidate) {
    final category = ContentClassifier.ofSong(candidate);
    return category == null || category == ContentClassifier.ofSong(seed);
  }

  /// Autoplay for a Stream song: suggestions from the SuggestionService, or (offline /
  /// no results) songs from the offline stream cache. Never Library songs.
  Future<List<Song>> _streamAutoplaySongs(Song seed) async {
    final recent = _repository != null
        ? await _repository.getLastPlayedStreamSongs(limit: 20)
        : <Song>[];

    final seeds = _autoplaySeeds(seed);
    final suggestions = await _suggestions.suggest(seeds, limit: 15, exclude: _excluded(recent));
    final recs = [for (final s in suggestions) s.toSong()];
    if (recs.isNotEmpty) return recs;

    final existingIds = _queue.map((s) => s.id).toSet();
    return StreamCacheService.instance
        .getCachedSongs()
        .where((s) => !existingIds.contains(s.id) && _sameContentKind(seed, s))
        .take(15)
        .toList();
  }

  /// Autoplay for a Library song, from the Library only: same artist first,
  /// then the same album, then the user's most-played songs. Never random
  /// songs, never Stream songs.
  Future<List<Song>> _libraryAutoplaySongs(Song seed) async {
    if (_repository == null) return const [];
    final all = await _repository.getAllSongs();
    final existingIds = _queue.map((s) => s.id).toSet();
    final pool = all
        .where((s) =>
            !existingIds.contains(s.id) &&
            _isLibrarySong(s) &&
            s.duration >= const Duration(seconds: 30) &&
            _sameContentKind(seed, s))
        .toList();
    if (pool.isEmpty) return const [];

    final picked = <Song>[];
    final pickedIds = <int>{};
    void take(Iterable<Song> songs, int max) {
      for (final s in songs) {
        if (picked.length >= 15 || max <= 0) return;
        if (pickedIds.add(s.id)) {
          picked.add(s);
          max--;
        }
      }
    }

    final seedArtists = UserTasteService.parseArtistTokens(seed.artist).toSet();
    if (seedArtists.isNotEmpty) {
      take(
        pool.where((s) => UserTasteService.parseArtistTokens(s.artist).any(seedArtists.contains)).toList()..shuffle(),
        8,
      );
    }

    const genericAlbums = {'', 'unknown', '<unknown>', 'youtube downloads', 'downloads', 'music', 'download'};
    final seedAlbum = seed.album.trim().toLowerCase();
    if (!genericAlbums.contains(seedAlbum)) {
      take(pool.where((s) => s.album.trim().toLowerCase() == seedAlbum), 4);
    }

    final mostPlayed = pool.where((s) => s.playCount > 0).toList()
      ..sort((a, b) => b.playCount.compareTo(a.playCount));
    take(mostPlayed, 15);

    return picked;
  }

  /// Resolves stream URLs for JioSaavn tracks in parallel (at most 6 concurrent).
  /// Returns the same list with filePath populated where resolution succeeded.
  Future<List<Song>> _resolveStreamUrls(List<Song> songs) async {
    const maxConcurrent = 6;
    final results = <Song>[];
    for (int i = 0; i < songs.length; i += maxConcurrent) {
      final batch = songs.sublist(i, (i + maxConcurrent).clamp(0, songs.length));
      final resolved = await Future.wait(batch.map((song) async {
        if (song.filePath.trim().isNotEmpty) return song;
        if (song.source != 'jiosaavn') return song;
        try {
          final lookupKey = (song.mediaId != null && song.mediaId!.isNotEmpty)
              ? song.mediaId!
              : song.id.toString();
          final details = await JioSaavnDecoder.fetchSongDetails(lookupKey);
          final streamUrl = details?.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(details?.encryptedMediaUrl);
          if (streamUrl != null && streamUrl.isNotEmpty) {
            return song.copyWith(filePath: streamUrl);
          }
        } catch (_) {}
        return song;
      }));
      results.addAll(resolved);
    }
    return results;
  }

  @override
  Future<void> close() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _currentIndexSubscription?.cancel();
    _playingSubscription?.cancel();
    _audioService.dispose();
    return super.close();
  }
}
