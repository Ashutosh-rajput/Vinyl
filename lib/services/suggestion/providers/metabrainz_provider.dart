import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:dio/dio.dart';
import 'package:vinyl/core/utils/song_dedupe.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_provider.dart';

/// Fetches JSON from [url]. Returns null on any failure.
typedef JsonGetFn = Future<dynamic> Function(Uri url);

/// Suggestions from MetaBrainz: the song is found on MusicBrainz, then
/// ListenBrainz's "similar recordings" (built from what real listeners play in
/// the same sessions) gives the songs to suggest.
///
/// Highest priority of the three sources, but two things set it apart:
///
///  * Its coverage is patchy: for many songs, especially recent or regional
///    ones, it has no data and the answer is an empty list. That is normal.
///  * It is SLOW. ListenBrainz's similar-recordings call takes 20 to 40
///    seconds, every time. Nothing can wait that long for a queue, so the
///    answer is fetched in the background ([warmUp], called when a song starts
///    playing) and cached. [suggest] returns the cached answer at once, waits
///    only up to [maxWait] for one that is still on its way, and otherwise
///    gives nothing, while the request carries on and fills the cache for the
///    next time.
class MetaBrainzProvider implements SuggestionProvider, SlowProvider {
  static const String _musicBrainz = 'https://musicbrainz.org/ws/2/recording';
  static const String _similarRecordings = 'https://labs.api.listenbrainz.org/similar-recordings/json';

  /// ListenBrainz's recommended "similar recordings" model.
  static const String _algorithm =
      'session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30';

  /// MusicBrainz allows one request per second per client.
  static const Duration _musicBrainzSpacing = Duration(milliseconds: 1100);

  final JsonGetFn _get;

  /// The longest [suggest] waits for a lookup that is still running.
  final Duration maxWait;

  /// How many MusicBrainz recordings of the same song to try. The same song
  /// often exists under several recording ids, and only some have data.
  final int maxRecordingsToTry;

  final Map<String, List<String>> _mbidCache = {};

  /// When a lookup fails (ListenBrainz drops the connection after ~40 seconds
  /// for some songs) it is not retried at once: every attempt costs the server
  /// that long. A failure is remembered for [retryAfterFailure].
  final Duration retryAfterFailure;
  final Map<String, DateTime> _failedAt = {};

  /// Finished answers by seed, and lookups still running.
  final Map<String, List<SuggestionCandidate>> _answers = {};
  final Map<String, Future<List<SuggestionCandidate>>> _running = {};
  DateTime _lastMusicBrainzCall = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _musicBrainzQueue = Future.value();

  MetaBrainzProvider({
    JsonGetFn? get,
    this.maxWait = const Duration(seconds: 4),
    this.maxRecordingsToTry = 2,
    this.retryAfterFailure = const Duration(minutes: 10),
  }) : _get = get ?? _defaultGet;

  @override
  SuggestionSource get source => SuggestionSource.metaBrainz;

