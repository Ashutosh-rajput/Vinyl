import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/presentation/widgets/album_art_widget.dart';
import 'package:vinyl/presentation/screens/library_screen.dart';
import 'package:vinyl/presentation/screens/stream_screen.dart';
import 'package:vinyl/presentation/screens/player_screen.dart';
import 'package:vinyl/presentation/screens/settings_screen.dart';

import 'package:vinyl/core/di/injection_container.dart';
import 'package:vinyl/services/audio_service.dart';
import 'package:vinyl/presentation/widgets/swipe_to_skip.dart';
import 'package:vinyl/presentation/widgets/update_dialog.dart';
import 'package:vinyl/presentation/widgets/welcome_intro_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// Global notifier to allow programmatic tab navigation from anywhere in the app.
  static final ValueNotifier<int> tabNotifier = ValueNotifier<int>(0);

  /// Switch the active tab on the home navigation bar (0: Library, 1: Stream, 2: Settings).
  static void switchToTab(int index) {
    tabNotifier.value = index;
  }

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    HomeScreen.tabNotifier.addListener(_handleTabChange);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // The first-launch intro goes first; the update popup waits for it.
      await WelcomeIntroSheet.show(context);
      if (mounted) UpdateDialog.checkAndShow(context);
    });
  }

  @override
  void dispose() {
    HomeScreen.tabNotifier.removeListener(_handleTabChange);
    super.dispose();
  }

  void _handleTabChange() {
    if (mounted && _selectedIndex != HomeScreen.tabNotifier.value) {
      setState(() {
        _selectedIndex = HomeScreen.tabNotifier.value;
      });
    }
  }

  final List<Widget> _pages = [
    const LibraryScreen(),
    const StreamScreen(),
    const SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _pages,
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _MiniPlayerDock(),
          Container(
            color: isDark ? const Color(0xFF181820) : Colors.white,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    _NavItem(
                      icon: Icons.library_music_outlined,
                      selectedIcon: Icons.library_music_rounded,
                      label: 'Library',
                      selected: _selectedIndex == 0,
                      onTap: () => HomeScreen.switchToTab(0),
                    ),
                    _NavItem(
                      icon: Icons.podcasts_outlined,
                      selectedIcon: Icons.podcasts_rounded,
                      label: 'Stream',
                      selected: _selectedIndex == 1,
                      onTap: () => HomeScreen.switchToTab(1),
                    ),
                    Container(
                      width: 1,
                      height: 32,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                    ),
                    _NavItem(
                      icon: Icons.settings_outlined,
                      selectedIcon: Icons.settings_rounded,
                      label: 'Settings',
                      selected: _selectedIndex == 2,
                      flex: 2,
                      onTap: () => HomeScreen.switchToTab(2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom bar item with a large rounded selection background behind the
/// icon and label (regular-sized icon).
class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Relative width in the bar; a smaller [flex] makes the item narrower.
  final int flex;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.flex = 4,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final color = selected
        ? primary
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65);

    return Expanded(
      flex: flex,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? primary.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? selectedIcon : icon, color: color, size: 24),
              const SizedBox(height: 3),
              Text(
                label,
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniPlayerDock extends StatelessWidget {
  const _MiniPlayerDock();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return BlocBuilder<PlayerBloc, PlayerState>(
      buildWhen: (previous, current) {
        if (previous.runtimeType != current.runtimeType) return true;
        if (previous is PlayerPlaying && current is PlayerPlaying) {
          return previous.song.id != current.song.id ||
              previous.duration != current.duration ||
              previous.song.duration != current.song.duration;
        }
        if (previous is PlayerPaused && current is PlayerPaused) {
          return previous.song.id != current.song.id ||
              previous.duration != current.duration ||
              previous.song.duration != current.song.duration;
        }
        return true;
      },
      builder: (context, state) {
        if (state is PlayerInitial || state is PlayerStopped) {
          return const SizedBox();
        }

        Song? currentSong;
        bool isPlaying = false;
        bool isLoading = false;

        if (state is PlayerPlaying) {
          currentSong = state.song;
          isPlaying = true;
        } else if (state is PlayerPaused) {
          currentSong = state.song;
          isPlaying = false;
        } else if (state is PlayerLoading) {
          currentSong = state.song;
          isLoading = true;
        }

        if (currentSong == null) return const SizedBox();
        final song = currentSong;

        return GestureDetector(
          onTap: () {
            Navigator.of(context).push(
              PlayerScreen.route(song),
            );
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Swipe the bar: left = next song, right = previous.
              SwipeToSkip(
                contentKey: song.id,
                maxTravel: 90,
                child: Container(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF232330)
                      : const Color(0xFFF2F2F7),
                  border: Border(
                    top: BorderSide(
                      color: isDark ? const Color(0xFF323242) : Colors.black12,
                      width: 0.8,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    AlbumArtWidget(
                      albumArt: song.albumArt,
                      width: 44,
                      height: 44,
                      borderRadius: BorderRadius.circular(10),
                      fallbackIcon: Icons.music_note_rounded,
                      iconSize: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            song.artist,
                            style: GoogleFonts.outfit(
                              fontSize: 12,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (isLoading)
                      const Padding(
                        padding: EdgeInsets.all(12.0),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      IconButton(
                        icon: Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        onPressed: () {
                          if (isPlaying) {
                            context.read<PlayerBloc>().add(const PauseEvent());
                          } else {
                            context.read<PlayerBloc>().add(const ResumeEvent());
                          }
                        },
                      ),
                    IconButton(
                      icon: const Icon(Icons.skip_next_rounded),
                      onPressed: () {
                        context.read<PlayerBloc>().add(const NextSongEvent(isManualSkip: true));
                      },
                    ),
                  ],
                ),
                ),
              ),
              StreamBuilder<Duration>(
                stream: getIt<AudioPlayerService>().positionStream,
                builder: (context, snapshot) {
                  final isChanging = state is PlayerLoading;
                  final livePos = isChanging ? Duration.zero : (snapshot.data ?? Duration.zero);
                  final effDur = (state is PlayerPlaying && state.duration > Duration.zero)
                      ? state.duration
                      : (state is PlayerPaused && state.duration > Duration.zero
                          ? state.duration
                          : (song.duration > Duration.zero
                              ? song.duration
                              : (getIt<AudioPlayerService>().player.duration ?? Duration.zero)));
                  final durationMs = effDur.inMilliseconds.toDouble();
                  final progress = durationMs > 0
                      ? (livePos.inMilliseconds.toDouble() / durationMs).clamp(0.0, 1.0)
                      : 0.0;

                  return LinearProgressIndicator(
                    value: progress,
                    minHeight: 2.5,
                    backgroundColor:
                        theme.colorScheme.primary.withValues(alpha: 0.15),
                    valueColor:
                        AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
