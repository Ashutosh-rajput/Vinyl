import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/data/repositories/music_repository.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/services/file_service.dart';
import 'package:vinyl/services/settings_service.dart';
import 'helpers/mock_audio_service.dart';

class _FakeRepo implements MusicRepository {
  final List<Song> songs;
  _FakeRepo(this.songs);

  @override
  Future<List<Song>> getAllSongs() async => songs;

  @override
  Future<List<Song>> getLastPlayedStreamSongs({int limit = 10}) async => [];

  @override
  Future<void> recordSongPlay(Song song) async {}

  @override
  Future<void> updateSong(Song song, {bool notify = true}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFiles implements FileService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setupPlatformMocks();

  final song1 = Song(
    id: 101,
    title: 'Track 1',
    artist: 'Artist A',
    album: 'Album X',
    filePath: 'https://example.com/1.mp3',
    duration: const Duration(minutes: 3),
    dateModified: DateTime.now(),
  );

  final song2 = Song(
    id: 102,
    title: 'Track 2',
    artist: 'Artist B',
    album: 'Album X',
    filePath: 'https://example.com/2.mp3',
    duration: const Duration(minutes: 4),
    dateModified: DateTime.now(),
  );

  final song3 = Song(
    id: 103,
    title: 'Track 3',
    artist: 'Artist C',
    album: 'Album X',
    filePath: 'https://example.com/3.mp3',
    duration: const Duration(minutes: 5),
    dateModified: DateTime.now(),
  );

  test('restores entire playback queue on resume last song after app restart', () async {
    SharedPreferences.setMockInitialValues({
      'setting_resume_last': true,
      'setting_last_played_song_id': 102,
      'setting_last_played_position_ms': 45000,
      'setting_saved_playback_queue': jsonEncode([
        song1.toJson(),
        song2.toJson(),
        song3.toJson(),
      ]),
    });

    final prefs = await SharedPreferences.getInstance();
    final repo = _FakeRepo([song1, song2, song3]);
    final settings = SettingsService(prefs: prefs, repository: repo, fileService: _FakeFiles());
    final audio = MockAudioPlayerService();

    final bloc = PlayerBloc(
      audioService: audio,
      settingsService: settings,
      repository: repo,
    );

    // Wait for RestoreLastPlayedEvent added in constructor to complete
    await Future.delayed(const Duration(milliseconds: 100));

    expect(bloc.state, isA<PlayerPaused>());
    final paused = bloc.state as PlayerPaused;

    // Resumed song is Track 2
    expect(paused.song.id, equals(102));
    expect(paused.position, equals(const Duration(milliseconds: 45000)));

    // Crucial check: All 3 songs are preserved in the queue, not just the resumed song!
    expect(paused.queue.length, equals(3));
    expect(paused.queue.map((s) => s.id).toList(), equals([101, 102, 103]));

    // Resume playback
    bloc.add(const ResumeEvent());
    await Future.delayed(const Duration(milliseconds: 50));
    expect(bloc.state, isA<PlayerPlaying>());

    // Next song correctly advances to Track 3 in the queue
    bloc.add(const NextSongEvent(isManualSkip: true));
    await Future.delayed(const Duration(milliseconds: 100));
    expect(bloc.state, isA<PlayerPlaying>());
    final nextPlaying = bloc.state as PlayerPlaying;
    expect(nextPlaying.song.id, equals(103));
    expect(nextPlaying.queue.length, equals(3));

    await bloc.close();
  });

  test('queue mutations persist to SettingsService savedPlaybackQueue', () async {
    SharedPreferences.setMockInitialValues({
      'setting_resume_last': true,
    });

    final prefs = await SharedPreferences.getInstance();
    final repo = _FakeRepo([song1, song2, song3]);
    final settings = SettingsService(prefs: prefs, repository: repo, fileService: _FakeFiles());
    final audio = MockAudioPlayerService();

    final bloc = PlayerBloc(
      audioService: audio,
      settingsService: settings,
      repository: repo,
    );

    // Play song1 with queue [song1, song2, song3]
    bloc.add(PlaySongEvent(song1, queue: [song1, song2, song3]));
    await Future.delayed(const Duration(milliseconds: 100));

    // Verify savedPlaybackQueue has all 3 songs saved
    final saved = settings.savedPlaybackQueue;
    expect(saved.length, equals(3));
    expect(saved.map((s) => s.id).toList(), equals([101, 102, 103]));

    await bloc.close();
  });
}
