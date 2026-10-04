import 'package:vinyl/core/utils/song_dedupe.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/data/models/song_model.dart';

/// Where a suggestion came from. The order is the priority order: the engine
/// prefers MetaBrainz, then YouTube, then JioSaavn.
enum SuggestionSource { metaBrainz, youtube, jioSaavn }

extension SuggestionSourcePriority on SuggestionSource {
  /// Base score of a suggestion from this source. The gap between tiers is
  /// larger than anything the rank inside a tier can add, so a higher-priority
  /// source always comes first unless several sources agree on a song.
  double get tierScore => switch (this) {
        SuggestionSource.metaBrainz => 3.0,
        SuggestionSource.youtube => 2.0,
        SuggestionSource.jioSaavn => 1.0,
      };
}

/// A song the user listened to. The input of the suggestion service.
///
/// Only [title] and [artist] are required; the more is known (album, length,
/// provider ids) the more reliably the providers can identify the song.
class SeedSong {
  final String title;

  /// Credit as shown to the user, e.g. "Dhanda Nyoliwala, KR$NA".
  final String artist;
  final String? album;

  /// 0 when unknown.
  final int durationSecs;

  /// JioSaavn id, when the song came from JioSaavn.
  final String? jioId;

  /// YouTube video id, when the song came from YouTube.
  final String? youtubeId;

  /// MusicBrainz recording id, when already known.
  final String? mbid;

  const SeedSong({
    required this.title,
    required this.artist,
    this.album,
    this.durationSecs = 0,
    this.jioId,
    this.youtubeId,
    this.mbid,
  });

  factory SeedSong.fromSong(Song song) {
    final source = song.effectiveSource;
    final providerId = (song.mediaId ?? '').trim();
    // JioSaavn credits look like "Artist, Artist - Album". The album is not an
    // artist: keep it out of the artist, and use it as the album when the song
    // has no album of its own.
    final album = song.album.isNotEmpty && song.album != 'JioSaavn' ? song.album : albumSuffixOf(song.artist);
    return SeedSong(
      title: song.title,
      artist: stripAlbumSuffix(song.artist),
      album: album,
      durationSecs: song.duration.inSeconds,
      jioId: source == 'jiosaavn' && providerId.isNotEmpty ? providerId : null,
      youtubeId: source == 'youtube' && providerId.isNotEmpty ? providerId : null,
    );
  }

  /// "title artist", the text used to find this song on a provider.
  String get searchText => '$title $artist'.replaceAll(RegExp(r'\s+'), ' ').trim();

  SeedSong copyWith({String? jioId, String? youtubeId, String? mbid}) => SeedSong(
        title: title,
        artist: artist,
        album: album,
        durationSecs: durationSecs,
        jioId: jioId ?? this.jioId,
        youtubeId: youtubeId ?? this.youtubeId,
        mbid: mbid ?? this.mbid,
      );

  @override
  String toString() => 'SeedSong("$title" by "$artist")';
}

/// One suggestion as a provider reports it, before it is matched to a
/// playable JioSaavn song.
class SuggestionCandidate {
  final String title;
  final String artist;
  final String? album;

  /// 0 when unknown.
  final int durationSecs;
  final SuggestionSource source;

  /// Position in the provider's own list, 0 = best.
  final int rank;

  /// Provider-specific identity (MusicBrainz recording id, YouTube video id,
  /// JioSaavn id).
  final String? providerId;

  /// Other (title, artist) readings of the same listing. YouTube titles such
  /// as "Artist - Song" are ambiguous, so the parser offers both orders.
  final List<({String title, String artist})> alternatives;

  /// Set when the candidate already is a playable JioSaavn song.
  final JioSaavnItem? jio;

  const SuggestionCandidate({
    required this.title,
    required this.artist,
    required this.source,
    required this.rank,
    this.album,
    this.durationSecs = 0,
    this.providerId,
    this.alternatives = const [],
    this.jio,
  });

  @override
  String toString() => '[${source.name} #$rank] "$title" by "$artist"';
}

/// A final suggestion: a playable JioSaavn song plus why it was chosen.
class Suggestion {
  final JioSaavnItem item;

  /// Every source that suggested this song.
  final Set<SuggestionSource> sources;

  /// How many of the seed songs led to it.
  final int seedHits;
  final double score;

  const Suggestion({
    required this.item,
    required this.sources,
    required this.seedHits,
    required this.score,
  });

  Song toSong() => item.toSong();

  @override
  String toString() =>
      '"${item.title}" by "${item.subtitle}" (${sources.map((s) => s.name).join('+')}, ${score.toStringAsFixed(2)})';
}
