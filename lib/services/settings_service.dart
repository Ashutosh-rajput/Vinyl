import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinyl/data/repositories/music_repository.dart';
import 'package:vinyl/services/file_service.dart';
import 'package:vinyl/services/stream_cache_service.dart';
import 'package:logger/logger.dart';

final _logger = Logger();

class StorageStats {
  final double musicSizeMb;
  final double cacheSizeMb;
  final double thumbnailsSizeMb;

  const StorageStats({
    required this.musicSizeMb,
    required this.cacheSizeMb,
    required this.thumbnailsSizeMb,
  });
}

class SettingsService {
  final SharedPreferences _prefs;
  final MusicRepository _repository;
  final FileService _fileService;

  SettingsService({
    required SharedPreferences prefs,
    required MusicRepository repository,
    required FileService fileService,
  })  : _prefs = prefs,
        _repository = repository,
        _fileService = fileService;

  // Keys
  static const _keyAutoPlayNext = 'setting_auto_play_next';
  static const _keyAutoplaySimilar = 'setting_autoplay_similar';
  static const _keyRepeatMode = 'setting_repeat_mode';
  static const _keyShuffleByDefault = 'setting_shuffle_default';
  static const _keyResumeLastSong = 'setting_resume_last';
  static const _keyLockScreenLyrics = 'setting_lock_screen_lyrics';
  static const _keyPlayerShowsLyrics = 'setting_player_shows_lyrics';
  static const _keyShowSuggestionSource = 'setting_dev_show_suggestion_source';
  static const _keyDefaultVolume = 'setting_default_volume';
  static const _keyDownloadQuality = 'setting_download_quality';
  static const _keyDownloadFormat = 'setting_download_format';
  static const _keyAutoDownloadPlaylistMetadata = 'setting_download_metadata';
  static const _keySkipAlreadyDownloaded = 'setting_skip_downloaded';
  static const _keyDownloadOnlyOnWifi = 'setting_download_wifi_only';
  static const _keyMaxSimultaneousDownloads = 'setting_max_simultaneous';
  static const _keyThemeMode = 'setting_theme_mode';
  static const _keyAccentColorIndex = 'setting_accent_color';
  static const _keyAmoledBlackMode = 'setting_amoled_black';
  static const _keyFontSize = 'setting_font_size';
  static const _keyAlbumArtSize = 'setting_art_size';
  static const _keyAutoScanMusicFolder = 'setting_auto_scan';
  static const _keyIgnoreShortAudio = 'setting_ignore_short';
  static const _keyShowHiddenFiles = 'setting_show_hidden';
  static const _keyIncludeOnlineResults = 'setting_online_results';
  static const _keyRetryFailedDownloads = 'setting_retry_failed';
  static const _keyDownloadTimeoutSeconds = 'setting_download_timeout';
  static const _keyShowPlaybackNotification = 'setting_show_notification';
  static const _keyLockScreenControls = 'setting_lock_controls';
  static const _keyDownloadNotifications = 'setting_download_notifications';
  static const _keyAutoAddSharedSongs = 'setting_auto_add_shared_songs';
  static const _keyLastPlayedSongId = 'setting_last_played_song_id';
  static const _keyLastPlayedPositionMs = 'setting_last_played_position_ms';

  static const _keyShowPlayerWaveform = 'setting_show_player_waveform';
  static const _keyStreamLanguage = 'setting_stream_language';
  static const _keyAutoDownloadStreamSongs = 'setting_auto_download_stream_songs';
  static const _keyCacheStreamSongs = 'setting_cache_stream_songs';
  static const _keyStreamCacheLimit = 'setting_stream_cache_limit';
  static const _keyAppLaunchCount = 'setting_app_launch_count';
  static const _keySupportBannerDismissed = 'setting_support_banner_dismissed';
  static const _keyHasSeenAppIntro = 'setting_has_seen_app_intro';

  static const Map<String, String> supportedStreamLanguages = {
    'hindi': 'Hindi',
    'punjabi': 'Punjabi',
    'english': 'English',
    'tamil': 'Tamil',
    'telugu': 'Telugu',
    'bhojpuri': 'Bhojpuri',
    'marathi': 'Marathi',
    'bengali': 'Bengali',
    'gujarati': 'Gujarati',
    'kannada': 'Kannada',
    'malayalam': 'Malayalam',
  };

