import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/core/utils/duration_formatter.dart';
import 'package:vinyl/presentation/bloc/library/library_bloc.dart';
import 'package:vinyl/presentation/bloc/library/library_event.dart';
import 'package:vinyl/presentation/bloc/library/library_state.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/core/di/injection_container.dart';
import 'package:vinyl/services/audio_service.dart';
import 'package:vinyl/services/lock_lyrics_service.dart';
import 'package:vinyl/services/settings_service.dart';
import 'package:vinyl/presentation/widgets/album_art_widget.dart';
import 'package:vinyl/presentation/widgets/swipe_to_skip.dart';
import 'package:vinyl/presentation/widgets/wavy_slider.dart';
import 'package:vinyl/presentation/widgets/queue_bottom_sheet.dart';
import 'package:vinyl/presentation/widgets/sleep_timer_dialog.dart';
import 'package:vinyl/services/stream_favorites_service.dart';
import 'package:vinyl/presentation/widgets/lyrics_view.dart';
import 'package:vinyl/presentation/widgets/add_to_playlist_sheet.dart';
import 'package:fluttertoast/fluttertoast.dart';

class PlayerScreen extends StatefulWidget {
  final Song song;

  const PlayerScreen({required this.song, super.key});

  /// The full player slides up from the bottom (where the mini player sits)
  /// and slides back down into it. While the user drags it down, the slide
  /// follows the finger exactly.
  static Route<void> route(Song song) => _PlayerRoute(song);

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

/// The slide-up route of the full player. It is a subclass so the swipe-down
/// gesture can reach the route's animation controller (it is protected).
class _PlayerRoute extends PageRouteBuilder<void> {
  _PlayerRoute(Song song)
      : super(
          settings: const RouteSettings(name: 'player'),
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, __, ___) => PlayerScreen(song: song),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // Linear while a finger is driving it, eased otherwise.
            final dragging = ModalRoute.of(context)?.navigator?.userGestureInProgress ?? false;
            final position = dragging
                ? animation
                : CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                    reverseCurve: Curves.easeInCubic,
                  );
            return SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(position),
              child: child,
            );
          },
        );

  AnimationController? get dragController => controller;
}

/// Drives the player route's own animation from a downward drag, so the screen
/// follows the finger and then either finishes sliding down into the mini
/// player or springs back (the same technique iOS uses for its back swipe).
class _PlayerDismissDrag {
  final NavigatorState navigator;
  final AnimationController controller;

  _PlayerDismissDrag(this.navigator, this.controller) {
    navigator.didStartUserGesture();
  }

  /// [fraction] = how far the finger moved, as a fraction of screen height.
  void update(double fraction) {
    controller.value -= fraction;
  }

  /// [velocity] = screen heights per second; positive means downward.
  void end(double velocity) {
    const settle = Duration(milliseconds: 260);
    final close = velocity.abs() > 1.0 ? velocity > 0 : controller.value < 0.7;

    if (close) {
      navigator.pop();
      if (controller.isAnimating) {
        controller.animateBack(0.0, duration: settle, curve: Curves.easeOutCubic);
      }
    } else {
      controller.animateTo(1.0, duration: settle, curve: Curves.easeOutCubic);
    }

    if (controller.isAnimating) {
      late AnimationStatusListener listener;
      listener = (status) {
        controller.removeStatusListener(listener);
        navigator.didStopUserGesture();
      };
      controller.addStatusListener(listener);
    } else {
      navigator.didStopUserGesture();
    }
  }
}

