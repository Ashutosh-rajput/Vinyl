import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vinyl/core/di/injection_container.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/presentation/screens/lock_lyrics_screen.dart';

/// Shows the lyrics full screen above the lock screen.
///
/// The Android side (MainActivity) tells this service when the screen locks and
/// unlocks. On lock, while a song is playing, a lyrics-only screen is opened
/// and the activity is allowed to stay above the keyguard; on unlock it closes.
/// Only that screen is ever visible while locked, never the rest of the app.
///
/// It works while the app is in front when the phone is locked: an app that is
/// already in the background cannot bring itself above the lock screen.
class LockLyricsService {
  LockLyricsService._();
  static final LockLyricsService instance = LockLyricsService._();

  static const MethodChannel _channel = MethodChannel('com.muskmelon.vinyl/lock_lyrics');

  GlobalKey<NavigatorState>? _navigatorKey;
  bool _enabled = false;

  /// Whether the lyrics switch of the main player is on (it is remembered, so
  /// it stays on while the player is minimised). The lock screen shows lyrics
  /// only then: a player showing the album art has not asked for them.
  bool lyricsOn = false;
  Route<void>? _route;

  /// Connects the service to the app's navigator and applies the saved setting.
  void attach(GlobalKey<NavigatorState> navigatorKey, {required bool enabled, bool lyricsOn = false}) {
    _navigatorKey = navigatorKey;
    this.lyricsOn = lyricsOn;
    _channel.setMethodCallHandler(_onCall);
    setEnabled(enabled);
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    if (!enabled) _close();
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } catch (_) {
      // Not on Android, or the channel is not there: nothing to switch.
    }
  }

  /// The phone maker in lower case ("xiaomi", "samsung", ...), or '' if unknown.
  /// Whether a maker's lock-screen permission is on cannot be read reliably, so
  /// the user is always told what to check for their brand.
  Future<String> manufacturer() async {
    try {
      return await _channel.invokeMethod<String>('manufacturer') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// What to switch on for the phone maker [maker], in plain words.
  static String permissionHelp(String maker) {
    bool is_(List<String> names) => names.any(maker.contains);
    if (is_(['xiaomi', 'redmi', 'poco'])) {
      return 'Xiaomi blocks apps from showing over the lock screen until you allow it.\n\n'
          'In the permissions page make sure "Show on Lock screen" is on. '
          'If lyrics still do not appear, also set Battery saver to "No restrictions" '
          'and turn on Autostart for this app.';
    }
    if (is_(['vivo', 'iqoo'])) {
      return 'Vivo can stop apps from showing over the lock screen.\n\n'
          'In the permissions page allow "Display on lock screen" and "Display pop-ups while running in background". '
          'Also allow background activity for this app in the battery settings.';
    }
    if (is_(['oppo', 'realme', 'oneplus'])) {
      return 'Your phone can stop apps from showing over the lock screen.\n\n'
          'In the app settings allow "Lock screen display" if you see it, turn on "Allow auto-launch", '
          'and set battery usage to "Allow background activity" or "Unrestricted".';
    }
    if (is_(['huawei', 'honor'])) {
      return 'Your phone can stop apps from showing over the lock screen.\n\n'
          'Open "App launch" for this app, turn off "Manage automatically" and allow all three switches '
          '(auto-launch, secondary launch, run in background).';
    }
    return 'Some phones stop apps from showing over the lock screen when the screen is off.\n\n'
        'If lyrics do not appear, set this app\'s battery usage to "Unrestricted" (or "Don\'t optimise") '
        'and allow any "show on lock screen" or "background" permission you find in its settings.';
  }

  /// Opens this app's permission page (Xiaomi's editor on Xiaomi phones).
  Future<void> openPermissionSettings() async {
    try {
      await _channel.invokeMethod<void>('openPermissions');
    } catch (_) {}
  }

  /// Asks the system to show the lock-screen unlock prompt.
  Future<void> requestUnlock() async {
    try {
      await _channel.invokeMethod<void>('unlock');
    } catch (_) {}
  }

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'locked':
        _open();
      case 'unlocked':
        _close();
    }
    return null;
  }

  /// The lock screen shows lyrics only when the setting is on, a song is
  /// playing (a paused or stopped player has nothing to follow), and the main
  /// player has its lyrics switched on.
  @visibleForTesting
  static bool shouldShow({
    required bool enabled,
    required bool lyricsOn,
    required bool playing,
    required bool alreadyShowing,
  }) =>
      enabled && lyricsOn && playing && !alreadyShowing;

  void _open() {
    final navigator = _navigatorKey?.currentState;
    if (navigator == null || !getIt.isRegistered<PlayerBloc>()) return;
    if (!shouldShow(
      enabled: _enabled,
      lyricsOn: lyricsOn,
      playing: getIt<PlayerBloc>().state is PlayerPlaying,
      alreadyShowing: _route != null,
    )) {
      return;
    }

    final route = PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (context, animation, secondaryAnimation) => const LockLyricsScreen(),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
    _route = route;
    navigator.push(route);
  }

  void _close() {
    final route = _route;
    if (route == null) return;
    _route = null;
    final navigator = _navigatorKey?.currentState;
    if (navigator != null && route.isActive) navigator.removeRoute(route);
  }
}
