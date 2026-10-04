import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/services/suggestion/providers/metabrainz_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';

Map<String, dynamic> recording(String id, String title, int score, {String artist = 'Arijit Singh'}) => {
      'id': id,
      'title': title,
      'score': score,
      // real MusicBrainz answers always say who the recording is credited to
      'artist-credit': [
        {'name': artist}
      ],
    };

Map<String, dynamic> similar(String id, String name, String artist, int score, {String? release}) => {
      'recording_mbid': id,
      'recording_name': name,
      'artist_credit_name': artist,
      'release_name': release,
      'score': score,
    };

void main() {
  group('MetaBrainz answers are read correctly', () {
    test('only confident, same-title recordings are kept, best first', () {
      final ids = MetaBrainzProvider.parseRecordingSearch({
        'recordings': [
          recording('weak', 'Boom Shaka', 70), // low score
          recording('other', 'Boom Shakalaka', 100), // different title
          recording('good-2', 'Boom Shaka', 95),
          recording('good-1', 'Boom Shaka', 100),
        ],
      }, 'Boom Shaka');
      expect(ids, ['good-1', 'good-2']);
    });

    test('similar recordings are ordered by similarity score', () {
      final candidates = MetaBrainzProvider.parseSimilarRecordings([
        similar('b', 'Second', 'B', 30),
        similar('a', 'First', 'A', 81, release: 'Aashiqui 2'),
        similar('c', 'Third', 'C', 10),
      ]);
      expect(candidates.map((c) => c.title), ['First', 'Second', 'Third']);
      expect(candidates.map((c) => c.rank), [0, 1, 2]);
      expect(candidates.first.album, 'Aashiqui 2');
      expect(candidates.first.source, SuggestionSource.metaBrainz);
      expect(candidates.first.providerId, 'a');
    });

    test('empty, malformed and null answers give nothing', () {
      expect(MetaBrainzProvider.parseSimilarRecordings([]), isEmpty);
      expect(MetaBrainzProvider.parseSimilarRecordings(null), isEmpty);
      expect(MetaBrainzProvider.parseSimilarRecordings({'oops': 1}), isEmpty);
      expect(MetaBrainzProvider.parseRecordingSearch(null, 'x'), isEmpty);
      expect(MetaBrainzProvider.parseRecordingSearch({'recordings': 'no'}, 'x'), isEmpty);
    });
  });

  group('MetaBrainzProvider', () {
    const seed = SeedSong(title: 'Tum Hi Ho', artist: 'Arijit Singh');

    test('finds the recording, then asks ListenBrainz for similar ones', () async {
      final urls = <Uri>[];
      final provider = MetaBrainzProvider(get: (url) async {
        urls.add(url);
        if (url.host == 'musicbrainz.org') {
          return {'recordings': [recording('mbid-1', 'Tum Hi Ho', 100)]};
        }
        return [similar('x', 'Sunn Raha Hai', 'Ankit Tiwari', 81, release: 'Aashiqui 2')];
      });
      final out = await provider.suggest(seed);

      expect(out.single.title, 'Sunn Raha Hai');
      expect(urls[0].queryParameters['query'], contains('Tum Hi Ho'));
      expect(urls[1].host, 'labs.api.listenbrainz.org');
      expect(urls[1].queryParameters['recording_mbids'], 'mbid-1');
    });

    test('tries the next recording of the same song when the first has no data', () async {
      final asked = <String>[];
      final provider = MetaBrainzProvider(get: (url) async {
        if (url.host == 'musicbrainz.org') {
          return {'recordings': [recording('empty', 'Tum Hi Ho', 100), recording('full', 'Tum Hi Ho', 98)]};
        }
        asked.add(url.queryParameters['recording_mbids']!);
        return url.queryParameters['recording_mbids'] == 'full' ? [similar('x', 'Song', 'A', 50)] : [];
      });
      final out = await provider.suggest(seed);
      expect(asked, ['empty', 'full']);
      expect(out, hasLength(1));
    });

    test('a known recording id skips the MusicBrainz lookup', () async {
      final hosts = <String>[];
      final provider = MetaBrainzProvider(get: (url) async {
        hosts.add(url.host);
        return [similar('x', 'Song', 'A', 50)];
      });
      await provider.suggest(const SeedSong(title: 'T', artist: 'A', mbid: 'known'));
      expect(hosts, ['labs.api.listenbrainz.org']);
    });

    test('a song MetaBrainz has no data for gives an empty list, not an error', () async {
      final provider = MetaBrainzProvider(get: (url) async {
        if (url.host == 'musicbrainz.org') return {'recordings': [recording('m', 'Tum Hi Ho', 100)]};
        return [];
      });
      expect(await provider.suggest(seed), isEmpty);
    });

    test('a song MusicBrainz does not know gives an empty list', () async {
      final provider = MetaBrainzProvider(get: (url) async => {'recordings': []});
      expect(await provider.suggest(seed), isEmpty);
    });

    test('network failures and timeouts give an empty list', () async {
      expect(await MetaBrainzProvider(get: (url) async => throw Exception('offline')).suggest(seed), isEmpty);
      final slow = MetaBrainzProvider(
        maxWait: const Duration(milliseconds: 50),
        get: (url) => Future.delayed(const Duration(seconds: 5), () => null),
      );
      expect(await slow.suggest(seed), isEmpty);
    });

    group('finding the song on MusicBrainz (from real logs: it said "does not know" for songs it has)', () {
      test('the artist is searched as written, hyphen kept: Nadeem-Shravan, not "nadeemshravan"', () async {
        final queries = <String>[];
        final provider = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') {
            queries.add(url.queryParameters['query']!);
            return {'recordings': [recording('m', 'Kitni Bechain Hoke', 100, artist: 'Nadeem-Shravan')]};
          }
          return [similar('x', 'Song', 'A', 50)];
        });
        await provider.suggest(const SeedSong(title: 'Kitni Bechain Hoke', artist: 'Nadeem-Shravan'));
        expect(queries.first, contains('artist:"Nadeem-Shravan"'));
        expect(queries.first, isNot(contains('nadeemshravan')));
      });

      test('the album JioSaavn glues onto the artist is not searched as an artist', () async {
        final queries = <String>[];
        final provider = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') {
            queries.add(url.queryParameters['query']!);
            return {'recordings': [recording('m', 'Kitni Bechain Hoke', 100, artist: 'Nadeem-Shravan')]};
          }
          return [similar('x', 'Song', 'A', 50)];
        });
        await provider.suggest(const SeedSong(title: 'Kitni Bechain Hoke', artist: 'Nadeem-Shravan - Kasoor'));
        expect(queries.first, isNot(contains('Kasoor')));
        expect(queries.first, contains('Nadeem-Shravan'));
      });

      test('when MusicBrainz credits another artist first, a title-only search still finds it', () async {
        // JioSaavn lists Babul Supriyo first; MusicBrainz credits Himesh Reshammiya.
        final queries = <String>[];
        final provider = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') {
            final q = url.queryParameters['query']!;
            queries.add(q);
            if (q.contains('artist:')) return {'recordings': []}; // the precise search finds nothing
            return {
              'recordings': [
                recording('himesh', 'Main Ishq Uska', 100, artist: 'Himesh Reshammiya'),
                recording('other', 'Main Ishq Uska', 100, artist: 'Anurati Roy'), // a different song, same title
              ]
            };
          }
          return [similar('x', 'Song', 'A', 50)];
        });
        final out = await provider.suggest(const SeedSong(
          title: 'Main Ishq Uska',
          artist: 'Babul Supriyo, Alka Yagnik, Himesh Reshammiya - Vaada',
        ));
        expect(out, hasLength(1));
        expect(queries, hasLength(2)); // precise first, then title only
        expect(queries.last, isNot(contains('artist:')));
      });

      test('a same-titled song by someone unrelated is never accepted', () async {
        final provider = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') {
            return {'recordings': [recording('other', 'Main Ishq Uska', 100, artist: 'Anurati Roy')]};
          }
          return [similar('x', 'Song', 'A', 50)];
        });
        final out = await provider.suggest(const SeedSong(title: 'Main Ishq Uska', artist: 'Himesh Reshammiya'));
        expect(out, isEmpty);
      });

      test('parseRecordingSearch checks the artist credit when asked to', () {
        final data = {
          'recordings': [
            recording('a', 'Song', 100, artist: 'Right Artist'),
            recording('b', 'Song', 100, artist: 'Wrong Artist'),
          ]
        };
        expect(MetaBrainzProvider.parseRecordingSearch(data, 'Song', mustShareArtist: const ['right artist']), ['a']);
        expect(MetaBrainzProvider.parseRecordingSearch(data, 'Song'), ['a', 'b']); // no artist given: title only
      });
    });

    group('after a failure the server is not hammered', () {
      MetaBrainzProvider failing(List<String> labsCalls, {Duration retry = const Duration(minutes: 10)}) => MetaBrainzProvider(
            retryAfterFailure: retry,
            get: (url) async {
              if (url.host == 'musicbrainz.org') {
                return {'recordings': [recording('m', 'Tum Hi Ho', 100)]};
              }
              labsCalls.add('labs');
              return null; // ListenBrainz drops the connection
            },
          );

      test('a failed lookup is not repeated straight away', () async {
        final calls = <String>[];
        final provider = failing(calls);
        expect(await provider.suggestPatiently(seed), isEmpty);
        expect(await provider.suggestPatiently(seed), isEmpty);
        provider.warmUp(seed); // playing the song again does not retry either
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(calls, hasLength(1));
      });

      test('after the cool-down it tries again', () async {
        final calls = <String>[];
        final provider = failing(calls, retry: const Duration(milliseconds: 150));
        await provider.suggestPatiently(seed);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await provider.suggestPatiently(seed);
        expect(calls, hasLength(2));
      });

      test('a failure for one song does not block another', () async {
        final calls = <String>[];
        final provider = failing(calls);
        await provider.suggestPatiently(seed);
        await provider.suggestPatiently(const SeedSong(title: 'Tum Hi Ho', artist: 'Arijit Singh', mbid: 'known')); // different seed key? same song -> blocked
        await provider.suggestPatiently(const SeedSong(title: 'Another Song', artist: 'Someone', mbid: 'other'));
        expect(calls.length, 2); // Tum Hi Ho once, Another Song once
      });

      test('a success clears the failure', () async {
        var attempt = 0;
        final provider = MetaBrainzProvider(
          retryAfterFailure: const Duration(milliseconds: 100),
          get: (url) async {
            if (url.host == 'musicbrainz.org') return {'recordings': [recording('m', 'Tum Hi Ho', 100)]};
            attempt++;
            return attempt == 1 ? null : [similar('x', 'Song', 'A', 50)];
          },
        );
        expect(await provider.suggestPatiently(seed), isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(await provider.suggestPatiently(seed), hasLength(1));
        expect(await provider.suggestPatiently(seed), hasLength(1)); // and it stays cached
      });
    });

    group('it is slow, so the answer is fetched in the background and cached', () {
      // ListenBrainz Labs takes 20-40 seconds; here: 400ms against a 100ms wait.
      MetaBrainzProvider slowProvider({required List<String> labsCalls}) => MetaBrainzProvider(
            maxWait: const Duration(milliseconds: 100),
            get: (url) async {
              if (url.host == 'musicbrainz.org') {
                return {'recordings': [recording('mbid', 'Tum Hi Ho', 100)]};
              }
              labsCalls.add(url.queryParameters['recording_mbids']!);
              await Future<void>.delayed(const Duration(milliseconds: 400));
              return [similar('x', 'Sunn Raha Hai', 'Ankit Tiwari', 81)];
            },
          );

      test('suggest does not wait for the slow answer...', () async {
        final provider = slowProvider(labsCalls: []);
        final sw = Stopwatch()..start();
        expect(await provider.suggest(seed), isEmpty);
        expect(sw.elapsedMilliseconds, lessThan(350));
      });

      test('...but the request carries on, and the next suggest has the answer at once', () async {
        final calls = <String>[];
        final provider = slowProvider(labsCalls: calls);
        await provider.suggest(seed); // gives up after 100ms
        await Future<void>.delayed(const Duration(milliseconds: 600)); // the request finishes
        final sw = Stopwatch()..start();
        final out = await provider.suggest(seed);
        expect(out.single.title, 'Sunn Raha Hai');
        expect(sw.elapsedMilliseconds, lessThan(50));
        expect(calls, hasLength(1)); // not asked again
      });

      test('warmUp fetches ahead of time, so suggest is instant when the queue needs it', () async {
        final calls = <String>[];
        final provider = slowProvider(labsCalls: calls);
        provider.warmUp(seed);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final sw = Stopwatch()..start();
        expect((await provider.suggest(seed)).single.title, 'Sunn Raha Hai');
        expect(sw.elapsedMilliseconds, lessThan(50));
        expect(calls, hasLength(1));
      });

      test('callers that ask while the request runs share one request', () async {
        final calls = <String>[];
        final provider = MetaBrainzProvider(
          maxWait: const Duration(seconds: 2),
          get: (url) async {
            if (url.host == 'musicbrainz.org') {
              return {'recordings': [recording('mbid', 'Tum Hi Ho', 100)]};
            }
            calls.add('labs');
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return [similar('x', 'Song', 'A', 50)];
          },
        );
        provider.warmUp(seed);
        final results = await Future.wait([provider.suggest(seed), provider.suggest(seed)]);
        expect(results.every((r) => r.length == 1), isTrue);
        expect(calls, hasLength(1));
      });

      test('a timeout (the HTTP layer returns nothing) is not remembered as "no data"', () async {
        var labsCalls = 0;
        final provider = MetaBrainzProvider(
          retryAfterFailure: Duration.zero,
          get: (url) async {
          if (url.host == 'musicbrainz.org') {
            return {'recordings': [recording('mbid', 'Tum Hi Ho', 100)]};
          }
          labsCalls++;
          return labsCalls == 1 ? null : [similar('x', 'Song', 'A', 50)]; // first call times out
        });
        expect(await provider.suggest(seed), isEmpty);
        expect(await provider.suggest(seed), hasLength(1)); // asked again, not cached as empty
        expect(labsCalls, 2);
      });

      test('a failed MusicBrainz name lookup is retried next time too', () async {
        var searches = 0;
        final provider = MetaBrainzProvider(
          retryAfterFailure: Duration.zero,
          get: (url) async {
          if (url.host == 'musicbrainz.org') {
            searches++;
            return searches == 1 ? null : {'recordings': [recording('mbid', 'Tum Hi Ho', 100)]};
          }
          return [similar('x', 'Song', 'A', 50)];
        });
        expect(await provider.suggest(seed), isEmpty);
        expect(await provider.suggest(seed), hasLength(1));
      });

      test('a genuine "no data" answer IS remembered, so it is not asked again', () async {
        var labsCalls = 0;
        final provider = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') {
            return {'recordings': [recording('mbid', 'Tum Hi Ho', 100)]};
          }
          labsCalls++;
          return []; // ListenBrainz answered: nothing for this song
        });
        await provider.suggest(seed);
        await provider.suggest(seed);
        expect(labsCalls, 1);
      });

      test('a failed request is not cached, so a later call can succeed', () async {
        var attempt = 0;
        final provider = MetaBrainzProvider(
          retryAfterFailure: Duration.zero,
          get: (url) async {
          if (url.host == 'musicbrainz.org') {
            return {'recordings': [recording('mbid', 'Tum Hi Ho', 100)]};
          }
          attempt++;
          if (attempt == 1) throw Exception('offline');
          return [similar('x', 'Song', 'A', 50)];
        });
        expect(await provider.suggest(seed), isEmpty);
        expect(await provider.suggest(seed), hasLength(1));
      });
    });

    test('the same song is only looked up on MusicBrainz once', () async {
      var musicBrainzCalls = 0;
      final provider = MetaBrainzProvider(get: (url) async {
        if (url.host == 'musicbrainz.org') {
          musicBrainzCalls++;
          return {'recordings': [recording('m', 'Tum Hi Ho', 100)]};
        }
        return [similar('x', 'Song', 'A', 50)];
      });
      await provider.suggest(seed);
      await provider.suggest(seed);
      expect(musicBrainzCalls, 1);
    });

    test('MusicBrainz requests are spaced at least a second apart', () async {
      final stamps = <DateTime>[];
      final provider = MetaBrainzProvider(get: (url) async {
        if (url.host == 'musicbrainz.org') {
          stamps.add(DateTime.now());
          return {'recordings': []};
        }
        return [];
      });
      await Future.wait([
        provider.suggest(const SeedSong(title: 'One', artist: 'A')),
        provider.suggest(const SeedSong(title: 'Two', artist: 'B')),
      ]);
      // Two unknown songs: each is searched precisely, then by title alone.
      expect(stamps.length, greaterThanOrEqualTo(2));
      for (var i = 1; i < stamps.length; i++) {
        expect(stamps[i].difference(stamps[i - 1]).inMilliseconds, greaterThanOrEqualTo(1000),
            reason: 'request $i came too soon after request ${i - 1}');
      }
    });
    group('cachedFor / suggestPatiently (used by the progressive Home list)', () {
      MetaBrainzProvider provider({int labsMs = 300, List<String>? labsCalls}) => MetaBrainzProvider(
            maxWait: const Duration(milliseconds: 50),
            get: (url) async {
              if (url.host == 'musicbrainz.org') {
                return {'recordings': [recording('mbid', 'Tum Hi Ho', 100)]};
              }
              labsCalls?.add('labs');
              await Future<void>.delayed(Duration(milliseconds: labsMs));
              return [similar('x', 'Sunn Raha Hai', 'Ankit Tiwari', 81)];
            },
          );

      test('cachedFor is null until the answer is known, and asking starts the lookup', () async {
        final calls = <String>[];
        final p = provider(labsCalls: calls);
        expect(p.cachedFor(seed), isNull);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(calls, hasLength(1)); // started by cachedFor itself
        expect(p.cachedFor(seed), hasLength(1));
      });

      test('suggestPatiently waits for the full answer, longer than maxWait', () async {
        final p = provider(labsMs: 250);
        final sw = Stopwatch()..start();
        final out = await p.suggestPatiently(seed);
        expect(out.single.title, 'Sunn Raha Hai');
        expect(sw.elapsedMilliseconds, greaterThan(200)); // it did wait, unlike suggest()
      });

      test('suggestPatiently gives up after its patience', () async {
        final p = provider(labsMs: 2000);
        final out = await p.suggestPatiently(seed, patience: const Duration(milliseconds: 100));
        expect(out, isEmpty);
      });

      test('"no data" is a known answer: cachedFor returns an empty list, not null', () async {
        final p = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') return {'recordings': [recording('m', 'Tum Hi Ho', 100)]};
          return [];
        });
        await p.suggestPatiently(seed);
        expect(p.cachedFor(seed), isEmpty);
        expect(p.cachedFor(seed), isNotNull);
      });

      test('suggestPatiently and suggest share one request', () async {
        final calls = <String>[];
        final p = provider(labsCalls: calls);
        await Future.wait([p.suggestPatiently(seed), p.suggest(seed), p.suggestPatiently(seed)]);
        expect(calls, hasLength(1));
      });
    });
  });
}
