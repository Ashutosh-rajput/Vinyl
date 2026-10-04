import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/services/suggestion/jio_resolver.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_service.dart';
import 'helpers/mock_audio_service.dart';

/// A suggestion source whose answer each test can script. It also records what
/// it was asked, and which songs it was told to warm up for.
class ScriptedProvider implements SuggestionProvider, WarmableProvider {
  Future<List<JioSaavnItem>> Function(SeedSong seed) script = (_) async => const [];
  final List<SeedSong> asked = [];
  final List<SeedSong> warmed = [];

  @override
  void warmUp(SeedSong seed) => warmed.add(seed);

  @override
  SuggestionSource get source => SuggestionSource.jioSaavn;

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async {
    asked.add(seed);
    final items = await script(seed);
    return [
      for (var i = 0; i < items.length; i++)
        SuggestionCandidate(
          title: items[i].title,
          artist: items[i].subtitle,
          source: SuggestionSource.jioSaavn,
          rank: i,
          providerId: items[i].id,
          jio: items[i],
        ),
    ];
  }
}

void main() {
  setupPlatformMocks();

  group('Infinite Playback Queue Auto-Expansion Tests', () {
    late MockAudioPlayerService audioService;
    late PlayerBloc playerBloc;
    late ScriptedProvider suggestions;

    Song createSong(int id, String title, {String artist = 'Artist'}) {
      return Song(
        id: id,
        title: title,
        artist: artist,
        album: 'Album',
        filePath: 'https://example.com/stream_$id.mp3',
        duration: const Duration(minutes: 3),
        dateModified: DateTime.now(),
        source: 'jiosaavn',
      );
    }

    JioSaavnItem createItem(String id, String title, {String artist = 'Artist'}) {
      return JioSaavnItem(
        type: 'song',
        id: id,
        token: id,
        title: title,
        subtitle: artist,
        imageUrl: 'https://example.com/art.jpg',
        directMediaUrl: 'https://example.com/$id.mp3',
        duration: '180',
      );
    }

    setUp(() {
      audioService = MockAudioPlayerService();

      // What the suggestion service answers; tests change it where needed.
      suggestions = ScriptedProvider()
        ..script = (_) async => [
              createItem('sug_101', 'Infinite Track 1', artist: 'Discovery 1'),
              createItem('sug_102', 'Infinite Track 2', artist: 'Discovery 2'),
              createItem('sug_103', 'Infinite Track 3', artist: 'Discovery 3'),
              createItem('sug_104', 'Infinite Track 4', artist: 'Discovery 4'),
            ];

      playerBloc = PlayerBloc(
        audioService: audioService,
        suggestionService: SuggestionService(
          providers: [suggestions],
          resolver: JioResolver(search: (q) async => const []),
        ),
      );
    });

    tearDown(() {
      playerBloc.close();
    });

    test('Queue does not expand when remaining songs > 3', () async {
      // 10 songs in queue, playing song 0 -> remaining = 9 > 3
      final initialQueue = List.generate(10, (i) => createSong(i + 1, 'Song ${i + 1}'));
      playerBloc.add(PlayQueueEvent(initialQueue, initialIndex: 0));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 1)),
      );

      // Wait brief moment for any async events
      await Future.delayed(const Duration(milliseconds: 150));

      final state = playerBloc.state;
      expect(state, isA<PlayerPlaying>());
      final playing = state as PlayerPlaying;
      expect(playing.queue.length, equals(10));
    });

    test('Queue does not expand while the user\'s own songs are still ahead', () async {
      // 5 songs, playing index 2 -> 2 of the user's songs still to come.
      final initialQueue = List.generate(5, (i) => createSong(i + 1, 'Song ${i + 1}'));
      playerBloc.add(PlayQueueEvent(initialQueue, initialIndex: 2));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 3)),
      );
      await Future.delayed(const Duration(milliseconds: 150));

      final state = playerBloc.state as PlayerPlaying;
      expect(state.queue.length, equals(5));
    });

    test('Queue automatically expands once the last song of the user\'s queue plays', () async {
      final initialQueue = List.generate(5, (i) => createSong(i + 1, 'Song ${i + 1}'));
      playerBloc.add(PlayQueueEvent(initialQueue, initialIndex: 4));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.queue.length > 5)),
      );

      final state = playerBloc.state as PlayerPlaying;
      expect(state.queue.length, greaterThan(5));
      // First 5 songs preserved in exact order
      for (int i = 0; i < 5; i++) {
        expect(state.queue[i].id, equals(initialQueue[i].id));
      }
      // Newly fetched songs appended to the end
      expect(state.queue.any((s) => s.title == 'Infinite Track 1'), isTrue);
      expect(state.queue.any((s) => s.title == 'Infinite Track 2'), isTrue);
    });

    test('NextSongEvent at end of queue fills queue and continues playback seamlessly', () async {
      final initialQueue = [
        createSong(1, 'Solo Track'),
      ];

      playerBloc.add(PlaySongEvent(initialQueue.first, queue: initialQueue));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying)),
      );

      // Trigger next song when at the very end
      playerBloc.add(const NextSongEvent());

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>(
          (s) => s is PlayerPlaying && s.song.title.contains('Infinite Track'),
        )),
      );

      final state = playerBloc.state as PlayerPlaying;
      expect(state.song.title, equals('Infinite Track 1'));
      expect(state.queue.length, greaterThan(1));
    });

    test('Queue expansion excludes existing songs to prevent duplicates', () async {
      // Setup suggestions containing a duplicate of a song already in queue
      suggestions.script = (_) async => [
            createItem('dup', 'Existing Song', artist: 'Artist'), // Duplicate
            createItem('unique_1', 'Brand New Song', artist: 'New Artist'),
          ];

      final initialQueue = [
        createSong(10, 'Existing Song', artist: 'Artist'),
        createSong(11, 'Second Song', artist: 'Artist'),
      ];

      playerBloc.add(PlayQueueEvent(initialQueue, initialIndex: 1));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.queue.length > 2)),
      );

      final state = playerBloc.state as PlayerPlaying;
      // Should not contain duplicate
      final existingCount = state.queue.where((s) => s.title.toLowerCase() == 'existing song').length;
      expect(existingCount, equals(1));
      expect(state.queue.any((s) => s.title == 'Brand New Song'), isTrue);
    });

    test('Queue from stream list advances through jiosaavn tracks with empty initial filePath and expands at end', () async {
      // Simulate stream screen queue where first song has URL, and remaining songs have empty initial filePath
      final song1 = createSong(1, 'List Song 1').copyWith(filePath: 'https://example.com/1.mp3');
      final song2 = createSong(2, 'List Song 2').copyWith(filePath: '');
      final song3 = createSong(3, 'List Song 3').copyWith(filePath: '');

      playerBloc.add(PlaySongEvent(song1, queue: [song1, song2, song3]));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 1)),
      );

      // Advance to song2 (whose initial filePath was empty)
      playerBloc.add(const NextSongEvent());

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 2)),
      );

      // Advance to song3
      playerBloc.add(const NextSongEvent());

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 3)),
      );

      // Advance past end of queue -> must expand infinitely with new tracks!
      playerBloc.add(const NextSongEvent());

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>(
          (s) => s is PlayerPlaying && s.song.title.contains('Infinite Track'),
        )),
      );

      final state = playerBloc.state as PlayerPlaying;
      expect(state.queue.length, greaterThan(3));
    });

    test('PlayerLoading state preserves entire queue when user clicks song in queue (prevents 0 tracks flash)', () async {
      final queue = List.generate(10, (i) => createSong(i + 1, 'Song ${i + 1}'));
      playerBloc.add(PlayQueueEvent(queue, initialIndex: 0));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 1)),
      );

      // User clicks song 5 from queue
      playerBloc.add(const PlaySongAtIndexEvent(4));

      // Must emit PlayerLoading carrying the full 10-song queue, NOT empty queue
      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) {
          if (s is PlayerLoading) {
            expect(s.queue.length, equals(10));
            expect(s.song?.id, equals(5));
            return true;
          }
          return false;
        })),
      );
    });

    test('Next on the last song while Autoplay is still fetching waits for it and plays on', () async {
      // Slow recommendation service: the fetch started on the last song is
      // still running when the user taps Next.
      final fetchRelease = Completer<void>();
      suggestions.script = (_) async {
        await fetchRelease.future;
        return [createItem('slow_1', 'Slow Track', artist: 'Slow Artist')];
      };

      final queue = [createSong(1, 'Only Song', artist: 'Seed Artist')];
      playerBloc.add(PlaySongEvent(queue.first, queue: queue));
      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 1)),
      );
      await Future.delayed(const Duration(milliseconds: 50)); // Autoplay fetch is now in flight

      playerBloc.add(const NextSongEvent(isManualSkip: true));
      await Future.delayed(const Duration(milliseconds: 50));
      fetchRelease.complete();

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.title == 'Slow Track')),
      );
    });

    test('A Library song never gets Stream songs appended by Autoplay', () async {
      final librarySong = Song(
        id: 501,
        title: 'Local Track',
        artist: 'Seed Artist',
        album: 'My Folder',
        filePath: '/storage/emulated/0/Music/local_track.mp3',
        duration: const Duration(minutes: 3),
        dateModified: DateTime.now(),
        source: 'local',
      );
      playerBloc.add(PlaySongEvent(librarySong, queue: [librarySong]));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 501)),
      );
      await Future.delayed(const Duration(milliseconds: 150));

      final state = playerBloc.state as PlayerPlaying;
      expect(state.queue.any((s) => s.source == 'jiosaavn'), isFalse);
    });

    test('Repeat All loops the user\'s queue instead of appending Autoplay songs', () async {
      playerBloc.add(const SetRepeatModeEvent('All'));
      final initialQueue = List.generate(3, (i) => createSong(i + 1, 'Song ${i + 1}'));
      playerBloc.add(PlayQueueEvent(initialQueue, initialIndex: 2));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 3)),
      );
      await Future.delayed(const Duration(milliseconds: 150));

      expect((playerBloc.state as PlayerPlaying).queue.length, equals(3));

      playerBloc.add(const NextSongEvent());
      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 1)),
      );
    });

    test('Shuffle plays every song of the user\'s queue exactly once before Autoplay', () async {
      playerBloc.add(const SetShuffleEvent(true));
      final initialQueue = List.generate(6, (i) => createSong(i + 1, 'Song ${i + 1}'));
      playerBloc.add(PlaySongEvent(initialQueue.first, queue: initialQueue));

      await expectLater(
        playerBloc.stream,
        emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 1)),
      );

      final played = <int>[1];
      for (var i = 0; i < 5; i++) {
        final before = (playerBloc.state as PlayerPlaying).song.id;
        playerBloc.add(const NextSongEvent());
        await expectLater(
          playerBloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id != before)),
        );
        played.add((playerBloc.state as PlayerPlaying).song.id);
      }

      // All six user songs, no repeats, no Autoplay song mixed in.
      expect(played.toSet(), equals({1, 2, 3, 4, 5, 6}));
    });

    group('Suggestions wired into the player', () {
      Song librarySong(int id, String title) => Song(
            id: id,
            title: title,
            artist: 'Local Artist',
            album: 'Local Album',
            filePath: '/music/$id.mp3',
            duration: const Duration(minutes: 3),
            dateModified: DateTime.now(),
            source: 'local',
          );

      test('Autoplay asks with the song the user picked and the song playing as seeds', () async {
        final queue = [
          createSong(1, 'Picked Song', artist: 'Seed Artist'),
          createSong(2, 'Second Song', artist: 'Seed Artist'),
        ];
        playerBloc.add(PlayQueueEvent(queue, initialIndex: 0));
        await expectLater(
          playerBloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 1)),
        );
        playerBloc.add(const NextSongEvent()); // now on the last song: Autoplay fills the queue
        await expectLater(
          playerBloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.queue.length > 2)),
        );
        expect(suggestions.asked, isNotEmpty);
        expect(suggestions.asked.first.title, 'Picked Song'); // the anchor leads
        expect(suggestions.asked.map((a) => a.title), contains('Second Song')); // plus what is playing
      });

      test('Autoplay uses up to 5 songs of the queue as seeds, the picked song first', () async {
        final queue = [for (var i = 1; i <= 8; i++) createSong(i, 'Queue Song $i', artist: 'Artist $i')];
        playerBloc.add(PlayQueueEvent(queue, initialIndex: 7)); // start on the last song
        await expectLater(
          playerBloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.queue.length > 8)),
        );
        final titles = suggestions.asked.map((a) => a.title).toList();
        expect(titles.toSet(), hasLength(5));
        expect(titles.first, 'Queue Song 8'); // the song the user picked leads
        // then the songs played just before it, nearest first
        expect(titles.toSet(), {'Queue Song 8', 'Queue Song 7', 'Queue Song 6', 'Queue Song 5', 'Queue Song 4'});
      });

      test('with fewer songs in the queue, Autoplay uses what there is', () async {
        final queue = [createSong(1, 'Only A'), createSong(2, 'Only B')];
        playerBloc.add(PlayQueueEvent(queue, initialIndex: 1));
        await expectLater(
          playerBloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.queue.length > 2)),
        );
        expect(suggestions.asked.map((a) => a.title).toSet(), {'Only B', 'Only A'});
      });

      test('songs Autoplay added itself are not used as seeds on the next refill', () async {
        final queue = [createSong(1, 'User Song', artist: 'Seed Artist')];
        playerBloc.add(PlayQueueEvent(queue, initialIndex: 0));
        await expectLater(
          playerBloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.queue.length > 1)),
        );
        suggestions.asked.clear();
        suggestions.script = (_) async => [createItem('n1', 'Second Wave', artist: 'Other')];
        playerBloc.add(const NextSongEvent()); // moves onto an Autoplay song
        await Future.delayed(const Duration(milliseconds: 300));
        playerBloc.add(const AutoExpandQueueEvent());
        await Future.delayed(const Duration(milliseconds: 300));
        final seeds = suggestions.asked.map((a) => a.title);
        expect(seeds, isNot(contains('Infinite Track 1')));
        expect(seeds, isNot(contains('Infinite Track 2')));
      });

      test('a Stream song that starts playing warms up the slow suggestion sources', () async {
        final song = createSong(1, 'Warm Me', artist: 'Some Artist');
        playerBloc.add(PlaySongEvent(song, queue: [song]));
        await expectLater(
          playerBloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 1)),
        );
        expect(suggestions.warmed.map((w) => w.title), contains('Warm Me'));
      });

      test('a Library song does not start any suggestion lookups', () async {
        final song = librarySong(5, 'Local Song');
        playerBloc.add(PlaySongEvent(song, queue: [song]));
        await expectLater(
          playerBloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.song.id == 5)),
        );
        await Future.delayed(const Duration(milliseconds: 100));
        expect(suggestions.warmed, isEmpty);
        expect(suggestions.asked, isEmpty);
      });

      test('Radio uses the radio service and queues what it suggests after the current song', () async {
        final radio = ScriptedProvider()
          ..script = (_) async => [
                createItem('r1', 'Radio Track 1', artist: 'Radio Artist 1'),
                createItem('r2', 'Radio Track 2', artist: 'Radio Artist 2'),
              ];
        final bloc = PlayerBloc(
          audioService: MockAudioPlayerService(),
          suggestionService: SuggestionService(providers: [suggestions], resolver: JioResolver(search: (q) async => const [])),
          radioSuggestionService: SuggestionService(providers: [radio], resolver: JioResolver(search: (q) async => const [])),
        );
        addTearDown(bloc.close);

        final song = createSong(1, 'Current Song', artist: 'Some Artist');
        bloc.add(StartRadioEvent(song));
        await expectLater(
          bloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.queue.length == 3)),
        );
        final queue = (bloc.state as PlayerPlaying).queue;
        expect(queue.map((s) => s.title), ['Current Song', 'Radio Track 1', 'Radio Track 2']);
        expect(radio.asked.single.title, 'Current Song');
        expect(suggestions.asked, isEmpty); // the Autoplay service was not used
      });

      test('suggestions that are already in the queue are not added again', () async {
        suggestions.script = (_) async => [
              createItem('x1', 'Already Queued', artist: 'Seed Artist'),
              createItem('x2', 'Fresh Track', artist: 'Another Artist'),
            ];
        final queue = [
          createSong(1, 'Already Queued', artist: 'Seed Artist'),
        ];
        playerBloc.add(PlayQueueEvent(queue, initialIndex: 0));
        await expectLater(
          playerBloc.stream,
          emitsThrough(predicate<PlayerState>((s) => s is PlayerPlaying && s.queue.length > 1)),
        );
        final titles = (playerBloc.state as PlayerPlaying).queue.map((s) => s.title).toList();
        expect(titles.where((t) => t == 'Already Queued'), hasLength(1));
        expect(titles, contains('Fresh Track'));
      });
    });
  });
}
