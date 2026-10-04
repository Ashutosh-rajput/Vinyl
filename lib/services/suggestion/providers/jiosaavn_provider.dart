import 'package:vinyl/core/utils/jiosaavn_decoder.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/services/suggestion/jio_resolver.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_provider.dart';

typedef JioSuggestionsFn = Future<List<JioSaavnItem>> Function(String songId, {int limit});
typedef JioSongArtistsFn = Future<List<({String id, String name})>> Function(String songId);
typedef JioArtistSongsFn = Future<List<JioSaavnItem>> Function(String artistId, String songId, {String lang});

/// Suggestions from JioSaavn's own recommendation call (`reco.getreco`).
///
/// Lowest priority of the three sources, but its songs are already playable,
/// so they need no matching step.
///
/// With [includeArtistSongs] the credited artists' other songs are added after
/// the recommendations (`search.artistOtherTopSongs`, one call per artist):
/// JioSaavn's recommendations are often a single artist's catalogue, and Radio
/// wants more than that.
class JioSaavnProvider implements SuggestionProvider {
  final JioSuggestionsFn _fetchSuggestions;
  final JioSongArtistsFn _fetchSongArtists;
  final JioArtistSongsFn _fetchArtistSongs;
  final JioResolver _resolver;
  final bool includeArtistSongs;
  /// Read each time, so a change of the Streaming Language applies at once.
  final String Function() languageOf;
  final Duration timeout;

  JioSaavnProvider({
    required JioResolver resolver,
    JioSuggestionsFn? fetchSuggestions,
    JioSongArtistsFn? fetchSongArtists,
    JioArtistSongsFn? fetchArtistSongs,
    this.includeArtistSongs = false,
    String Function()? languageOf,
    this.timeout = const Duration(seconds: 12),
  })  : _resolver = resolver,
        _fetchSuggestions = fetchSuggestions ?? JioSaavnDecoder.fetchSongSuggestions,
        _fetchSongArtists = fetchSongArtists ?? JioSaavnDecoder.fetchSongArtists,
        _fetchArtistSongs = fetchArtistSongs ?? JioSaavnDecoder.fetchArtistOtherSongs,
        languageOf = languageOf ?? (() => 'hindi');

  @override
  SuggestionSource get source => SuggestionSource.jioSaavn;

  @override
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25}) async {
    try {
      return await _suggest(seed, limit).timeout(timeout, onTimeout: () => const []);
    } catch (_) {
      return const [];
    }
  }

  Future<List<SuggestionCandidate>> _suggest(SeedSong seed, int limit) async {
    // The seed may come from YouTube or the device: find it on JioSaavn first.
    var songId = seed.jioId;
    if (songId == null || songId.isEmpty) {
      songId = (await _resolver.resolveSeed(seed))?.id;
    }
    if (songId == null || songId.isEmpty) return const [];

    final found = <JioSaavnItem>[
      ...await _fetchSuggestions(songId, limit: limit),
    ];

    if (includeArtistSongs) {
      final artists = await _fetchSongArtists(songId);
      final lists = await Future.wait(artists.take(4).map((a) async {
        try {
          return await _fetchArtistSongs(a.id, songId!, lang: languageOf());
        } catch (_) {
          return <JioSaavnItem>[];
        }
      }));
      for (final list in lists) {
        found.addAll(list);
      }
    }

    var rank = 0;
    return [
      for (final item in found)
        if (item.isSong && item.title.trim().isNotEmpty)
          SuggestionCandidate(
            title: item.title,
            artist: JioResolver.jioArtists(item).join(', '),
            album: item.album,
            durationSecs: int.tryParse(item.duration ?? '') ?? 0,
            source: SuggestionSource.jioSaavn,
            rank: rank++,
            providerId: item.id,
            jio: item,
          ),
    ];
  }
}
