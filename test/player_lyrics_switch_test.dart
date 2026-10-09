import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinyl/data/repositories/music_repository.dart';
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
  Future<SettingsService> settings() async => SettingsService(
        prefs: await SharedPreferences.getInstance(),
        repository: _Repo(),
        fileService: _Files(),
      );

  test('the main player starts with lyrics off', () async {
    SharedPreferences.setMockInitialValues({});
    expect((await settings()).playerShowsLyrics, isFalse);
  });

  test('the lyrics switch is remembered, so it survives minimising and restarts', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await settings();
    await first.setPlayerShowsLyrics(true);
    expect((await settings()).playerShowsLyrics, isTrue); // a new service reading the same storage
    await first.setPlayerShowsLyrics(false);
    expect((await settings()).playerShowsLyrics, isFalse);
  });
}
