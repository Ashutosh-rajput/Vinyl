import 'package:flutter/material.dart';

/// A column of rows where rows that ARRIVE later glide in instead of popping in.
///
/// A new row grows from nothing between the rows that are already there (they
/// slide aside smoothly), fades and slides in, and glows for a moment so the
/// eye finds it. Rows that were already shown do not animate again, however
/// the list is reordered, because each row is keyed by [idOf].
///
/// Used for suggestions that improve while the screen is open: the fast sources
/// answer first, and the slow MetaBrainz songs arrive a few seconds later.
class ArrivalList<T> extends StatefulWidget {
  final List<T> items;
  final String Function(T item) idOf;
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// Whether the rows of the very first list animate too (one after another),
  /// or appear at once.
  final bool animateInitial;

  /// Delay between the first list's rows when [animateInitial] is true.
  final Duration stagger;

  const ArrivalList({
    super.key,
    required this.items,
    required this.idOf,
    required this.itemBuilder,
    this.animateInitial = false,
    this.stagger = const Duration(milliseconds: 55),
  });

  @override
  State<ArrivalList<T>> createState() => _ArrivalListState<T>();
}

class _ArrivalListState<T> extends State<ArrivalList<T>> {
  /// Ids that have been shown before; their rows never animate again.
  late final Set<String> _known = {};

  /// Ids that are new in the current list.
  Set<String> _fresh = {};

  bool _first = true;

  @override
  void initState() {
    super.initState();
    _absorb();
  }

  @override
  void didUpdateWidget(ArrivalList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _absorb();
  }

  void _absorb() {
    final ids = widget.items.map(widget.idOf).toList();
    _fresh = {
      for (final id in ids)
        if (!_known.contains(id)) id
    };
    _known.addAll(ids);
  }

  @override
  Widget build(BuildContext context) {
    final first = _first;
    _first = false;
    var freshIndex = 0;
    return Column(
      children: [
        for (final item in widget.items)
          // Keyed here, directly in the Column: that is what lets rows that
          // were already shown keep their place (and not animate) when a new
          // row is inserted above them.
          Builder(
            key: ValueKey(widget.idOf(item)),
            builder: (context) {
              final id = widget.idOf(item);
              final isFresh = _fresh.contains(id);
              final animate = isFresh && (!first || widget.animateInitial);
              final delay = animate && first
                  ? widget.stagger * (freshIndex++)
                  : Duration.zero;
              return _ArrivalRow(
                animate: animate,
                delay: delay,
                child: widget.itemBuilder(context, item),
              );
            },
          ),
      ],
    );
  }
}

class _ArrivalRow extends StatefulWidget {
  final bool animate;
  final Duration delay;
  final Widget child;

  const _ArrivalRow(
      {required this.animate, required this.delay, required this.child});

  @override
  State<_ArrivalRow> createState() => _ArrivalRowState();
}

class _ArrivalRowState extends State<_ArrivalRow>
    with SingleTickerProviderStateMixin {
  static const Duration _enter = Duration(milliseconds: 3200);

  late final AnimationController _controller;
  late final Animation<double> _size;
  late final Animation<double> _fade;
  late final Animation<double> _slide;
  late final Animation<double> _pop;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    final total = _enter + widget.delay;
    _controller = AnimationController(vsync: this, duration: total);

    // One timeline: [delay][grow 1s][fade/slide/pop][glow fades out].
    double at(Duration d) => d.inMicroseconds / total.inMicroseconds;
    final start = at(widget.delay);
    Animation<double> part(double fromMs, double toMs, Curve curve) =>
        CurvedAnimation(
          parent: _controller,
          curve: Interval(
            start + at(Duration(milliseconds: fromMs.round())),
            start + at(Duration(milliseconds: toMs.round())),
            curve: curve,
          ),
        );
    _size = part(0, 1000, Curves.easeInOutCubic);
    _fade = part(250, 1200, Curves.easeOut);
    _slide = part(250, 1500, Curves.easeOutCubic);
    // the pop-up: overshoots a little, then settles
    _pop = part(250, 1700, Curves.easeOutBack);
    _glow = part(900, 3200, Curves.easeIn);

    if (widget.animate) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        return SizeTransition(
          sizeFactor: _size,
          alignment: Alignment.topCenter, // grows downward from its top edge
          child: FadeTransition(
            opacity: _fade,
            child: Transform.scale(
              scale: 0.82 + 0.18 * _pop.value,
              alignment: Alignment.centerLeft,
              child: Transform.translate(
                offset: Offset(28 * (1 - _slide.value), 0),
                // The glow is an overlay on top of the row, not a coloured box
                // around it: a coloured ancestor hides a ListTile's own
                // background and tap splash (Flutter asserts about exactly that).
                child: Stack(
                  children: [
                    child!,
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          key: const ValueKey('arrival-glow'),
                          decoration: BoxDecoration(
                            // A soft glow that fades out once the row has settled.
                            color: highlight.withValues(
                                alpha: 0.16 * (1 - _glow.value)),
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
