import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:vinyl/core/utils/content_classifier.dart';
import 'package:vinyl/core/utils/song_dedupe.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/services/suggestion/jio_resolver.dart';
import 'package:vinyl/services/suggestion/providers/jiosaavn_provider.dart';
import 'package:vinyl/services/suggestion/providers/metabrainz_provider.dart';
import 'package:vinyl/services/suggestion/providers/youtube_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_provider.dart';

/// Songs in, suggested songs out.
///
/// Give it one song and it returns many songs like it. Give it several (what
/// the user listened to lately) and it returns many songs that fit them all.
///
/// It asks every provider, in parallel, for songs similar to each seed:
///
///   MetaBrainz  (first priority)
///   YouTube     (second)
///   JioSaavn    (third)
///
/// Whatever MetaBrainz and YouTube suggest is matched to the real, playable
/// JioSaavn song (see [JioResolver]), and a suggestion that has no strict match
/// is dropped. The results are then merged: a song several sources agree on is
/// listed once and ranks higher, higher-priority sources come first, and
/// devotional / kids tracks are kept out unless the user listens to those.
///
/// It knows nothing about the user's taste. The optional [tasteBoost] lets the
/// caller (PulseIQ, which only stores taste) nudge the order.
class SuggestionService {
  final List<SuggestionProvider> providers;
  final JioResolver resolver;

  /// How many of the seeds count; the first seed is the most important.
  final int maxSeeds;

  /// How many candidates of each source are matched to JioSaavn, per seed.
  final int resolvePerSource;

  /// How many JioSaavn searches may run at once.
  final int resolveConcurrency;

  /// After this long, no new JioSaavn search is started and the songs matched
  /// so far are used. A queue that arrives a little short beats one that
  /// arrives late.
  final Duration resolveDeadline;

  /// Extra score for songs the user is likely to like, between 0 and
  /// [maxTasteBoost]. Optional.
  final double Function(JioSaavnItem item)? tasteBoost;
  static const double maxTasteBoost = 0.6;

  SuggestionService({
    required this.providers,
    required this.resolver,
    this.maxSeeds = 5,
    this.resolvePerSource = 15,
    this.resolveConcurrency = 6,
    this.resolveDeadline = const Duration(seconds: 12),
    this.tasteBoost,
  });

  /// The standard setup: MetaBrainz, YouTube and JioSaavn sharing one matcher.
  ///
  /// [includeArtistSongs] also adds the seed's credited artists' other songs
  /// (used by Radio). Pass the same [metaBrainz] and [resolver] to every
  /// service in the app so that MetaBrainz answers and JioSaavn matches are
  /// fetched once and reused.
  factory SuggestionService.standard({
    bool includeArtistSongs = false,
    String Function()? language,
    double Function(JioSaavnItem item)? tasteBoost,
    JioResolver? resolver,
    MetaBrainzProvider? metaBrainz,
  }) {
    final jioResolver = resolver ?? JioResolver(youtubeLength: YoutubeProvider.videoLength);
    return SuggestionService(
      resolver: jioResolver,
      tasteBoost: tasteBoost,
      providers: [
        metaBrainz ?? MetaBrainzProvider(),
        YoutubeProvider(),
        JioSaavnProvider(resolver: jioResolver, includeArtistSongs: includeArtistSongs, languageOf: language),
      ],
    );
  }

  static const List<double> _seedWeights = [1.0, 0.8, 0.65, 0.5, 0.4];

  /// Lets the slow providers (MetaBrainz) start working on [seed] now. Call it
  /// when a song starts playing, so the answer is ready when suggestions are
  /// needed minutes later.
  void warmUp(SeedSong seed) {
    for (final provider in providers) {
      if (provider is WarmableProvider) {
        try {
          (provider as WarmableProvider).warmUp(seed);
        } catch (_) {}
      }
    }
  }

  /// Suggestions for [seeds], best first, at most [limit].
  ///
  /// [exclude] lists songs that must not come back (the queue, recent plays).
  /// The seeds themselves never do.
  Future<List<Suggestion>> suggest(
    List<SeedSong> seeds, {
    int limit = 25,
    Iterable<SeedSong> exclude = const [],
  }) =>
      _run(seeds, limit, exclude);

