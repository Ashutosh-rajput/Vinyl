
import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/services/suggestion/jio_resolver.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_service.dart';

JioSaavnItem jio(String id, String title, String artist, {int secs = 200, String? album, int plays = 0}) => JioSaavnItem(
      type: 'song',
      id: id,
      token: id,
      title: title,
      subtitle: artist,
      imageUrl: '',
      duration: '$secs',
      album: album,
      playCount: plays,
      directMediaUrl: 'https://x/$id.mp4',
    );

/// Answers from a table: seed title -> candidates.
class FakeProvider implements SuggestionProvider {
  @override
  final SuggestionSource source;
  final Map<String, List<SuggestionCandidate>> answers;
  final Future<List<SuggestionCandidate>> Function(SeedSong)? custom;
  int calls = 0;

  FakeProvider(this.source, this.answers, {this.custom});

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async {
    calls++;
    if (custom != null) return custom!(seed);
    return answers[seed.title] ?? const [];
  }
}

SuggestionCandidate cand(SuggestionSource s, int rank, String title, String artist, {JioSaavnItem? item, int secs = 200}) =>
    SuggestionCandidate(
        title: title, artist: artist, source: s, rank: rank, durationSecs: secs, jio: item, providerId: '$s$rank');

/// A JioSaavn catalogue the resolver can search.
JioResolver catalogue(List<JioSaavnItem> songs) => JioResolver(
      search: (q) async {
        final lower = q.toLowerCase();
        return songs.where((s) => lower.contains(s.title.toLowerCase())).toList();
      },
    );

const seedA = SeedSong(title: 'Seed A', artist: 'Seed Artist', durationSecs: 200);
const seedB = SeedSong(title: 'Seed B', artist: 'Seed Artist 2', durationSecs: 200);

