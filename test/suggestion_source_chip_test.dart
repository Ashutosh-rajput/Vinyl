import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinyl/data/repositories/music_repository.dart';
import 'package:vinyl/presentation/widgets/suggestion_source_chip.dart';
import 'package:vinyl/services/file_service.dart';
import 'package:vinyl/services/settings_service.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';

class _Repo implements MusicRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Files implements FileService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  Future<SettingsService> setUpSettings({bool on = false}) async {
    SharedPreferences.setMockInitialValues({'setting_dev_show_suggestion_source': on});
    final settings = SettingsService(prefs: await SharedPreferences.getInstance(), repository: _Repo(), fileService: _Files());
    if (getIt.isRegistered<SettingsService>()) getIt.unregister<SettingsService>();
    getIt.registerSingleton<SettingsService>(settings);
    return settings;
  }

  tearDown(() {
    if (getIt.isRegistered<SettingsService>()) getIt.unregister<SettingsService>();
  });

  Future<void> pump(WidgetTester tester, Set<SuggestionSource>? sources) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SuggestionSourceChip(sources: sources))),
      );

  testWidgets('off by default: nothing is shown', (tester) async {
    await setUpSettings();
    await pump(tester, {SuggestionSource.youtube});
    expect(find.text('YouTube'), findsNothing);
  });

  testWidgets('when the developer option is on, the service name is shown', (tester) async {
    await setUpSettings(on: true);
    await pump(tester, {SuggestionSource.deezer});
    expect(find.text('Deezer'), findsOneWidget);
  });

  testWidgets('a song several services agree on lists them, best source first', (tester) async {
    await setUpSettings(on: true);
    await pump(tester, {SuggestionSource.jioSaavn, SuggestionSource.metaBrainz, SuggestionSource.youtube});
    expect(find.text('MetaBrainz + YouTube + JioSaavn'), findsOneWidget);
  });

  testWidgets('switching the option follows live, on a row already on screen', (tester) async {
    final settings = await setUpSettings();
    await pump(tester, {SuggestionSource.metaBrainz});
    expect(find.text('MetaBrainz'), findsNothing);

    await tester.runAsync(() => settings.setShowSuggestionSource(true));
    await tester.pump();
    expect(find.text('MetaBrainz'), findsOneWidget);

    await tester.runAsync(() => settings.setShowSuggestionSource(false));
    await tester.pump();
    expect(find.text('MetaBrainz'), findsNothing);
  });

  testWidgets('a song with no known source shows nothing even when the option is on', (tester) async {
    await setUpSettings(on: true);
    await pump(tester, null);
    expect(find.byType(Text), findsNothing);
  });
}