  /// Suggestions that improve over time, for a screen that is on view while
  /// they are found.
  ///
  /// Every source delivers its songs the moment it is ready, and each delivery
  /// produces an improved list:
  ///
  ///  1. JioSaavn answers first (about a second): the first list.
  ///  2. YouTube follows once its videos are found and matched on JioSaavn
  ///     (a few seconds): its songs are added.
  ///  3. MetaBrainz comes last (20 to 40 seconds, or at once if it was already
  ///     fetched in the background): its songs are added, and rank first.
  ///
  /// A list is only emitted when it differs from the previous one, and nothing
  /// is emitted until there is something to show; if every source comes back
  /// empty, one empty list is emitted at the end. The stream ends when all
  /// sources have answered.
  ///
  /// Cancelling the subscription stops the work at once; the MetaBrainz
  /// lookups carry on in the background and are cached for next time.
  Stream<List<Suggestion>> suggestProgressive(
    List<SeedSong> seeds, {
    int limit = 25,
    Iterable<SeedSong> exclude = const [],
    Duration patience = const Duration(seconds: 75),
  }) {
    // A controller rather than an `async*` generator: a generator cannot be
    // cancelled while it waits, so leaving the screen would leave it running.
    late final StreamController<List<Suggestion>> out;
    StreamController<void>? signals;
    var cancelled = false;

    Future<void> work() async {
      final usedSeeds = seeds.where((s) => s.title.trim().isNotEmpty).take(maxSeeds).toList();
      if (usedSeeds.isEmpty || limit <= 0) return;

      // What each source has said so far, by (source, seed).
      final got = <String, List<_Entry>>{};
      final controller = signals = StreamController<void>();
      var running = 0;

      // Starts one piece of work; when it finishes the list is rebuilt.
      void launch(Future<void> Function() job) {
        running++;
        job().catchError((_) {}).whenComplete(() {
          if (controller.isClosed) return;
          controller.add(null);
          if (--running == 0) controller.close();
        });
      }

      for (var pi = 0; pi < providers.length; pi++) {
        final provider = providers[pi];
        if (provider is SlowProvider) {
          // Slow source: take what it already knows, and wait for the rest,
          // seed by seed.
          final slowProvider = provider as SlowProvider;
          for (var si = 0; si < usedSeeds.length; si++) {
            final seed = usedSeeds[si];
            List<_Entry> entries(List<SuggestionCandidate> list) =>
                [for (final c in list.take(max(limit, 20))) _Entry(c, si)];
            final known = slowProvider.cachedFor(seed); // also starts the lookup
            if (known != null) {
              got['$pi|$si'] = entries(known);
            } else {
              launch(() async {
                final list = await slowProvider
                    .suggestPatiently(seed, limit: max(limit, 20), patience: patience)
                    .catchError((_) => const <SuggestionCandidate>[]);
                got['$pi|$si'] = entries(list);
              });
            }
          }
        } else {
          // Fast source: all its seeds together; it delivers when it is done.
          launch(() async {
            final lists = await Future.wait([
              for (var si = 0; si < usedSeeds.length; si++) _askProvider(provider, usedSeeds[si], si, limit),
            ]);
            for (var si = 0; si < lists.length; si++) {
              got['$pi|$si'] = lists[si];
            }
          });
        }
      }

      var current = <Suggestion>[];
      var emitted = false;
      if (running == 0) controller.close(); // nothing to wait for

      var assembledFrom = -1; // how many candidates the last list was built from
      await for (final _ in controller.stream) {
        if (cancelled) return;
        final entries = got.values.expand((e) => e).toList();
        // An answer that added nothing (a source with no data) changes nothing:
        // do not rebuild the list for it.
        if (entries.length == assembledFrom) continue;
        assembledFrom = entries.length;
        final next = await _assemble(entries, usedSeeds, limit, exclude);
        if (cancelled) return;
        if (next.isEmpty) continue; // nothing to show yet
        if (!emitted || !_sameSongs(current, next)) {
          current = next;
          emitted = true;
          out.add(current);
        }
      }
      if (!cancelled && !emitted) out.add(const []); // every source came back empty
    }

    out = StreamController<List<Suggestion>>(
      onListen: () {
        work().whenComplete(() {
          if (!out.isClosed) out.close();
        });
      },
      onCancel: () {
        cancelled = true;
        signals?.close(); // wake the waiting loop so it can stop
      },
    );
    return out.stream;
  }

