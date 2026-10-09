import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vinyl/core/di/injection_container.dart';
import 'package:vinyl/core/utils/jiosaavn_decoder.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/data/repositories/music_repository.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/presentation/screens/home_screen.dart';
import 'package:vinyl/presentation/widgets/album_art_widget.dart';
import 'package:vinyl/presentation/widgets/arrival_list.dart';
import 'package:vinyl/presentation/widgets/stream_home_skeleton.dart';
import 'package:vinyl/presentation/widgets/suggestion_source_chip.dart';
import 'package:vinyl/presentation/widgets/suggestion_placeholder_rows.dart';
import 'package:vinyl/presentation/widgets/download_queue_snackbar.dart';
import 'package:vinyl/services/download_service.dart';
import 'package:vinyl/services/settings_service.dart';
import 'package:vinyl/services/stream_cache_service.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_service.dart';
import 'package:vinyl/services/user_taste_service.dart';
import 'package:vinyl/services/stream_favorites_service.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:vinyl/data/models/playlist_model.dart';
import 'package:vinyl/services/stream_playlists_service.dart';
import 'package:vinyl/presentation/widgets/support_banner_widget.dart';
import 'package:vinyl/presentation/widgets/song_options_bottom_sheet.dart';

class StreamScreen extends StatefulWidget {
  const StreamScreen({super.key});

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends State<StreamScreen> with AutomaticKeepAliveClientMixin {
  late String _currentLang;
  bool _isLoading = true;
  String? _errorMessage;
  String? _loadingSongId;
  int _selectedFilter = 0; // 0: All, 1: Songs, 2: Albums, 3: Playlists, 4: Favorites, 5: Last Played, 6: Offline Cache

  // Search state
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;
  bool _isSearchLoading = false;
  List<JioSaavnItem> _searchSongs = [];
  List<JioSaavnItem> _searchAlbums = [];
  List<JioSaavnItem> _searchArtists = [];

  List<JioSaavnItem> _relatedAlbums = [];
  List<JioSaavnItem> _newReleases = [];
  Map<String, List<JioSaavnItem>> _homeModules = {};
  List<Song> _topPlayed = [];
  List<Song> _lastPlayedStreamSongs = [];
  List<JioSaavnItem> _suggestedSongs = [];

  /// Which service(s) each suggested song came from, by song id (developer option).
  Map<String, Set<SuggestionSource>> _suggestionSources = {};

  // Suggestions arrive in stages: YouTube and JioSaavn first, MetaBrainz's
  // songs (slow: 20-40 s) later. They are shown as they come.
  StreamSubscription<List<Suggestion>>? _suggestionsSub;
  bool _suggestionsRefining = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    HomeScreen.tabNotifier.addListener(_handleTabChange);
    final settings = getIt<SettingsService>();
    _currentLang = settings.streamLanguage;
    _loadStreamData();
  }

  @override
  void dispose() {
    HomeScreen.tabNotifier.removeListener(_handleTabChange);
    _suggestionsSub?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (!mounted) return;
    // Rebuild so the search back-handler only applies while this tab is shown.
    setState(() {});
    if (HomeScreen.tabNotifier.value == 1) {
      _loadLastPlayedSongs();
    }
  }

  Future<void> _loadLastPlayedSongs() async {
    try {
      final history = await getIt<MusicRepository>().getLastPlayedStreamSongs(limit: 50);
      if (mounted) {
        setState(() => _lastPlayedStreamSongs = history);
      }
    } catch (_) {}
  }

  Future<void> _loadStreamData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. Fetch top 5 most played songs & last played stream history from repository
      // Stream songs only: Stream recommendations must not be seeded by
      // Library files (whose names are often things like "AUD-2023...").
      _topPlayed = await getIt<MusicRepository>().getMostPlayedSongs(limit: 5, streamOnly: true);
      _lastPlayedStreamSongs = await getIt<MusicRepository>().getLastPlayedStreamSongs();

      // 2. Start the suggestions NOW, in parallel with everything below, so
      // that the section is there when the page is (JioSaavn's songs answer in
      // about a second; YouTube's and MetaBrainz's are added as they arrive).
      _startHomeSuggestions(
        seeds: [
          ...UserTasteService.instance.topSeedSongs(limit: 3),
          ...StreamFavoritesService.instance.favorites.take(2).map(SeedSong.fromSong),
          ..._lastPlayedStreamSongs.take(2).map(SeedSong.fromSong),
        ],
      );

      // 3. Fetch the related albums, new releases and the home feed together
      // (they used to run one after another).
      final results = await Future.wait([
        JioSaavnDecoder.fetchNewReleases(lang: _currentLang),
        JioSaavnDecoder.fetchHomeFeed(lang: _currentLang),
        _fetchRelatedAlbumsForTopSongs(_topPlayed),
      ]);

      final newReleases = results[0] as List<JioSaavnItem>;
      final homeModules = results[1] as Map<String, List<JioSaavnItem>>;

      if (!mounted) return;
      setState(() {
        _newReleases = newReleases;
        _homeModules = homeModules;
        _relatedAlbums = results[2] as List<JioSaavnItem>;
        _isLoading = false;
      });

