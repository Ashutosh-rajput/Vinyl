import 'package:get_it/get_it.dart';
import 'package:vinyl/data/database/app_database.dart';
import 'package:vinyl/data/datasources/local/music_local_datasource.dart';
import 'package:vinyl/data/repositories/music_repository.dart';
import 'package:vinyl/services/audio_service.dart';
import 'package:vinyl/services/file_service.dart';
import 'package:vinyl/services/permission_service.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/library/library_bloc.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinyl/services/settings_service.dart';
import 'package:vinyl/services/download_service.dart';
import 'package:vinyl/services/lyrics_service.dart';
import 'package:vinyl/services/stream_cache_service.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/services/suggestion/jio_resolver.dart';
import 'package:vinyl/services/suggestion/providers/metabrainz_provider.dart';
import 'package:vinyl/services/suggestion/providers/youtube_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_service.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/user_taste_service.dart';
import 'package:vinyl/services/stream_favorites_service.dart';
import 'package:vinyl/services/stream_playlists_service.dart';

import 'package:vinyl/presentation/bloc/theme/theme_cubit.dart';

final getIt = GetIt.instance;

/// Name of the Radio flavour of the [SuggestionService] (it also adds the
/// credited artists' other songs).
const String radioSuggestionService = 'radio';

Future<void> getItSetup() async {
  // Database & Preferences
  final db = AppDatabase();
  getIt.registerSingleton<AppDatabase>(db);

  final prefs = await SharedPreferences.getInstance();
  getIt.registerSingleton<SharedPreferences>(prefs);

  // Data sources
  getIt.registerLazySingleton<MusicLocalDatasource>(
    () => MusicLocalDatasourceImpl(getIt<AppDatabase>()),
  );

  // Repositories
  getIt.registerLazySingleton<MusicRepository>(
    () => MusicRepositoryImpl(getIt<MusicLocalDatasource>()),
  );

  // Services
  getIt.registerLazySingleton<AudioPlayerService>(
    () => AudioPlayerService(),
    dispose: (service) => service.dispose(),
  );
  getIt.registerLazySingleton<FileService>(() => FileService());
  getIt.registerLazySingleton<PermissionService>(() => PermissionService());
  getIt.registerLazySingleton<SettingsService>(
    () => SettingsService(
      prefs: getIt<SharedPreferences>(),
      repository: getIt<MusicRepository>(),
      fileService: getIt<FileService>(),
    ),
  );
  getIt.registerLazySingleton<DownloadService>(
    () => DownloadService(
      repository: getIt<MusicRepository>(),
      settingsService: getIt<SettingsService>(),
    ),
  );
  getIt.registerLazySingleton<LyricsService>(
    () => LyricsService(getIt<AppDatabase>()),
  );
  getIt.registerLazySingleton<StreamCacheService>(
    () => StreamCacheService(),
  );
  getIt.registerLazySingleton<UserTasteService>(
    () => UserTasteService(),
  );

  // Suggestions: songs in, suggested songs out (MetaBrainz > YouTube > JioSaavn).
  // The two services share one MetaBrainz provider and one JioSaavn matcher, so
  // slow MetaBrainz answers and JioSaavn matches are fetched once and reused.
  final metaBrainz = MetaBrainzProvider();
  final jioResolver = JioResolver(youtubeLength: YoutubeProvider.videoLength);
  String streamLanguage() => getIt<SettingsService>().streamLanguage;
  double taste(JioSaavnItem item) =>
      getIt<UserTasteService>().likeness(item) * SuggestionService.maxTasteBoost;

  Set<SuggestionSource> enabledSources() {
    final s = getIt<SettingsService>();
    final set = <SuggestionSource>{
      if (s.suggestionMetaBrainzEnabled) SuggestionSource.metaBrainz,
      if (s.suggestionDeezerEnabled) SuggestionSource.deezer,
      if (s.suggestionYoutubeEnabled) SuggestionSource.youtube,
      if (s.suggestionJioSaavnEnabled) SuggestionSource.jioSaavn,
    };
    // If the user turned everything off, fall back to all on.
    return set;
  }

  getIt.registerLazySingleton<SuggestionService>(
    () => SuggestionService.standard(
      language: streamLanguage,
      tasteBoost: taste,
      resolver: jioResolver,
      metaBrainz: metaBrainz,
      enabledSources: enabledSources,
    ),
  );
  getIt.registerLazySingleton<SuggestionService>(
    () => SuggestionService.standard(
      includeArtistSongs: true,
      language: streamLanguage,
      tasteBoost: taste,
      resolver: jioResolver,
      metaBrainz: metaBrainz,
      enabledSources: enabledSources,
    ),
    instanceName: radioSuggestionService,
  );
  getIt.registerLazySingleton<StreamFavoritesService>(
    () => StreamFavoritesService(),
  );
  getIt.registerLazySingleton<StreamPlaylistsService>(
    () => StreamPlaylistsService(),
  );

  // BLoCs & Cubits
  getIt.registerLazySingleton<ThemeCubit>(
    () => ThemeCubit(getIt<SettingsService>()),
  );

  getIt.registerLazySingleton<PlayerBloc>(
    () => PlayerBloc(
      audioService: getIt<AudioPlayerService>(),
      repository: getIt<MusicRepository>(),
      settingsService: getIt<SettingsService>(),
      suggestionService: getIt<SuggestionService>(),
      radioSuggestionService: getIt<SuggestionService>(instanceName: radioSuggestionService),
    ),
    dispose: (bloc) => bloc.close(),
  );

  getIt.registerLazySingleton<LibraryBloc>(
    () => LibraryBloc(
      repository: getIt<MusicRepository>(),
      fileService: getIt<FileService>(),
      permissionService: getIt<PermissionService>(),
      settingsService: getIt<SettingsService>(),
    ),
    dispose: (bloc) => bloc.close(),
  );
}