class _PlayerScreenState extends State<PlayerScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _rotationController;
  late AnimationController _waveController;
  StreamSubscription<bool>? _playingSubscription;
  bool _isDragging = false;
  double _dragPosition = 0.0;
  // Remembered: lyrics stay on when the player is minimised, reopened or the app restarts.
  bool _showLyrics = getIt<SettingsService>().playerShowsLyrics;
  final GlobalKey<LyricsViewState> _lyricsKey = GlobalKey<LyricsViewState>();

  // Swipe-down-to-minimise: drives this route's slide animation by hand.
  _PlayerDismissDrag? _dismissDrag;

  void _onDismissStart(DragStartDetails details) {
    final route = ModalRoute.of(context);
    if (route is! _PlayerRoute || route.dragController == null || !route.isCurrent) return;
    _dismissDrag = _PlayerDismissDrag(Navigator.of(context), route.dragController!);
  }

  void _onDismissUpdate(DragUpdateDetails details) {
    final height = MediaQuery.sizeOf(context).height;
    _dismissDrag?.update((details.primaryDelta ?? 0) / height);
  }

  void _onDismissEnd(DragEndDetails details) {
    final height = MediaQuery.sizeOf(context).height;
    _dismissDrag?.end((details.primaryVelocity ?? 0) / height);
    _dismissDrag = null;
  }

  void _onDismissCancel() {
    _dismissDrag?.end(0);
    _dismissDrag = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rotationController = AnimationController(
      duration: const Duration(seconds: 20),
      vsync: this,
    );
    _waveController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    final isAudioPlaying = getIt<AudioPlayerService>().isPlaying;
    final playerState = context.read<PlayerBloc>().state;
    if (playerState is PlayerPlaying && isAudioPlaying) {
      _rotationController.repeat();
      _waveController.repeat();
    }

    _playingSubscription = getIt<AudioPlayerService>().playingStream.listen((playing) {
      if (!playing) {
        if (_rotationController.isAnimating) _rotationController.stop();
        if (_waveController.isAnimating) _waveController.stop();
      } else {
        if (mounted && context.read<PlayerBloc>().state is PlayerPlaying) {
          if (!_rotationController.isAnimating) _rotationController.repeat();
          if (!_waveController.isAnimating) _waveController.repeat();
        }
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _playingSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _rotationController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.resumed) {
      _syncAnimation(context.read<PlayerBloc>().state);
    }
  }

  void _syncAnimation(PlayerState state) {
    final shouldAnimate = state is PlayerPlaying && getIt<AudioPlayerService>().isPlaying;
    if (shouldAnimate) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
      if (!_waveController.isAnimating) {
        _waveController.repeat();
      }
    } else {
      if (_rotationController.isAnimating) {
        _rotationController.stop();
      }
      if (_waveController.isAnimating) {
        _waveController.stop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // The lock screen follows this switch, and it is remembered across restarts.
    if (LockLyricsService.instance.lyricsOn != _showLyrics) {
      LockLyricsService.instance.lyricsOn = _showLyrics;
      getIt<SettingsService>().setPlayerShowsLyrics(_showLyrics);
    }

    return BlocConsumer<PlayerBloc, PlayerState>(
      buildWhen: (previous, current) {
        if (previous.runtimeType != current.runtimeType) return true;
        if (previous is PlayerPlaying && current is PlayerPlaying) {
          return previous.song.id != current.song.id ||
              previous.duration != current.duration ||
              previous.song.duration != current.song.duration ||
              previous.isShuffle != current.isShuffle ||
              previous.isRepeat != current.isRepeat ||
              previous.repeatMode != current.repeatMode ||
              previous.playbackRate != current.playbackRate;
        }
        if (previous is PlayerPaused && current is PlayerPaused) {
          return previous.song.id != current.song.id ||
              previous.duration != current.duration ||
              previous.song.duration != current.song.duration ||
              previous.isShuffle != current.isShuffle ||
              previous.isRepeat != current.isRepeat ||
              previous.repeatMode != current.repeatMode;
        }
        return true;
      },
      listener: (context, state) => _syncAnimation(state),
      builder: (context, state) {
        Song currentSong = widget.song;
        Duration position = Duration.zero;
        Duration duration = widget.song.duration;
        bool isPlaying = false;
        bool isLoading = false;
        bool isShuffle = false;
        String repeatMode = 'Off';

        final isActuallyPlaying = (state is PlayerPlaying) && getIt<AudioPlayerService>().isPlaying;
        final isActuallyLoading = (state is PlayerLoading) && getIt<AudioPlayerService>().isPlaying;

        if (state is PlayerPlaying) {
          currentSong = state.song;
          position = state.position;
          duration = state.duration.inMilliseconds > 0
              ? state.duration
              : currentSong.duration;
          isPlaying = isActuallyPlaying;
          isShuffle = state.isShuffle;
          repeatMode = state.repeatMode;
        } else if (state is PlayerPaused) {
          currentSong = state.song;
          position = state.position;
          duration = state.duration.inMilliseconds > 0
              ? state.duration
              : currentSong.duration;
          isPlaying = false;
          isShuffle = state.isShuffle;
          repeatMode = state.repeatMode;
        } else if (state is PlayerLoading) {
          if (state.song != null) {
            currentSong = state.song!;
          }
          position = Duration.zero;
          duration = currentSong.duration;
          isLoading = isActuallyLoading;
          isPlaying = false;
          isShuffle = state.isShuffle;
          repeatMode = state.repeatMode;
        }

        if (!isPlaying) {
          if (_rotationController.isAnimating) _rotationController.stop();
          if (_waveController.isAnimating) _waveController.stop();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncAnimation(state);
        });

        final screen = Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 32,
                color: isDark ? Colors.white : Colors.black87,
              ),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              'NOW PLAYING',
              style: GoogleFonts.outfit(
                fontSize: 13,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
            actions: [
              IconButton(
                icon: Icon(
                  _showLyrics ? Icons.album_rounded : Icons.lyrics_rounded,
                  color: _showLyrics
                      ? theme.colorScheme.primary
                      : (isDark ? Colors.white : Colors.black87),
                ),
                tooltip: _showLyrics ? 'Show Album Art' : 'Show Lyrics',
                onPressed: () {
                  setState(() {
                    _showLyrics = !_showLyrics;
                  });
                },
              ),
              IconButton(
                icon: Icon(
                  Icons.radio_rounded,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                tooltip: 'Start Radio',
                onPressed: () {
                  context.read<PlayerBloc>().add(StartRadioEvent(currentSong));
                },
              ),
              IconButton(
                icon: Icon(
                  Icons.queue_music_rounded,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                tooltip: 'Playback Queue',
                onPressed: () {
                  QueueBottomSheet.show(context);
                },
              ),
              IconButton(
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                onPressed: () {
                  double currentRate = 1.0;
                  if (state is PlayerPlaying) {
                    currentRate = state.playbackRate;
                  } else if (state is PlayerPaused) {
                    currentRate = state.playbackRate;
                  }
                  _showPlayerMenu(context, currentRate, currentSong);
                },
              ),
            ],
          ),
          body: Stack(
            children: [
              Column(
            children: [
              SizedBox(height: _showLyrics ? 4 : 20),
              // Album Art with Vinyl Spinning Effect or Synced Lyrics
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _showLyrics
                      ? Container(
                          key: const ValueKey('lyrics_view'),
                          child: LyricsView(key: _lyricsKey, song: currentSong),
                        )
                      : GestureDetector(
                          key: const ValueKey('album_art_view'),
                          onTap: () {
                            setState(() {
                              _showLyrics = true;
                            });
                          },
                          // Swipe the disc: left = next song, right = previous.
                          child: SwipeToSkip(
                            contentKey: currentSong.id,
                            child: Center(
                            child: RotationTransition(
                              turns: _rotationController,
                              child: Container(
                                width: 280,
                                height: 280,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: isDark
                                          ? Colors.black.withValues(alpha: 0.6)
                                          : theme.colorScheme.primary.withValues(alpha: 0.3),
                                      blurRadius: 30,
                                      spreadRadius: 5,
                                    ),
                                  ],
                                ),
                                child: AlbumArtWidget(
                                  albumArt: currentSong.albumArt,
                                  width: 280,
                                  height: 280,
                                  isCircular: true,
                                  fallbackIcon: Icons.music_note_rounded,
                                  iconSize: 130,
                                ),
                              ),
                            ),
                          ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              // Song Info with Heart (Favorite) Button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            currentSong.title.isNotEmpty ? currentSong.title : 'Unknown Title',
                            style: GoogleFonts.outfit(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            currentSong.album.isNotEmpty && currentSong.album != 'Unknown Album'
                                ? '${currentSong.artist} • ${currentSong.album}'
                                : currentSong.artist,
                            style: GoogleFonts.outfit(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          // Source & quality badges
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(
                              spacing: 8,
                              children: [
                                _SourceBadge(source: currentSong.effectiveSource),
                                if (currentSong.effectiveAudioQuality != null)
                                  _QualityBadge(quality: currentSong.effectiveAudioQuality!),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Builder(
                      builder: (context) {
                        final isStream = currentSong.filePath.startsWith('http://') ||
                            currentSong.filePath.startsWith('https://') ||
                            currentSong.source == 'jiosaavn';

                        if (isStream) {
                          return StreamBuilder<List<Song>>(
                            stream: StreamFavoritesService.instance.onFavoritesChanged,
                            builder: (context, snapshot) {
                              final isFav = StreamFavoritesService.instance.isFavorite(currentSong.id);
                              return IconButton(
                                icon: Icon(
                                  isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                  color: isFav ? Colors.redAccent : (isDark ? Colors.white70 : Colors.black54),
                                ),
                                iconSize: 28,
                                onPressed: () async {
                                  final added = await StreamFavoritesService.instance.toggleFavorite(currentSong);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        added ? 'Added to Stream Favorites' : 'Removed from Stream Favorites',
                                        style: GoogleFonts.outfit(),
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                },
                              );
                            },
                          );
                        }

                        final libState = context.watch<LibraryBloc>().state;
                        bool isFavorite = false;
                        if (libState is LibraryLoaded) {
                          final favIndex = libState.playlists.indexWhere((p) => p.name.toLowerCase() == 'favorites');
                          if (favIndex != -1) {
                            isFavorite = libState.playlists[favIndex].songs.any((s) => s.id == currentSong.id);
                          }
                        }

                        return IconButton(
                          icon: Icon(
                            isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                            color: isFavorite
                                ? Colors.redAccent
                                : (isDark ? Colors.white70 : Colors.black54),
                          ),
                          iconSize: 28,
                          onPressed: () {
                            context.read<LibraryBloc>().add(ToggleFavoriteEvent(currentSong));
                            ScaffoldMessenger.of(context).hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  isFavorite
                                      ? 'Removed from Library Favorites'
                                      : 'Added to Library Favorites',
                                  style: GoogleFonts.outfit(),
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Progress Slider with Live Sine Wave Track & Timers
              StreamBuilder<Duration>(
                stream: getIt<AudioPlayerService>().positionStream,
                builder: (context, snapshot) {
                  final isChanging = state is PlayerLoading;
                  final livePos = isChanging ? Duration.zero : (snapshot.data ?? position);
                  final currentPos = _isDragging
                      ? Duration(milliseconds: _dragPosition.toInt())
                      : livePos;
                  final liveDuration = (duration > Duration.zero)
                      ? duration
                      : (currentSong.duration > Duration.zero
                          ? currentSong.duration
                          : (getIt<AudioPlayerService>().player.duration ?? Duration.zero));
                  final liveSliderMax = liveDuration.inMilliseconds.toDouble() > 0
                      ? liveDuration.inMilliseconds.toDouble()
                      : 1.0;
                  final liveSliderValue = currentPos.inMilliseconds.toDouble().clamp(0.0, liveSliderMax);

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        AnimatedBuilder(
                          animation: _waveController,
                          builder: (context, child) {
                            final showWave = getIt<SettingsService>().showPlayerWaveform;
                            final waving = isPlaying && showWave;
                            // The wave eases in on play and flattens on pause.
                            return TweenAnimationBuilder<double>(
                              tween: Tween<double>(end: waving ? 1.0 : 0.0),
                              duration: const Duration(milliseconds: 450),
                              curve: Curves.easeInOut,
                              builder: (context, amplitude, _) => SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackShape: WavySliderTrackShape(
                                  waveAnimationValue: _waveController.value,
                                  isPlaying: waving,
                                  amplitude: amplitude,
                                ),
                                thumbShape: SnakeHeadSliderThumbShape(
                                  thumbRadius: 11.0,
                                  waveAnimationValue: _waveController.value,
                                  isPlaying: waving,
                                ),
                                overlayShape: SliderComponentShape.noOverlay,
                                activeTrackColor: theme.colorScheme.primary,
                                inactiveTrackColor: theme.colorScheme.primary.withValues(alpha: 0.25),
                                thumbColor: theme.colorScheme.primary,
                              ),
                              child: Slider(
                                min: 0,
                                max: liveSliderMax,
                                value: liveSliderValue,
                                onChangeStart: (value) {
                                  setState(() {
                                    _isDragging = true;
                                    _dragPosition = value;
                                  });
                                },
                                onChanged: (value) {
                                  setState(() {
                                    _dragPosition = value;
                                  });
                                },
                                onChangeEnd: (value) {
                                  setState(() {
                                    _isDragging = false;
                                  });
                                  context.read<PlayerBloc>().add(
                                        SeekEvent(Duration(milliseconds: value.toInt())),
                                      );
                                },
                              ),
                              ),
                            );
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                formatDuration(currentPos),
                                style: GoogleFonts.outfit(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white70 : Colors.black54,
                                ),
                              ),
                              Text(
                                formatDuration(liveDuration),
                                style: GoogleFonts.outfit(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white70 : Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              // Control Action Buttons
              Padding(
                padding: const EdgeInsets.only(bottom: 22, left: 16, right: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.shuffle_rounded,
                        color: isShuffle
                            ? theme.colorScheme.primary
                            : (isDark ? Colors.white54 : Colors.black38),
                      ),
                      iconSize: 26,
                      onPressed: () {
                        context.read<PlayerBloc>().add(const ToggleShuffleEvent());
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.skip_previous_rounded,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      iconSize: 38,
                      onPressed: () {
                        context.read<PlayerBloc>().add(const PreviousSongEvent());
                      },
                    ),
                    Container(
                      width: 66,
                      height: 66,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.primary,
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.primary.withValues(alpha: 0.4),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: isLoading
                          ? const Center(
                              child: SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 3,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: Icon(
                                isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: Colors.white,
                              ),
                              iconSize: 34,
                              onPressed: () {
                                if (isPlaying) {
                                  context.read<PlayerBloc>().add(const PauseEvent());
                                } else {
                                  context.read<PlayerBloc>().add(const ResumeEvent());
                                }
                              },
                            ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.skip_next_rounded,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      iconSize: 38,
                      onPressed: () {
                        context.read<PlayerBloc>().add(const NextSongEvent(isManualSkip: true));
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        repeatMode == 'One'
                            ? Icons.repeat_one_rounded
                            : Icons.repeat_rounded,
                        color: repeatMode != 'Off'
                            ? theme.colorScheme.primary
                            : (isDark ? Colors.white54 : Colors.black38),
                      ),
                      tooltip: 'Repeat Mode: $repeatMode',
                      iconSize: 26,
                      onPressed: () {
                        context.read<PlayerBloc>().add(const ToggleRepeatEvent());
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
            ], // Stack children
          ), // Stack
        );

        // Swipe down anywhere to minimise into the mini player.
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: _onDismissStart,
          onVerticalDragUpdate: _onDismissUpdate,
          onVerticalDragEnd: _onDismissEnd,
          onVerticalDragCancel: _onDismissCancel,
          child: screen,
        );
      },
    );
  }

  void _showPlayerMenu(BuildContext context, double currentRate, Song currentSong) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text(
                    'Playback Speed',
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    children: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((rate) {
                      final isSelected = (rate - currentRate).abs() < 0.01;
                      return ChoiceChip(
                        label: Text('${rate}x'),
                        selected: isSelected,
                        onSelected: (selected) {
                          context
                              .read<PlayerBloc>()
                              .add(SetPlaybackRateEvent(rate));
                          Navigator.pop(ctx);
                        },
                      );
                    }).toList(),
                  ),
                  const Divider(height: 28),

                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.playlist_add_rounded, color: Color(0xFF2BC5B4)),
                    title: Text(
                      'Add to Playlist',
                      style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      'Save this track to one of your playlists',
                      style: GoogleFonts.outfit(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(ctx);
                      AddToPlaylistSheet.show(context, currentSong);
                    },
                  ),
                  const Divider(height: 16),

                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.queue_music_rounded, color: Color(0xFF2BC5B4)),
                    title: Text(
                      'Add to Queue',
                      style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      'Play this track next in the current queue',
                      style: GoogleFonts.outfit(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(ctx);
                      context.read<PlayerBloc>().add(AddToQueueEvent(currentSong));
                      Fluttertoast.showToast(
                        msg: 'Added "${currentSong.title}" to queue',
                        toastLength: Toast.LENGTH_SHORT,
                      );
                    },
                  ),
                  const Divider(height: 16),

                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.radio_rounded, color: Color(0xFF2BC5B4)),
                    title: Text(
                      'Start Radio',
                      style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      'Queue similar tracks powered by JioSaavn recommendations',
                      style: GoogleFonts.outfit(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(ctx);
                      context.read<PlayerBloc>().add(StartRadioEvent(currentSong));
                    },
                  ),
                  const Divider(height: 20),

                  // Lyrics Controls in Three-Dot Menu
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_showLyrics ? Icons.album_rounded : Icons.lyrics_rounded),
                    title: Text(
                      _showLyrics ? 'Show Album Art' : 'Show Synced Lyrics',
                      style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() => _showLyrics = !_showLyrics);
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.search_rounded),
                    title: Text('Search Lyrics', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(ctx);
                      if (!_showLyrics) setState(() => _showLyrics = true);
                      LyricsView.showSearchModal(context, currentSong);
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.refresh_rounded),
                    title: Text('Reload Lyrics', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(ctx);
                      if (!_showLyrics) setState(() => _showLyrics = true);
                      _lyricsKey.currentState?.reloadLyrics();
                    },
                  ),
                  const Divider(height: 20),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.bedtime_rounded),
                    title: Text('Sleep Timer', style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(ctx);
                      SleepTimerDialog.show(context);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Badge showing song source: YouTube, JioSaavn, or Local
class _SourceBadge extends StatelessWidget {
  final String source;
  const _SourceBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (source.toLowerCase()) {
      'youtube' => ('YouTube', const Color(0xFFFF5252), Icons.smart_display_rounded),
      'jiosaavn' => ('JioSaavn', const Color(0xFF26C6DA), Icons.music_note_rounded),
      _ => ('Local', const Color(0xFF90A4AE), Icons.folder_rounded),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 10.5,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Badge showing audio quality
class _QualityBadge extends StatelessWidget {
  final String quality;
  const _QualityBadge({required this.quality});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.high_quality_rounded, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            quality,
            style: GoogleFonts.outfit(
              fontSize: 10.5,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
