import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/services/suggestion/jio_resolver.dart';
import 'package:vinyl/services/suggestion/providers/metabrainz_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_service.dart';

/// Runs [body] and returns everything it printed with debugPrint.
Future<List<String>> captureLogs(Future<void> Function() body) async {
  final logs = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) logs.add(message);
  };
  try {
    await body();
  } finally {
    debugPrint = original;
  }
  return logs;
}

Map<String, dynamic> recording(String id, String title) => {
      'id': id,
      'title': title,
      'score': 100,
      'artist-credit': [
        {'name': 'Arijit Singh'}
      ],
    };

Map<String, dynamic> similar(String id, String name) =>
    {'recording_mbid': id, 'recording_name': name, 'artist_credit_name': 'A', 'score': 50};

void main() {
  const seed = SeedSong(title: 'Tum Hi Ho', artist: 'Arijit Singh');

  group('MetaBrainz says what happened, so you can tell whether it is coming', () {
    test('songs found: says how many', () async {
      final logs = await captureLogs(() async {
        final p = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') return {'recordings': [recording('m', 'Tum Hi Ho')]};
          return [similar('a', 'One'), similar('b', 'Two')];
        });
        await p.suggestPatiently(seed);
      });
      expect(logs.any((l) => l.contains('MetaBrainz: looking up "Tum Hi Ho"')), isTrue);
      expect(logs.any((l) => l.contains('MetaBrainz: 2 similar songs for "Tum Hi Ho"')), isTrue);
    });

    test('ListenBrainz has nothing: says "no data", not "failed"', () async {
      final logs = await captureLogs(() async {
        final p = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') return {'recordings': [recording('m', 'Tum Hi Ho')]};
          return [];
        });
        await p.suggestPatiently(seed);
      });
      expect(logs.any((l) => l.contains('no data for "Tum Hi Ho"') && l.contains('not covered')), isTrue);
      expect(logs.any((l) => l.contains('FAILED')), isFalse);
    });

    test('MusicBrainz does not know the song: says so', () async {
      final logs = await captureLogs(() async {
        final p = MetaBrainzProvider(get: (url) async => {'recordings': []});
        await p.suggestPatiently(seed);
      });
      expect(logs.any((l) => l.contains('MusicBrainz does not know "Tum Hi Ho"')), isTrue);
    });

    test('a network failure says FAILED and that it will retry (and why)', () async {
      final logs = await captureLogs(() async {
        final p = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') return {'recordings': [recording('m', 'Tum Hi Ho')]};
          return null; // timeout
        });
        await p.suggestPatiently(seed);
      });
      final failed = logs.where((l) => l.contains('FAILED')).toList();
      expect(failed, hasLength(1));
      expect(failed.single, contains('will retry'));
      expect(failed.single, contains('ListenBrainz'));
    });

    test('the log says how long the lookup took', () async {
      final logs = await captureLogs(() async {
        final p = MetaBrainzProvider(get: (url) async {
          if (url.host == 'musicbrainz.org') return {'recordings': [recording('m', 'Tum Hi Ho')]};
          return [similar('a', 'One')];
        });
        await p.suggestPatiently(seed);
      });
      expect(logs.any((l) => RegExp(r'\(\d+\.\d+s\)').hasMatch(l)), isTrue);
    });
  });

  group('The summary line says where the songs came from', () {
    JioSaavnItem jio(String id, String title, String artist) => JioSaavnItem(
        type: 'song', id: id, token: id, title: title, subtitle: artist, imageUrl: '', duration: '200', directMediaUrl: 'https://x/$id');

    test('per source: asked -> playable -> in the final list', () async {
      final jioSong = jio('j', 'Jio Song', 'Jio Artist');
      final ytSong = jio('y', 'YT Song', 'YT Artist');
      final service = SuggestionService(
        providers: [
          _Fixed(SuggestionSource.jioSaavn, [SuggestionCandidate(title: 'Jio Song', artist: 'Jio Artist', source: SuggestionSource.jioSaavn, rank: 0, jio: jioSong)]),
          _Fixed(SuggestionSource.youtube, [
            const SuggestionCandidate(title: 'YT Song', artist: 'YT Artist', source: SuggestionSource.youtube, rank: 0),
            const SuggestionCandidate(title: 'Not On Jio', artist: 'Nobody', source: SuggestionSource.youtube, rank: 1),
          ]),
        ],
        resolver: JioResolver(search: (q) async => [ytSong].where((s) => q.contains(s.title)).toList()),
      );
      final logs = await captureLogs(() async {
        await service.suggest([const SeedSong(title: 'Seed', artist: 'S')]);
      });
      final summary = logs.singleWhere((l) => l.startsWith('Suggestions ['));
      expect(summary, contains('jioSaavn 1->1->1'));
      expect(summary, contains('youtube 2->1->1')); // 2 asked, 1 matched on JioSaavn, 1 shown
      expect(summary, contains('metaBrainz 0->0->0')); // and MetaBrainz visibly contributed nothing
      expect(summary, contains('2 picked'));
    });
  });
}

class _Fixed implements SuggestionProvider {
  @override
  final SuggestionSource source;
  final List<SuggestionCandidate> candidates;
  _Fixed(this.source, this.candidates);

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async => candidates;
}