  static bool _sameSongs(List<Suggestion> a, List<Suggestion> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].item.id != b[i].item.id) return false;
    }
    return true;
  }

  Future<List<Suggestion>> _run(
    List<SeedSong> seeds,
    int limit,
    Iterable<SeedSong> exclude,
  ) async {
    final usedSeeds = seeds.where((s) => s.title.trim().isNotEmpty).take(maxSeeds).toList();
    if (usedSeeds.isEmpty || limit <= 0) return const [];

    // 1. Ask every provider about every seed, all at once.
    final perSeed = await Future.wait([
      for (var i = 0; i < usedSeeds.length; i++) _candidatesFor(usedSeeds[i], i, limit),
    ]);
    return _assemble(perSeed.expand((e) => e).toList(), usedSeeds, limit, exclude);
  }

  /// Turns raw candidates into the final list: matches them to JioSaavn,
  /// merges, filters, scores and orders.
  Future<List<Suggestion>> _assemble(
    List<_Entry> entries,
    List<SeedSong> usedSeeds,
    int limit,
    Iterable<SeedSong> exclude,
  ) async {
    // 2. Match MetaBrainz / YouTube candidates to playable JioSaavn songs.
    final resolved = await _resolveAll(entries);

    // 3. Merge into one list of distinct songs.
    final merged = <_Merged>[];
    for (final r in resolved) {
      final fingerprint = _fingerprintOf(r.item);
      var target = merged.where((m) => m.fingerprint.isSameSongAs(fingerprint)).firstOrNull;
      if (target == null) {
        target = _Merged(r.item, fingerprint);
        merged.add(target);
      }
      target.add(r);
    }

    // 4. Drop the seeds, the excluded songs and off-topic content.
    final blocked = [
      ...usedSeeds.map(_fingerprintOfSeed),
      ...exclude.map(_fingerprintOfSeed),
    ];
    final allowedKinds = {for (final s in usedSeeds) ContentClassifier.classify('${s.title} ${s.artist} ${s.album ?? ''}')};
    final survivors = merged.where((m) {
      if (blocked.any((b) => b.isSameSongAs(m.fingerprint))) return false;
      final kind = ContentClassifier.ofItem(m.item);
      return kind == null || allowedKinds.contains(kind);
    }).toList();

    // 5. Score and order.
    for (final m in survivors) {
      m.finalScore = m.score + _taste(m.item);
    }
    // Source priority first (MetaBrainz > YouTube > JioSaavn), score within a
    // tier: JioSaavn-only songs only ever fill the space below the others,
    // and among them the most streamed come first (JioSaavn's own suggestions
    // are otherwise unranked filler). Songs with an unknown count go last.
    double bestTier(_Merged m) => m.sources.map((s) => s.tierScore).reduce(max);
    final jioOnly = SuggestionSource.jioSaavn.tierScore;
    survivors.sort((a, b) {
      final byTier = bestTier(b).compareTo(bestTier(a));
      if (byTier != 0) return byTier;
      if (bestTier(a) == jioOnly) {
        final byStreams = b.item.playCount.compareTo(a.item.playCount);
        if (byStreams != 0) return byStreams;
      }
      return b.finalScore.compareTo(a.finalScore);
    });

    final picked = _limitPerArtist(survivors, limit);
    debugPrint(_summary(entries, resolved, picked));
    return [
      for (final m in picked)
        Suggestion(item: m.item, sources: m.sources, seedHits: m.seeds.length, score: m.finalScore),
    ];
  }

  /// One log line that says where the songs came from, per source:
  /// asked -> playable (matched on JioSaavn) -> in the final list.
  String _summary(List<_Entry> entries, List<_Resolved> resolved, List<_Merged> picked) {
    String count(SuggestionSource source) {
      final asked = entries.where((e) => e.candidate.source == source).length;
      final playable = resolved.where((r) => r.candidate.source == source).length;
      final inList = picked.where((m) => m.sources.contains(source)).length;
      return '${source.name} $asked->$playable->$inList';
    }

    return 'Suggestions [asked->playable->in list]: ${SuggestionSource.values.map(count).join(', ')} '
        '| ${picked.length} picked';
  }

  // ---- Steps ----------------------------------------------------------------

  /// What one provider says about one seed.
  Future<List<_Entry>> _askProvider(SuggestionProvider p, SeedSong seed, int seedIndex, int limit) async {
    try {
      final list = await p.suggest(seed, limit: max(limit, 20));
      return [for (final c in list) _Entry(c, seedIndex)];
    } catch (_) {
      return const <_Entry>[];
    }
  }

  Future<List<_Entry>> _candidatesFor(SeedSong seed, int seedIndex, int limit) async {
    final lists = await Future.wait(providers.map((p) async {
      try {
        return await p.suggest(seed, limit: max(limit, 20));
      } catch (_) {
        return const <SuggestionCandidate>[];
      }
    }));
    return [
      for (final list in lists)
        for (final c in list) _Entry(c, seedIndex),
    ];
  }

  Future<List<_Resolved>> _resolveAll(List<_Entry> entries) async {
    // Only the best few of each source are looked up on JioSaavn.
    final taken = <String, int>{};
    final toResolve = <_Entry>[];
    for (final e in entries) {
      if (e.candidate.jio != null) {
        toResolve.add(e);
        continue;
      }
      final key = '${e.seedIndex}|${e.candidate.source.name}';
      final n = taken[key] ?? 0;
      if (n < resolvePerSource) {
        taken[key] = n + 1;
        toResolve.add(e);
      }
    }

    final out = List<_Resolved?>.filled(toResolve.length, null);
    final clock = Stopwatch()..start();
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= toResolve.length) return;
        // Past the deadline only songs that need no search are still taken.
        if (clock.elapsed > resolveDeadline && toResolve[i].candidate.jio == null) continue;
        final e = toResolve[i];
        JioSaavnItem? item;
        try {
          item = await resolver.resolve(e.candidate);
        } catch (_) {
          item = null;
        }
        if (item != null) out[i] = _Resolved(item, e.candidate, e.seedIndex);
      }
    }

    await Future.wait(List.generate(max(1, resolveConcurrency), (_) => worker()));

    // Say which YouTube / MetaBrainz songs found no JioSaavn match, so a low
    // "playable" count in the summary can be explained from the log.
    final missed = [
      for (var i = 0; i < toResolve.length; i++)
        if (out[i] == null && toResolve[i].candidate.jio == null) toResolve[i].candidate,
    ];
    if (missed.isNotEmpty) {
      final sample = missed.take(6).map((c) => '"${c.title}" (${c.source.name}${c.durationSecs > 0 ? ', ${c.durationSecs}s' : ''})');
      debugPrint('Suggestions: no JioSaavn match for ${missed.length} of ${toResolve.length}: ${sample.join(', ')}');
    }
    return out.whereType<_Resolved>().toList();
  }

  double _taste(JioSaavnItem item) {
    final boost = tasteBoost;
    if (boost == null) return 0;
    try {
      return boost(item).clamp(0.0, maxTasteBoost);
    } catch (_) {
      return 0;
    }
  }

  /// At most 4 songs per main artist, except when the suggestions come from so
  /// few artists that the cap could not fill [limit] (a rapper's catalogue).
  List<_Merged> _limitPerArtist(List<_Merged> sorted, int limit) {
    String artistOf(_Merged m) => JioResolver.jioArtists(m.item).firstOrNull ?? '';
    final distinct = {for (final m in sorted) artistOf(m)}..remove('');
    final cap = distinct.length * 4 < limit ? limit : 4;

    final counts = <String, int>{};
    final out = <_Merged>[];
    for (final m in sorted) {
      final artist = artistOf(m);
      if (artist.isNotEmpty) {
        final n = counts[artist] ?? 0;
        if (n >= cap) continue;
        counts[artist] = n + 1;
      }
      out.add(m);
      if (out.length >= limit) break;
    }
    return out;
  }

  SongFingerprint _fingerprintOf(JioSaavnItem item) => SongFingerprint.of(
        identity: item.id.isNotEmpty ? 'jiosaavn:${item.id}' : '',
        title: item.title,
        artist: JioResolver.jioArtists(item).join(', '),
        durationSecs: int.tryParse(item.duration ?? '') ?? 0,
      );

  SongFingerprint _fingerprintOfSeed(SeedSong s) => SongFingerprint.of(
        identity: s.jioId != null && s.jioId!.isNotEmpty ? 'jiosaavn:${s.jioId}' : '',
        title: s.title,
        artist: s.artist,
        durationSecs: s.durationSecs,
      );
}

