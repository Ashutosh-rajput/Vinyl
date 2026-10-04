import 'package:flutter/material.dart';

/// Placeholder rows shown where the suggestions will appear, while the first
/// songs are being found, so that the section is on screen with the rest of
/// the page from the start instead of popping in later and pushing things down.
class SuggestionPlaceholderRows extends StatefulWidget {
  final int count;

  const SuggestionPlaceholderRows({super.key, this.count = 4});

  @override
  State<SuggestionPlaceholderRows> createState() => _SuggestionPlaceholderRowsState();
}

class _SuggestionPlaceholderRowsState extends State<SuggestionPlaceholderRows>
    with SingleTickerProviderStateMixin {
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
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final shade = base.withValues(alpha: 0.05 + 0.06 * _pulse.value);
        Widget bar(double width, double height) => Container(
              width: width,
              height: height,
              decoration: BoxDecoration(color: shade, borderRadius: BorderRadius.circular(6)),
            );
        return Column(
          children: [
            for (var i = 0; i < widget.count; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(color: shade, borderRadius: BorderRadius.circular(10)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bar(150 + (i % 2) * 40, 13),
                          const SizedBox(height: 8),
                          bar(100 + (i % 3) * 25, 10),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
