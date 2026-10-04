import 'dart:async';

import 'package:vinyl/core/utils/song_dedupe.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// The few fields of a YouTube video the provider needs.
class YtVideo {
  final String id;
  final String title;
  final String author;

  /// 0 when YouTube does not say (related videos usually do not).
  final int durationSecs;

  const YtVideo({required this.id, required this.title, required this.author, this.durationSecs = 0});
}

typedef YtSearchFn = Future<List<YtVideo>> Function(String query);
typedef YtRelatedFn = Future<List<YtVideo>> Function(String videoId);

/// A song name and artist read out of a YouTube video title.
class ParsedYoutubeSong {
  final String title;
  final String artist;

  /// Other readings, for titles like "A - B" where it is unclear which side is
  /// the artist.
  final List<({String title, String artist})> alternatives;

  const ParsedYoutubeSong(this.title, this.artist, this.alternatives);

  @override
  String toString() => '"$title" by "$artist" (+${alternatives.length} alt)';
}

/// Suggestions from YouTube's "related videos" graph.
///
/// Second priority. YouTube's videos are not songs: titles carry labels and
/// hashtags, uploaders are channels, and the list includes reactions and
/// re-uploads. So every video is first cleaned into a (title, artist) pair,
/// junk is thrown away, and only what later matches a real JioSaavn song
/// strictly (see JioResolver) becomes a suggestion.
class YoutubeProvider implements SuggestionProvider {
  final YtSearchFn _search;
  final YtRelatedFn _related;
  final Duration timeout;

  YoutubeProvider({YtSearchFn? search, YtRelatedFn? related, this.timeout = const Duration(seconds: 15)})
      : _search = search ?? _defaultSearch,
        _related = related ?? _defaultRelated;

  @override
  SuggestionSource get source => SuggestionSource.youtube;

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async {
    try {
      return await _suggest(seed, limit).timeout(timeout, onTimeout: () => const []);
    } catch (_) {
      return const [];
    }
  }

