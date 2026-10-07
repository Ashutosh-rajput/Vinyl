import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinyl/data/repositories/music_repository.dart';
import 'package:vinyl/presentation/widgets/support_banner_widget.dart';
import 'package:vinyl/services/file_service.dart';
import 'package:vinyl/services/settings_service.dart';

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

  Future<SettingsService> setUpSettings([Map<String, Object> saved = const {}]) async {
    SharedPreferences.setMockInitialValues(saved);
    final settings = SettingsService(
      prefs: await SharedPreferences.getInstance(),
      repository: _Repo(),
      fileService: _Files(),
    );
    if (getIt.isRegistered<SettingsService>()) getIt.unregister<SettingsService>();
    getIt.registerSingleton<SettingsService>(settings);
    return settings;
  }

  tearDown(() {
    if (getIt.isRegistered<SettingsService>()) getIt.unregister<SettingsService>();
  });

  Future<void> pumpBanner(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: Scaffold(body: SupportBannerWidget())));

  testWidgets('a new install shows the banner (on by default)', (tester) async {
    await setUpSettings();
    await pumpBanner(tester);
    expect(find.text('Support This Project'), findsOneWidget);
  });

  testWidgets('dismissing hides it', (tester) async {
    await setUpSettings();
    await pumpBanner(tester);
    await tester.tap(find.byTooltip('Dismiss banner'));
    await tester.pump();
    expect(find.text('Support This Project'), findsNothing);
  });

  testWidgets('switching it on in Settings shows a banner that is already on screen', (tester) async {
    final settings = await setUpSettings({'setting_support_banner_dismissed': true});
    await pumpBanner(tester);
    expect(find.text('Support This Project'), findsNothing);

    await tester.runAsync(() => settings.setSupportBannerEnabled(true));
    await tester.pump();
    expect(find.text('Support This Project'), findsOneWidget);
  });

  testWidgets('switching it off in Settings hides it straight away', (tester) async {
    final settings = await setUpSettings();
    await pumpBanner(tester);
    await tester.runAsync(() => settings.setSupportBannerEnabled(false));
    await tester.pump();
    expect(find.text('Support This Project'), findsNothing);
  });
}