  /// Starts the lookup for [seed] in the background, so that its answer is
  /// ready by the time suggestions are needed.
  @override
  void warmUp(SeedSong seed) {
    unawaited(_lookup(seed));
  }

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async {
    try {
      final answer = await _lookup(seed).timeout(maxWait, onTimeout: () => const []);
      return answer.take(limit).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  List<SuggestionCandidate>? cachedFor(SeedSong seed) {
    final known = _answers[_seedKey(seed)];
    if (known == null) warmUp(seed); // not known yet: start finding out
    return known;
  }

  @override
  Future<List<SuggestionCandidate>> suggestPatiently(
    SeedSong seed, {
    int limit = 25,
    Duration? patience,
  }) async {
    try {
      final answer = await _lookup(seed).timeout(patience ?? const Duration(seconds: 75), onTimeout: () => const []);
      return answer.take(limit).toList();
    } catch (_) {
      return const [];
    }
  }

  static String _seedKey(SeedSong seed) =>
      '${normalizeSongTitle(seed.title)}|${parseArtistNames(seed.artist).firstOrNull ?? ''}';

  /// The (cached) answer for [seed]. One request per song, however many
  /// callers ask while it is running.
  Future<List<SuggestionCandidate>> _lookup(SeedSong seed) {
    final key = _seedKey(seed);
    final done = _answers[key];
    if (done != null) return Future.value(done);

    final failedAt = _failedAt[key];
    if (failedAt != null && DateTime.now().difference(failedAt) < retryAfterFailure) {
      return Future.value(const <SuggestionCandidate>[]); // failed recently: not again yet
    }

    return _running.putIfAbsent(key, () async {
      final clock = Stopwatch()..start();
      final name = '"${seed.title}" by "${seed.artist}"';
      debugPrint('MetaBrainz: looking up $name ...');
      try {
        final answer = await _fetch(seed);
        _answers[key] = answer;
        _failedAt.remove(key);
        debugPrint(answer.isEmpty
            ? 'MetaBrainz: no data for $name (${_secs(clock)}) - this song is not covered'
            : 'MetaBrainz: ${answer.length} similar songs for $name (${_secs(clock)})');
        return answer;
      } catch (e) {
        _failedAt[key] = DateTime.now();
        debugPrint('MetaBrainz: lookup FAILED for $name after ${_secs(clock)}: $e - will retry in ${retryAfterFailure.inMinutes} min');
        return const <SuggestionCandidate>[]; // not cached as an answer: a later call may succeed
      } finally {
        _running.remove(key);
      }
    });
  }

  static String _secs(Stopwatch clock) => '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';

  Future<List<SuggestionCandidate>> _fetch(SeedSong seed) async {
    final mbids = seed.mbid != null ? [seed.mbid!] : await _findRecordings(seed);

    var anyFailed = false;
    for (final mbid in mbids) {
      final data = await _get(Uri.parse(_similarRecordings).replace(queryParameters: {
        'recording_mbids': mbid,
        'algorithm': _algorithm,
      }));
      if (data == null) {
        anyFailed = true; // timeout / network error: not the same as "no data"
        continue;
      }
      final candidates = parseSimilarRecordings(data);
      if (candidates.isNotEmpty) return candidates;
    }
    // "No data" is a real answer and is remembered; a failure is not, so a
    // later call tries again.
    if (anyFailed) throw StateError('ListenBrainz request failed or timed out');
    return const [];
  }

  /// MusicBrainz recording ids for [seed]: confident matches only.
  Future<List<String>> _findRecordings(SeedSong seed) async {
    final key = _seedKey(seed);
    final cached = _mbidCache[key];
    if (cached != null) return cached;

    // The artist as written ("Nadeem-Shravan"), not the comparison form with the
    // punctuation removed, which MusicBrainz would not find.
    final artists = splitArtistCredit(seed.artist);
    final wantedArtists = parseArtistNames(seed.artist);

    Future<List<String>> search(String query, {required List<String> mustShareArtist}) async {
      final data = await _musicBrainzGet(Uri.parse(_musicBrainz).replace(queryParameters: {
        'query': query,
        'fmt': 'json',
        'limit': '25',
      }));
      if (data == null) throw StateError('MusicBrainz name lookup failed (network or rate limit)'); // do not remember a failure
      return parseRecordingSearch(data, seed.title, mustShareArtist: mustShareArtist);
    }

    final title = _escape(seed.title);
    // 1. Title + the first artist: precise.
    var found = artists.isEmpty
        ? await search('recording:"$title"', mustShareArtist: const [])
        : await search('recording:"$title" AND artist:"${_escape(artists.first)}"', mustShareArtist: wantedArtists);
    // 2. MusicBrainz often credits a different artist than JioSaavn lists first
    // (the composer, the lead singer): search by title alone, but accept only a
    // recording that shares at least one artist with the song.
    if (found.isEmpty && artists.isNotEmpty) {
      found = await search('recording:"$title"', mustShareArtist: wantedArtists);
    }
    found = found.take(maxRecordingsToTry).toList();
    if (found.isEmpty) debugPrint('MetaBrainz: MusicBrainz does not know "${seed.title}" by "${seed.artist}" (no confident match)');
    return _mbidCache[key] = found;
  }

  /// MusicBrainz calls are queued and spaced out, whatever the caller does.
  Future<dynamic> _musicBrainzGet(Uri url) {
    final result = Completer<dynamic>();
    _musicBrainzQueue = _musicBrainzQueue.then((_) async {
      final wait = _musicBrainzSpacing - DateTime.now().difference(_lastMusicBrainzCall);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _lastMusicBrainzCall = DateTime.now();
      try {
        result.complete(await _get(url));
      } catch (e) {
        result.complete(null);
      }
    });
    return result.future;
  }

  static String _escape(String s) => s.replaceAll('"', ' ').replaceAll('\\', ' ');

  /// Recording ids from a MusicBrainz search whose title is the wanted title
  /// and whose match score is high, best first.
  ///
  /// With [mustShareArtist] (comparison names, see [parseArtistNames]) a
  /// recording is only accepted if its artist credit contains one of them, so a
  /// different song that happens to have the same title is never taken.
  static List<String> parseRecordingSearch(
    dynamic data,
    String wantedTitle, {
    List<String> mustShareArtist = const [],
  }) {
    if (data is! Map || data['recordings'] is! List) return const [];
    final wanted = normalizeSongTitle(wantedTitle);
    final hits = <({String id, int score})>[];
    for (final r in (data['recordings'] as List).whereType<Map>()) {
      final id = r['id']?.toString() ?? '';
      final score = int.tryParse(r['score']?.toString() ?? '') ?? 0;
      final title = normalizeSongTitle(r['title']?.toString() ?? '');
      if (id.isEmpty || score < 90 || title != wanted) continue;
      if (mustShareArtist.isNotEmpty) {
        final credited = parseArtistNames(_creditText(r));
        if (!credited.any(mustShareArtist.contains)) continue;
      }
      hits.add((id: id, score: score));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return [for (final h in hits) h.id];
  }

  /// The artist credit of a MusicBrainz recording as one string.
  static String _creditText(Map recording) {
    final credit = recording['artist-credit'];
    if (credit is! List) return '';
    return credit
        .whereType<Map>()
        .map((c) => (c['name'] ?? (c['artist'] is Map ? (c['artist'] as Map)['name'] : null))?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .join(', ');
  }

  /// Candidates from a ListenBrainz "similar recordings" answer, highest
  /// similarity score first.
  static List<SuggestionCandidate> parseSimilarRecordings(dynamic data) {
    if (data is! List) return const [];
    final rows = data.whereType<Map>().toList()
      ..sort((a, b) => _score(b).compareTo(_score(a)));
    var rank = 0;
    return [
      for (final r in rows)
        if ((r['recording_name']?.toString() ?? '').trim().isNotEmpty)
          SuggestionCandidate(
            title: r['recording_name'].toString(),
            artist: r['artist_credit_name']?.toString() ?? '',
            album: r['release_name']?.toString(),
            source: SuggestionSource.metaBrainz,
            rank: rank++,
            providerId: r['recording_mbid']?.toString(),
          ),
    ];
  }

  static num _score(Map r) => num.tryParse(r['score']?.toString() ?? '') ?? 0;

  static Future<dynamic> _defaultGet(Uri url) async {
    final dio = Dio();
    try {
      final resp = await dio.getUri(
        url,
        options: Options(
          // The Labs API needs 20 to 40 seconds; it runs in the background.
          receiveTimeout: url.host.startsWith('labs.') ? const Duration(seconds: 70) : const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          // MusicBrainz asks every client to identify itself.
          headers: {'User-Agent': 'Vinyl-Music-App/2.0 (https://github.com/Ashutosh-rajput/Vinyl)'},
        ),
      );
      final data = resp.data;
      return data is String ? jsonDecode(data) : data;
    } catch (_) {
      return null;
    } finally {
      dio.close();
    }
  }
}
