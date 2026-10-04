import 'package:flutter/material.dart';

/// A pulsing outline of the Stream home page, shown while it first loads: a
/// section title with song rows, then a title with a row of cards. It replaces
/// a full-page spinner, so the page already has its final shape when the real
/// content arrives.
class StreamHomeSkeleton extends StatefulWidget {
  const StreamHomeSkeleton({super.key});

  @override
  State<StreamHomeSkeleton> createState() => _StreamHomeSkeletonState();
}

class _StreamHomeSkeletonState extends State<StreamHomeSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurface;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final shade = base.withValues(alpha: 0.05 + 0.06 * _pulse.value);
          Widget block(double? width, double height, {double radius = 6}) => Container(
                width: width,
                height: height,
                decoration: BoxDecoration(color: shade, borderRadius: BorderRadius.circular(radius)),
              );

          Widget header(double titleWidth) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    block(28, 28, radius: 8),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [block(titleWidth, 16), const SizedBox(height: 7), block(titleWidth + 60, 10)],
                      ),
                    ),
                  ],
                ),
              );

          Widget songRow(int i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    block(50, 50, radius: 10),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [block(150.0 + (i % 2) * 40, 13), const SizedBox(height: 8), block(100.0 + (i % 3) * 25, 10)],
                      ),
                    ),
                  ],
                ),
              );

          Widget card() => Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [block(130, 130, radius: 14), const SizedBox(height: 8), block(100, 12), const SizedBox(height: 6), block(70, 10)],
                ),
              );

          return ListView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            children: [
              header(130),
              for (var i = 0; i < 4; i++) songRow(i),
              const SizedBox(height: 20),
              header(110),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: SizedBox(
                  height: 190,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [for (var i = 0; i < 4; i++) card()],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