  // Getters
  String get streamLanguage => _prefs.getString(_keyStreamLanguage) ?? 'hindi';
  bool get autoDownloadStreamSongs => _prefs.getBool(_keyAutoDownloadStreamSongs) ?? false;
  bool get cacheStreamSongs => _prefs.getBool(_keyCacheStreamSongs) ?? true;
  int get streamCacheLimit => _prefs.getInt(_keyStreamCacheLimit) ?? 50;
  int get appLaunchCount => _prefs.getInt(_keyAppLaunchCount) ?? 0;
  bool get supportBannerDismissed => _prefs.getBool(_keySupportBannerDismissed) ?? false;
  bool get isSupportBannerEnabled => !supportBannerDismissed;
  bool get shouldShowSupportBanner => !supportBannerDismissed;

  /// Whether the GitHub support banner is showing. Banners already on screen
  /// listen to this, so changing the setting takes effect at once.
  late final ValueNotifier<bool> supportBannerVisible = ValueNotifier<bool>(shouldShowSupportBanner);
  bool get hasSeenAppIntro => _prefs.getBool(_keyHasSeenAppIntro) ?? false;
  Future<void> setHasSeenAppIntro(bool value) => _prefs.setBool(_keyHasSeenAppIntro, value);
  bool get autoPlayNext => _prefs.getBool(_keyAutoPlayNext) ?? true;
  /// Keep playing similar songs once the user's own queue has finished.
  bool get autoplaySimilar => _prefs.getBool(_keyAutoplaySimilar) ?? true;
  String get repeatMode => _prefs.getString(_keyRepeatMode) ?? 'Off';
  bool get shuffleByDefault => _prefs.getBool(_keyShuffleByDefault) ?? false;
  bool get resumeLastSong => _prefs.getBool(_keyResumeLastSong) ?? true;

  /// Show the synced lyrics above the lock screen while a song plays.
  bool get lockScreenLyrics => _prefs.getBool(_keyLockScreenLyrics) ?? false;
  Future<void> setLockScreenLyrics(bool value) => _prefs.setBool(_keyLockScreenLyrics, value);

  /// Developer option: label every suggested song with the service it came from.
  bool get showSuggestionSource => _prefs.getBool(_keyShowSuggestionSource) ?? false;

  /// Labels already on screen listen to this, so the switch takes effect at once.
  late final ValueNotifier<bool> showSuggestionSourceNotifier = ValueNotifier<bool>(showSuggestionSource);
  Future<void> setShowSuggestionSource(bool value) async {
    await _prefs.setBool(_keyShowSuggestionSource, value);
    showSuggestionSourceNotifier.value = value;
  }

  /// The main player's lyrics switch. It is remembered, so lyrics stay on when
  /// the player is minimised or reopened, and the lock screen follows it.
  bool get playerShowsLyrics => _prefs.getBool(_keyPlayerShowsLyrics) ?? false;
  Future<void> setPlayerShowsLyrics(bool value) => _prefs.setBool(_keyPlayerShowsLyrics, value);
  double get defaultVolume => _prefs.getDouble(_keyDefaultVolume) ?? 0.8;
  String get downloadQuality =>
      _prefs.getString(_keyDownloadQuality) ?? 'Best';
  String get downloadFormat =>
      (_prefs.getString(_keyDownloadFormat) == 'WebM') ? 'WebM' : 'M4A';
  bool get autoDownloadPlaylistMetadata =>
      _prefs.getBool(_keyAutoDownloadPlaylistMetadata) ?? true;
  bool get skipAlreadyDownloaded =>
      _prefs.getBool(_keySkipAlreadyDownloaded) ?? true;
  bool get downloadOnlyOnWifi =>
      _prefs.getBool(_keyDownloadOnlyOnWifi) ?? false;
  int get maxSimultaneousDownloads =>
      _prefs.getInt(_keyMaxSimultaneousDownloads) ?? 2;
  String get themeMode => _prefs.getString(_keyThemeMode) ?? 'Dark';
  int get accentColorIndex => _prefs.getInt(_keyAccentColorIndex) ?? 0;
  bool get amoledBlackMode => _prefs.getBool(_keyAmoledBlackMode) ?? true;
  String get fontSize => _prefs.getString(_keyFontSize) ?? 'Medium';
  String get albumArtSize => _prefs.getString(_keyAlbumArtSize) ?? 'Medium';
  bool get autoScanMusicFolder =>
      _prefs.getBool(_keyAutoScanMusicFolder) ?? false;
  bool get showPlayerWaveform =>
      _prefs.getBool(_keyShowPlayerWaveform) ?? true;
  bool get ignoreShortAudio => _prefs.getBool(_keyIgnoreShortAudio) ?? true;
  bool get showHiddenFiles => _prefs.getBool(_keyShowHiddenFiles) ?? false;
  bool get includeOnlineResults => _prefs.getBool(_keyIncludeOnlineResults) ?? true;
  bool get retryFailedDownloads => _prefs.getBool(_keyRetryFailedDownloads) ?? true;
  int get downloadTimeoutSeconds => _prefs.getInt(_keyDownloadTimeoutSeconds) ?? 60;
  bool get showPlaybackNotification => _prefs.getBool(_keyShowPlaybackNotification) ?? true;
  bool get lockScreenControls => _prefs.getBool(_keyLockScreenControls) ?? true;
  bool get downloadNotifications => _prefs.getBool(_keyDownloadNotifications) ?? true;
  bool get autoAddSharedSongs => _prefs.getBool(_keyAutoAddSharedSongs) ?? true;
  int? get lastPlayedSongId => _prefs.getInt(_keyLastPlayedSongId);
  int get lastPlayedPositionMs => _prefs.getInt(_keyLastPlayedPositionMs) ?? 0;

