import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/services/suggestion/providers/deezer_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';

Map<String, dynamic> track(int id, String title, String artist, int secs) =>
    {'id': id, 'title': title, 'duration': secs, 'artist': {'name': artist}};

/// A fake Deezer: artist search by name, and one radio per artist id.
DeezerGetFn fakeDeezer({
  Map<String, int> artists = const {},
  Map<int, List<Map<String, dynamic>>> radios = const {},
  List<String>? calls,
}) =>
    (url) async {
      calls?.add(url.path);
      if (url.path == '/search/artist') {
        final q = url.queryParameters['q']!;
        return {
          'data': [
            // a near-miss comes first: it must not be taken
            {'id': 999, 'name': '$q Jr'},
            if (artists.containsKey(q)) {'id': artists[q], 'name': q},
          ]
        };
      }
      final m = RegExp(r'/artist/(\d+)/radio').firstMatch(url.path);
      if (m != null) return {'data': radios[int.parse(m.group(1)!)] ?? []};
      return null;
    };

void main() {
  const seed = SeedSong(title: 'Kitni Bechain Hoke', artist: 'Udit Narayan, Alka Yagnik - Kasoor');

  test('the radio of the seed artists becomes candidates, with real artist and length', () async {
    final provider = DeezerProvider(
      get: fakeDeezer(
        artists: {'Udit Narayan': 1, 'Alka Yagnik': 2},
        radios: {
          1: [track(10, 'Meri Mehbooba', 'Kumar Sanu', 415)],
          2: [track(20, 'Song: Dola Re', 'Kavita Krishnamurthy', 302)],
        },
      ),
    );
    final out = await provider.suggest(seed);
    expect(out.map((c) => c.title), ['Meri Mehbooba', 'Dola Re']); // taken in turns, "Song: " dropped
    expect(out.first.artist, 'Kumar Sanu');
    expect(out.first.durationSecs, 415);
    expect(out.every((c) => c.source == SuggestionSource.deezer), isTrue);
    expect(out.map((c) => c.rank), [0, 1]);
  });

  test('an artist with only a similar name is never used', () async {
    final provider = DeezerProvider(get: fakeDeezer(artists: {}, radios: {999: [track(1, 'Wrong', 'Someone', 200)]}));
    expect(await provider.suggest(seed), isEmpty);
  });

  test('the same song from two radios is listed once', () async {
    final dup = track(10, 'Meri Mehbooba', 'Kumar Sanu', 415);
    final provider = DeezerProvider(get: fakeDeezer(artists: {'Udit Narayan': 1, 'Alka Yagnik': 2}, radios: {1: [dup], 2: [dup]}));
    expect(await provider.suggest(seed), hasLength(1));
  });

  test('the album JioSaavn glues onto the artist is not searched for', () async {
    final calls = <String>[];
    final provider = DeezerProvider(get: fakeDeezer(artists: {'Udit Narayan': 1}, radios: {1: [track(1, 'A', 'B', 100)]}, calls: calls));
    await provider.suggest(const SeedSong(title: 'T', artist: 'Udit Narayan - Kasoor'));
    expect(calls.where((p) => p == '/search/artist'), hasLength(1));
  });

  test('a repeat request for the same artist is served from memory', () async {
    final calls = <String>[];
    final provider = DeezerProvider(get: fakeDeezer(artists: {'Udit Narayan': 1}, radios: {1: [track(1, 'A', 'B', 100)]}, calls: calls));
    const one = SeedSong(title: 'T', artist: 'Udit Narayan');
    await provider.suggest(one);
    final after = calls.length;
    await provider.suggest(one);
    expect(calls.length, after);
  });

  test('a failed request gives nothing and is not remembered as "unknown artist"', () async {
    var fail = true;
    final provider = DeezerProvider(get: (url) async {
      if (fail) return null;
      return fakeDeezer(artists: {'Udit Narayan': 1}, radios: {1: [track(1, 'A', 'B', 100)]})(url);
    });
    const one = SeedSong(title: 'T', artist: 'Udit Narayan');
    expect(await provider.suggest(one), isEmpty);
    fail = false;
    expect(await provider.suggest(one), hasLength(1));
  });

  test('hyphen and spacing do not stop an artist from being found', () {
    expect(DeezerProvider.normalizeArtistName('Nadeem-Shravan'), DeezerProvider.normalizeArtistName('Nadeem Shravan'));
  });
}
