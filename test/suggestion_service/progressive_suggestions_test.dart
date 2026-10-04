import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/services/suggestion/jio_resolver.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_service.dart';

JioSaavnItem jio(String id, String title, String artist) => JioSaavnItem(
      type: 'song',
      id: id,
      token: id,
      title: title,
      subtitle: artist,
      imageUrl: '',
      duration: '200',
      directMediaUrl: 'https://x/$id.mp4',
    );

/// A fast source with a fixed answer.
class FastProvider implements SuggestionProvider {
  @override
  SuggestionSource get source => SuggestionSource.jioSaavn;
  final List<JioSaavnItem> songs;
  FastProvider(this.songs);

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async => [
        for (var i = 0; i < songs.length; i++)
          SuggestionCandidate(
              title: songs[i].title, artist: songs[i].subtitle, source: source, rank: i, jio: songs[i]),
      ];
}

/// A MetaBrainz stand-in: its answer arrives only when the test says so.
class FakeSlowProvider implements SuggestionProvider, SlowProvider {
  @override
  SuggestionSource get source => SuggestionSource.metaBrainz;

  final Map<String, Completer<List<SuggestionCandidate>>> _pending = {};
  final Map<String, List<SuggestionCandidate>> _known = {};
  int warmUps = 0;

  /// Makes the answer for [seedTitle] available at once, as if cached.
  void know(String seedTitle, List<SuggestionCandidate> answer) => _known[seedTitle] = answer;

  /// Delivers the answer for [seedTitle] now.
  void arrive(String seedTitle, List<SuggestionCandidate> answer) {
    _known[seedTitle] = answer;
    _pending[seedTitle]?.complete(answer);
  }

  Completer<List<SuggestionCandidate>> _completer(String title) =>
      _pending.putIfAbsent(title, () => Completer<List<SuggestionCandidate>>());

  @override
  void warmUp(SeedSong seed) => warmUps++;

  @override
  List<SuggestionCandidate>? cachedFor(SeedSong seed) {
    final known = _known[seed.title];
    if (known == null) warmUp(seed);
    return known;
  }

  @override
  Future<List<SuggestionCandidate>> suggestPatiently(SeedSong seed, {int limit = 25, Duration? patience}) {
    final known = _known[seed.title];
    if (known != null) return Future.value(known);
    return _completer(seed.title).future;
  }

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async => cachedFor(seed) ?? const [];
}

SuggestionCandidate mb(int rank, String title, String artist) =>
    SuggestionCandidate(title: title, artist: artist, source: SuggestionSource.metaBrainz, rank: rank);