      // Nothing to base suggestions on (new user, or offline)? Use the feed.
      if (_suggestedSongs.isEmpty && !_suggestionsRefining) _suggestFromHomeFeed();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load stream: $e';
      });
    }
  }

  Future<List<JioSaavnItem>> _fetchRelatedAlbumsForTopSongs(List<Song> songs) async {
    final relatedList = <JioSaavnItem>[];
    final seenIds = <String>{};

    for (final song in songs) {
      if (relatedList.length >= 15) break;
      try {
        final query = (song.album.isNotEmpty && song.album != 'Local Music' && song.album != 'Downloads')
            ? song.album
            : song.title;
        final albums = await JioSaavnDecoder.searchAlbums(query);
        if (albums.isNotEmpty) {
          final targetAlbum = albums.first;
          final related = await JioSaavnDecoder.fetchRelatedAlbums(targetAlbum.id);
          for (final item in related) {
            if (!seenIds.contains(item.id)) {
              seenIds.add(item.id);
              relatedList.add(item);
            }
          }
        }
      } catch (_) {}
    }

    return relatedList;
  }

  /// All individual songs aggregated from Trending, New Releases & Home Modules
  List<JioSaavnItem> get _allSongs {
    final list = <JioSaavnItem>[];
    final seen = <String>{};

    // First collect songs from home modules (Trending Now, What's Hot, etc.)
    for (final entry in _homeModules.entries) {
      for (final item in entry.value) {
        if (item.isSong && !seen.contains(item.id)) {
          seen.add(item.id);
          list.add(item);
        }
      }
    }

    // Next collect songs from new releases
    for (final item in _newReleases) {
      if (item.isSong && !seen.contains(item.id)) {
        seen.add(item.id);
        list.add(item);
      }
    }

    // Collect songs from suggestions
    for (final item in _suggestedSongs) {
      if (item.isSong && !seen.contains(item.id)) {
        seen.add(item.id);
        list.add(item);
      }
    }

    return list;
  }

  /// All albums aggregated
  List<JioSaavnItem> get _allAlbums {
    final list = <JioSaavnItem>[];
    final seen = <String>{};

    for (final item in _relatedAlbums) {
      if (!seen.contains(item.id)) {
        seen.add(item.id);
        list.add(item);
      }
    }

    for (final item in _newReleases) {
      if (item.isAlbum && !seen.contains(item.id)) {
        seen.add(item.id);
        list.add(item);
      }
    }

    for (final entry in _homeModules.entries) {
      for (final item in entry.value) {
        if (item.isAlbum && !seen.contains(item.id)) {
          seen.add(item.id);
          list.add(item);
        }
      }
    }

    return list;
  }

  /// All playlists aggregated
  List<JioSaavnItem> get _allPlaylists {
    final list = <JioSaavnItem>[];
    final seen = <String>{};

    for (final entry in _homeModules.entries) {
      for (final item in entry.value) {
        if (item.isPlaylist && !seen.contains(item.id)) {
          seen.add(item.id);
          list.add(item);
        }
      }
    }

    return list;
  }

  void _showLanguageSelector() {
    final theme = Theme.of(context);
    final langs = SettingsService.supportedStreamLanguages;

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  children: [
                    Icon(Icons.language_rounded, color: theme.colorScheme.primary, size: 22),
                    const SizedBox(width: 10),
                    Text(
                      'Select Streaming Language',
                      style: GoogleFonts.outfit(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: langs.entries.map((entry) {
                    final isSelected = entry.key == _currentLang;
                    return ListTile(
                      title: Text(
                        entry.value,
                        style: GoogleFonts.outfit(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? theme.colorScheme.primary : null,
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary)
                          : null,
                      onTap: () async {
                        Navigator.pop(ctx);
                        if (entry.key != _currentLang) {
                          setState(() => _currentLang = entry.key);
                          await getIt<SettingsService>().setStreamLanguage(entry.key);
                          _loadStreamData();
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openAlbumDetails(JioSaavnItem album) {
    final fromSearch = _isSearching;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _AlbumTracksSheet(
        item: album,
        fromSearch: fromSearch,
      ),
    );
  }

  void _openUserPlaylistDetails(PlaylistModel playlist) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _UserStreamPlaylistSheet(
        playlistId: playlist.id,
      ),
    );
  }

  void _showCreateStreamPlaylistDialog(BuildContext context, {Song? initialSong}) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(
          'Create Stream Playlist',
          style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Playlist Title (e.g. Chill Beats)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                final playlist = await StreamPlaylistsService.instance.createPlaylist(name);
                if (initialSong != null) {
                  await StreamPlaylistsService.instance.addSongToPlaylist(playlist.id, initialSong);
                }
                Fluttertoast.showToast(
                  msg: 'Created "$name"',
                  toastLength: Toast.LENGTH_SHORT,
                );
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _openSuggestedSongsDetails() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _SuggestedSongsSheet(
        songs: _suggestedSongs,
        sources: _suggestionSources,
        hasPersonalization: _topPlayed.isNotEmpty || StreamFavoritesService.instance.favorites.isNotEmpty,
      ),
    );
  }

  /// Starts (or restarts) the Stream home suggestions for [seeds]: several
  /// songs in, many songs out.
  ///
  /// The list is shown as soon as the fast sources have answered, and improves
  /// when MetaBrainz's songs arrive; the new rows glide in between the ones
  /// already there (see [ArrivalList]).
  void _startHomeSuggestions({required List<SeedSong> seeds}) {
    _suggestionsSub?.cancel();
    if (seeds.isEmpty) {
      setState(() => _suggestionsRefining = false);
      return;
    }

    setState(() => _suggestionsRefining = true);
    _suggestionsSub = getIt<SuggestionService>()
        .suggestProgressive(
          seeds,
          limit: 30,
          exclude: _lastPlayedStreamSongs.map(SeedSong.fromSong),
        )
        .listen(
      (suggestions) {
        if (!mounted) return;
        setState(() {
          _suggestedSongs = [for (final s in suggestions) s.item];
          _suggestionSources = {for (final s in suggestions) s.item.id: s.sources};
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _suggestionsRefining = false);
        // Every source came back empty: fall back to the home feed.
        if (_suggestedSongs.isEmpty && _homeModules.isNotEmpty) _suggestFromHomeFeed();
      },
      onError: (_) {
        if (mounted) setState(() => _suggestionsRefining = false);
      },
    );
  }

  /// Fallback when there is nothing to base suggestions on yet (a new user, or
  /// offline): songs similar to the first song of the home feed.
  Future<void> _suggestFromHomeFeed() async {
    String? seedId;
    for (final list in _homeModules.values) {
      for (final item in list) {
        if (item.isSong && item.id.isNotEmpty) {
          seedId = item.id;
          break;
        }
      }
      if (seedId != null) break;
    }
    seedId ??= _newReleases.where((i) => i.isSong && i.id.isNotEmpty).firstOrNull?.id;
    if (seedId == null || seedId.isEmpty) return;
    final suggestions = await JioSaavnDecoder.fetchSongSuggestions(seedId, limit: 25);
    if (mounted && suggestions.isNotEmpty && _suggestedSongs.isEmpty) {
      setState(() {
        _suggestedSongs = suggestions;
        _suggestionSources = {for (final s in suggestions) s.id: {SuggestionSource.jioSaavn}};
      });
    }
  }

  Future<void> _streamSingleSong(
    JioSaavnItem item, {
    List<JioSaavnItem>? contextQueue,
    List<Song>? contextSongQueue,
    bool fromSearch = false,
  }) async {
    if (_loadingSongId != null) return;
    setState(() => _loadingSongId = item.id);

    try {
      String? streamUrl = item.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(item.encryptedMediaUrl);
      if (streamUrl == null || streamUrl.isEmpty) {
        final details = await JioSaavnDecoder.fetchSongDetails(item.token);
        streamUrl = details?.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(details?.encryptedMediaUrl);
      }

      if (streamUrl == null || streamUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Stream proxy could not load "${item.title}". You can download it from YouTube in Library.', style: GoogleFonts.outfit()),
              action: SnackBarAction(
                label: 'YouTube',
                textColor: Theme.of(context).colorScheme.primary,
                onPressed: () => HomeScreen.switchToTab(0),
              ),
              duration: const Duration(seconds: 5),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      final song = item.toSong(overrideStreamUrl: streamUrl);
      if (!mounted) return;

      List<Song> queueToPlay;
      if (fromSearch) {
        queueToPlay = [song];
        UserTasteService.instance.recordSearchPlay(song, item: item);
      } else if (contextSongQueue != null && contextSongQueue.isNotEmpty) {
        queueToPlay = contextSongQueue.map((s) => s.id == song.id ? song : s).toList();
        if (!queueToPlay.any((s) => s.id == song.id)) {
          queueToPlay.insert(0, song);
        }
      } else if (contextQueue != null && contextQueue.isNotEmpty) {
        queueToPlay = contextQueue.map((it) => it.id == item.id ? song : it.toSong()).toList();
        if (!queueToPlay.any((s) => s.id == song.id)) {
          queueToPlay.insert(0, song);
        }
      } else {
        queueToPlay = [song];
      }

      context.read<PlayerBloc>().add(PlaySongEvent(song, queue: queueToPlay));
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _loadLastPlayedSongs();
      });

      // The suggestion list is left as it is: rebuilding it on every tap
      // reshuffles the screen under the user and is expensive.

      if (getIt<SettingsService>().autoDownloadStreamSongs) {
        _downloadSong(item, overrideUrl: streamUrl);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Streaming "${song.title}" from JioSaavn', style: GoogleFonts.outfit()),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Stream proxy error: $e. You can search & download this from YouTube in Library.', style: GoogleFonts.outfit()),
            action: SnackBarAction(
              label: 'Library',
              textColor: Theme.of(context).colorScheme.primary,
              onPressed: () => HomeScreen.switchToTab(0),
            ),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingSongId = null);
      }
    }
  }

  Future<void> _downloadSong(JioSaavnItem track, {String? overrideUrl}) async {
    final downloadService = getIt<DownloadService>();
    var directUrl = overrideUrl;
    if (directUrl == null || directUrl.isEmpty) {
      if (track.directMediaUrl != null && track.directMediaUrl!.isNotEmpty) {
        if (track.directMediaUrl!.startsWith('http://') || track.directMediaUrl!.startsWith('https://')) {
          directUrl = track.directMediaUrl;
        } else if (File(track.directMediaUrl!).existsSync()) {
          directUrl = track.directMediaUrl;
        }
      }
    }
    if (directUrl == null || directUrl.isEmpty) {
      directUrl = JioSaavnDecoder.decryptMediaUrl(track.encryptedMediaUrl);
    }
    if (directUrl == null || directUrl.isEmpty) {
      // Some items (e.g. from recommendations) carry no token, only an id.
      final lookupKey = track.token.isNotEmpty ? track.token : track.id;
      final details = await JioSaavnDecoder.fetchSongDetails(lookupKey);
      directUrl = details?.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(details?.encryptedMediaUrl);
    }
    if (directUrl != null && directUrl.isNotEmpty && mounted) {
      final secs = int.tryParse(track.duration ?? '0') ?? 0;
      downloadService.enqueueDownload(
        url: directUrl,
        title: track.title,
        artist: track.subtitle,
        album: track.subtitle.isNotEmpty ? track.subtitle : 'JioSaavn',
        albumArt: track.imageUrl,
        duration: secs > 0 ? Duration(seconds: secs) : null,
        // One download per song, whichever URL it arrives with (stream URL,
        // 320 kbps URL, offline-cache file, auto-download + manual tap).
        songKey: track.id.isNotEmpty ? track.id : track.token,
      );
      showDownloadQueuedSnackBar(context, title: track.title);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not fetch download link for "${track.title}"', style: GoogleFonts.outfit()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _addSongToQueue(JioSaavnItem item) {
    final song = item.toSong();
    context.read<PlayerBloc>().add(AddToQueueEvent(song));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added "${item.title}" to queue', style: GoogleFonts.outfit()),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchSongs = [];
        _searchAlbums = [];
        _searchArtists = [];
        _isSearchLoading = false;
      });
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      _executeSearch(query.trim());
    });
  }

  Future<void> _executeSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() => _isSearchLoading = true);

    try {
      final results = await Future.wait([
        JioSaavnDecoder.searchSongs(q),
        JioSaavnDecoder.searchAlbums(q),
        JioSaavnDecoder.searchArtists(q),
      ]);

      if (!mounted) return;
      setState(() {
        _searchSongs = results[0];
        _searchAlbums = results[1];
        _searchArtists = results[2];
        _isSearchLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSearchLoading = false);
    }
  }

  void _stopSearch() {
    _searchDebounce?.cancel();
    _searchFocusNode.unfocus();
    _searchController.clear();
    setState(() {
      _isSearching = false;
      _searchSongs = [];
      _searchAlbums = [];
      _searchArtists = [];
      _isSearchLoading = false;
    });
  }

  Widget _buildSearchResults() {
    if (_isSearchLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            const Text('Searching JioSaavn...'),
          ],
        ),
      );
    }

    if (_searchController.text.trim().isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              'Search songs, albums, and artists on JioSaavn',
              style: GoogleFonts.outfit(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      );
    }

    if (_searchSongs.isEmpty && _searchAlbums.isEmpty && _searchArtists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 64,
              color: Colors.orange.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'No results found for "${_searchController.text.trim()}"',
              style: GoogleFonts.outfit(fontSize: 15),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 120),
      children: [
        if (_searchSongs.isNotEmpty) ...[
          _buildSectionHeader(
            title: 'Songs (${_searchSongs.length})',
            icon: Icons.music_note_rounded,
          ),
          ..._searchSongs.map((song) => _StreamSongTile(
                item: song,
                isLoading: _loadingSongId == song.id,
                onPlay: () => _streamSingleSong(song, fromSearch: true),
                onDownload: () => _downloadSong(song),
                onAddToQueue: () => _addSongToQueue(song),
              )),
          const SizedBox(height: 16),
        ],
        if (_searchArtists.isNotEmpty) ...[
          _buildSectionHeader(
            title: 'Artists (${_searchArtists.length})',
            icon: Icons.person_rounded,
          ),
          _buildHorizontalCardList(_searchArtists),
          const SizedBox(height: 16),
        ],
        if (_searchAlbums.isNotEmpty) ...[
          _buildSectionHeader(
            title: 'Albums (${_searchAlbums.length})',
            icon: Icons.album_rounded,
          ),
          _buildHorizontalCardList(_searchAlbums),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final langName = SettingsService.supportedStreamLanguages[_currentLang] ?? _currentLang;
    final allSongs = _allSongs;
    final theme = Theme.of(context);

    if (_isSearching) {
      return PopScope(
        // Tabs live in an IndexedStack, so this stays registered while hidden;
        // only intercept back when the Stream tab is the one on screen.
        canPop: HomeScreen.tabNotifier.value != 1,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _stopSearch();
        },
        child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back',
            onPressed: _stopSearch,
          ),
          title: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            autofocus: true,
            style: GoogleFonts.outfit(fontSize: 16),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search songs, albums, and artists on JioSaavn...',
              hintStyle: GoogleFonts.outfit(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              border: InputBorder.none,
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                      },
                    )
                  : null,
            ),
            onChanged: _onSearchChanged,
            onSubmitted: _executeSearch,
          ),
        ),
        body: _buildSearchResults(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.podcasts_rounded, color: theme.colorScheme.primary, size: 24),
            const SizedBox(width: 8),
            Text(
              'Stream',
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 22),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Search JioSaavn',
            onPressed: () => setState(() => _isSearching = true),
          ),
          // Language selector chip in AppBar
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ActionChip(
              avatar: Icon(Icons.language_rounded, size: 16, color: theme.colorScheme.primary),
              label: Text(
                langName,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.15),
              side: BorderSide(color: theme.colorScheme.primary, width: 0.8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              onPressed: _showLanguageSelector,
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: _buildFilterChips(),
        ),
      ),
      body: BlocListener<PlayerBloc, PlayerState>(
        // Only react when a new song starts. PlayerPlaying is re-emitted for
        // every position tick; rebuilding this screen and querying the DB on
        // each tick made the whole app lag.
        listenWhen: (previous, current) =>
            current is PlayerPlaying &&
            (previous is! PlayerPlaying || previous.song.id != current.song.id),
        listener: (context, state) {
          if (state is PlayerPlaying) {
            final song = state.song;
            setState(() {
              _lastPlayedStreamSongs = [
                song,
                ..._lastPlayedStreamSongs.where((s) =>
                    s.id != song.id &&
                    (s.title.toLowerCase().trim() != song.title.toLowerCase().trim() ||
                     s.artist.toLowerCase().trim() != song.artist.toLowerCase().trim())),
              ];
            });
            _loadLastPlayedSongs();
          }
        },
        child: (_isLoading && _selectedFilter < 3)
            ? const StreamHomeSkeleton()
            : (_errorMessage != null && _selectedFilter == 0)
                ? _buildStreamFailureView()
                : RefreshIndicator(
                    color: theme.colorScheme.primary,
                    onRefresh: _loadStreamData,
                    child: _buildBodyContent(langName, allSongs),
                  ),
      ),
    );
  }

  Widget _buildFilterChips() {
    final cachedCount = StreamCacheService.instance.cachedCount;
    final filters = [
      'All',
      'Songs',
      'Albums',
      'Playlists',
      'Favorites',
      'Last Played',
      if (cachedCount > 0) 'Offline Cache ($cachedCount)' else 'Offline Cache',
    ];

    return SizedBox(
      height: 40,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final isSelected = _selectedFilter == index;
          return ChoiceChip(
            showCheckmark: false,
            label: Text(
              filters[index],
              style: GoogleFonts.outfit(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                color: isSelected ? Theme.of(context).colorScheme.onPrimary : null,
              ),
            ),
            selected: isSelected,
            selectedColor: Theme.of(context).colorScheme.primary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (val) {
              if (val) {
                setState(() => _selectedFilter = index);
                if (index == 0 || index == 5) {
                  _loadLastPlayedSongs();
                }
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildBodyContent(String langName, List<JioSaavnItem> allSongs) {
    if (_selectedFilter == 1) {
      // SONGS ONLY VIEW
      return _buildSongsOnlyList(allSongs);
    } else if (_selectedFilter == 2) {
      // ALBUMS ONLY VIEW
      return _buildAlbumsOnlyGrid();
    } else if (_selectedFilter == 3) {
      // PLAYLISTS ONLY VIEW
      return _buildPlaylistsOnlyGrid();
    } else if (_selectedFilter == 4) {
      // FAVORITES VIEW
      return _buildFavoritesView();
    } else if (_selectedFilter == 5) {
      // LAST PLAYED (HISTORY) VIEW
      return _buildLastPlayedView();
    } else if (_selectedFilter == 6) {
      // OFFLINE CACHE VIEW
      return _buildCachedSongsView();
    }

    // ALL (Default overview)
    return ListView(
      padding: const EdgeInsets.only(bottom: 120),
      children: [
        // 0. Support Project GitHub Banner
        _buildSupportBanner(),

        // 2. Last Played Stream History (if any)
        if (_lastPlayedStreamSongs.isNotEmpty) ...[
          _buildSectionHeader(
            title: 'Last Played',
            subtitle: 'Recently streamed songs',
            icon: Icons.history_rounded,
            actionLabel: _lastPlayedStreamSongs.length > 5 ? 'See All (${_lastPlayedStreamSongs.length})' : null,
            onAction: () => setState(() => _selectedFilter = 5),
          ),
          ..._lastPlayedStreamSongs.take(5).map((song) {
            final item = song.toJioSaavnItem();
            return _StreamSongTile(
              item: item,
              isLoading: _loadingSongId == item.id,
              onPlay: () {
                if (song.filePath.isNotEmpty && !song.filePath.startsWith('http')) {
                  context.read<PlayerBloc>().add(PlaySongEvent(song, queue: _lastPlayedStreamSongs));
                } else {
                  _streamSingleSong(
                    item,
                    contextSongQueue: _lastPlayedStreamSongs,
                  );
                }
              },
              onDownload: () => _downloadSong(item),
              onAddToQueue: () => _addSongToQueue(item),
            );
          }),
          const SizedBox(height: 16),
        ],

        // 1. Song Suggestions: on screen from the start; placeholder rows while
        // the first songs are found, then the songs, and later songs glide in.
        if (_suggestedSongs.isNotEmpty || _suggestionsRefining) ...[
          _buildSectionHeader(
            title: 'Song Suggestions',
            subtitle: _suggestionsRefining
                ? 'Finding more songs for you…'
                : (_topPlayed.isNotEmpty || StreamFavoritesService.instance.favorites.isNotEmpty)
                    ? 'Curated from your favorite artists & composers'
                    : 'Recommended songs for you',
            icon: Icons.recommend_rounded,
            actionLabel: _suggestedSongs.length > 6 ? 'See All (${_suggestedSongs.length})' : null,
            onAction: _openSuggestedSongsDetails,
          ),
          if (_suggestedSongs.isEmpty)
            const SuggestionPlaceholderRows()
          else
          // Songs that arrive later (YouTube, MetaBrainz) glide in between these rows.
          ArrivalList<JioSaavnItem>(
            items: _suggestedSongs.take(10).toList(),
            idOf: (item) => item.id,
            animateInitial: true,
            itemBuilder: (context, item) => _StreamSongTile(
              item: item,
              sources: _suggestionSources[item.id],
              isLoading: _loadingSongId == item.id,
              onPlay: () => _streamSingleSong(
                item,
                contextQueue: _suggestedSongs,
              ),
              onDownload: () => _downloadSong(item),
              onAddToQueue: () => _addSongToQueue(item),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // 2. Trending Songs (Directly playable single songs)
        if (allSongs.isNotEmpty) ...[
          _buildSectionHeader(
            title: 'Trending Songs',
            subtitle: 'Tap to stream instant 320 kbps audio',
            icon: Icons.local_fire_department_rounded,
            actionLabel: allSongs.length > 5 ? 'See All (${allSongs.length})' : null,
            onAction: () => setState(() => _selectedFilter = 1),
          ),
          ...allSongs.take(6).map((item) => _StreamSongTile(
                item: item,
                isLoading: _loadingSongId == item.id,
                onPlay: () => _streamSingleSong(
                  item,
                  contextQueue: allSongs,
                ),
                onDownload: () => _downloadSong(item),
                onAddToQueue: () => _addSongToQueue(item),
              )),
          const SizedBox(height: 16),
        ],

        // User Stream Playlists in Feed
        StreamBuilder<List<PlaylistModel>>(
          stream: StreamPlaylistsService.instance.onPlaylistsChanged,
          initialData: StreamPlaylistsService.instance.playlists,
          builder: (context, snap) {
            final userPlaylists = snap.data ?? StreamPlaylistsService.instance.playlists;
            if (userPlaylists.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  title: 'My Playlists',
                  subtitle: 'Your custom streaming collections',
                  icon: Icons.playlist_add_check_circle_rounded,
                  actionLabel: 'See All',
                  onAction: () => setState(() => _selectedFilter = 3),
                ),
                SizedBox(
                  height: 185,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    scrollDirection: Axis.horizontal,
                    itemCount: userPlaylists.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (context, index) => _buildUserPlaylistCard(userPlaylists[index]),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            );
          },
        ),

        // 2. Recommended For You (based on top 5 most played songs)
        if (_relatedAlbums.isNotEmpty) ...[
          _buildSectionHeader(
            title: 'Recommended For You',
            subtitle: _topPlayed.isNotEmpty
                ? 'Based on your most played tracks'
                : 'Similar to popular albums',
            icon: Icons.auto_awesome_rounded,
          ),
          _buildHorizontalCardList(_relatedAlbums),
          const SizedBox(height: 16),
        ],

        // 3. New Releases (From /api/new)
        if (_newReleases.isNotEmpty) ...[
          _buildSectionHeader(
            title: 'New Releases',
            subtitle: 'Fresh $langName tracks and albums',
            icon: Icons.new_releases_rounded,
          ),
          _buildHorizontalCardList(_newReleases),
          const SizedBox(height: 16),
        ],

        // 4. Home Feed Modules (Top Charts, Editorial Picks, etc.)
        ..._homeModules.entries.where((entry) {
          final normalized = entry.key.trim().toLowerCase().replaceAll('_', ' ');
          return normalized != 'new releases';
        }).map((entry) {
          final title = entry.key.replaceAll('_', ' ').toUpperCase();
          final items = entry.value;
          if (items.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader(
                title: title,
                icon: Icons.queue_music_rounded,
              ),
              _buildHorizontalCardList(items),
              const SizedBox(height: 16),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildLastPlayedView() {
    if (_lastPlayedStreamSongs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.history_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No stream history yet',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Songs you stream from JioSaavn will appear here',
              style: GoogleFonts.outfit(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(top: 8, bottom: 120),
      itemCount: _lastPlayedStreamSongs.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (ctx, index) {
        final song = _lastPlayedStreamSongs[index];
        final item = song.toJioSaavnItem();
        return _StreamSongTile(
          item: item,
          isLoading: _loadingSongId == item.id,
          onPlay: () {
            if (song.filePath.isNotEmpty && !song.filePath.startsWith('http')) {
              context.read<PlayerBloc>().add(PlaySongEvent(song, queue: _lastPlayedStreamSongs));
            } else {
              _streamSingleSong(
                item,
                contextSongQueue: _lastPlayedStreamSongs,
              );
            }
          },
          onDownload: () => _downloadSong(item),
          onAddToQueue: () => _addSongToQueue(item),
        );
      },
    );
  }

  Widget _buildFavoritesView() {
    return StreamBuilder<List<Song>>(
      stream: StreamFavoritesService.instance.onFavoritesChanged,
      initialData: StreamFavoritesService.instance.favorites,
      builder: (context, snapshot) {
        final favorites = snapshot.data ?? StreamFavoritesService.instance.favorites;
        if (favorites.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.favorite_border_rounded,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                ),
                const SizedBox(height: 16),
                Text(
                  'No stream favorites yet',
                  style: GoogleFonts.outfit(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Tap the heart icon on any streamed song to add it here',
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.only(top: 8, bottom: 120),
          itemCount: favorites.length,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
          itemBuilder: (ctx, index) {
            final song = favorites[index];
            final item = song.toJioSaavnItem();
            return _StreamSongTile(
              item: item,
              isLoading: _loadingSongId == item.id,
              onPlay: () => _streamSingleSong(
                item,
                contextSongQueue: favorites,
              ),
              onDownload: () => _downloadSong(item),
              onAddToQueue: () => _addSongToQueue(item),
            );
          },
        );
      },
    );
  }

  Widget _buildSupportBanner() => const SupportBannerWidget();

  Widget _buildCachedSongsView() {
    final cachedItems = StreamCacheService.instance.getCachedItems();
    final cachedSongs = StreamCacheService.instance.getCachedSongs();
    final theme = Theme.of(context);

    if (cachedItems.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cached_rounded, size: 48, color: Colors.orange),
              ),
              const SizedBox(height: 16),
              Text(
                'No Cached Stream Songs Yet',
                style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Songs you stream are automatically saved here (up to 50 songs) for instant offline playback.\n\nYou can also search and download any song from YouTube via the Library tab.',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                ),
                icon: const Icon(Icons.library_music_rounded, size: 18),
                label: const Text('Go to Library & YouTube'),
                onPressed: () => HomeScreen.switchToTab(0),
              ),
            ],
          ),
        ),
      );
    }

    final totalMb = StreamCacheService.instance.totalSizeMb.toStringAsFixed(1);

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 120),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.15),
                  Colors.green.withValues(alpha: 0.08),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.offline_pin_rounded, color: theme.colorScheme.primary, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${cachedItems.length} Cached Songs ($totalMb MB)',
                        style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Saved locally • Plays 100% offline',
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 26),
                  tooltip: 'Play All Cached Songs',
                  onPressed: () {
                    context.read<PlayerBloc>().add(PlayQueueEvent(cachedSongs, initialIndex: 0));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Playing ${cachedSongs.length} offline cached songs', style: GoogleFonts.outfit()),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        ...cachedItems.map((item) => _StreamSongTile(
              item: item,
              isLoading: _loadingSongId == item.id,
              onPlay: () => _streamSingleSong(
                item,
                contextQueue: cachedItems,
              ),
              onDownload: () => _downloadSong(item),
              onAddToQueue: () => _addSongToQueue(item),
              inCacheSection: true,
              onCacheRemoved: () {
                if (mounted) setState(() {});
              },
            )),
      ],
    );
  }

  Widget _buildStreamFailureView() {
    final cachedSongs = StreamCacheService.instance.getCachedSongs();
    final cachedItems = StreamCacheService.instance.getCachedItems();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      children: [
        // Error & Proxy Alert Card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2C1E1A) : const Color(0xFFFFF0EC),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.wifi_off_rounded, color: Colors.redAccent, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Streaming Service Unavailable',
                          style: GoogleFonts.outfit(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.redAccent,
                          ),
                        ),
                        Text(
                          'Proxy API is down or connection timed out',
                          style: GoogleFonts.outfit(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Streaming APIs connect to public proxies which may stop working at any moment. In the meantime, use the Library to search & download tracks from YouTube, or play your saved offline songs below.',
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  height: 1.4,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('Download on YouTube'),
                      onPressed: () => HomeScreen.switchToTab(0),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry'),
                    onPressed: _loadStreamData,
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // If user has cached songs, show them immediately so music never stops!
        if (cachedItems.isNotEmpty) ...[
          _buildSectionHeader(
            title: 'Offline Stream Cache (${cachedItems.length})',
            subtitle: 'Saved on your device • Plays 100% offline',
            icon: Icons.offline_pin_rounded,
            actionLabel: 'Play All',
            onAction: () {
              context.read<PlayerBloc>().add(PlayQueueEvent(cachedSongs, initialIndex: 0));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Playing ${cachedSongs.length} offline cached songs', style: GoogleFonts.outfit()),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          ...cachedItems.map((item) => _StreamSongTile(
                item: item,
                isLoading: _loadingSongId == item.id,
                onPlay: () => _streamSingleSong(
                  item,
                  contextQueue: cachedItems,
                ),
                onDownload: () => _downloadSong(item),
                onAddToQueue: () => _addSongToQueue(item),
                inCacheSection: true,
                onCacheRemoved: () {
                  if (mounted) setState(() {});
                },
              )),
        ] else ...[
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  Icon(Icons.library_music_rounded, size: 48, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
                  const SizedBox(height: 12),
                  Text(
                    'No songs cached yet',
                    style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Switch to the Library tab to search and download high-quality tracks directly from YouTube.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSongsOnlyList(List<JioSaavnItem> songs) {
    if (songs.isEmpty) {
      return Center(
        child: Text('No songs found for this language.', style: GoogleFonts.outfit()),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(top: 8, bottom: 120),
      itemCount: songs.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (ctx, index) {
        final item = songs[index];
        return _StreamSongTile(
          item: item,
          isLoading: _loadingSongId == item.id,
          onPlay: () => _streamSingleSong(
            item,
            contextQueue: songs,
          ),
          onDownload: () => _downloadSong(item),
          onAddToQueue: () => _addSongToQueue(item),
        );
      },
    );
  }

  Widget _buildAlbumsOnlyGrid() {
    final albums = _allAlbums;
    if (albums.isEmpty) {
      return Center(
        child: Text('No albums found.', style: GoogleFonts.outfit()),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 120),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.72,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: albums.length,
      itemBuilder: (ctx, idx) {
        final item = albums[idx];
        return _StreamCard(
          item: item,
          onTap: () => _openAlbumDetails(item),
        );
      },
    );
  }

  Widget _buildPlaylistsOnlyGrid() {
    final curatedPlaylists = _allPlaylists;

    return StreamBuilder<List<PlaylistModel>>(
      stream: StreamPlaylistsService.instance.onPlaylistsChanged,
      initialData: StreamPlaylistsService.instance.playlists,
      builder: (context, snapshot) {
        final userPlaylists = snapshot.data ?? StreamPlaylistsService.instance.playlists;

        if (userPlaylists.isEmpty && curatedPlaylists.isEmpty) {
          return Center(
            child: Text('No playlists found.', style: GoogleFonts.outfit()),
          );
        }

        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 120),
          children: [
            // User Stream Playlists Header
            _buildSectionHeader(
              title: 'My Playlists (${userPlaylists.length})',
              subtitle: 'Your personal streaming collections',
              icon: Icons.playlist_add_check_circle_rounded,
              actionLabel: '+ New Playlist',
              onAction: () => _showCreateStreamPlaylistDialog(context),
            ),

            if (userPlaylists.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Card(
                  elevation: 0,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15)),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.playlist_add_rounded, color: Theme.of(context).colorScheme.primary),
                    ),
                    title: Text(
                      'Create Your First Stream Playlist',
                      style: GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    subtitle: Text(
                      'Group songs together and stream them anytime',
                      style: GoogleFonts.outfit(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: () => _showCreateStreamPlaylistDialog(context),
                      child: const Text('Create'),
                    ),
                  ),
                ),
              )
            else
              SizedBox(
                height: 185,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: userPlaylists.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 14),
                  itemBuilder: (context, index) {
                    final playlist = userPlaylists[index];
                    return _buildUserPlaylistCard(playlist);
                  },
                ),
              ),

            const SizedBox(height: 16),

            // Curated / Featured JioSaavn Playlists
            if (curatedPlaylists.isNotEmpty) ...[
              _buildSectionHeader(
                title: 'Featured Playlists',
                subtitle: 'Top charts & editorial picks',
                icon: Icons.queue_music_rounded,
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 0.72,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                ),
                itemCount: curatedPlaylists.length,
                itemBuilder: (ctx, idx) {
                  final item = curatedPlaylists[idx];
                  return _StreamCard(
                    item: item,
                    onTap: () => _openAlbumDetails(item),
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildUserPlaylistCard(PlaylistModel playlist) {
    final theme = Theme.of(context);
    final songsWithArt = playlist.songs.where((s) => s.albumArt != null && s.albumArt!.isNotEmpty);
    final firstArt = songsWithArt.isNotEmpty ? songsWithArt.first.albumArt : null;

    return InkWell(
      onTap: () => _openUserPlaylistDetails(playlist),
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          theme.colorScheme.primary.withValues(alpha: 0.25),
                          theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: firstArt != null && firstArt.isNotEmpty
                        ? AlbumArtWidget(
                            albumArt: firstArt,
                            width: 130,
                            height: 130,
                            fallbackIcon: Icons.playlist_play_rounded,
                          )
                        : Icon(
                            Icons.playlist_play_rounded,
                            size: 48,
                            color: theme.colorScheme.primary,
                          ),
                  ),
                ),
                if (playlist.songs.isNotEmpty)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          context.read<PlayerBloc>().add(
                                PlayQueueEvent(playlist.songs, initialIndex: 0),
                              );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Playing "${playlist.name}"', style: GoogleFonts.outfit()),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.4),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: 18,
                            color: theme.colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            Text(
              '${playlist.songs.length} ${playlist.songs.length == 1 ? 'track' : 'tracks'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontSize: 11,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader({
    required String title,
    String? subtitle,
    required IconData icon,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: GoogleFonts.outfit(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: Theme.of(context).colorScheme.primary,
              ),
              child: Text(actionLabel, style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  Widget _buildHorizontalCardList(List<JioSaavnItem> items) {
    return SizedBox(
      height: 215,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final item = items[index];
          return _StreamCard(
            item: item,
            onTap: () {
              if (item.isSong) {
                final songItems = items.where((i) => i.isSong).toList();
                _streamSingleSong(
                  item,
                  contextQueue: songItems,
                );
              } else {
                _openAlbumDetails(item);
              }
            },
          );
        },
      ),
    );
  }
}

/// Song tile for immediate direct playback
/// The URL to download [track] from. Falls back to a `jiosaavn-token:` link
/// that DownloadService resolves itself, instead of silently doing nothing
/// when the item has no media URL yet.
String _downloadUrlFor(JioSaavnItem track) {
  final direct = track.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(track.encryptedMediaUrl);
  if (direct != null && direct.isNotEmpty) return direct;
  return 'jiosaavn-token:${track.token.isNotEmpty ? track.token : track.id}';
}

class _StreamSongTile extends StatelessWidget {
  final JioSaavnItem item;

  /// Where the song was suggested from; shown only with the developer option.
  final Set<SuggestionSource>? sources;
  final bool isLoading;
  final VoidCallback onPlay;
  final VoidCallback onDownload;
  final VoidCallback? onAddToQueue;
  final bool inCacheSection;
  final VoidCallback? onCacheRemoved;

  const _StreamSongTile({
    required this.item,
    this.sources,
    this.isLoading = false,
    required this.onPlay,
    required this.onDownload,
    this.onAddToQueue,
    this.inCacheSection = false,
    this.onCacheRemoved,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final songId = item.stableId;
    final isCached = StreamCacheService.instance.isSongCached(songId);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AlbumArtWidget(
          albumArt: item.imageUrl,
          width: 50,
          height: 50,
          fallbackIcon: Icons.music_note_rounded,
        ),
      ),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Row(
        children: [
          SuggestionSourceChip(sources: sources),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '320k',
              style: GoogleFonts.outfit(
                fontSize: 10,
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (isCached)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(
                Icons.offline_pin_rounded,
                size: 11,
                color: Colors.greenAccent,
              ),
            ),
          Expanded(
            child: Text(
              item.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              tooltip: 'Song options',
              visualDensity: VisualDensity.compact,
              onPressed: () => SongOptionsBottomSheet.show(
                context,
                song: item.toSong(),
                onDownload: onDownload,
                showRemoveFromCache: inCacheSection,
                onCacheRemoved: onCacheRemoved,
              ),
            ),
        ],
      ),
      onTap: isLoading ? null : onPlay,
    );
  }
}

class _StreamCard extends StatelessWidget {
  final JioSaavnItem item;
  final VoidCallback onTap;

  const _StreamCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final badgeText = item.isSong
        ? 'SONG'
        : (item.isArtist
            ? 'ARTIST'
            : (item.isAlbum ? 'ALBUM' : 'PLAYLIST'));
    final badgeColor = item.isSong
        ? theme.colorScheme.primary
        : (item.isArtist
            ? Colors.deepPurpleAccent
            : (item.isAlbum ? Colors.indigoAccent : Colors.amber.shade800));

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Artwork with play icon & type pill
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(item.isArtist ? 70 : 14),
                  child: Container(
                    width: 140,
                    height: 140,
                    color: isDark ? theme.colorScheme.surfaceContainerHighest : Colors.grey[200],
                    child: AlbumArtWidget(
                      albumArt: item.imageUrl,
                      width: 140,
                      height: 140,
                      fallbackIcon: item.isSong
                          ? Icons.music_note_rounded
                          : (item.isArtist ? Icons.person_rounded : Icons.album_rounded),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 18,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),
                // Item Type Badge (SONG / ARTIST / ALBUM / PLAYLIST)
                Positioned(
                  top: 6,
                  left: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeColor,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                    child: Text(
                      badgeText,
                      style: GoogleFonts.outfit(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: (item.isSong || item.isArtist) ? theme.colorScheme.onPrimary : Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              item.subtitle.isNotEmpty ? item.subtitle : badgeText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontSize: 11,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestedSongsSheet extends StatelessWidget {
  final List<JioSaavnItem> songs;
  final Map<String, Set<SuggestionSource>> sources;
  final bool hasPersonalization;

  const _SuggestedSongsSheet({
    required this.songs,
    required this.sources,
    required this.hasPersonalization,
  });

  Future<void> _streamTrack(BuildContext context, int index) async {
    if (songs.isEmpty || index < 0 || index >= songs.length) return;
    final messenger = ScaffoldMessenger.of(context);
    final targetTrack = songs[index];

    String? directUrl = targetTrack.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(targetTrack.encryptedMediaUrl);
    if (directUrl == null || directUrl.isEmpty) {
      final details = await JioSaavnDecoder.fetchSongDetails(targetTrack.token.isNotEmpty ? targetTrack.token : targetTrack.id);
      directUrl = details?.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(details?.encryptedMediaUrl);
    }

    final songModels = songs.map((t) {
      final s = t.toSong(albumName: 'Song Suggestions');
      if (t.id == targetTrack.id && directUrl != null && directUrl.isNotEmpty) {
        return s.copyWith(filePath: directUrl);
      }
      return s;
    }).toList();

    if (!context.mounted) return;
    context.read<PlayerBloc>().add(PlayQueueEvent(songModels, initialIndex: index));
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Streaming "${songModels[index].title}"', style: GoogleFonts.outfit()),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    if (getIt<SettingsService>().autoDownloadStreamSongs && index < songs.length) {
      _downloadTrack(context, songs[index]);
    }
  }

  void _downloadTrack(BuildContext context, JioSaavnItem track) {
    final secs = int.tryParse(track.duration ?? '0') ?? 0;
    getIt<DownloadService>().enqueueDownload(
      url: _downloadUrlFor(track),
      title: track.title,
      artist: track.subtitle,
      album: 'Song Suggestions',
      albumArt: track.imageUrl,
      duration: secs > 0 ? Duration(seconds: secs) : null,
      songKey: track.id.isNotEmpty ? track.id : track.token,
    );
    showDownloadQueuedSnackBar(context, title: track.title);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      expand: false,
      builder: (ctx, scrollController) {
        return Column(
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.recommend_rounded,
                      color: theme.colorScheme.primary,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Song Suggestions (${songs.length})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasPersonalization
                              ? 'Curated from your favorite artists & composers'
                              : 'Recommended songs for you',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(
                            fontSize: 13,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.auto_awesome_rounded, size: 14, color: theme.colorScheme.primary),
                            const SizedBox(width: 4),
                            Text(
                              'PulseIQ Recommendation Engine',
                              style: TextStyle(fontSize: 11, color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (songs.isNotEmpty)
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 28),
                      tooltip: 'Play All',
                      onPressed: () => _streamTrack(context, 0),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: songs.isEmpty
                  ? const Center(child: Text('No song suggestions available.'))
                  : ListView.separated(
                      controller: scrollController,
                      itemCount: songs.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        indent: 72,
                        color: isDark ? Colors.white10 : Colors.black12,
                      ),
                      itemBuilder: (ctx, index) {
                        final track = songs[index];
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: AlbumArtWidget(
                              albumArt: track.imageUrl,
                              width: 44,
                              height: 44,
                              fallbackIcon: Icons.music_note_rounded,
                            ),
                          ),
                          title: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Row(
                            children: [
                              SuggestionSourceChip(sources: sources[track.id]),
                              Expanded(
                                child: Text(
                                  track.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.outfit(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.more_vert_rounded, size: 20),
                            tooltip: 'Song options',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => SongOptionsBottomSheet.show(
                              context,
                              song: track.toSong(albumName: 'Song Suggestions'),
                              onDownload: () => _downloadTrack(context, track),
                            ),
                          ),
                          onTap: () => _streamTrack(context, index),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _AlbumTracksSheet extends StatefulWidget {
  final JioSaavnItem item;
  final bool fromSearch;
  const _AlbumTracksSheet({required this.item, this.fromSearch = false});

  @override
  State<_AlbumTracksSheet> createState() => _AlbumTracksSheetState();
}

class _AlbumTracksSheetState extends State<_AlbumTracksSheet> {
  bool _isLoading = true;
  List<JioSaavnItem> _tracks = [];

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    final List<JioSaavnItem> list;
    if (widget.item.isArtist) {
      list = await JioSaavnDecoder.fetchArtistSongs(
        widget.item.token.isNotEmpty ? widget.item.token : widget.item.title,
      );
    } else if (widget.item.isAlbum) {
      list = await JioSaavnDecoder.fetchAlbumSongs(widget.item.token);
    } else {
      list = await JioSaavnDecoder.fetchPlaylistSongs(widget.item.token);
    }

    if (!mounted) return;
    setState(() {
      _tracks = list;
      _isLoading = false;
    });
  }

  Future<void> _streamTrack(int index) async {
    if (_tracks.isEmpty || index < 0 || index >= _tracks.length) return;
    final messenger = ScaffoldMessenger.of(context);
    final targetTrack = _tracks[index];

    // Ensure direct stream URL is available for the selected track
    String? directUrl = targetTrack.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(targetTrack.encryptedMediaUrl);
    if (directUrl == null || directUrl.isEmpty) {
      final details = await JioSaavnDecoder.fetchSongDetails(targetTrack.token.isNotEmpty ? targetTrack.token : targetTrack.id);
      directUrl = details?.directMediaUrl ?? JioSaavnDecoder.decryptMediaUrl(details?.encryptedMediaUrl);
    }

    final songs = _tracks.map((t) {
      final s = t.toSong(albumName: widget.item.title);
      if (t.id == targetTrack.id && directUrl != null && directUrl.isNotEmpty) {
        return s.copyWith(filePath: directUrl);
      }
      return s;
    }).toList();

    if (!mounted) return;
    if (widget.fromSearch && index < songs.length) {
      UserTasteService.instance.recordSearchPlay(songs[index], item: targetTrack);
    }
    context.read<PlayerBloc>().add(PlayQueueEvent(songs, initialIndex: index));
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Streaming "${songs[index].title}"', style: GoogleFonts.outfit()),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    if (getIt<SettingsService>().autoDownloadStreamSongs && index < _tracks.length) {
      _downloadTrack(_tracks[index]);
    }
  }

  void _downloadTrack(JioSaavnItem track) {
    final secs = int.tryParse(track.duration ?? '0') ?? 0;
    getIt<DownloadService>().enqueueDownload(
      url: _downloadUrlFor(track),
      title: track.title,
      artist: track.subtitle,
      album: widget.item.title,
      albumArt: track.imageUrl.isNotEmpty ? track.imageUrl : widget.item.imageUrl,
      duration: secs > 0 ? Duration(seconds: secs) : null,
      songKey: track.id.isNotEmpty ? track.id : track.token,
    );
    showDownloadQueuedSnackBar(context, title: track.title);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, scrollController) {
        return Column(
          children: [
            // Handle bar
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(widget.item.isArtist ? 30 : 10),
                    child: AlbumArtWidget(
                      albumArt: widget.item.imageUrl,
                      width: 60,
                      height: 60,
                      fallbackIcon: widget.item.isArtist ? Icons.person_rounded : Icons.album_rounded,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.item.isArtist && (widget.item.subtitle.isEmpty || widget.item.subtitle == 'Artist')
                              ? 'Top Tracks & Releases'
                              : widget.item.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(
                            fontSize: 13,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(widget.item.isArtist ? Icons.person_rounded : Icons.high_quality_rounded, size: 14, color: theme.colorScheme.primary),
                            const SizedBox(width: 4),
                            Text(
                              widget.item.isArtist ? 'Artist Top Tracks • JioSaavn' : '320 kbps Stream • JioSaavn',
                              style: TextStyle(fontSize: 11, color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_tracks.isNotEmpty)
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 28),
                      tooltip: 'Play All',
                      onPressed: () => _streamTrack(0),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Tracks List
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator(color: theme.colorScheme.primary))
                  : _tracks.isEmpty
                      ? const Center(child: Text('No playable tracks found.'))
                      : ListView.separated(
                          controller: scrollController,
                          itemCount: _tracks.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            indent: 72,
                            color: isDark ? Colors.white10 : Colors.black12,
                          ),
                          itemBuilder: (ctx, index) {
                            final track = _tracks[index];
                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: AlbumArtWidget(
                                  albumArt: track.imageUrl.isNotEmpty ? track.imageUrl : widget.item.imageUrl,
                                  width: 44,
                                  height: 44,
                                  fallbackIcon: Icons.music_note_rounded,
                                ),
                              ),
                              title: Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                track.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.outfit(fontSize: 12),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.more_vert_rounded, size: 20),
                                tooltip: 'Song options',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => SongOptionsBottomSheet.show(
                                  context,
                                  song: track.toSong(albumName: widget.item.title),
                                  onDownload: () => _downloadTrack(track),
                                ),
                              ),
                              onTap: () => _streamTrack(index),
                            );
                          },
                        ),
            ),
          ],
        );
      },
    );
  }
}

class _UserStreamPlaylistSheet extends StatelessWidget {
  final int playlistId;
  const _UserStreamPlaylistSheet({required this.playlistId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return StreamBuilder<List<PlaylistModel>>(
      stream: StreamPlaylistsService.instance.onPlaylistsChanged,
      initialData: StreamPlaylistsService.instance.playlists,
      builder: (context, snapshot) {
        final playlist = StreamPlaylistsService.instance.getPlaylist(playlistId);
        if (playlist == null) {
          return const SizedBox.shrink();
        }
        final songs = playlist.songs;
        final songsWithArt = songs.where((s) => s.albumArt != null && s.albumArt!.isNotEmpty);
        final firstArt = songsWithArt.isNotEmpty ? songsWithArt.first.albumArt : null;

        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (ctx, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Playlist Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                theme.colorScheme.primary.withValues(alpha: 0.3),
                                theme.colorScheme.primaryContainer,
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: firstArt != null && firstArt.isNotEmpty
                              ? AlbumArtWidget(
                                  albumArt: firstArt,
                                  width: 60,
                                  height: 60,
                                  fallbackIcon: Icons.playlist_play_rounded,
                                )
                              : Icon(Icons.playlist_play_rounded, size: 32, color: theme.colorScheme.primary),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              playlist.name,
                              style: GoogleFonts.outfit(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${songs.length} ${songs.length == 1 ? 'track' : 'tracks'} • Stream Playlist',
                              style: GoogleFonts.outfit(
                                fontSize: 13,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert_rounded),
                        onSelected: (val) async {
                          if (val == 'delete') {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (dCtx) => AlertDialog(
                                title: Text('Delete Playlist', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
                                content: Text('Are you sure you want to delete "${playlist.name}"?'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
                                  FilledButton(
                                    style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                                    onPressed: () => Navigator.pop(dCtx, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await StreamPlaylistsService.instance.deletePlaylist(playlist.id);
                              Fluttertoast.showToast(msg: 'Deleted "${playlist.name}"');
                              if (context.mounted) Navigator.pop(context);
                            }
                          } else if (val == 'rename') {
                            final renameController = TextEditingController(text: playlist.name);
                            final newName = await showDialog<String>(
                              context: context,
                              builder: (dCtx) => AlertDialog(
                                title: Text('Rename Playlist', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
                                content: TextField(
                                  controller: renameController,
                                  autofocus: true,
                                  decoration: const InputDecoration(hintText: 'New Playlist Name'),
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Cancel')),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(dCtx, renameController.text.trim()),
                                    child: const Text('Rename'),
                                  ),
                                ],
                              ),
                            );
                            if (newName != null && newName.isNotEmpty && newName != playlist.name) {
                              await StreamPlaylistsService.instance.renamePlaylist(playlist.id, newName);
                              Fluttertoast.showToast(msg: 'Renamed to "$newName"');
                            }
                          }
                        },
                        itemBuilder: (ctx) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: Row(
                              children: [
                                Icon(Icons.edit_rounded, size: 20),
                                SizedBox(width: 10),
                                Text('Rename Playlist'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                                SizedBox(width: 10),
                                Text('Delete Playlist', style: TextStyle(color: Colors.redAccent)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                if (songs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            icon: const Icon(Icons.play_arrow_rounded, size: 20),
                            label: const Text('Play All'),
                            onPressed: () {
                              context.read<PlayerBloc>().add(PlayQueueEvent(songs, initialIndex: 0));
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Playing "${playlist.name}"', style: GoogleFonts.outfit()),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                          ),
                          icon: const Icon(Icons.shuffle_rounded, size: 18),
                          label: const Text('Shuffle'),
                          onPressed: () {
                            final shuffled = List<Song>.from(songs)..shuffle();
                            context.read<PlayerBloc>().add(PlayQueueEvent(shuffled, initialIndex: 0));
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Shuffling "${playlist.name}"', style: GoogleFonts.outfit()),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                const Divider(height: 1),

                // Songs List
                Expanded(
                  child: songs.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.playlist_add_rounded, size: 48, color: theme.colorScheme.primary.withValues(alpha: 0.4)),
                                const SizedBox(height: 12),
                                Text('This playlist is empty', style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Text(
                                  'Tap the 3 dots on any song in Stream to add it to this playlist',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.outfit(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          controller: scrollController,
                          itemCount: songs.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            indent: 72,
                            color: isDark ? Colors.white10 : Colors.black12,
                          ),
                          itemBuilder: (ctx, index) {
                            final track = songs[index];
                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: AlbumArtWidget(
                                  albumArt: track.albumArt,
                                  width: 44,
                                  height: 44,
                                  fallbackIcon: Icons.music_note_rounded,
                                ),
                              ),
                              title: Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.outfit(fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.close_rounded, size: 18),
                                    tooltip: 'Remove from playlist',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () async {
                                      await StreamPlaylistsService.instance.removeSongFromPlaylist(playlist.id, track.id);
                                      Fluttertoast.showToast(msg: 'Removed from "${playlist.name}"');
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.more_vert_rounded, size: 20),
                                    tooltip: 'Song options',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => SongOptionsBottomSheet.show(context, song: track),
                                  ),
                                ],
                              ),
                              onTap: () {
                                context.read<PlayerBloc>().add(PlayQueueEvent(songs, initialIndex: index));
                                Navigator.pop(context);
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

extension SongToJioSaavnItem on Song {
  JioSaavnItem toJioSaavnItem() {
    return JioSaavnItem(
      type: 'song',
      id: id.toString(),
      token: id.toString(),
      title: title,
      subtitle: artist,
      imageUrl: albumArt ?? '',
      directMediaUrl: filePath,
      duration: duration.inSeconds.toString(),
      quality: audioQuality ?? '320 kbps',
    );
  }
}