class _Entry {
  final SuggestionCandidate candidate;
  final int seedIndex;
  _Entry(this.candidate, this.seedIndex);
}

class _Resolved {
  final JioSaavnItem item;
  final SuggestionCandidate candidate;
  final int seedIndex;
  _Resolved(this.item, this.candidate, this.seedIndex);
}

/// One distinct song and everything that suggested it.
class _Merged {
  JioSaavnItem item;
  final SongFingerprint fingerprint;
  final Set<SuggestionSource> sources = {};
  final Set<int> seeds = {};
  double _best = 0;
  double finalScore = 0;

  _Merged(this.item, this.fingerprint);

  void add(_Resolved r) {
    sources.add(r.candidate.source);
    seeds.add(r.seedIndex);

    final weight = r.seedIndex < SuggestionService._seedWeights.length
        ? SuggestionService._seedWeights[r.seedIndex]
        : SuggestionService._seedWeights.last;
    // The tier decides the order between sources; the rank only orders songs
    // within a tier (it can never add as much as the gap between tiers).
    final occurrence = r.candidate.source.tierScore + weight * 0.9 / (r.candidate.rank + 1);
    if (occurrence > _best) {
      _best = occurrence;
      item = r.item; // keep the listing the best-ranked source pointed at
    }
  }

  /// Best single suggestion, plus a bonus for every extra source that agrees
  /// and every extra seed song that led to it. A song that fits several of the
  /// listener's songs is the point of giving several songs, so the seed bonus
  /// is large enough to beat a single-seed top pick; it is capped so that it
  /// can never override the order of the sources outright.
  double get score => _best + 0.5 * (sources.length - 1) + min(1.0, 0.6 * (seeds.length - 1));
}
