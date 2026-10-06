import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:vinyl/core/utils/song_dedupe.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_provider.dart';

typedef DeezerGetFn = Future<dynamic> Function(Uri url);

/// Songs from Deezer's artist radio: a mix of songs by artists that sound like
/// the seed's artist. It needs no account or key, answers in about a second,
/// and (unlike YouTube) names the real artist and the exact length of every
/// song, so its songs match JioSaavn reliably.
///
/// It works from the artist, not the song: the suggestions fit the seed's
/// style and era, not its exact tune. That is why it ranks below MetaBrainz
/// (which is song to song) and above YouTube (whose videos are noisy).
class DeezerProvider implements SuggestionProvider {
  static const String _api = 'https://api.deezer.com';

  final DeezerGetFn _get;

  /// How many of the seed's credited artists are used.
  final int maxArtists;

  /// Deezer artist ids by normalised name; null when Deezer does not know the
  /// artist (also remembered, so it is not searched again).
  final Map<String, int?> _artistIds = {};

  /// Radio mixes by artist id. A mix changes on every request, so keeping one
  /// makes repeated suggestions for the same artist stable and saves requests.
  final Map<int, List<Map<String, dynamic>>> _radios = {};

  DeezerProvider({DeezerGetFn? get, this.maxArtists = 2}) : _get = get ?? _defaultGet;

  @override
  SuggestionSource get source => SuggestionSource.deezer;

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async {
    try {
      return await _suggest(seed, limit).timeout(const Duration(seconds: 12), onTimeout: () => const []);
    } catch (_) {
      return const [];
    }
  }

  Future<List<SuggestionCandidate>> _suggest(SeedSong seed, int limit) async {
    final artists = splitArtistCredit(stripAlbumSuffix(seed.artist)).take(maxArtists).toList();
    if (artists.isEmpty) return const [];

    final mixes = await Future.wait([
      for (final name in artists) _radioFor(name, limit),
    ]);
    final found = mixes.fold<int>(0, (n, m) => n + m.length);
    debugPrint('Deezer: $found songs from the radio of ${artists.join(' + ')}');

    // Take the mixes in turns, so one artist does not push the other out.
    final out = <SuggestionCandidate>[];
    final seen = <String>{};
    var rank = 0;
    for (var i = 0; out.length < limit; i++) {
      var any = false;
      for (final mix in mixes) {
        if (i >= mix.length) continue;
        any = true;
        final track = mix[i];
        final candidate = _candidate(track, rank);
        if (candidate == null || !seen.add(track['id'].toString())) continue;
        out.add(candidate);
        rank++;
        if (out.length >= limit) break;
      }
      if (!any) break;
    }
    return out;
  }

  SuggestionCandidate? _candidate(Map<String, dynamic> track, int rank) {
    final title = _cleanTitle(track['title']?.toString() ?? '');
    final artist = (track['artist'] as Map?)?['name']?.toString() ?? '';
    if (title.isEmpty || artist.isEmpty) return null;
    return SuggestionCandidate(
      title: title,
      artist: artist,
      durationSecs: int.tryParse(track['duration']?.toString() ?? '') ?? 0,
      source: SuggestionSource.deezer,
      rank: rank,
      providerId: track['id']?.toString(),
    );
  }

  /// Deezer sometimes prefixes film songs with "Song: ".
  static String _cleanTitle(String title) => title.replaceFirst(RegExp(r'^\s*song\s*:\s*', caseSensitive: false), '').trim();

  Future<List<Map<String, dynamic>>> _radioFor(String artistName, int limit) async {
    final id = await _artistId(artistName);
    if (id == null) return const [];
    final cached = _radios[id];
    if (cached != null) return cached;

    final data = await _get(Uri.parse('$_api/artist/$id/radio?limit=${limit.clamp(10, 40)}'));
    final list = [
      if (data is Map && data['data'] is List)
        for (final t in data['data'] as List)
          if (t is Map<String, dynamic>) t,
    ];
    if (list.isNotEmpty) _radios[id] = list; // an empty or failed answer is not kept
    return list;
  }

  /// The Deezer id of [name]: the first search hit with the same name. A
  /// near-miss (a different artist with a similar name) is never accepted.
  Future<int?> _artistId(String name) async {
    final key = normalizeArtistName(name);
    if (key.isEmpty) return null;
    if (_artistIds.containsKey(key)) return _artistIds[key];

    final data = await _get(Uri.parse('$_api/search/artist?q=${Uri.encodeQueryComponent(name)}&limit=5'));
    if (data is! Map || data['data'] is! List) return null; // failed: try again next time
    int? id;
    for (final a in data['data'] as List) {
      if (a is Map && normalizeArtistName(a['name']?.toString() ?? '') == key) {
        id = (a['id'] as num?)?.toInt();
        break;
      }
    }
    return _artistIds[key] = id;
  }

  /// Names compared without case, punctuation or spacing ("Nadeem-Shravan" and
  /// "Nadeem Shravan" are the same).
  @visibleForTesting
  static String normalizeArtistName(String name) => name.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static Future<dynamic> _defaultGet(Uri url) async {
    final dio = Dio();
    try {
      final resp = await dio.getUri(
        url,
        options: Options(receiveTimeout: const Duration(seconds: 10), sendTimeout: const Duration(seconds: 10)),
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
