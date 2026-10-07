import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vinyl/core/di/injection_container.dart';
import 'package:vinyl/services/settings_service.dart';

class SupportBannerWidget extends StatefulWidget {
  final VoidCallback? onDismissed;
  final EdgeInsetsGeometry padding;

  const SupportBannerWidget({
    super.key,
    this.onDismissed,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  @override
  State<SupportBannerWidget> createState() => _SupportBannerWidgetState();
}

class _SupportBannerWidgetState extends State<SupportBannerWidget> {
  final ValueNotifier<bool> _visible = getIt<SettingsService>().supportBannerVisible;

  Future<void> _openGitHubRepo() async {
    getIt<SettingsService>().dismissSupportBanner();
    widget.onDismissed?.call();
    const urlString = 'https://github.com/Ashutosh-rajput/Vinyl';
    final url = Uri.parse(urlString);
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(url);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open $urlString: $e', style: GoogleFonts.outfit()),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _dismiss() {
    getIt<SettingsService>().dismissSupportBanner();
    widget.onDismissed?.call();
  }

  @override
  Widget build(BuildContext context) {
    // Follows the setting live: switching the banner on in Settings shows it
    // here at once, even though this screen was built earlier.
    return ValueListenableBuilder<bool>(
      valueListenable: _visible,
      builder: (context, visible, _) => visible ? _buildBanner(context) : const SizedBox.shrink(),
    );
  }

  Widget _buildBanner(BuildContext context) {

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: widget.padding,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? [
                    theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    theme.colorScheme.surface.withValues(alpha: 0.8),
                  ]
                : [
                    theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    theme.colorScheme.surface.withValues(alpha: 0.7),
                  ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.favorite_rounded,
                    color: theme.colorScheme.primary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Support This Project',
                            style: GoogleFonts.outfit(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'GitHub',
                              style: GoogleFonts.outfit(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Enjoying Vinyl? Support the project on GitHub to help keep it alive and growing!',
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          height: 1.35,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Dismiss banner',
                  onPressed: _dismiss,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.favorite_rounded, size: 16),
                  label: Text(
                    'Donate',
                    style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  onPressed: _openGitHubRepo,
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 14),
                  label: Text(
                    'GitHub',
                    style: GoogleFonts.outfit(fontSize: 12),
                  ),
                  onPressed: _openGitHubRepo,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