  // Setters
  Future<void> setAutoPlayNext(bool value) => _prefs.setBool(_keyAutoPlayNext, value);
  Future<void> setAutoplaySimilar(bool value) => _prefs.setBool(_keyAutoplaySimilar, value);
  Future<void> setRepeatMode(String value) => _prefs.setString(_keyRepeatMode, value);
  Future<void> setShuffleByDefault(bool value) => _prefs.setBool(_keyShuffleByDefault, value);
  Future<void> setResumeLastSong(bool value) => _prefs.setBool(_keyResumeLastSong, value);
  Future<void> setDefaultVolume(double value) => _prefs.setDouble(_keyDefaultVolume, value);
  Future<void> setDownloadQuality(String value) => _prefs.setString(_keyDownloadQuality, value);
  Future<void> setDownloadFormat(String value) => _prefs.setString(_keyDownloadFormat, value);
  Future<void> setAutoDownloadPlaylistMetadata(bool value) => _prefs.setBool(_keyAutoDownloadPlaylistMetadata, value);
  Future<void> setSkipAlreadyDownloaded(bool value) => _prefs.setBool(_keySkipAlreadyDownloaded, value);
  Future<void> setDownloadOnlyOnWifi(bool value) => _prefs.setBool(_keyDownloadOnlyOnWifi, value);
  Future<void> setMaxSimultaneousDownloads(int value) => _prefs.setInt(_keyMaxSimultaneousDownloads, value);
  Future<void> setThemeMode(String value) => _prefs.setString(_keyThemeMode, value);
  Future<void> setAccentColorIndex(int value) => _prefs.setInt(_keyAccentColorIndex, value);
  Future<void> setAmoledBlackMode(bool value) => _prefs.setBool(_keyAmoledBlackMode, value);
  Future<void> setFontSize(String value) => _prefs.setString(_keyFontSize, value);
  Future<void> setAlbumArtSize(String value) => _prefs.setString(_keyAlbumArtSize, value);
  Future<void> setAutoScanMusicFolder(bool value) => _prefs.setBool(_keyAutoScanMusicFolder, value);
  Future<void> setShowPlayerWaveform(bool value) => _prefs.setBool(_keyShowPlayerWaveform, value);
  Future<void> setIgnoreShortAudio(bool value) => _prefs.setBool(_keyIgnoreShortAudio, value);
  Future<void> setShowHiddenFiles(bool value) => _prefs.setBool(_keyShowHiddenFiles, value);
  Future<void> setIncludeOnlineResults(bool value) => _prefs.setBool(_keyIncludeOnlineResults, value);
  Future<void> setRetryFailedDownloads(bool value) => _prefs.setBool(_keyRetryFailedDownloads, value);
  Future<void> setDownloadTimeoutSeconds(int value) => _prefs.setInt(_keyDownloadTimeoutSeconds, value);
  Future<void> setShowPlaybackNotification(bool value) => _prefs.setBool(_keyShowPlaybackNotification, value);
  Future<void> setLockScreenControls(bool value) => _prefs.setBool(_keyLockScreenControls, value);
  Future<void> setDownloadNotifications(bool value) => _prefs.setBool(_keyDownloadNotifications, value);
  Future<void> setAutoAddSharedSongs(bool value) => _prefs.setBool(_keyAutoAddSharedSongs, value);
  Future<void> setStreamLanguage(String value) => _prefs.setString(_keyStreamLanguage, value);
  Future<void> setAutoDownloadStreamSongs(bool value) => _prefs.setBool(_keyAutoDownloadStreamSongs, value);
  Future<void> setCacheStreamSongs(bool value) => _prefs.setBool(_keyCacheStreamSongs, value);
  Future<void> setStreamCacheLimit(int value) async {
    await _prefs.setInt(_keyStreamCacheLimit, value);
    StreamCacheService.instance.pruneToLimit(value);
  }
  Future<void> clearStreamCache() async {
    await StreamCacheService.instance.clearAllCache();
  }
  Future<int> incrementAppLaunchCount() async {
    final next = appLaunchCount + 1;
    await _prefs.setInt(_keyAppLaunchCount, next);
    return next;
  }
  Future<void> dismissSupportBanner() async {
    await _prefs.setBool(_keySupportBannerDismissed, true);
    supportBannerVisible.value = false;
  }
  Future<void> setSupportBannerEnabled(bool enabled) async {
    await _prefs.setBool(_keySupportBannerDismissed, !enabled);
    supportBannerVisible.value = enabled;
  }
  Future<void> setLastPlayedSongId(int? id) async {
    if (id != null) {
      await _prefs.setInt(_keyLastPlayedSongId, id);
    } else {
      await _prefs.remove(_keyLastPlayedSongId);
    }
  }
  Future<void> setLastPlayedPositionMs(int ms) => _prefs.setInt(_keyLastPlayedPositionMs, ms);

