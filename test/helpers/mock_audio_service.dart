import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/services/audio_service.dart';

/// Mock AudioPlayerService for headless unit & integration tests
class MockAudioPlayerService implements AudioPlayerService {
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _currentIndexController = StreamController<int?>.broadcast();
  final _playingController = StreamController<bool>.broadcast();

  List<Song> _queue = [];
  int _currentIndex = 0;
  AudioPlayer? _player;

  @override
  AudioPlayer get player => _player ??= AudioPlayer();

  void emitPlayerState(PlayerState state) => _playerStateController.add(state);
  void emitCurrentIndex(int? index) {
    if (index != null) _currentIndex = index;
    _currentIndexController.add(index);
  }
  void emitPosition(Duration position) {
    _position = position;
    _positionController.add(position);
  }

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => Stream.value(const Duration(minutes: 3));

  @override
  Stream<int?> get currentIndexStream => _currentIndexController.stream;

  @override
  int? get currentIndex => _currentIndex;

  Duration _position = Duration.zero;
  @override
  Duration get position => _position;

  final Duration _duration = const Duration(minutes: 3);
  @override
  Duration? get duration => _duration;

  bool _isPlaying = false;

  @override
  bool get isPlaying => _isPlaying;

  String? failPath;

  /// When set, play() waits on it before "loading" finishes, to simulate a
  /// slow source load.
  Completer<void>? playGate;

  @override
  Future<void> play(
    String path, {
    Song? songInfo,
    List<Song>? queue,
    int? initialIndex,
    bool Function()? isCancelled,
  }) async {
    if (playGate != null) await playGate!.future;
    if (failPath != null && path == failPath) {
      throw Exception('(0) Source error');
    }
    if (isCancelled?.call() ?? false) return;
    _isPlaying = true;
    _playingController.add(true);
    if (queue != null) {
      _queue = List.from(queue);
      _currentIndex = initialIndex ?? (songInfo != null ? _queue.indexWhere((s) => s.id == songInfo.id) : 0);
      if (_currentIndex < 0) _currentIndex = 0;
    }
    _playerStateController.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> playQueue(List<Song> queue, {required int initialIndex}) async {
    _isPlaying = true;
    _playingController.add(true);
    _queue = List.from(queue);
    _currentIndex = initialIndex;
    _currentIndexController.add(_currentIndex);
    _playerStateController.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> addSongsToQueue(List<Song> songs) async {
    _queue.addAll(songs);
  }

  /// Upcoming order most recently pushed to the "player" via [syncUpcoming].
  List<Song>? lastSyncedUpcoming;

  @override
  Future<void> syncUpcoming(Song current, List<Song> upcoming) async {
    lastSyncedUpcoming = List.from(upcoming);
  }

  @override
  Future<void> pause() async {
    _isPlaying = false;
    _playingController.add(false);
    _playerStateController.add(PlayerState(false, ProcessingState.ready));
  }

  @override
  Future<void> resume() async {
    _isPlaying = true;
    _playingController.add(true);
    _playerStateController.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> stop() async {
    _isPlaying = false;
    _playingController.add(false);
    _playerStateController.add(PlayerState(false, ProcessingState.idle));
  }

  @override
  Future<void> seek(Duration position) async {
    _positionController.add(position);
  }

  @override
  Future<void> prepare(Song song, {List<Song>? queue, int? initialIndex}) async {
    if (queue != null) {
      _queue = List.from(queue);
      _currentIndex = initialIndex ?? _queue.indexWhere((s) => s.id == song.id);
      if (_currentIndex < 0) _currentIndex = 0;
    }
  }

  @override
  Future<void> seekToNext() async {
    if (_queue.isNotEmpty) {
      _currentIndex = (_currentIndex + 1) % _queue.length;
      _currentIndexController.add(_currentIndex);
    }
  }

  @override
  Future<void> seekToPrevious() async {
    if (_queue.isNotEmpty) {
      _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
      _currentIndexController.add(_currentIndex);
    }
  }

  @override
  Future<void> seekToIndex(int index) async {
    _currentIndex = index;
    _currentIndexController.add(_currentIndex);
  }

  /// What [ensureAudioFocus] reports; set false to simulate another app
  /// still holding audio focus.
  bool focusGranted = true;

  @override
  double get volume => 1.0;

  @override
  Future<bool> ensureAudioFocus() async => focusGranted;

  @override
  Future<void> setLoopMode(LoopMode mode) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setPlaybackRate(double rate) async {}

  @override
  void dispose() {
    _playerStateController.close();
    _positionController.close();
    _currentIndexController.close();
    _player?.dispose();
    _player = null;
  }
}

/// Setup channel mocks for platform plugins in headless test environment
void setupPlatformMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ryanheise.just_audio.methods');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
    if (methodCall.method == 'init') {
      return {'id': 'test_player_id'};
    }
    if (methodCall.method == 'dispose') {
      return {};
    }
    if (methodCall.method == 'load') {
      return {'duration': 180000000};
    }
    return {};
  });

  const toastChannel = MethodChannel('PonnamKarthik/fluttertoast');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(toastChannel, (MethodCall methodCall) async {
    return true;
  });
}