void main() {
  final mbSong = jio('mb1', 'MB Song', 'Artist One');
  final ytSong = jio('yt1', 'YT Song', 'Artist Two');
  final jioSong = jio('jio1', 'Jio Song', 'Artist Three');

  SuggestionService build(
    List<SuggestionProvider> providers, {
    List<JioSaavnItem>? songs,
    double Function(JioSaavnItem)? taste,
    int resolveConcurrency = 6,
  }) =>
      SuggestionService(
        providers: providers,
        resolver: catalogue(songs ?? [mbSong, ytSong, jioSong]),
        tasteBoost: taste,
        resolveConcurrency: resolveConcurrency,
      );

  group('priority: MetaBrainz first, then YouTube, then JioSaavn', () {
    test('one song in, songs from all three sources out, in that order', () async {
      final service = build([
        // Registered in the "wrong" order on purpose: order of the list must not matter.
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [cand(SuggestionSource.jioSaavn, 0, 'Jio Song', 'Artist Three', item: jioSong)]
        }),
        FakeProvider(SuggestionSource.youtube, {
          'Seed A': [cand(SuggestionSource.youtube, 0, 'YT Song', 'Artist Two')]
        }),
        FakeProvider(SuggestionSource.metaBrainz, {
          'Seed A': [cand(SuggestionSource.metaBrainz, 0, 'MB Song', 'Artist One')]
        }),
      ]);
      final out = await service.suggest([seedA]);
      expect(out.map((s) => s.item.title), ['MB Song', 'YT Song', 'Jio Song']);
      expect(out.map((s) => s.sources.single), [SuggestionSource.metaBrainz, SuggestionSource.youtube, SuggestionSource.jioSaavn]);
    });

    test('a bad rank in a better source still beats the best rank of a worse source', () async {
      final songs = [for (var i = 0; i < 12; i++) jio('m$i', 'MB $i', 'Artist M$i'), jioSong];
      final service = build([
        FakeProvider(SuggestionSource.metaBrainz, {
          'Seed A': [for (var i = 0; i < 12; i++) cand(SuggestionSource.metaBrainz, i, 'MB $i', 'Artist M$i')]
        }),
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [cand(SuggestionSource.jioSaavn, 0, 'Jio Song', 'Artist Three', item: jioSong)]
        }),
      ], songs: songs);
      final out = await service.suggest([seedA], limit: 30);
      expect(out.last.item.title, 'Jio Song');
    });
  });

  group('mixing', () {
    test('a song that several sources suggest is listed once and ranks higher', () async {
      final both = jio('both', 'Shared Song', 'Artist Shared');
      final service = build([
        FakeProvider(SuggestionSource.youtube, {
          'Seed A': [
            cand(SuggestionSource.youtube, 0, 'YT Song', 'Artist Two'),
            cand(SuggestionSource.youtube, 1, 'Shared Song', 'Artist Shared'),
          ]
        }),
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [cand(SuggestionSource.jioSaavn, 0, 'Shared Song', 'Artist Shared', item: both)]
        }),
      ], songs: [ytSong, both]);
      final out = await service.suggest([seedA]);
      expect(out.where((s) => s.item.title == 'Shared Song'), hasLength(1));
      expect(out.first.item.title, 'Shared Song');
      expect(out.first.sources, {SuggestionSource.youtube, SuggestionSource.jioSaavn});
    });

    test('the same recording listed under two JioSaavn ids is merged', () async {
      final single = jio('id-1', 'Kesariya', 'Arijit Singh', secs: 268, album: 'Single');
      final film = jio('id-2', 'Kesariya (From "Brahmastra")', 'Arijit Singh, Pritam', secs: 268, album: 'Brahmastra');
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [
            cand(SuggestionSource.jioSaavn, 0, 'Kesariya', 'Arijit Singh', item: single),
            cand(SuggestionSource.jioSaavn, 1, 'Kesariya', 'Arijit Singh, Pritam', item: film),
          ]
        }),
      ]);
      expect(await service.suggest([seedA]), hasLength(1));
    });

    test('a different song with the same title by someone else stays', () async {
      final other = jio('id-3', 'Kesariya', 'Someone Else', secs: 190);
      final real = jio('id-1', 'Kesariya', 'Arijit Singh', secs: 268);
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [
            cand(SuggestionSource.jioSaavn, 0, 'Kesariya', 'Arijit Singh', item: real),
            cand(SuggestionSource.jioSaavn, 1, 'Kesariya', 'Someone Else', item: other),
          ]
        }),
      ]);
      expect(await service.suggest([seedA]), hasLength(2));
    });

    test('suggestions with no strict JioSaavn match are dropped; playable ones stay', () async {
      final service = build([
        FakeProvider(SuggestionSource.youtube, {
          'Seed A': [
            cand(SuggestionSource.youtube, 0, 'Not On Jio', 'Nobody'),
            cand(SuggestionSource.youtube, 1, 'YT Song', 'Wrong Artist'), // title matches, artist does not
            cand(SuggestionSource.youtube, 2, 'YT Song', 'Artist Two'),
          ]
        }),
      ]);
      final out = await service.suggest([seedA]);
      expect(out.map((s) => s.item.id), ['yt1']);
    });
  });

  group('several songs in', () {
    test('suggestions for every seed are returned', () async {
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [cand(SuggestionSource.jioSaavn, 0, 'MB Song', 'Artist One', item: mbSong)],
          'Seed B': [cand(SuggestionSource.jioSaavn, 0, 'YT Song', 'Artist Two', item: ytSong)],
        }),
      ]);
      final out = await service.suggest([seedA, seedB]);
      expect(out.map((s) => s.item.title).toSet(), {'MB Song', 'YT Song'});
    });

    test('a song that fits several seeds outranks one that fits a single seed', () async {
      final common = jio('c', 'Common Song', 'Artist Common');
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [
            cand(SuggestionSource.jioSaavn, 0, 'Jio Song', 'Artist Three', item: jioSong),
            cand(SuggestionSource.jioSaavn, 1, 'Common Song', 'Artist Common', item: common),
          ],
          'Seed B': [cand(SuggestionSource.jioSaavn, 3, 'Common Song', 'Artist Common', item: common)],
        }),
      ]);
      final out = await service.suggest([seedA, seedB]);
      expect(out.first.item.title, 'Common Song');
      expect(out.first.seedHits, 2);
    });

    test('only the first few seeds are used', () async {
      final provider = FakeProvider(SuggestionSource.jioSaavn, {});
      final service = SuggestionService(providers: [provider], resolver: catalogue([]), maxSeeds: 3);
      await service.suggest([for (var i = 0; i < 10; i++) SeedSong(title: 'S$i', artist: 'A')]);
      expect(provider.calls, 3);
    });
  });

  group('what never comes back', () {
    test('the seed itself, even under a different JioSaavn listing', () async {
      final seedListing = jio('s1', 'Seed A', 'Seed Artist', secs: 201);
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [
            cand(SuggestionSource.jioSaavn, 0, 'Seed A', 'Seed Artist', item: seedListing),
            cand(SuggestionSource.jioSaavn, 1, 'MB Song', 'Artist One', item: mbSong),
          ]
        }),
      ]);
      expect((await service.suggest([seedA])).map((s) => s.item.title), ['MB Song']);
    });

    test('songs in the exclude list (queue, recent plays)', () async {
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [
            cand(SuggestionSource.jioSaavn, 0, 'MB Song', 'Artist One', item: mbSong),
            cand(SuggestionSource.jioSaavn, 1, 'YT Song', 'Artist Two', item: ytSong),
          ]
        }),
      ]);
      final out = await service.suggest([seedA], exclude: [const SeedSong(title: 'MB Song', artist: 'Artist One', durationSecs: 200)]);
      expect(out.map((s) => s.item.title), ['YT Song']);
    });

    test('devotional and kids songs, unless the user listens to them', () async {
      final aarti = jio('a', 'Jai Ambe Gauri Aarti', 'Bhajan Group');
      final cartoon = jio('k', 'Motu Patlu Theme Song', 'Cartoon Kids');
      final answers = {
        'Seed A': [
          cand(SuggestionSource.jioSaavn, 0, 'Jai Ambe Gauri Aarti', 'Bhajan Group', item: aarti),
          cand(SuggestionSource.jioSaavn, 1, 'Motu Patlu Theme Song', 'Cartoon Kids', item: cartoon),
          cand(SuggestionSource.jioSaavn, 2, 'MB Song', 'Artist One', item: mbSong),
        ],
        'Devotional Seed': [
          cand(SuggestionSource.jioSaavn, 0, 'Jai Ambe Gauri Aarti', 'Bhajan Group', item: aarti),
          cand(SuggestionSource.jioSaavn, 1, 'Motu Patlu Theme Song', 'Cartoon Kids', item: cartoon),
        ],
      };
      final service = build([FakeProvider(SuggestionSource.jioSaavn, answers)]);

      expect((await service.suggest([seedA])).map((s) => s.item.title), ['MB Song']);

      final out = await service.suggest([const SeedSong(title: 'Devotional Seed', artist: 'Bhajan Bhakti Group')]);
      expect(out.map((s) => s.item.title), contains('Jai Ambe Gauri Aarti'));
      expect(out.map((s) => s.item.title), isNot(contains('Motu Patlu Theme Song')));
    });
  });

  group('robustness', () {
    test('a provider that throws does not stop the others', () async {
      final service = build([
        FakeProvider(SuggestionSource.metaBrainz, {}, custom: (_) async => throw Exception('boom')),
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [cand(SuggestionSource.jioSaavn, 0, 'Jio Song', 'Artist Three', item: jioSong)]
        }),
      ]);
      expect((await service.suggest([seedA])).map((s) => s.item.title), ['Jio Song']);
    });

    test('providers run at the same time, not one after another', () async {
      Future<List<SuggestionCandidate>> slow(SeedSong _) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return const [];
      }

      final service = build([
        FakeProvider(SuggestionSource.metaBrainz, {}, custom: slow),
        FakeProvider(SuggestionSource.youtube, {}, custom: slow),
        FakeProvider(SuggestionSource.jioSaavn, {}, custom: slow),
      ]);
      final sw = Stopwatch()..start();
      await service.suggest([seedA]);
      expect(sw.elapsedMilliseconds, lessThan(700)); // 3 x 300ms if it were sequential
    });

    test('no seeds, blank seeds and a zero limit give nothing', () async {
      final service = build([FakeProvider(SuggestionSource.jioSaavn, {})]);
      expect(await service.suggest([]), isEmpty);
      expect(await service.suggest([const SeedSong(title: '  ', artist: 'x')]), isEmpty);
      expect(await service.suggest([seedA], limit: 0), isEmpty);
    });

    test('JioSaavn searches run a few at a time, not all at once', () async {
      var inFlight = 0;
      var peak = 0;
      final resolver = JioResolver(search: (q) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return const [];
      });
      final service = SuggestionService(
        resolver: resolver,
        resolveConcurrency: 3,
        providers: [
          FakeProvider(SuggestionSource.youtube, {
            'Seed A': [for (var i = 0; i < 12; i++) cand(SuggestionSource.youtube, i, 'Song $i', 'Artist $i')]
          }),
        ],
      );
      await service.suggest([seedA]);
      expect(peak, lessThanOrEqualTo(3));
      expect(peak, greaterThan(1));
    });
  });

  group('limits and variety', () {
    test('at most the requested number of songs', () async {
      final songs = [for (var i = 0; i < 30; i++) jio('j$i', 'Song $i', 'Artist $i')];
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [for (var i = 0; i < 30; i++) cand(SuggestionSource.jioSaavn, i, 'Song $i', 'Artist $i', item: songs[i])]
        }),
      ], songs: songs);
      expect(await service.suggest([seedA], limit: 10), hasLength(10));
    });

    test('no more than 4 songs by one artist when the suggestions are varied', () async {
      final songs = [
        for (var i = 0; i < 10; i++) jio('d$i', 'Dhanda $i', 'Dhanda Nyoliwala'),
        for (var i = 0; i < 12; i++) jio('o$i', 'Other $i', 'Artist $i'),
      ];
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [for (var i = 0; i < songs.length; i++) cand(SuggestionSource.jioSaavn, i, songs[i].title, songs[i].subtitle, item: songs[i])]
        }),
      ], songs: songs);
      final out = await service.suggest([seedA], limit: 15);
      expect(out.where((s) => s.item.subtitle == 'Dhanda Nyoliwala'), hasLength(4));
    });

    test('a list that is all one artist still fills the queue', () async {
      final songs = [for (var i = 0; i < 20; i++) jio('d$i', 'Dhanda $i', 'Dhanda Nyoliwala')];
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [for (var i = 0; i < 20; i++) cand(SuggestionSource.jioSaavn, i, songs[i].title, 'Dhanda Nyoliwala', item: songs[i])]
        }),
      ], songs: songs);
      expect(await service.suggest([seedA], limit: 15), hasLength(15));
    });
  });

  group('taste boost (optional, from PulseIQ)', () {
    final first = jio('f', 'First', 'Artist F');
    final second = jio('s', 'Second', 'Artist S');
    final answers = {
      'Seed A': [
        cand(SuggestionSource.jioSaavn, 0, 'First', 'Artist F', item: first),
        cand(SuggestionSource.jioSaavn, 1, 'Second', 'Artist S', item: second),
      ]
    };

    test('without taste the order is the providers\' order', () async {
      final out = await build([FakeProvider(SuggestionSource.jioSaavn, answers)], songs: [first, second]).suggest([seedA]);
      expect(out.map((s) => s.item.title), ['First', 'Second']);
    });

    test('a liked song moves up within its source', () async {
      final out = await build(
        [FakeProvider(SuggestionSource.jioSaavn, answers)],
        songs: [first, second],
        taste: (item) => item.title == 'Second' ? 0.6 : 0.0,
      ).suggest([seedA]);
      expect(out.first.item.title, 'Second');
    });

    test('taste can never lift a song above a higher-priority source', () async {
      final mb = jio('mb', 'MB Pick', 'Artist M');
      final out = await build([
        FakeProvider(SuggestionSource.metaBrainz, {
          'Seed A': [cand(SuggestionSource.metaBrainz, 5, 'MB Pick', 'Artist M')]
        }),
        FakeProvider(SuggestionSource.jioSaavn, answers),
      ], songs: [mb, first, second], taste: (item) => 100.0 /* absurd: gets clamped */).suggest([seedA]);
      expect(out.first.item.title, 'MB Pick');
    });

    test('a failing taste function is ignored', () async {
      final out = await build(
        [FakeProvider(SuggestionSource.jioSaavn, answers)],
        songs: [first, second],
        taste: (item) => throw StateError('no profile'),
      ).suggest([seedA]);
      expect(out, hasLength(2));
    });
  });

  group('songs without a stream link yet', () {
    test('a JioSaavn suggestion with no media link is still returned (it is resolved when played)', () async {
      const noLink = JioSaavnItem(
        type: 'song', id: 'stream_999', token: 'stream_999', title: 'Online Stream Track',
        subtitle: 'Online Artist', imageUrl: '', directMediaUrl: null, encryptedMediaUrl: null);
      final service = build([
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [cand(SuggestionSource.jioSaavn, 0, 'Online Stream Track', 'Online Artist', item: noLink)]
        }),
      ]);
      final out = await service.suggest([seedA]);
      expect(out, hasLength(1));
      final song = out.single.toSong();
      expect(song.title, 'Online Stream Track');
      expect(song.source, 'jiosaavn');
      expect(song.mediaId, 'stream_999'); // what the player resolves the stream link from
    });
  });
  group('JioSaavn songs are taken by stream count', () {
    test('among JioSaavn-only songs the most streamed come first', () async {
      final quiet = jio('q', 'Quiet Song', 'Artist Q', plays: 1000);
      final hit = jio('h', 'Hit Song', 'Artist H', plays: 90000000);
      final unknown = jio('u', 'Unknown Song', 'Artist U');
      final middle = jio('m', 'Middle Song', 'Artist M', plays: 5000000);
      final service = SuggestionService(providers: [
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [
            cand(SuggestionSource.jioSaavn, 0, 'Quiet Song', 'Artist Q', item: quiet),
            cand(SuggestionSource.jioSaavn, 1, 'Unknown Song', 'Artist U', item: unknown),
            cand(SuggestionSource.jioSaavn, 2, 'Middle Song', 'Artist M', item: middle),
            cand(SuggestionSource.jioSaavn, 3, 'Hit Song', 'Artist H', item: hit),
          ]
        }),
      ], resolver: catalogue([]));
      final out = await service.suggest([seedA]);
      expect(out.map((s) => s.item.id), ['h', 'm', 'q', 'u']);
    });

    test('stream count never lifts a JioSaavn song above a YouTube or MetaBrainz one', () async {
      final popular = jio('p', 'Popular', 'Artist P', plays: 900000000);
      final ytSong = jio('y', 'YT Song', 'Artist Y', plays: 10);
      final service = SuggestionService(providers: [
        FakeProvider(SuggestionSource.jioSaavn, {
          'Seed A': [cand(SuggestionSource.jioSaavn, 0, 'Popular', 'Artist P', item: popular)]
        }),
        FakeProvider(SuggestionSource.youtube, {
          'Seed A': [cand(SuggestionSource.youtube, 0, 'YT Song', 'Artist Y')]
        }),
      ], resolver: catalogue([ytSong]));
      final out = await service.suggest([seedA]);
      expect(out.map((s) => s.item.id), ['y', 'p']);
    });
  });
}