void main() {
  final jioSong = jio('j1', 'Jio Song', 'Jio Artist');
  final mb1 = jio('m1', 'MB One', 'MB Artist One');
  final mb2 = jio('m2', 'MB Two', 'MB Artist Two');
  const seed = SeedSong(title: 'Seed', artist: 'Seed Artist');

  late FakeSlowProvider slow;
  late SuggestionService service;

  setUp(() {
    slow = FakeSlowProvider();
    service = SuggestionService(
      providers: [FastProvider([jioSong]), slow],
      resolver: JioResolver(
        search: (q) async => [mb1, mb2].where((s) => q.toLowerCase().contains(s.title.toLowerCase())).toList(),
      ),
    );
  });

  group('stage by stage: JioSaavn, then YouTube, then MetaBrainz', () {
    final ytSong = jio('y1', 'YT Song', 'YT Artist');

    SuggestionService staged({required Duration jioDelay, required Duration ytDelay}) => SuggestionService(
          providers: [
            _DelayedProvider(jioSong, jioDelay),
            _DelayedYoutubeProvider('YT Song', 'YT Artist', ytDelay),
            slow,
          ],
          resolver: JioResolver(
            search: (q) async => [ytSong, mb1].where((s) => q.toLowerCase().contains(s.title.toLowerCase())).toList(),
          ),
        );

    test('the first list holds JioSaavn songs only, and arrives before YouTube is done', () async {
      final service = staged(jioDelay: const Duration(milliseconds: 50), ytDelay: const Duration(milliseconds: 600));
      final sw = Stopwatch()..start();
      final first = await service.suggestProgressive([seed]).first;
      expect(first.map((s) => s.item.title), ['Jio Song']);
      expect(sw.elapsedMilliseconds, lessThan(450)); // did not wait for YouTube
    });

    test('YouTube songs are added when YouTube is done, ranked above JioSaavn', () async {
      final service = staged(jioDelay: const Duration(milliseconds: 50), ytDelay: const Duration(milliseconds: 300));
      final lists = <List<String>>[];
      final done = Completer<void>();
      service.suggestProgressive([seed]).listen((l) => lists.add([for (final s in l) s.item.title]), onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      slow.arrive('Seed', const []); // MetaBrainz has nothing
      await done.future.timeout(const Duration(seconds: 3));
      expect(lists, [
        ['Jio Song'],
        ['YT Song', 'Jio Song'],
      ]);
    });

    test('then MetaBrainz songs are added on top: three stages', () async {
      final service = staged(jioDelay: const Duration(milliseconds: 50), ytDelay: const Duration(milliseconds: 300));
      final lists = <List<String>>[];
      final done = Completer<void>();
      service.suggestProgressive([seed]).listen((l) => lists.add([for (final s in l) s.item.title]), onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      slow.arrive('Seed', [mb(0, 'MB One', 'MB Artist One')]);
      await done.future.timeout(const Duration(seconds: 3));
      expect(lists, [
        ['Jio Song'],
        ['YT Song', 'Jio Song'],
        ['MB One', 'YT Song', 'Jio Song'],
      ]);
    });

    test('a source that comes back empty does not produce an empty list', () async {
      final service = SuggestionService(
        providers: [_DelayedProvider(null, const Duration(milliseconds: 10)), slow],
        resolver: JioResolver(search: (q) async => [mb1].where((s) => q.toLowerCase().contains(s.title.toLowerCase())).toList()),
      );
      final lists = <int>[];
      final done = Completer<void>();
      service.suggestProgressive([seed]).listen((l) => lists.add(l.length), onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      slow.arrive('Seed', [mb(0, 'MB One', 'MB Artist One')]);
      await done.future.timeout(const Duration(seconds: 3));
      expect(lists.where((n) => n == 0), isEmpty);
    });

    test('when every source is empty, one empty list is sent and the stream ends', () async {
      final service = SuggestionService(
        providers: [_DelayedProvider(null, const Duration(milliseconds: 10))],
        resolver: JioResolver(search: (q) async => const []),
      );
      final lists = await service.suggestProgressive([seed]).toList();
      expect(lists, hasLength(1));
      expect(lists.single, isEmpty);
    });
  });

  group('suggestProgressive', () {
    test('the first list comes at once, without waiting for the slow source', () async {
      final sw = Stopwatch()..start();
      final first = await service.suggestProgressive([seed]).first;
      expect(first.map((s) => s.item.title), ['Jio Song']);
      expect(sw.elapsedMilliseconds, lessThan(500));
      expect(slow.warmUps, greaterThan(0)); // and the slow lookup was started
    });

    test('when the slow answer arrives, an improved list follows with its songs first', () async {
      final lists = <List<String>>[];
      final done = Completer<void>();
      service.suggestProgressive([seed]).listen(
        (l) => lists.add([for (final s in l) s.item.title]),
        onDone: done.complete,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(lists, [
        ['Jio Song']
      ]);

      slow.arrive('Seed', [mb(0, 'MB One', 'MB Artist One'), mb(1, 'MB Two', 'MB Artist Two')]);
      await done.future.timeout(const Duration(seconds: 3));

      expect(lists, hasLength(2));
      expect(lists[1], ['MB One', 'MB Two', 'Jio Song']); // MetaBrainz outranks the rest
    });

    test('an answer that arrives WHILE the first list is being built is still merged in', () async {
      // The fast source takes 300ms; the slow answer arrives during that time.
      final slowFast = SuggestionService(
        providers: [_DelayedProvider(jioSong, const Duration(milliseconds: 300)), slow],
        resolver: JioResolver(
          search: (q) async => [mb1, mb2].where((s) => q.toLowerCase().contains(s.title.toLowerCase())).toList(),
        ),
      );
      final lists = <List<String>>[];
      final done = Completer<void>();
      slowFast.suggestProgressive([seed]).listen(
        (l) => lists.add([for (final s in l) s.item.title]),
        onDone: done.complete,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100)); // first list still being built
      slow.arrive('Seed', [mb(0, 'MB One', 'MB Artist One')]);
      await done.future.timeout(const Duration(seconds: 3));

      // MetaBrainz answered before the fast source finished: it is shown as soon
      // as it is known, and the fast source's songs join it, nothing is lost.
      expect(lists.last, ['MB One', 'Jio Song']);
      expect(lists.every((l) => l.contains('MB One') || l.contains('Jio Song')), isTrue);
    });

    test('an answer with no data does not rebuild the list', () async {
      var builds = 0;
      final counting = SuggestionService(
        providers: [FastProvider([jioSong]), slow],
        resolver: JioResolver(search: (q) async {
          builds++; // only called when something has to be matched on JioSaavn
          return const [];
        }),
      );
      final done = Completer<void>();
      final lists = <int>[];
      counting.suggestProgressive([seed]).listen((l) => lists.add(l.length), onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      slow.arrive('Seed', const []); // no data
      await done.future.timeout(const Duration(seconds: 3));
      expect(lists, [1]);
      expect(builds, 0);
    });

    test('the stream ends once nothing more is expected', () async {
      final done = Completer<void>();
      service.suggestProgressive([seed]).listen((_) {}, onDone: done.complete);
      slow.arrive('Seed', [mb(0, 'MB One', 'MB Artist One')]);
      await done.future.timeout(const Duration(seconds: 3));
    });

    test('a slow answer that has no data adds no second list', () async {
      final lists = <int>[];
      final done = Completer<void>();
      service.suggestProgressive([seed]).listen((l) => lists.add(l.length), onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      slow.arrive('Seed', const []); // "no data for this song"
      await done.future.timeout(const Duration(seconds: 3));
      expect(lists, [1]);
    });

    test('an answer that is already known gives a single, complete list', () async {
      slow.know('Seed', [mb(0, 'MB One', 'MB Artist One')]);
      final lists = await service.suggestProgressive([seed]).toList();
      expect(lists, hasLength(1));
      expect(lists.single.first.item.title, 'MB One');
    });

    test('a slow song that cannot be matched on JioSaavn does not cause a repeated list', () async {
      final lists = <int>[];
      final done = Completer<void>();
      service.suggestProgressive([seed]).listen((l) => lists.add(l.length), onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      slow.arrive('Seed', [mb(0, 'Not On Jio', 'Nobody')]); // no strict JioSaavn match
      await done.future.timeout(const Duration(seconds: 3));
      expect(lists, [1]); // the list did not change, so it is not sent again
    });

    test('with several seeds, each slow answer improves the list as it arrives', () async {
      const seedB = SeedSong(title: 'Seed B', artist: 'Other');
      final lists = <List<String>>[];
      final done = Completer<void>();
      service.suggestProgressive([seed, seedB]).listen(
        (l) => lists.add([for (final s in l) s.item.title]),
        onDone: done.complete,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      slow.arrive('Seed', [mb(0, 'MB One', 'MB Artist One')]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      slow.arrive('Seed B', [mb(0, 'MB Two', 'MB Artist Two')]);
      await done.future.timeout(const Duration(seconds: 3));

      expect(lists, hasLength(3));
      expect(lists[1], contains('MB One'));
      expect(lists[1], isNot(contains('MB Two')));
      expect(lists[2], containsAll(['MB One', 'MB Two']));
    });

    test('when the slow answer never comes, the fast list stands and the stream ends', () async {
      final neverService = SuggestionService(
        providers: [FastProvider([jioSong]), _NeverProvider()],
        resolver: JioResolver(search: (q) async => const []),
      );
      final lists = await neverService.suggestProgressive([seed], patience: const Duration(milliseconds: 200)).toList();
      expect(lists, hasLength(1));
    });

    test('cancelling stops the updates without errors', () async {
      final received = <int>[];
      final sub = service.suggestProgressive([seed]).listen((l) => received.add(l.length));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();
      slow.arrive('Seed', [mb(0, 'MB One', 'MB Artist One')]); // arrives after the user left
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, [1]);
    });

    test('no seeds gives an empty stream', () async {
      expect(await service.suggestProgressive([]).toList(), isEmpty);
    });

    test('plain suggest still waits for slow providers (Autoplay and Radio)', () async {
      slow.know('Seed', [mb(0, 'MB One', 'MB Artist One')]);
      final out = await service.suggest([seed]);
      expect(out.first.item.title, 'MB One');
    });
  });
}

/// A slow source that never answers.
class _NeverProvider implements SuggestionProvider, SlowProvider {
  @override
  SuggestionSource get source => SuggestionSource.metaBrainz;
  @override
  void warmUp(SeedSong seed) {}
  @override
  List<SuggestionCandidate>? cachedFor(SeedSong seed) => null;
  @override
  Future<List<SuggestionCandidate>> suggestPatiently(SeedSong seed, {int limit = 25, Duration? patience}) =>
      Completer<List<SuggestionCandidate>>().future.timeout(patience ?? const Duration(seconds: 1), onTimeout: () => const []);
  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async => const [];
}

/// A fast source that takes a while (null song = it has nothing to say).
class _DelayedProvider implements SuggestionProvider {
  @override
  SuggestionSource get source => SuggestionSource.jioSaavn;
  final JioSaavnItem? song;
  final Duration delay;
  _DelayedProvider(this.song, this.delay);

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async {
    await Future<void>.delayed(delay);
    final s = song;
    if (s == null) return const [];
    return [SuggestionCandidate(title: s.title, artist: s.subtitle, source: source, rank: 0, jio: s)];
  }
}

/// A YouTube stand-in: slower, and its songs still have to be matched on JioSaavn.
class _DelayedYoutubeProvider implements SuggestionProvider {
  @override
  SuggestionSource get source => SuggestionSource.youtube;
  final String title;
  final String artist;
  final Duration delay;
  _DelayedYoutubeProvider(this.title, this.artist, this.delay);

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async {
    await Future<void>.delayed(delay);
    return [SuggestionCandidate(title: title, artist: artist, source: source, rank: 0)];
  }
}
