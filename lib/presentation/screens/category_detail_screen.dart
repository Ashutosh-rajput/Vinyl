import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/screens/player_screen.dart';
import 'package:vinyl/presentation/widgets/album_art_widget.dart';
import 'package:vinyl/presentation/widgets/song_options_bottom_sheet.dart';
import 'package:vinyl/presentation/bloc/theme/theme_cubit.dart';

class CategoryDetailScreen extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Song> songs;

  const CategoryDetailScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.songs,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Card
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E28) : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.15),
                    child: Icon(icon, color: theme.colorScheme.primary, size: 28),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$subtitle • ${songs.length} track${songs.length == 1 ? '' : 's'}',
                          style: GoogleFonts.outfit(
                            fontSize: 13,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (songs.isNotEmpty) ...[
                    IconButton(
                      icon: const Icon(Icons.shuffle_rounded),
                      tooltip: 'Shuffle All',
                      color: theme.colorScheme.primary,
                      onPressed: () {
                        final shuffled = List<Song>.from(songs)..shuffle();
                        context.read<PlayerBloc>().add(
                              PlaySongEvent(shuffled.first, queue: shuffled),
                            );
                        Navigator.of(context).push(
                          PlayerScreen.route(shuffled.first),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.play_circle_fill_rounded, size: 38),
                      tooltip: 'Play All',
                      color: theme.colorScheme.primary,
                      onPressed: () {
                        context.read<PlayerBloc>().add(
                              PlaySongEvent(songs.first, queue: songs),
                            );
                        Navigator.of(context).push(
                          PlayerScreen.route(songs.first),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Songs List
          Expanded(
            child: songs.isEmpty
                ? Center(
                    child: Text(
                      'No tracks in this category',
                      style: GoogleFonts.outfit(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  )
                : Builder(
                    builder: (context) {
                      final artDim = context.select<ThemeCubit, double>(
                        (c) => c.state.albumArtDimension * 0.85,
                      );
                      return ListView.builder(
                        itemCount: songs.length,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        itemBuilder: (context, index) {
                          final song = songs[index];

                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
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
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${song.artist} • ${song.album}',
                          style: GoogleFonts.outfit(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.more_vert_rounded, size: 20),
                          tooltip: 'Song options',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => SongOptionsBottomSheet.show(context, song: song, showDeleteFromLibrary: true),
                        ),
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
                },
              ),
          ),
        ],
      ),
    );
  }
}
