import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vinyl/core/di/injection_container.dart';
import 'package:vinyl/services/settings_service.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';

/// Developer aid: a small label naming the service(s) a suggested song came
/// from. It is invisible unless the "Show suggestion source" developer option
/// is on, and follows that option live.
///
/// Pass [alwaysShow] = true (e.g. in the playback queue) to show the chip
/// regardless of the developer toggle.
class SuggestionSourceChip extends StatelessWidget {
  final Set<SuggestionSource>? sources;

  /// When true the chip is always visible. When false (default) it respects
  /// the "Show suggestion source" developer setting.
  final bool alwaysShow;

  const SuggestionSourceChip({super.key, required this.sources, this.alwaysShow = false});

  static Color colorOf(SuggestionSource source) => switch (source) {
        SuggestionSource.metaBrainz => const Color(0xFFB07CFF),
        SuggestionSource.deezer => const Color(0xFFFF6FA5),
        SuggestionSource.youtube => const Color(0xFFFF5252),
        SuggestionSource.jioSaavn => const Color(0xFF2BC4A8),
      };

  /// Highest-priority source first, so the main reason is read first.
  static List<SuggestionSource> ordered(Set<SuggestionSource> sources) =>
      SuggestionSource.values.where(sources.contains).toList();

  Widget _chip(Set<SuggestionSource> list) {
    final sources = ordered(list);
    final color = colorOf(sources.first);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.6),
      ),
      child: Text(
        sources.map((s) => s.label).join(' + '),
        style: GoogleFonts.outfit(fontSize: 10, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = sources;
    if (list == null || list.isEmpty) return const SizedBox.shrink();

    // Queue / always-visible mode — skip developer toggle.
    if (alwaysShow) return _chip(list);

    // Developer toggle mode — only visible when the setting is on.
    return ValueListenableBuilder<bool>(
      valueListenable: getIt<SettingsService>().showSuggestionSourceNotifier,
      builder: (context, show, _) {
        if (!show) return const SizedBox.shrink();
        return _chip(list);
      },
    );
  }
}
