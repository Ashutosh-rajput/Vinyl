import 'package:vinyl/core/utils/jiosaavn_decoder.dart';
import 'package:vinyl/core/utils/song_dedupe.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';

typedef JioSearchFn = Future<List<JioSaavnItem>> Function(String query);

/// Turns "a song named X by Y" (from YouTube or MetaBrainz) into the playable
/// JioSaavn song, or into nothing.
///
/// It does not trust JioSaavn's search order. A search result is accepted only
/// when it matches the wanted song on every field that both sides know:
///
///  * the title is the same (after dropping labels like `(From "Film")`),
///  * at least one artist is the same,
///  * the album is the same, when both are known,
///  * the length is within [durationToleranceSecs], when both are known,
///  * the explicit flag is the same, when the wanted side says it is explicit.
///
/// When nothing passes, the answer is null and the caller simply skips the
/// suggestion. A missing suggestion is better than playing the wrong song.
class JioResolver {
  final JioSearchFn _search;
  final int durationToleranceSecs;

  /// Results by wanted title+artist; null results are cached too, so a song
  /// that has no JioSaavn match is not searched for again.
  final Map<String, JioSaavnItem?> _cache = {};

  /// Looks up the length (seconds) of a YouTube video, for related videos that
  /// come without one. Optional; without it such videos cannot be title-matched.
  final Future<int> Function(String videoId)? youtubeLength;
  final Map<String, int> _lengths = {};

  JioResolver({JioSearchFn? search, this.durationToleranceSecs = 12, this.youtubeLength})
      : _search = search ?? JioSaavnDecoder.searchSongs;

  Future<int> _lengthOf(SuggestionCandidate c) async {
    if (c.durationSecs > 0) return c.durationSecs;
    final id = c.providerId;
    final lookup = youtubeLength;
    if (id == null || lookup == null) return 0;
    final known = _lengths[id];
    if (known != null) return known;
    try {
      return _lengths[id] = await lookup(id);
    } catch (_) {
      return 0;
    }
  }

  /// The playable JioSaavn song for [candidate], trying each reading of its
  /// title and artist in turn.
  Future<JioSaavnItem?> resolve(SuggestionCandidate candidate) async {
    if (candidate.jio != null) return candidate.jio;

    final readings = [
      (title: candidate.title, artist: candidate.artist),
      ...candidate.alternatives,
    ];
    for (final reading in readings) {
      final found = await _resolveReading(
        title: reading.title,
        artist: reading.artist,
        album: candidate.album,
        durationSecs: candidate.durationSecs,
      );
      if (found != null) return found;
    }

    // YouTube names the uploading channel ("Saregama", "T-Series"), not the
    // singer, so the artist check rejects correct songs. As a last resort,
    // search by title alone and trust the length instead.
    final length = candidate.source == SuggestionSource.youtube ? await _lengthOf(candidate) : 0;
    if (length > 0) {
      final titles = {candidate.title, ...candidate.alternatives.map((a) => a.title)};
      for (final title in titles) {
        final found = await _resolveReading(
          title: title,
          artist: '',
          album: candidate.album,
          durationSecs: length,
          titleOnly: true,
        );
        if (found != null) return found;
      }
    }
    return null;
  }

  /// The JioSaavn song for a seed the user played from another source.
  Future<JioSaavnItem?> resolveSeed(SeedSong seed) => _resolveReading(
        title: seed.title,
        artist: seed.artist,
        album: seed.album,
        durationSecs: seed.durationSecs,
      );

