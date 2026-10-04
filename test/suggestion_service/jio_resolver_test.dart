import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/services/suggestion/jio_resolver.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';

JioSaavnItem jio(String id, String title, String artists, {String? album, int secs = 218, bool explicit = false}) =>
    JioSaavnItem(
      type: 'song',
      id: id,
      token: id,
      title: title,
      subtitle: artists,
      imageUrl: '',
      duration: '$secs',
      album: album,
      explicit: explicit,
      directMediaUrl: 'https://x/$id.mp4',
    );

void main() {
  group('A JioSaavn result is accepted only when it is the same song', () {
    bool ok(
      JioSaavnItem c, {
      String title = 'Boom Shaka',
      String artist = 'Dhanda Nyoliwala, KR\$NA',
      String? album,
      int secs = 218,
    }) =>
        JioResolver.matches(c, title: title, artist: artist, album: album, durationSecs: secs);

    test('same title, artist, album and length', () {
      expect(ok(jio('1', 'Boom Shaka', 'Dhanda Nyoliwala, KR\$NA', album: 'Boom Shaka'), album: 'Boom Shaka'), isTrue);
    });
    test('different title is rejected, even by the same artist', () {
      expect(ok(jio('1', 'Russian Bandana', 'Dhanda Nyoliwala')), isFalse);
    });
    test('same title by an unrelated artist is rejected', () {
      expect(ok(jio('1', 'Boom Shaka', 'Someone Else')), isFalse);
    });
    test('one shared artist is enough', () {
      expect(ok(jio('1', 'Boom Shaka', 'KR\$NA')), isTrue);
    });
    test('the album glued onto the subtitle does not count as an artist', () {
      expect(ok(jio('1', 'Boom Shaka', 'Dhanda Nyoliwala, KR\$NA - Boom Shaka')), isTrue);
      expect(ok(jio('1', 'Boom Shaka', 'Someone - Dhanda Nyoliwala')), isFalse);
    });
    test('a different album is rejected only when both sides know it', () {
      expect(ok(jio('1', 'Boom Shaka', 'KR\$NA', album: 'Other Album'), album: 'Boom Shaka'), isFalse);
      expect(ok(jio('1', 'Boom Shaka', 'KR\$NA', album: 'Other Album')), isTrue);
    });
    test('length must be within 12 seconds when both are known', () {
      expect(ok(jio('1', 'Boom Shaka', 'KR\$NA', secs: 228), secs: 218), isTrue);
      expect(ok(jio('1', 'Boom Shaka', 'KR\$NA', secs: 260), secs: 218), isFalse);
      expect(ok(jio('1', 'Boom Shaka', 'KR\$NA', secs: 260), secs: 0), isTrue);
    });
    test('a remix is a different song; a film label is not', () {
      expect(ok(jio('1', 'Boom Shaka (Remix)', 'KR\$NA')), isFalse);
      expect(ok(jio('1', 'Boom Shaka (From "Some Film")', 'KR\$NA')), isTrue);
    });
  });

  group('JioResolver', () {
    test('picks the right song out of a list of wrong ones', () async {
      final searches = <String>[];
      final resolver = JioResolver(search: (q) async {
        searches.add(q);
        return [
          jio('a', 'Boom Shaka', 'Someone Else'),
          jio('b', 'Boom Shaka', 'Dhanda Nyoliwala, KR\$NA', album: 'Boom Shaka'),
        ];
      });
      final found = await resolver.resolve(const SuggestionCandidate(
        title: 'Boom Shaka',
        artist: 'KR\$NA',
        album: 'Boom Shaka',
        source: SuggestionSource.metaBrainz,
        rank: 0,
      ));
      expect(found?.id, 'b');
      expect(searches.first, contains('Boom Shaka'));
    });

    test('prefers a result whose album also matches', () async {
      final resolver = JioResolver(
        search: (q) async => [
          jio('single', 'Tum Hi Ho', 'Arijit Singh', album: 'Tum Hi Ho (Single)'),
          jio('film', 'Tum Hi Ho', 'Arijit Singh', album: 'Aashiqui 2'),
        ],
      );
      final found = await resolver.resolve(const SuggestionCandidate(
        title: 'Tum Hi Ho',
        artist: 'Arijit Singh',
        album: 'Aashiqui 2',
        source: SuggestionSource.metaBrainz,
        rank: 0,
      ));
      expect(found?.id, 'film');
    });

    test('returns null (not the first result) when nothing matches', () async {
      final resolver = JioResolver(search: (q) async => [jio('a', 'Totally Different', 'Nobody')]);
      expect(
        await resolver.resolve(const SuggestionCandidate(
            title: 'Boom Shaka', artist: 'KR\$NA', source: SuggestionSource.youtube, rank: 0)),
        isNull,
      );
    });

    test('tries the other reading of an ambiguous YouTube title', () async {
      final resolver = JioResolver(search: (q) async => [jio('x', 'Joota Japani', 'KR\$NA, Mukesh')]);
      final found = await resolver.resolve(const SuggestionCandidate(
        title: 'KR\$NA',
        artist: 'Joota Japani', // wrong way round
        source: SuggestionSource.youtube,
        rank: 0,
        alternatives: [(title: 'Joota Japani', artist: 'KR\$NA')],
      ));
      expect(found?.id, 'x');
    });

    test('a song with no match is not searched for twice', () async {
      var calls = 0;
      final resolver = JioResolver(search: (q) async {
        calls++;
        return const [];
      });
      const c = SuggestionCandidate(title: 'Ghost Song', artist: 'Nobody', source: SuggestionSource.youtube, rank: 0);
      await resolver.resolve(c);
      final after = calls;
      await resolver.resolve(c);
      expect(calls, after);
    });

    test('a failing search is treated as no match', () async {
      final resolver = JioResolver(search: (q) async => throw Exception('offline'));
      expect(
        await resolver.resolve(const SuggestionCandidate(title: 'X', artist: 'Y', source: SuggestionSource.youtube, rank: 0)),
        isNull,
      );
    });

    test('a candidate that already is a JioSaavn song needs no search', () async {
      var calls = 0;
      final resolver = JioResolver(search: (q) async {
        calls++;
        return const [];
      });
      final item = jio('j', 'Song', 'A');
      final found = await resolver.resolve(
          SuggestionCandidate(title: 'Song', artist: 'A', source: SuggestionSource.jioSaavn, rank: 0, jio: item));
      expect(found, item);
      expect(calls, 0);
    });
  });
  group('YouTube names the uploading channel, not the singer', () {
    test('a song uploaded by a label still resolves, backed by its length', () async {
      final song = jio('k', 'Kitni Bechain Hoke (From "Kasoor")', 'Alka Yagnik, Udit Narayan - Saregama Carnival', secs: 300);
      final resolver = JioResolver(search: (q) async => [song]);
      final found = await resolver.resolve(const SuggestionCandidate(
        title: 'Kitni Bechain Hoke',
        artist: 'Saregama',
        durationSecs: 297,
        source: SuggestionSource.youtube,
        rank: 0,
      ));
      expect(found, song);
    });

    test('a related video that comes without a length has it looked up, once', () async {
      final song = jio('k', 'Kitni Bechain Hoke (From "Kasoor")', 'Alka Yagnik, Udit Narayan', secs: 300);
      var lookups = 0;
      final resolver = JioResolver(
        search: (q) async => [song],
        youtubeLength: (id) async {
          lookups++;
          return 298;
        },
      );
      const candidate = SuggestionCandidate(
        title: 'Kitni Bechain Hoke',
        artist: 'Saregama',
        source: SuggestionSource.youtube,
        rank: 0,
        providerId: 'vid1',
      );
      expect(await resolver.resolve(candidate), song);
      expect(lookups, 1);
    });

    test('a same-titled song of a different length is not accepted', () async {
      final other = jio('o', 'Tum Hi Ho', 'Someone Else', secs: 150);
      final resolver = JioResolver(search: (q) async => [other]);
      final found = await resolver.resolve(const SuggestionCandidate(
        title: 'Tum Hi Ho',
        artist: 'T-Series',
        durationSecs: 262,
        source: SuggestionSource.youtube,
        rank: 0,
      ));
      expect(found, isNull);
    });

    test('without a known length, a title-only match is refused', () async {
      final song = jio('k', 'Tum Hi Ho', 'Someone Else', secs: 262);
      final resolver = JioResolver(search: (q) async => [song]);
      final found = await resolver.resolve(const SuggestionCandidate(
        title: 'Tum Hi Ho',
        artist: 'T-Series',
        source: SuggestionSource.youtube,
        rank: 0,
      ));
      expect(found, isNull);
    });
  });
}
