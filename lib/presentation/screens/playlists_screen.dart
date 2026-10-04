import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vinyl/data/models/playlist_model.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/presentation/widgets/album_art_widget.dart';
import 'package:vinyl/presentation/bloc/library/library_bloc.dart';
import 'package:vinyl/presentation/bloc/library/library_event.dart';
import 'package:vinyl/presentation/bloc/library/library_state.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/screens/category_detail_screen.dart';
import 'package:vinyl/presentation/screens/player_screen.dart';
import 'package:vinyl/presentation/bloc/theme/theme_cubit.dart';

class PlaylistsScreen extends StatelessWidget {
  /// When true, renders inside the Library tab (no app bar, transparent bg).
  final bool embedded;

  const PlaylistsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: embedded ? Colors.transparent : null,
      appBar: embedded
          ? null
          : AppBar(
        title: Text(
          'Playlists',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.playlist_add_rounded),
            tooltip: 'New Playlist',
            onPressed: () => _showCreatePlaylistDialog(context),
          ),
        ],
      ),
      body: BlocBuilder<LibraryBloc, LibraryState>(
        builder: (context, state) {
          if (state is LibraryLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          final allSongs = state is LibraryLoaded ? state.allSongs : <Song>[];
          final playlists = state is LibraryLoaded ? state.playlists : <PlaylistModel>[];
          final artDim = context.select<ThemeCubit, double>(
            (c) => c.state.albumArtDimension * 0.85,
          );

          final recentlyAdded = List<Song>.from(allSongs)
            ..sort((a, b) => b.dateModified.compareTo(a.dateModified));
          final downloaded = allSongs.where((s) {
            final album = s.album.toLowerCase();
            final genre = (s.genre ?? '').toLowerCase();
            final path = s.filePath.toLowerCase();
            return album.contains('download') ||
                genre.contains('download') ||
                path.contains('vinyl');
          }).toList();
          final dummyDate = DateTime(2000);
          final favoritesPlaylist = playlists.firstWhere(
            (p) => p.name.toLowerCase() == 'favorites',
            orElse: () => PlaylistModel(
              id: -1,
              name: 'Favorites',
              dateCreated: dummyDate,
              dateModified: dummyDate,
            ),
          );

          return ListView(
            padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 120),
            children: [
              // Smart Playlists Header
              Text(
                'Smart Playlists',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildSmartTile(
                      context,
                      title: 'Favorites',
                      subtitle: '${favoritesPlaylist.songs.length} tracks',
                      icon: Icons.favorite_rounded,
                      iconColor: Colors.redAccent,
                      isDark: isDark,
                      onTap: () {
                        if (favoritesPlaylist.songs.isNotEmpty) {
                          context.read<PlayerBloc>().add(
                                PlaySongEvent(favoritesPlaylist.songs.first, queue: favoritesPlaylist.songs),
                              );
                          Navigator.of(context).push(
                            PlayerScreen.route(favoritesPlaylist.songs.first),
                          );
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildSmartTile(
                      context,
                      title: 'Recently Added',
                      subtitle: '${recentlyAdded.length} tracks',
                      icon: Icons.auto_awesome_rounded,
                      iconColor: theme.colorScheme.primary,
                      isDark: isDark,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CategoryDetailScreen(
                              title: 'Recently Added',
                              subtitle: 'Smart Playlist',
                              icon: Icons.auto_awesome_rounded,
                              songs: recentlyAdded,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildSmartTile(
                      context,
                      title: 'Downloaded',
                      subtitle: '${downloaded.length} tracks',
                      icon: Icons.download_for_offline_rounded,
                      iconColor: theme.colorScheme.secondary,
                      isDark: isDark,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CategoryDetailScreen(
                              title: 'Downloaded',
                              subtitle: 'Smart Playlist',
                              icon: Icons.download_for_offline_rounded,
                              songs: downloaded,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              const Divider(height: 32),

              // Custom Playlists Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'My Custom Playlists (${playlists.length})',
                    style: GoogleFonts.outfit(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Create New'),
                    onPressed: () => _showCreatePlaylistDialog(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (playlists.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      children: [
                        Icon(
                          Icons.queue_music_rounded,
                          size: 56,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No Playlists Found',
                          style: GoogleFonts.outfit(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tap "Create New" above to organize your music library!',
                          style: GoogleFonts.outfit(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...playlists.map((playlist) {
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    elevation: 0,
                    color: isDark ? const Color(0xFF1E1E26) : Colors.white,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: theme.colorScheme.primaryContainer,
                          ),
                          child: Icon(
                            Icons.playlist_play_rounded,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                        title: Text(
                          playlist.name,
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: Text(
                          '${playlist.songs.length} track${playlist.songs.length == 1 ? '' : 's'}',
                          style: GoogleFonts.outfit(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (playlist.songs.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.play_circle_fill_rounded, size: 30),
                                color: theme.colorScheme.primary,
                                onPressed: () {
                                  context.read<PlayerBloc>().add(
                                        PlaySongEvent(playlist.songs.first, queue: playlist.songs),
                                      );
                                  Navigator.of(context).push(
                                    PlayerScreen.route(playlist.songs.first),
                                  );
                                },
                              ),
                            if (playlist.name.toLowerCase() != 'favorites')
                              IconButton(
                                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                                onPressed: () {
                                  context.read<LibraryBloc>().add(DeletePlaylistEvent(playlist.id));
                                },
                              ),
                          ],
                        ),
                        children: playlist.songs.isEmpty
                            ? [
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    'Playlist is empty. Add songs from your library!',
                                    style: GoogleFonts.outfit(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                    ),
                                  ),
                                )
                              ]
                            : playlist.songs.map((song) {
                                return ListTile(
                                  leading: AlbumArtWidget(
                                    albumArt: song.albumArt,
                                    width: artDim,
                                    height: artDim,
                                    borderRadius: BorderRadius.circular(8),
                                    fallbackIcon: Icons.music_note_rounded,
                                    iconSize: 20,
                                  ),
                                  title: Text(
                                    song.title,
                                    style: GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 14),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    song.artist,
                                    style: GoogleFonts.outfit(fontSize: 12),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
                                    onPressed: () {
                                      context.read<LibraryBloc>().add(
                                            RemoveSongFromPlaylistEvent(playlist.id, song.id),
                                          );
                                    },
                                  ),
                                  onTap: () {
                                    context.read<PlayerBloc>().add(
                                          PlaySongEvent(song, queue: playlist.songs),
                                        );
                                    Navigator.of(context).push(
                                      PlayerScreen.route(song),
                                    );
                                  },
                                );
                              }).toList(),
                      ),
                    ),
                  );
                }),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSmartTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E26) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: iconColor.withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(height: 8),
            Text(
              title,
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: GoogleFonts.outfit(
                fontSize: 11,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  static void _showCreatePlaylistDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Create New Playlist', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Playlist Title (e.g., Workout Hits)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                context.read<LibraryBloc>().add(CreatePlaylistEvent(name));
              }
              Navigator.pop(dialogCtx);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}
