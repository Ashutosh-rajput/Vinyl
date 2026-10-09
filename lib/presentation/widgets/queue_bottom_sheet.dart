import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/presentation/widgets/album_art_widget.dart';
import 'package:vinyl/presentation/widgets/suggestion_source_chip.dart';

class QueueBottomSheet extends StatelessWidget {
  const QueueBottomSheet({super.key});

  static Future<void> show(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const QueueBottomSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF16161E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: BlocBuilder<PlayerBloc, PlayerState>(
        buildWhen: (previous, current) {
          if (previous is PlayerPlaying && current is PlayerPlaying) {
            return previous.song.id != current.song.id ||
                previous.queue != current.queue;
          }
          if (previous is PlayerPaused && current is PlayerPaused) {
            return previous.song.id != current.song.id ||
                previous.queue != current.queue;
          }
          if (previous is PlayerLoading && current is PlayerLoading) {
            return previous.song?.id != current.song?.id ||
                previous.queue != current.queue;
          }
          return true;
        },
        builder: (context, state) {
          List<Song> queue = [];
          Song? currentSong;

          if (state is PlayerPlaying) {
            queue = state.queue;
            currentSong = state.song;
          } else if (state is PlayerPaused) {
            queue = state.queue;
            currentSong = state.song;
          } else if (state is PlayerLoading) {
            queue = state.queue;
            currentSong = state.song;
          }

          return Column(
            children: [
              // Top Drag Handle
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Queue Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Playback Queue',
                          style: GoogleFonts.outfit(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${queue.length} tracks in queue',
                          style: GoogleFonts.outfit(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (currentSong != null)
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF2BC5B4),
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            icon: const Icon(Icons.radio_rounded, size: 18),
                            label: Text(
                              'Radio',
                              style: GoogleFonts.outfit(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onPressed: () {
                              context.read<PlayerBloc>().add(StartRadioEvent(currentSong!));
                            },
                          ),
                        if (queue.length > 1)
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            icon: const Icon(Icons.clear_all_rounded, size: 18),
                            label: Text('Clear', style: GoogleFonts.outfit(fontSize: 13)),
                            onPressed: () {
                              context.read<PlayerBloc>().add(const ClearQueueEvent());
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 24),

              // Queue List
              Expanded(
                child: queue.isEmpty
                    ? Center(
                        child: Text(
                          'Queue is empty',
                          style: GoogleFonts.outfit(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      )
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: queue.length,
                        // ignore: deprecated_member_use
                        onReorder: (oldIndex, newIndex) {
                          context.read<PlayerBloc>().add(
                                ReorderQueueEvent(oldIndex, newIndex),
                              );
                        },
                        itemBuilder: (context, index) {
                          if (index < 0 || index >= queue.length) {
                            return const SizedBox.shrink(key: ValueKey('empty_queue_guard'));
                          }
                          final song = queue[index];
                          final isCurrent = currentSong?.id == song.id;

                          return Material(
                            key: ValueKey('queue_item_${song.id}'),
                            color: isCurrent
                                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                                : Colors.transparent,
                            child: ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      AlbumArtWidget(
                                        albumArt: song.albumArt,
                                        width: 44,
                                        height: 44,
                                        borderRadius: BorderRadius.circular(8),
                                        fallbackIcon: Icons.music_note_rounded,
                                      ),
                                      if (isCurrent)
                                        Container(
                                          color: Colors.black.withValues(alpha: 0.45),
                                          child: Center(
                                            child: Icon(
                                              Icons.graphic_eq_rounded,
                                              color: theme.colorScheme.primary,
                                              size: 22,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.outfit(
                                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.w600,
                                  color: isCurrent ? theme.colorScheme.primary : null,
                                ),
                              ),
                              subtitle: Row(
                                children: [
                                  // Developer option: the service that suggested this song
                                  // (Radio / Autoplay songs only; hidden unless switched on).
                                  SuggestionSourceChip(sources: context.read<PlayerBloc>().suggestedBy(song.id)),
                                  Expanded(
                                    child: Text(
                                      song.artist,
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
                                  IconButton(
                                    icon: const Icon(Icons.close_rounded, size: 20),
                                    onPressed: () {
                                      context.read<PlayerBloc>().add(
                                            RemoveFromQueueEvent(index),
                                          );
                                    },
                                  ),
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: const Icon(Icons.drag_handle_rounded),
                                  ),
                                ],
                              ),
                              onTap: () {
                                context.read<PlayerBloc>().add(
                                      PlaySongAtIndexEvent(index),
                                    );
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