  // Real Storage & File Operations
  Future<StorageStats> calculateStorageSizes() async {
    double musicSize = 0.0;
    double cacheSize = 0.0;
    double thumbSize = 0.0;

    try {
      Directory? musicDir;
      if (Platform.isAndroid) {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          musicDir = Directory('${downloadsDir.path}/vinyl');
        }
      }
      musicDir ??= Directory('${(await getApplicationDocumentsDirectory()).path}/vinyl');
      if (await musicDir.exists()) {
        musicSize = await _getDirSizeMb(musicDir);
      }
    } catch (_) {}

    try {
      final cacheDir = await getApplicationCacheDirectory();
      if (await cacheDir.exists()) {
        cacheSize = await _getDirSizeMb(cacheDir);
      }
    } catch (_) {}

    try {
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        thumbSize = await _getDirSizeMb(tempDir);
      }
    } catch (_) {}

    return StorageStats(
      musicSizeMb: musicSize,
      cacheSizeMb: cacheSize,
      thumbnailsSizeMb: thumbSize,
    );
  }

  Future<double> _getDirSizeMb(Directory dir) async {
    int totalBytes = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          totalBytes += await entity.length();
        }
      }
    } catch (e) {
      _logger.w('Error calculating directory size for ${dir.path}: $e');
    }
    return totalBytes / (1024 * 1024);
  }

  Future<void> clearCache() async {
    try {
      await StreamCacheService.instance.clearAllCache();
      final cacheDir = await getApplicationCacheDirectory();
      if (await cacheDir.exists()) {
        await for (final entity in cacheDir.list(followLinks: false)) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (e) {
      _logger.e('Failed to clear cache: $e');
    }
  }

  Future<void> clearThumbnails() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        await for (final entity in tempDir.list(followLinks: false)) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (e) {
      _logger.e('Failed to clear thumbnails: $e');
    }
  }

  Future<int> rescanMusicLibrary() async {
    try {
      final scannedSongs = await _fileService.scanMusicLibrary();
      for (final song in scannedSongs) {
        await _repository.addSong(song);
      }
      return scannedSongs.length;
    } catch (e) {
      _logger.e('Error rescanning music library: $e');
      return 0;
    }
  }

  Future<int> clearMissingSongs() async {
    int removedCount = 0;
    try {
      final allSongs = await _repository.getAllSongs();
      for (final song in allSongs) {
        final file = File(song.filePath);
        if (!await file.exists()) {
          await _repository.deleteSong(song.id);
          removedCount++;
        }
      }
    } catch (e) {
      _logger.e('Error clearing missing songs: $e');
    }
    return removedCount;
  }
}