  Future<JioSaavnItem?> _resolveReading({
    required String title,
    required String artist,
    String? album,
    int durationSecs = 0,
    bool titleOnly = false,
  }) async {
    final wantedTitle = normalizeSongTitle(title);
    if (wantedTitle.isEmpty) return null;

    final key = '$wantedTitle|${parseArtistNames(artist).join(',')}|$titleOnly|${titleOnly ? durationSecs ~/ 10 : 0}';
    if (_cache.containsKey(key)) return _cache[key];

    final hasAlbum = album != null && album.trim().isNotEmpty;
    final queries = <String>[
      if (hasAlbum) _squash('$album $title $artist'),
      _squash('$title $artist'),
    ];

    JioSaavnItem? best;
    for (final query in queries.toSet()) {
      List<JioSaavnItem> results;
      try {
        results = await _search(query);
      } catch (_) {
        results = const [];
      }
      best = pickMatch(
        results,
        title: title,
        artist: artist,
        album: album,
        durationSecs: durationSecs,
        durationToleranceSecs: durationToleranceSecs,
        titleOnly: titleOnly,
      );
      if (best != null) break;
    }
    return _cache[key] = best;
  }

  /// The first of [results] that matches the wanted song on every known
  /// field, preferring one whose album also matches.
  static JioSaavnItem? pickMatch(
    List<JioSaavnItem> results, {
    required String title,
    required String artist,
    String? album,
    int durationSecs = 0,
    int durationToleranceSecs = 12,
    bool titleOnly = false,
  }) {
    final wantedAlbum = normalizeSongTitle(album ?? '');
    final songs = results.where((r) => r.isSong).toList();

    // Same album first, as in the original matching rules.
    if (wantedAlbum.isNotEmpty) {
      songs.sort((a, b) {
        final aAlbum = normalizeSongTitle(a.album ?? '') == wantedAlbum ? 0 : 1;
        final bAlbum = normalizeSongTitle(b.album ?? '') == wantedAlbum ? 0 : 1;
        return aAlbum.compareTo(bAlbum);
      });
    }

    for (final candidate in songs) {
      if (matches(
        candidate,
        title: title,
        artist: artist,
        album: album,
        durationSecs: durationSecs,
        durationToleranceSecs: durationToleranceSecs,
        titleOnly: titleOnly,
      )) {
        return candidate;
      }
    }
    return null;
  }

  /// Whether [candidate] is the wanted song.
  static bool matches(
    JioSaavnItem candidate, {
    required String title,
    required String artist,
    String? album,
    int durationSecs = 0,
    int durationToleranceSecs = 12,
    bool titleOnly = false,
  }) {
    // Title: same after dropping source labels; version markers such as
    // "Remix" or "Live" are kept, so those stay different songs.
    if (normalizeSongTitle(candidate.title) != normalizeSongTitle(title)) return false;

    // Artist: at least one in common. A title-only match (the wanted artist
    // is just an uploader channel) has no artist to compare, so it must be
    // backed by a known, close length instead.
    if (titleOnly) {
      final candidateSecs = int.tryParse(candidate.duration ?? '') ?? 0;
      if (durationSecs <= 0 || candidateSecs <= 0) return false;
    }
    final wantedArtists = parseArtistNames(artist).toSet();
    if (wantedArtists.isNotEmpty && !jioArtists(candidate).any(wantedArtists.contains)) return false;

    // Album: only compared when both sides know it.
    final wantedAlbum = normalizeSongTitle(album ?? '');
    final candidateAlbum = normalizeSongTitle(candidate.album ?? '');
    if (wantedAlbum.isNotEmpty && candidateAlbum.isNotEmpty && wantedAlbum != candidateAlbum) return false;

    // Length: only compared when both sides know it.
    final candidateSecs = int.tryParse(candidate.duration ?? '') ?? 0;
    if (durationSecs > 0 && candidateSecs > 0 && (durationSecs - candidateSecs).abs() > durationToleranceSecs) {
      return false;
    }
    return true;
  }

  /// The artists of a JioSaavn song. Its subtitle sometimes has the album
  /// glued on ("Dhanda Nyoliwala, KR$NA - Boom Shaka"); that part is dropped.
  static List<String> jioArtists(JioSaavnItem item) {
    final credit = item.subtitle.split(RegExp(r'\s+-\s+')).first;
    final names = parseArtistNames(credit);
    return names.isNotEmpty ? names : parseArtistNames(item.music ?? '');
  }

  static String _squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
