import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';

/// Lets the user swipe [child] sideways to change song: left plays the next
/// song, right plays the previous one.
///
/// The motion is a full slide: the tile follows the finger; on a swipe it
/// slides the rest of the way out, and the new song's tile slides in from the
/// opposite side and settles in place, instead of just appearing. A song that
/// changes by itself (autoplay, the Next button) slides in the same way, from
/// the right.
///
/// [contentKey] identifies what [child] is showing (e.g. the song id). The
/// slide-in starts when it changes; if it does not change within
/// [changeTimeout] (the song is slow to load, or there is nothing to skip to)
/// the tile slides back in with its current content.
///
/// A quick flick or a drag of at least [swipeDistance] counts as a swipe;
/// anything smaller springs back. Taps pass through to the child.
class SwipeToSkip extends StatefulWidget {
  final Widget child;
  final Object? contentKey;

  /// How far the child may follow the finger before the swipe is released.
  final double maxTravel;

  /// Drag distance (px) that counts as a swipe.
  final double swipeDistance;

  /// Flick speed (px/s) that counts as a swipe.
  final double swipeVelocity;

  /// How long to wait for the new song before sliding back in.
  final Duration changeTimeout;

  const SwipeToSkip({
    super.key,
    required this.child,
    this.contentKey,
    this.maxTravel = 140,
    this.swipeDistance = 60,
    this.swipeVelocity = 350,
    this.changeTimeout = const Duration(milliseconds: 900),
  });

  @override
  State<SwipeToSkip> createState() => _SwipeToSkipState();
}

class _SwipeToSkipState extends State<SwipeToSkip> with SingleTickerProviderStateMixin {
  /// Horizontal offset of the tile, in px. 0 = resting place.
  final ValueNotifier<double> _dragX = ValueNotifier<double>(0);

  /// Drives every programmatic slide; its value is written into [_dragX].
  late final AnimationController _anim;

  double _width = 300;

  /// True from the moment a swipe is released until the new tile has settled.
  bool _busy = false;

  /// Completed when [SwipeToSkip.contentKey] changes during a swipe.
  Completer<void>? _contentChanged;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(SwipeToSkip old) {
    super.didUpdateWidget(old);
    if (old.contentKey == widget.contentKey) return;

    final waiting = _contentChanged;
    if (_busy && waiting != null && !waiting.isCompleted) {
      waiting.complete(); // the swipe's new song arrived
    } else if (!_busy) {
      _slideInFromRight(); // changed on its own: autoplay, Next button, ...
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _dragX.dispose();
    super.dispose();
  }

  /// Animates [_dragX] from where it is now to [target].
  Future<void> _slideTo(double target, Duration duration, Curve curve) async {
    final from = _dragX.value;
    if (from == target) return;
    _anim
      ..stop()
      ..duration = duration
      ..value = 0;
    void tick() => _dragX.value = from + (target - from) * curve.transform(_anim.value);
    _anim.addListener(tick);
    try {
      await _anim.forward().orCancel;
    } on TickerCanceled {
      // disposed or restarted mid-slide
    } finally {
      _anim.removeListener(tick);
    }
    if (mounted) _dragX.value = target;
  }

  /// A song changed without a swipe: the new tile glides in from the right.
  Future<void> _slideInFromRight() async {
    _dragX.value = _width * 0.35;
    await _slideTo(0, const Duration(milliseconds: 300), Curves.easeOutCubic);
  }

  Future<void> _commitSwipe(int direction) async {
    // direction: -1 = left (next), +1 = right (previous)
    _busy = true;
    _contentChanged = Completer<void>();
    HapticFeedback.lightImpact();

    final bloc = context.read<PlayerBloc>();
    bloc.add(direction < 0 ? const NextSongEvent(isManualSkip: true) : const PreviousSongEvent());

    // 1. The current tile slides the rest of the way out.
    await _slideTo(direction * _width, const Duration(milliseconds: 180), Curves.easeIn);
    if (!mounted) return;

    // 2. Wait for the new song (or give up and show what is there).
    await _contentChanged!.future.timeout(widget.changeTimeout, onTimeout: () {});
    if (!mounted) return;

    // 3. The new tile enters from the opposite side and settles.
    _dragX.value = -direction * _width;
    await _slideTo(0, const Duration(milliseconds: 340), Curves.easeOutCubic);
    _busy = false;
    _contentChanged = null;
  }

  void _onDragEnd(DragEndDetails details) {
    if (_busy) return;
    final travelled = _dragX.value;
    final velocity = details.primaryVelocity ?? 0;

    final left = velocity < -widget.swipeVelocity || travelled < -widget.swipeDistance;
    final right = velocity > widget.swipeVelocity || travelled > widget.swipeDistance;
    if (left) {
      _commitSwipe(-1);
    } else if (right) {
      _commitSwipe(1);
    } else {
      _slideTo(0, const Duration(milliseconds: 220), Curves.easeOut); // spring back
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedWidth) _width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) {
            if (!_busy) _anim.stop(); // grab a tile that is still springing back
          },
          onHorizontalDragUpdate: (d) {
            if (_busy) return;
            _dragX.value = (_dragX.value + d.delta.dx).clamp(-widget.maxTravel, widget.maxTravel);
          },
          onHorizontalDragCancel: () {
            if (!_busy) _slideTo(0, const Duration(milliseconds: 220), Curves.easeOut);
          },
          onHorizontalDragEnd: _onDragEnd,
          child: ValueListenableBuilder<double>(
            valueListenable: _dragX,
            child: widget.child,
            builder: (context, dx, child) {
              // Fades as it slides away, so a tile leaving the screen does not
              // end abruptly at the edge of its box.
              final away = (dx.abs() / _width).clamp(0.0, 1.0);
              return Opacity(
                opacity: 1.0 - 0.85 * away,
                child: Transform.translate(offset: Offset(dx, 0), child: child),
              );
            },
          ),
        );
      },
    );
  }
}
