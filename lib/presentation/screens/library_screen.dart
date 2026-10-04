import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:vinyl/core/di/injection_container.dart';
import 'package:vinyl/services/download_service.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/data/models/youtube_video_item.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/core/utils/jiosaavn_decoder.dart';
import 'package:vinyl/core/utils/duration_formatter.dart';
import 'package:vinyl/presentation/bloc/library/library_bloc.dart';
import 'package:vinyl/presentation/bloc/library/library_event.dart';
import 'package:vinyl/presentation/bloc/library/library_state.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/presentation/screens/home_screen.dart';
import 'package:vinyl/presentation/screens/player_screen.dart';
import 'package:vinyl/presentation/screens/playlists_screen.dart';
import 'package:vinyl/presentation/screens/category_detail_screen.dart';
import 'package:vinyl/presentation/widgets/album_art_widget.dart';
import 'package:vinyl/presentation/widgets/folder_picker_dialog.dart';
import 'package:vinyl/presentation/widgets/download_queue_sheet.dart';
import 'package:vinyl/presentation/widgets/download_queue_snackbar.dart';
import 'package:vinyl/presentation/bloc/theme/theme_cubit.dart';
import 'package:vinyl/presentation/widgets/support_banner_widget.dart';
import 'package:vinyl/presentation/widgets/song_options_bottom_sheet.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Rebuild on focus or tab change so back-press handling stays in sync
    _searchFocusNode.addListener(_rebuild);
    HomeScreen.tabNotifier.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HomeScreen.tabNotifier.removeListener(_rebuild);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PopScope(
      // Back closes search (focus and/or results) instead of exiting the app.
      // Tabs live in an IndexedStack, so only intercept while Library is shown.
      canPop: HomeScreen.tabNotifier.value != 0 ||
          (!_searchFocusNode.hasFocus && _searchController.text.trim().isEmpty),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _searchFocusNode.unfocus();
        if (_searchController.text.trim().isNotEmpty) {
          _searchController.clear();
          context.read<LibraryBloc>().add(const SearchSongsEvent(''));
        }
        if (mounted) setState(() {});
      },
      child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Search & Scan Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          textInputAction: TextInputAction.search,
                          onChanged: (query) {
                            if (query.trim().isEmpty) {
                              context
                                  .read<LibraryBloc>()
                                  .add(const SearchSongsEvent(''));
                            }
                            setState(() {});
                          },
                          onSubmitted: (query) {
                            final q = query.trim();
                            if (q.isNotEmpty) {
                              context
                                  .read<LibraryBloc>()
                                  .add(SearchSongsEvent(q));
                            }
                          },
                          decoration: InputDecoration(
                            hintText: 'Search songs, artists, albums',
                            prefixIcon: IconButton(
                              icon: const Icon(Icons.search_rounded),
                              tooltip: 'Search',
                              onPressed: () {
                                final q = _searchController.text.trim();
                                if (q.isNotEmpty) {
                                  _searchFocusNode.unfocus();
                                  context
                                      .read<LibraryBloc>()
                                      .add(SearchSongsEvent(q));
                                }
                              },
                            ),
                            suffixIcon: _searchController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear_rounded),
                                    onPressed: () {
                                      _searchController.clear();
                                      context
                                          .read<LibraryBloc>()
                                          .add(const SearchSongsEvent(''));
                                      setState(() {});
                                    },
                                  )
                                : null,
                            filled: true,
                            fillColor: isDark
                                ? const Color(0xFF262632)
                                : Colors.grey.shade200,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 16,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        icon: const Icon(Icons.create_new_folder_rounded),
                        tooltip: 'Add Custom Folder',
                        onPressed: () => _showAddFolderDialog(context),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        icon: const Icon(Icons.cloud_download_rounded),
                        tooltip: 'Open download queue',
                        onPressed: () => DownloadQueueSheet.show(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Category Chips
                  BlocBuilder<LibraryBloc, LibraryState>(
                    builder: (context, state) {
                      String selectedCategory = 'All';
                      if (state is LibraryLoaded) {
                        selectedCategory = state.selectedCategory;
                        // Categories don't apply to search results
                        if (state.searchQuery.trim().isNotEmpty) {
                          return const SizedBox.shrink();
                        }
                      }

                      final categories = [
                        'All',
                        'Folders',
                        'Albums',
                        'Artists',
                        'Playlists',
                      ];
                      // Same chip style as the Stream section's filter row
                      return SizedBox(
                        height: 40,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: categories.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final cat = categories[index];
                            final isSelected = selectedCategory == cat;
                            return ChoiceChip(
                              showCheckmark: false,
                              label: Text(
                                cat,
                                style: GoogleFonts.outfit(
                                  fontSize: 12,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w600,
                                  color: isSelected
                                      ? theme.colorScheme.onPrimary
                                      : null,
                                ),
                              ),
                              selected: isSelected,
                              selectedColor: theme.colorScheme.primary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              onSelected: (val) {
                                if (val) {
                                  context.read<LibraryBloc>().add(
                                        SelectCategoryEvent(cat),
                                      );
                                }
                              },
                            );
                          },
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),

            if (_searchController.text.trim().isEmpty)
              const SupportBannerWidget(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              ),

            // Main Content Area
            Expanded(
              child: BlocBuilder<LibraryBloc, LibraryState>(
                builder: (context, state) {
                  if (state is LibraryLoading) {
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  }

                  if (state is LibraryLoaded) {
                    if (state.searchQuery.trim().isNotEmpty) {
                      return _buildSearchResultsView(context, state, theme);
                    }

                    if (state.selectedCategory == 'Playlists') {
                      return const PlaylistsScreen(embedded: true);
                    }

                    final songs = state.displayedSongs;
                    if (songs.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.music_off_rounded,
                              size: 64,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.4),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No music yet',
                              style: GoogleFonts.outfit(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 32),
                              child: Text(
                                'Use the search bar or download icon above to find music, or share a song or playlist from another app to add it here',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.outfit(
                                  fontSize: 14,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    if (state.selectedCategory == 'Folders') {
                      return _buildFolderList(context, songs);
                    }

                    if (state.selectedCategory == 'Albums') {
                      return _buildAlbumList(context, songs);
                    }

                    if (state.selectedCategory == 'Artists') {
                      return _buildArtistList(context, songs);
                    }

                    return ListView.builder(
                      itemCount: songs.length,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemBuilder: (context, index) {
                        final song = songs[index];
                        return _SongListTile(
                          song: song,
                          onTap: () {
                            context.read<PlayerBloc>().add(
                                  PlaySongEvent(song, queue: songs),
                                );
                            Navigator.of(context).push(
                              PlayerScreen.route(song),
                            );
                          },
                        );
                      },
                    );
                  }

                  if (state is LibraryError) {
                    return Center(
                      child: Text('Error loading library: ${state.message}'),
                    );
                  }

                  return const SizedBox();
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

  Widget _buildSearchResultsView(
      BuildContext context, LibraryLoaded state, ThemeData theme) {
    final localSongs = state.displayedSongs;
    final onlineItems = state.onlineResults;
    final jiosaavnItems = state.jiosaavnResults;
    final isSearchingOnline = state.isSearchingOnline;

    if (localSongs.isEmpty && onlineItems.isEmpty && jiosaavnItems.isEmpty && !isSearchingOnline) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 64,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              'No results found for "${state.searchQuery}"',
              style:
                  GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        if (localSongs.isNotEmpty) ...[
          _resultsHeader(
            theme,
            icon: Icons.phone_android_rounded,
            title: 'On this device',
            detail: '${localSongs.length} ${localSongs.length == 1 ? 'song' : 'songs'}',
            color: theme.colorScheme.primary,
          ),
          ...localSongs.map((song) => _SongListTile(
                song: song,
                card: true,
                onTap: () {
                  context
                      .read<PlayerBloc>()
                      .add(PlaySongEvent(song, queue: localSongs));
                  Navigator.of(context).push(
                    PlayerScreen.route(song),
                  );
                },
              )),
          const SizedBox(height: 16),
        ],
        if (isSearchingOnline && jiosaavnItems.isEmpty && onlineItems.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(
                  'Searching online...',
                  style: GoogleFonts.outfit(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        if (jiosaavnItems.isNotEmpty) ...[
          _resultsHeader(
            theme,
            icon: Icons.music_note_rounded,
            title: 'JioSaavn',
            detail: '${jiosaavnItems.length} results • 320 kbps',
            color: const Color(0xFFFF6B35),
          ),
          ...jiosaavnItems.map((item) => _JioSaavnResultTile(item: item)),
          const SizedBox(height: 16),
        ],
        if (onlineItems.isNotEmpty) ...[
          _resultsHeader(
            theme,
            icon: Icons.smart_display_rounded,
            title: 'YouTube',
            detail: '${onlineItems.length} results • 128 kbps',
            color: Colors.red,
          ),
          ...onlineItems.map((item) => _OnlineResultTile(item: item)),
        ],
      ],
    );
  }

  Widget _resultsHeader(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String detail,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: GoogleFonts.outfit(
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddFolderDialog(BuildContext context) async {
    final bloc = context.read<LibraryBloc>();
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => const FolderPickerDialog(),
    );
    if (selected != null && selected.isNotEmpty) {
      bloc.add(ScanStorageEvent(customPaths: [selected]));
    }
  }

  Widget _buildFolderList(BuildContext context, List<Song> songs) {
    Map<String, List<Song>> folderMap = {};
    for (var song in songs) {
      final parts = song.filePath.split(RegExp(r'[/\\]'));
      final folderName = parts.length > 1 ? parts[parts.length - 2] : 'Root';
      folderMap.putIfAbsent(folderName, () => []).add(song);
    }

    final folders = folderMap.entries.toList();
    if (folders.isEmpty) {
      return const Center(child: Text('No folders found'));
    }

    return ListView.builder(
      itemCount: folders.length,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemBuilder: (context, index) {
        final entry = folders[index];
        return ListTile(
          leading: const CircleAvatar(
            child: Icon(Icons.folder_rounded),
          ),
          title: Text(
            entry.key,
            style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            '${entry.value.length} songs',
            style: GoogleFonts.outfit(fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CategoryDetailScreen(
                  title: entry.key,
                  subtitle: 'Folder',
                  icon: Icons.folder_rounded,
                  songs: entry.value,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAlbumList(BuildContext context, List<Song> songs) {
    Map<String, List<Song>> albumMap = {};
    for (var song in songs) {
      albumMap.putIfAbsent(song.album, () => []).add(song);
    }

    final albums = albumMap.entries.toList();
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.85,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final entry = albums[index];
        return InkWell(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CategoryDetailScreen(
                  title: entry.key,
                  subtitle: 'Album',
                  icon: Icons.album_rounded,
                  songs: entry.value,
                ),
              ),
            );
          },
          borderRadius: BorderRadius.circular(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.album_rounded,
                      size: 64,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                entry.key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
              ),
              Text(
                '${entry.value.length} songs',
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildArtistList(BuildContext context, List<Song> songs) {
    Map<String, List<Song>> artistMap = {};
    for (var song in songs) {
      artistMap.putIfAbsent(song.artist, () => []).add(song);
    }

    final artists = artistMap.entries.toList();
    return ListView.builder(
      itemCount: artists.length,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemBuilder: (context, index) {
        final entry = artists[index];
        return ListTile(
          leading: CircleAvatar(
            child: Text(
              entry.key.isNotEmpty ? entry.key[0].toUpperCase() : '?',
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
            ),
          ),
          title: Text(
            entry.key,
            style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            '${entry.value.length} songs',
            style: GoogleFonts.outfit(fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CategoryDetailScreen(
                  title: entry.key,
                  subtitle: 'Artist',
                  icon: Icons.person_rounded,
                  songs: entry.value,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SongListTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  /// Render as a rounded card (same as the online result tiles), used in
  /// search results.
  final bool card;

  const _SongListTile({
    required this.song,
    required this.onTap,
    this.card = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artDimension = card
        ? 50.0
        : context.select<ThemeCubit, double>(
            (cubit) => cubit.state.albumArtDimension,
          );

    final isCurrentSong = context.select<PlayerBloc, bool>((bloc) {
      final s = bloc.state;
      return (s is PlayerPlaying && s.song.id == song.id) ||
          (s is PlayerPaused && s.song.id == song.id);
    });
    final isPlaying = context.select<PlayerBloc, bool>((bloc) {
      final s = bloc.state;
      return s is PlayerPlaying && s.song.id == song.id;
    });

    final titleColor =
        isCurrentSong ? theme.colorScheme.primary : theme.colorScheme.onSurface;

    final tile = ListTile(
      contentPadding: card
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : const EdgeInsets.symmetric(vertical: 4),
      leading: AlbumArtWidget(
        albumArt: song.albumArt,
        width: artDimension,
        height: artDimension,
        borderRadius: BorderRadius.circular(8),
        fallbackIcon:
            isCurrentSong ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
        fallbackBgColor: isCurrentSong
            ? theme.colorScheme.primary
            : theme.colorScheme.primaryContainer,
        fallbackIconColor: isCurrentSong
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.onPrimaryContainer,
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.outfit(
          fontWeight: isCurrentSong ? FontWeight.bold : FontWeight.w600,
          color: titleColor,
        ),
      ),
      subtitle: Text(
        '${song.artist} • ${song.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.outfit(
          color: isCurrentSong
              ? theme.colorScheme.primary.withValues(alpha: 0.8)
              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isPlaying)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: _PlayingEqualizerBars(),
            )
          else if (isCurrentSong)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.pause_circle_rounded,
                  color: theme.colorScheme.primary, size: 20),
            ),
          Text(
            formatDuration(song.duration),
            style: GoogleFonts.outfit(
              color: isCurrentSong
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: isCurrentSong ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.more_vert_rounded, size: 20),
            tooltip: 'Song options',
            visualDensity: VisualDensity.compact,
            onPressed: () => SongOptionsBottomSheet.show(context, song: song, showDeleteFromLibrary: true),
          ),
        ],
      ),
      onTap: onTap,
    );

    if (!card) return tile;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: theme.colorScheme.surfaceContainerLow,
      child: tile,
    );
  }
}

class _PlayingEqualizerBars extends StatefulWidget {
  const _PlayingEqualizerBars();

  @override
  State<_PlayingEqualizerBars> createState() => _PlayingEqualizerBarsState();
}

class _PlayingEqualizerBarsState extends State<_PlayingEqualizerBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;

    return AnimatedBuilder(
      animation: _animController,
      builder: (context, _) {
        final value = _animController.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _bar((8 + (value * 12)).clamp(4.0, 20.0), color),
            const SizedBox(width: 2.5),
            _bar((18 - (value * 12)).clamp(4.0, 20.0), color),
            const SizedBox(width: 2.5),
            _bar((6 + (value * 14)).clamp(4.0, 20.0), color),
            const SizedBox(width: 2.5),
            _bar((16 - (value * 10)).clamp(4.0, 20.0), color),
          ],
        );
      },
    );
  }

  Widget _bar(double height, Color color) {
    return Container(
      width: 3,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }
}

class _OnlineResultTile extends StatelessWidget {
  final YouTubeVideoItem item;

  const _OnlineResultTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final downloadService = getIt<DownloadService>();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ValueListenableBuilder<List<ActiveDownload>>(
        valueListenable: downloadService.downloadQueueNotifier,
        builder: (context, queue, _) {
          final active = downloadService.getDownloadByUrl(item.url);

          Widget trailingWidget;
          if (active == null) {
            trailingWidget = IconButton(
              icon: const Icon(Icons.download_rounded, size: 22),
              tooltip: 'Download Track',
              onPressed: () => _triggerDownload(context, downloadService),
            );
          } else if (active.isCompleted) {
            trailingWidget = const IconButton(
              icon: Icon(Icons.check_circle_rounded,
                  color: Colors.green, size: 24),
              tooltip: 'Downloaded',
              onPressed: null,
            );
          } else if (active.isDownloading) {
            trailingWidget = Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    value: active.progress > 0 ? active.progress : null,
                    strokeWidth: 3,
                  ),
                ),
                Text(
                  '${(active.progress * 100).toInt()}%',
                  style: GoogleFonts.outfit(
                      fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            );
          } else if (active.isQueued) {
            trailingWidget = const Chip(
              avatar:
                  Icon(Icons.schedule_rounded, size: 14, color: Colors.orange),
              label: Text('Queued',
                  style: TextStyle(fontSize: 11, color: Colors.orange)),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
          } else {
            trailingWidget = IconButton(
              icon: const Icon(Icons.refresh_rounded,
                  color: Colors.red, size: 20),
              tooltip: 'Retry Download',
              onPressed: () => _triggerDownload(context, downloadService),
            );
          }

          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: item.thumbnailUrl,
                width: 50,
                height: 50,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) =>
                    const Icon(Icons.music_note_rounded),
              ),
            ),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    item.quality,
                    style: GoogleFonts.outfit(
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${item.author} • ${formatDuration(item.duration)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(fontSize: 12),
                  ),
                ),
              ],
            ),
            trailing: trailingWidget,
            onTap: () => _triggerDownload(context, downloadService),
          );
        },
      ),
    );
  }

  void _triggerDownload(BuildContext context, DownloadService service) {
    service.enqueueDownload(
      url: item.url,
      title: item.title,
      artist: item.author,
      albumArt: item.thumbnailUrl,
      duration: item.duration,
    );
    showDownloadQueuedSnackBar(
      context,
      title: item.title,
      onViewQueue: () => DownloadQueueSheet.show(context),
    );
  }
}

// ── JioSaavn result tile ──────────────────────────────────────────────────────

class _JioSaavnResultTile extends StatefulWidget {
  final JioSaavnItem item;

  const _JioSaavnResultTile({required this.item});

  @override
  State<_JioSaavnResultTile> createState() => _JioSaavnResultTileState();
}

class _JioSaavnResultTileState extends State<_JioSaavnResultTile> {
  bool _isExpanded = false;
  bool _isLoading = false;
  bool _loadFailed = false;
  List<JioSaavnItem> _tracks = [];

  void _toggleExpand() async {
    if (!widget.item.isAlbum && !widget.item.isPlaylist) return;
    setState(() {
      _isExpanded = !_isExpanded;
    });

    if (_isExpanded && _tracks.isEmpty && !_isLoading) {
      setState(() {
        _isLoading = true;
        _loadFailed = false;
      });
      final token =
          widget.item.token.isNotEmpty ? widget.item.token : widget.item.id;
      final list = widget.item.isAlbum
          ? await JioSaavnDecoder.fetchAlbumSongs(token)
          : await JioSaavnDecoder.fetchPlaylistSongs(token);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _tracks = list;
        _loadFailed = list.isEmpty;
      });
    }
  }

  void _triggerJioSaavnDownload(BuildContext context, DownloadService service) {
    String url;
    if (widget.item.directMediaUrl != null &&
        widget.item.directMediaUrl!.isNotEmpty) {
      url = widget.item.directMediaUrl!;
    } else if (widget.item.encryptedMediaUrl != null) {
      final decrypted =
          JioSaavnDecoder.decryptMediaUrl(widget.item.encryptedMediaUrl);
      url = decrypted ?? 'jiosaavn:${widget.item.encryptedMediaUrl}';
    } else if (widget.item.isAlbum) {
      url =
          'jiosaavn-album:${widget.item.token.isNotEmpty ? widget.item.token : widget.item.id}';
    } else if (widget.item.isPlaylist) {
      url =
          'jiosaavn-playlist:${widget.item.token.isNotEmpty ? widget.item.token : widget.item.id}';
    } else {
      url =
          'jiosaavn-token:${widget.item.token.isNotEmpty ? widget.item.token : widget.item.id}';
    }
    final secs = int.tryParse(widget.item.duration ?? '0') ?? 0;
    service.enqueueDownload(
      url: url,
      title: widget.item.title,
      artist: widget.item.subtitle,
      album: widget.item.isAlbum
          ? widget.item.title
          : (widget.item.subtitle.isNotEmpty
              ? widget.item.subtitle
              : 'JioSaavn'),
      albumArt: widget.item.imageUrl,
      duration: secs > 0 ? Duration(seconds: secs) : null,
      songKey: widget.item.isSong ? widget.item.id : null,
    );
    showDownloadQueuedSnackBar(
      context,
      title: widget.item.title,
      onViewQueue: () => DownloadQueueSheet.show(context),
    );
  }

  void _downloadTrack(
      BuildContext context, DownloadService service, JioSaavnItem track) {
    final directUrl = track.directMediaUrl ??
        JioSaavnDecoder.decryptMediaUrl(track.encryptedMediaUrl);
    final secs = int.tryParse(track.duration ?? '0') ?? 0;
    service.enqueueDownload(
      // No URL yet: DownloadService resolves the song from its id.
      url: (directUrl != null && directUrl.isNotEmpty)
          ? directUrl
          : 'jiosaavn-token:${track.token.isNotEmpty ? track.token : track.id}',
      title: track.title,
      artist: track.subtitle,
      album: widget.item.isAlbum ? widget.item.title : track.subtitle,
      albumArt:
          track.imageUrl.isNotEmpty ? track.imageUrl : widget.item.imageUrl,
      duration: secs > 0 ? Duration(seconds: secs) : null,
      songKey: track.id.isNotEmpty ? track.id : null,
    );
    showDownloadQueuedSnackBar(
      context,
      title: track.title,
      onViewQueue: () => DownloadQueueSheet.show(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloadService = getIt<DownloadService>();
    final theme = Theme.of(context);
    final isExpandable = widget.item.isAlbum || widget.item.isPlaylist;

    IconData typeIcon;
    if (widget.item.isAlbum) {
      typeIcon = Icons.album_rounded;
    } else if (widget.item.isArtist) {
      typeIcon = Icons.person_rounded;
    } else if (widget.item.isPlaylist) {
      typeIcon = Icons.queue_music_rounded;
    } else {
      typeIcon = Icons.music_note_rounded;
    }

    String subtitleText = widget.item.subtitle;
    if (widget.item.isSong && widget.item.duration != null) {
      final secs = int.tryParse(widget.item.duration ?? '0') ?? 0;
      subtitleText += ' • ${formatDuration(Duration(seconds: secs))}';
    } else if (isExpandable && widget.item.songCount != null) {
      subtitleText = '${widget.item.songCount} songs';
    }

    Widget? trailingWidget;
    if (widget.item.isSong &&
        (widget.item.directMediaUrl != null ||
            widget.item.encryptedMediaUrl != null)) {
      trailingWidget = ValueListenableBuilder<List<ActiveDownload>>(
        valueListenable: downloadService.downloadQueueNotifier,
        builder: (context, queue, _) {
          final directUrl = widget.item.directMediaUrl ??
              JioSaavnDecoder.decryptMediaUrl(widget.item.encryptedMediaUrl);
          final active = queue.where((d) =>
              (directUrl != null && d.url == directUrl) ||
              (widget.item.encryptedMediaUrl != null &&
                  (d.url == widget.item.encryptedMediaUrl ||
                      d.url == 'jiosaavn:${widget.item.encryptedMediaUrl}')) ||
              d.id == widget.item.id ||
              d.id == 'song:${widget.item.id}').isNotEmpty
              ? queue.lastWhere((d) =>
                  (directUrl != null && d.url == directUrl) ||
                  (widget.item.encryptedMediaUrl != null &&
                      (d.url == widget.item.encryptedMediaUrl ||
                          d.url ==
                              'jiosaavn:${widget.item.encryptedMediaUrl}')) ||
                  d.id == widget.item.id ||
              d.id == 'song:${widget.item.id}')
              : null;

          if (active == null) {
            return IconButton(
              icon: const Icon(Icons.download_rounded, size: 22),
              tooltip: 'Download from JioSaavn',
              onPressed: () =>
                  _triggerJioSaavnDownload(context, downloadService),
            );
          } else if (active.isCompleted) {
            return const Icon(Icons.check_circle_rounded,
                color: Colors.green, size: 24);
          } else if (active.isDownloading) {
            return Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    value: active.progress > 0 ? active.progress : null,
                    strokeWidth: 3,
                  ),
                ),
                Text(
                  '${(active.progress * 100).toInt()}%',
                  style: GoogleFonts.outfit(
                      fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            );
          } else if (active.isQueued) {
            return const Chip(
              avatar: Icon(Icons.schedule_rounded,
                  size: 14, color: Colors.orange),
              label: Text('Queued',
                  style: TextStyle(fontSize: 11, color: Colors.orange)),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
          } else {
            return IconButton(
              icon: const Icon(Icons.refresh_rounded,
                  color: Colors.red, size: 20),
              tooltip: 'Retry',
              onPressed: () =>
                  _triggerJioSaavnDownload(context, downloadService),
            );
          }
        },
      );
    } else if (isExpandable) {
      trailingWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.download_rounded, size: 22),
            tooltip: 'Download all songs',
            onPressed: () =>
                _triggerJioSaavnDownload(context, downloadService),
          ),
          IconButton(
            icon: Icon(
              _isExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 22,
            ),
            tooltip: _isExpanded ? 'Collapse' : 'Expand album',
            onPressed: _toggleExpand,
          ),
        ],
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: widget.item.imageUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: widget.item.imageUrl,
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        width: 50,
                        height: 50,
                        color: theme.colorScheme.primaryContainer,
                        child: Icon(typeIcon,
                            color: theme.colorScheme.onPrimaryContainer),
                      ),
                    )
                  : Container(
                      width: 50,
                      height: 50,
                      color: theme.colorScheme.primaryContainer,
                      child: Icon(typeIcon,
                          color: theme.colorScheme.onPrimaryContainer),
                    ),
            ),
            title: Text(
              widget.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B35).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.item.type.toUpperCase(),
                    style: GoogleFonts.outfit(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFFFF6B35),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.item.quality,
                    style: GoogleFonts.outfit(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF00C853),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    subtitleText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(fontSize: 12),
                  ),
                ),
              ],
            ),
            trailing: trailingWidget,
            onTap: isExpandable
                ? _toggleExpand
                : () => _triggerJioSaavnDownload(context, downloadService),
          ),
          if (isExpandable && _isExpanded) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            if (_isLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Loading tracks...',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              )
            else if (_loadFailed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: TextButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: Text('Failed to load tracks. Tap to retry',
                      style: GoogleFonts.outfit(fontSize: 12)),
                  onPressed: () {
                    setState(() => _tracks = []);
                    _toggleExpand();
                  },
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
                child: Row(
                  children: [
                    Text(
                      '${_tracks.length} Songs in ${widget.item.isAlbum ? 'Album' : 'Playlist'}',
                      style: GoogleFonts.outfit(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.download_rounded, size: 14),
                      label: Text('Download All',
                          style: GoogleFonts.outfit(
                              fontSize: 11, fontWeight: FontWeight.bold)),
                      onPressed: () =>
                          _triggerJioSaavnDownload(context, downloadService),
                    ),
                  ],
                ),
              ),
              ...List.generate(_tracks.length, (index) {
                final track = _tracks[index];
                final secs = int.tryParse(track.duration ?? '0') ?? 0;
                final dur =
                    secs > 0 ? formatDuration(Duration(seconds: secs)) : '';
                return ListTile(
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  leading: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${index + 1}',
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  title: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          track.quality,
                          style: GoogleFonts.outfit(
                            fontSize: 8.5,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF00C853),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${track.subtitle}${dur.isNotEmpty ? ' • $dur' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  trailing: ValueListenableBuilder<List<ActiveDownload>>(
                    valueListenable: downloadService.downloadQueueNotifier,
                    builder: (context, queue, _) {
                      final directUrl = track.directMediaUrl ??
                          JioSaavnDecoder.decryptMediaUrl(
                              track.encryptedMediaUrl);
                      final active = queue.where((d) =>
                          (directUrl != null && d.url == directUrl) ||
                          (track.encryptedMediaUrl != null &&
                              (d.url == track.encryptedMediaUrl ||
                                  d.url ==
                                      'jiosaavn:${track.encryptedMediaUrl}')) ||
                          d.id == track.id).isNotEmpty
                          ? queue.lastWhere((d) =>
                              (directUrl != null && d.url == directUrl) ||
                              (track.encryptedMediaUrl != null &&
                                  (d.url == track.encryptedMediaUrl ||
                                      d.url ==
                                          'jiosaavn:${track.encryptedMediaUrl}')) ||
                              d.id == track.id)
                          : null;

                      if (active == null) {
                        return IconButton(
                          icon: const Icon(Icons.download_rounded, size: 18),
                          tooltip: 'Download song',
                          onPressed: () => _downloadTrack(
                              context, downloadService, track),
                        );
                      } else if (active.isCompleted) {
                        return const Icon(Icons.check_circle_rounded,
                            color: Colors.green, size: 20);
                      } else if (active.isDownloading) {
                        return SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            value: active.progress > 0 ? active.progress : null,
                            strokeWidth: 2.5,
                          ),
                        );
                      } else if (active.isQueued) {
                        return const Icon(Icons.schedule_rounded,
                            color: Colors.orange, size: 20);
                      } else {
                        return IconButton(
                          icon: const Icon(Icons.refresh_rounded,
                              color: Colors.red, size: 18),
                          onPressed: () => _downloadTrack(
                              context, downloadService, track),
                        );
                      }
                    },
                  ),
                  onTap: () =>
                      _downloadTrack(context, downloadService, track),
                );
              }),
              const SizedBox(height: 6),
            ],
          ],
        ],
      ),
    );
  }
}
