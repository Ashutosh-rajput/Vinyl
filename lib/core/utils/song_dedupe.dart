// Recognises when two listings are the SAME song.
//
// JioSaavn often lists one recording several times (one entry per album or
// release, each with its own id), so the same song can appear twice in a
// list of suggestions. The listings differ in small ways: the title may carry
// a suffix like `(From "Brahmastra")`, or one entry credits one artist and
// another credits two.
//
// What does NOT make two songs the same: only sharing a title. Another
// artist's song with the same name, or a dub in another language, is a
// different song.

/// The artists of a credit as written, without the album JioSaavn glues onto it:
/// "Nadeem-Shravan - Kasoor" -> "Nadeem-Shravan". Only a spaced " - " counts, so
/// hyphenated names stay whole.
String stripAlbumSuffix(String credit) => credit.split(RegExp(r'\s+[-\u2013\u2014]\s+')).first.trim();

/// The album glued onto a credit ("Nadeem-Shravan - Kasoor" -> "Kasoor"), or null.
String? albumSuffixOf(String credit) {
  final parts = credit.split(RegExp(r'\s+[-\u2013\u2014]\s+'));
  if (parts.length < 2) return null;
  final album = parts.sublist(1).join(' - ').trim();
  return album.isEmpty ? null : album;
}

/// Splits an artist credit like "Arijit Singh, Pritam feat. X" into the names as
/// written (punctuation kept: "Nadeem-Shravan", "KR$NA"). The album JioSaavn
/// adds after " - " is not an artist and is dropped first.
List<String> splitArtistCredit(String credit) {
  final artists = stripAlbumSuffix(credit);
  if (artists.isEmpty) return const [];
  return artists
      .split(_artistSplit)
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty && t.toLowerCase() != 'unknown' && t.toLowerCase() != 'various artists')
      .toList();
}

/// Splits an artist credit like "Arijit Singh, Pritam feat. X" into clean,
/// lower-case names, for comparing (punctuation removed).
List<String> parseArtistNames(String artists) {
  if (artists.trim().isEmpty) return const [];
  return splitArtistCredit(artists)
      .map((t) => t.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), ''))
      .where((t) => t.isNotEmpty)
      .toList();
}

final RegExp _artistSplit = RegExp(
  r'[,&/]|(?:\s+feat\.?\s+)|\s+ft\.?\s+|\s+featuring\s+|(?:\s+with\s+)|\s+x\s+',
  caseSensitive: false,
);

/// Words that, at the start of a bracketed title suffix, only describe where
/// the listing comes from, not a different version of the song.
final RegExp _labelSuffix = RegExp(
  r'^(from|feat|ft|featuring|with|original|ost|official|lyric|lyrics|audio|video|full|film|movie|soundtrack|theme from|title)\b',
  caseSensitive: false,
);

/// Normalises a title so two listings of one song compare equal.
///
/// Drops source labels like `(From "Brahmastra")`, ` - From "X"` and
/// `(feat. Y)`, but keeps version markers like `(Remix)`, `(Live)`,
/// `(Reprise)`, `(Acoustic)`: those are different recordings.
String normalizeSongTitle(String title) {
  var t = title
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .toLowerCase();

  t = t.replaceAllMapped(RegExp(r'\s*[\(\[]([^\)\]]*)[\)\]]'), (m) {
    final inner = m.group(1)!.trim();
    return _labelSuffix.hasMatch(inner) ? '' : ' $inner ';
  });
  t = t.replaceAll(RegExp(r'\s+-\s+(from|feat\.?|ft\.?|featuring|with)\b.*$'), '');
  t = t.replaceAll(RegExp(r'[^\w\s]'), ' ');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The facts needed to compare two listings.
class SongFingerprint {
  /// Provider identity (e.g. "jiosaavn:abc123"); equal identities are always
  /// the same song.
  final String identity;
  final String titleKey;
  final Set<String> artists;

  /// Duration in seconds, 0 when unknown.
  final int durationSecs;

  const SongFingerprint._(this.identity, this.titleKey, this.artists, this.durationSecs);

  factory SongFingerprint.of({
    required String identity,
    required String title,
    required String artist,
    int durationSecs = 0,
  }) =>
      SongFingerprint._(identity, normalizeSongTitle(title), parseArtistNames(artist).toSet(), durationSecs);

  /// Same recording listed twice usually differs by at most a second or two;
  /// a remix, live take, extended cut or a dub in another language differs by
  /// more.
  static const int _sameRecordingToleranceSecs = 4;

  /// Duration alone is only trusted this tightly when the artists differ.
  static const int _creditMismatchToleranceSecs = 2;

  bool isSameSongAs(SongFingerprint other) {
    if (identity.isNotEmpty && identity == other.identity) return true;
    if (titleKey.isEmpty || titleKey != other.titleKey) return false;

    final bothDurationsKnown = durationSecs > 0 && other.durationSecs > 0;
    final durationGap = (durationSecs - other.durationSecs).abs();
    if (bothDurationsKnown && durationGap > _sameRecordingToleranceSecs) {
      return false; // a different recording that happens to share the title
    }

    final artistsOverlap = artists.any(other.artists.contains);
    if (artistsOverlap) return true;

    // No shared artist (or no artist given). Listings credited differently
    // can still be one recording; require a near-identical length for that.
    if (bothDurationsKnown && durationGap <= _creditMismatchToleranceSecs) return true;

    // Not enough evidence either way: only when a listing has no artist at
    // all do we treat the title as sufficient.
    return artists.isEmpty || other.artists.isEmpty;
  }
}
