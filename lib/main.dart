import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:audio_session/audio_session.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:vinyl/core/di/injection_container.dart';
import 'package:vinyl/core/theme/app_theme.dart';
import 'package:vinyl/presentation/bloc/library/library_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/theme/theme_cubit.dart';
import 'package:vinyl/presentation/screens/splash_screen.dart';
import 'package:vinyl/services/download_background_service.dart';
import 'package:vinyl/services/download_notification_service.dart';
import 'package:vinyl/services/download_service.dart';
import 'package:vinyl/services/stream_cache_service.dart';
import 'package:vinyl/services/user_taste_service.dart';
import 'package:vinyl/services/stream_favorites_service.dart';
import 'package:vinyl/services/stream_playlists_service.dart';
import 'package:vinyl/services/lock_lyrics_service.dart';
import 'package:vinyl/services/settings_service.dart';

import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:google_fonts/google_fonts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  // Minimal setup needed to enqueue a download: DI + notifications + the
  // keep-alive shield. Checked before any audio/session setup so a
  // share-only cold start never touches playback machinery it doesn't need.
  await getItSetup();
  try {
    await DownloadNotificationService().init();
  } catch (e) {
    debugPrint('DownloadNotificationService init error: $e');
  }
  try {
    await initializeDownloadBackgroundService();
  } catch (e) {
    debugPrint('Download keep-alive service init error: $e');
  }
  try {
    await getIt<StreamCacheService>().init();
  } catch (e) {
    debugPrint('StreamCacheService init error: $e');
  }
  try {
    await getIt<UserTasteService>().init();
  } catch (e) {
    debugPrint('UserTasteService init error: $e');
  }
  try {
    await getIt<StreamFavoritesService>().init();
  } catch (e) {
    debugPrint('StreamFavoritesService init error: $e');
  }
  try {
    await getIt<StreamPlaylistsService>().init();
  } catch (e) {
    debugPrint('StreamPlaylistsService init error: $e');
  }
  try {
    await getIt<SettingsService>().incrementAppLaunchCount();
  } catch (e) {
    debugPrint('incrementAppLaunchCount error: $e');
  }

  final initialMedia = await ReceiveSharingIntent.instance.getInitialMedia();
  final sharedUrl = initialMedia.isNotEmpty ? initialMedia.first.path.trim() : '';

  if (sharedUrl.isNotEmpty) {
    // Launched purely to receive a shared link: never show the app UI.
    // Enqueue the download in the background, toast over whatever app the
    // user is still looking at, and hand control straight back to it.
    await _handleSharedUrl(sharedUrl);
    runApp(const SizedBox.shrink());
    SystemNavigator.pop();
    return;
  }

  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.muskmelon.vinyl.playback',
      androidNotificationChannelName: 'Audio Playback',
      androidNotificationChannelDescription:
          'Controls and track details for music currently playing',
      androidNotificationOngoing: false,
      androidNotificationIcon: 'drawable/ic_stat_music',
    );
    debugPrint("Background initialized");
  } catch (e) {
    debugPrint('JustAudioBackground init error: $e');
  }

  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (e) {
    debugPrint('Audio session configuration error: $e');
  }

  try {
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  } catch (e) {
    debugPrint('Notification permission error: $e');
  }

  runApp(const PixelPlayerApp());
}

/// Enqueues a shared link for background download and lets the user know via
/// a native toast — a real overlay that floats above whatever app currently
/// has the screen, unlike an in-app SnackBar which requires our UI to be
/// visible.
Future<void> _handleSharedUrl(String text) async {
  final url = text.trim();
  if (url.isEmpty) return;

  getIt<DownloadService>().enqueueDownload(url: url, fromShare: true);

  try {
    await Fluttertoast.showToast(msg: 'Song download started…');
  } catch (e) {
    debugPrint('Failed to show download-started toast: $e');
  }
}

class PixelPlayerApp extends StatefulWidget {
  const PixelPlayerApp({super.key});

  @override
  State<PixelPlayerApp> createState() => _PixelPlayerAppState();
}

class _PixelPlayerAppState extends State<PixelPlayerApp> with WidgetsBindingObserver {
  StreamSubscription? _intentDataStreamSubscription;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initShareIntentListener();
    LockLyricsService.instance.attach(
      _navigatorKey,
      enabled: getIt.isRegistered<SettingsService>() && getIt<SettingsService>().lockScreenLyrics,
      lyricsOn: getIt.isRegistered<SettingsService>() && getIt<SettingsService>().playerShowsLyrics,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      if (getIt.isRegistered<UserTasteService>()) {
        getIt<UserTasteService>().flush();
      }
    }
    // Returning to the app is the usual moment Wi-Fi is back; start any
    // downloads that were paused waiting for it.
    if (state == AppLifecycleState.resumed && getIt.isRegistered<DownloadService>()) {
      getIt<DownloadService>().resumePausedDownloads();
    }
    // Other apps (Instagram, calls) may have taken audio focus while we were
    // in the background; make the play state and the sound match again.
    if (state == AppLifecycleState.resumed && getIt.isRegistered<PlayerBloc>()) {
      getIt<PlayerBloc>().add(const ResyncPlaybackEvent());
    }
    debugPrint('App lifecycle state changed: $state');
  }

  void _initShareIntentListener() {
    // Cold-start shares are already handled and consumed in main() before
    // this widget is ever built. This only needs to cover shares arriving
    // while the app is already alive in memory.
    _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      if (value.isNotEmpty) {
        _handleSharedUrl(value.first.path);
      }
    }, onError: (err) {
      debugPrint("getIntentDataStream error: $err");
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _intentDataStreamSubscription?.cancel();
    if (getIt.isRegistered<UserTasteService>()) {
      getIt<UserTasteService>().dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<ThemeCubit>(create: (_) => getIt<ThemeCubit>()),
        BlocProvider<PlayerBloc>(create: (_) => getIt<PlayerBloc>()),
        BlocProvider<LibraryBloc>(create: (_) => getIt<LibraryBloc>()),
      ],
      child: BlocBuilder<ThemeCubit, ThemeSettingsState>(
        builder: (context, themeState) {
          ThemeMode mode = ThemeMode.system;
          if (themeState.themeMode == 'Light') mode = ThemeMode.light;
          if (themeState.themeMode == 'Dark') mode = ThemeMode.dark;

          final light = AppTheme.buildTheme(
            brightness: Brightness.light,
            accentIndex: themeState.accentColorIndex,
            isAmoled: false,
          );

          final dark = AppTheme.buildTheme(
            brightness: Brightness.dark,
            accentIndex: themeState.accentColorIndex,
            isAmoled: themeState.amoledBlackMode,
          );

          return MaterialApp(
            navigatorKey: _navigatorKey,
            title: 'Vinyl',
            debugShowCheckedModeBanner: false,
            theme: light,
            darkTheme: dark,
            themeMode: mode,
            builder: (context, child) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(themeState.fontScale),
                ),
                child: child!,
              );
            },
            home: const SplashScreen(),
          );
        },
      ),
    );
  }
}