  Future<List<SuggestionCandidate>> _suggest(SeedSong seed, int limit) async {
    final videoId = seed.youtubeId ?? await _findSeedVideo(seed);
    if (videoId == null) return const [];

    final related = await _related(videoId);
    var rank = 0;
    final out = <SuggestionCandidate>[];
    for (final video in related) {
      if (video.id == videoId) continue;
      final parsed = parseYoutubeTitle(video.title, video.author);
      if (parsed == null) continue;
      out.add(SuggestionCandidate(
        title: parsed.title,
        artist: parsed.artist,
        durationSecs: video.durationSecs,
        source: SuggestionSource.youtube,
        rank: rank++,
        providerId: video.id,
        alternatives: parsed.alternatives,
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// The YouTube video of the seed song: the first search result whose title
  /// really contains the song's name (the top result is sometimes a cover or a
  /// reaction).
  Future<String?> _findSeedVideo(SeedSong seed) async {
    final results = await _search(seed.searchText);
    final wanted = normalizeSongTitle(seed.title);
    if (wanted.isEmpty) return null;
    for (final video in results) {
      if (parseYoutubeTitle(video.title, video.author) == null) continue; // reaction, compilation...
      if (normalizeSongTitle(video.title).contains(wanted)) return video.id;
    }
    return null;
  }

  // ---- Title cleaning -------------------------------------------------------

  /// Videos that are about a song rather than being the song.
  static final RegExp _notASong = RegExp(
    r'\b(reaction|reacts?|reviews?|tutorial|how to|jukebox|mashup|megamix|nonstop|non stop|'
    r'full album|top \d+|best of|playlist|compilation|karaoke|status|shorts?|ringtone|'
    r'interview|behind the scenes|making of|trailer|teaser|live stream|podcast|episode|'
    r'1 hour|10 hours?|8d audio|slowed|reverb|sped up|nightcore|cover by)\b',
    caseSensitive: false,
  );

  /// Bracketed or trailing labels that describe the upload, not the song.
  static final RegExp _uploadLabel = RegExp(
    r'official|video|audio|lyric|lyrics|lyrical|full song|full video|visuali[sz]er|hd|4k|8k|'
    r'music video|out now|new song|latest|prod\.?|promo|from the album|studio version|'
    r'teaser|trending|viral|1st time|with lyrics|hq|#',
    caseSensitive: false,
  );

  static final RegExp _channelNoise = RegExp(
    r'\b(vevo|official|music|records|recordings|label|entertainment|productions?|channel|tv|topic)\b',
    caseSensitive: false,
  );

  /// Reads a song title and artist out of a YouTube video title, or returns
  /// null when the video is not a song (reactions, compilations, ...).
  ///
  /// "Artist - Song (Official Video) | Label #hashtag" becomes
  /// (Song, Artist). When there is no "Artist - " part the channel name is the
  /// artist. Titles of the form "A - B" keep both readings.
  static ParsedYoutubeSong? parseYoutubeTitle(String rawTitle, String channel) {
    var t = rawTitle
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();
    if (t.isEmpty || _notASong.hasMatch(t)) return null;

    // Only what comes before the first "|" is the song; the rest is credits.
    t = t.split('|').first;

    // Drop bracketed upload labels: (Official Video), [Lyrics], (HD) ...
    t = t.replaceAllMapped(RegExp(r'\s*[\(\[]([^\)\]]*)[\)\]]'), (m) {
      return _uploadLabel.hasMatch(m.group(1)!) ? '' : m.group(0)!;
    });
    // Hashtags and the labels left hanging at the end ("... Official Video").
    t = t.replaceAll(RegExp(r'#\S+'), ' ');
    t = t.replaceAll(
      RegExp(r'\s*[-–—:]?\s*\b(official\s+(music\s+)?video|official\s+audio|lyric(al)?\s+video|full\s+(video|song)|audio\s+song|video\s+song|music\s+video)\b.*$', caseSensitive: false),
      '',
    );
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return null;

    final channelName = _cleanChannel(channel);
    final parts = t
        .split(RegExp(r'\s+[-–—]\s+'))
        .map((p) => p.trim())
        // "Aaya Sher - Lyrical": a part that is only an upload label is not a name.
        .where((p) => p.isNotEmpty && !_pureLabel.hasMatch(p))
        .toList();
    if (parts.isEmpty) return null;

    if (parts.length >= 2) {
      // "Artist - Song". With more parts ("A - A – Song") the last is the song.
      final a = parts.first;
      final b = parts.last;
      final middle = parts.length > 2 ? parts.sublist(1).join(' - ') : null;
      return ParsedYoutubeSong(b, a, [
        (title: a, artist: b),
        if (middle != null) (title: middle, artist: a),
        if (channelName.isNotEmpty) (title: a, artist: channelName),
      ]);
    }
    if (channelName.isEmpty) return null;
    return ParsedYoutubeSong(parts.first, channelName, const []);
  }

  /// A piece of a title that only says what kind of upload it is.
  static final RegExp _pureLabel = RegExp(
    r'^(official(\s+(music|lyric|audio|video))*|lyrical(\s+video)?|lyrics?(\s+video)?|audio(\s+song)?|'
    r'video(\s+song)?|full\s+(song|video)|music\s+video|hd|4k|8k|visuali[sz]er|new\s+song|latest)$',
    caseSensitive: false,
  );

  static String _cleanChannel(String channel) {
    return channel.replaceAll(_channelNoise, ' ').replaceAll(RegExp(r'[^\w\s&,.$]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ---- youtube_explode ------------------------------------------------------

  static YtVideo _toVideo(Video v) => YtVideo(
        id: v.id.value,
        title: v.title,
        author: v.author,
        durationSecs: v.duration?.inSeconds ?? 0,
      );

  static Future<List<YtVideo>> _defaultSearch(String query) async {
    final yt = YoutubeExplode();
    try {
      final results = await yt.search.search(query);
      return [for (final v in results.take(8)) YtVideo(id: v.id.value, title: v.title, author: v.author, durationSecs: v.duration?.inSeconds ?? 0)];
    } finally {
      yt.close();
    }
  }

  /// The length in seconds of one video (0 when YouTube does not say).
  static Future<int> videoLength(String videoId) async {
    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(videoId).timeout(const Duration(seconds: 6));
      return video.duration?.inSeconds ?? 0;
    } finally {
      yt.close();
    }
  }

  static Future<List<YtVideo>> _defaultRelated(String videoId) async {
    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(videoId);
      final related = await yt.videos.getRelatedVideos(video);
      return [for (final v in related ?? const <Video>[]) _toVideo(v)];
    } finally {
      yt.close();
    }
  }
}
