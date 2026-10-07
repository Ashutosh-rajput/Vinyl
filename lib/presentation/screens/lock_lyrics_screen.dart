import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/presentation/widgets/lyrics_view.dart';
import 'package:vinyl/services/lock_lyrics_service.dart';

/// The only screen shown above the lock screen: the song and its synced lyrics.
/// It follows the player, so the lyrics change when the song does.
class LockLyricsScreen extends StatelessWidget {
  const LockLyricsScreen({super.key});

  static Song? _songOf(PlayerState state) {
    if (state is PlayerPlaying) return state.song;
    if (state is PlayerPaused) return state.song;
    if (state is PlayerLoading) return state.song;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Always dark: it is shown on a locked, often dark, screen.
    final theme = ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black);
    return Theme(
      data: theme,
      child: Scaffold(
        body: SafeArea(
          child: BlocBuilder<PlayerBloc, PlayerState>(
            buildWhen: (a, b) => _songOf(a)?.id != _songOf(b)?.id,
            builder: (context, state) {
              final song = _songOf(state);
              if (song == null) return const SizedBox.shrink();
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                    child: Column(
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white60),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: LyricsView(key: ValueKey(song.id), song: song)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextButton.icon(
                      onPressed: LockLyricsService.instance.requestUnlock,
                      icon: const Icon(Icons.lock_open_rounded, size: 18),
                      label: const Text('Unlock'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
