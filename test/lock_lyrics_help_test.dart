import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/services/lock_lyrics_service.dart';

void main() {
  test('each phone maker gets the steps for its own settings', () {
    expect(LockLyricsService.permissionHelp('xiaomi'), contains('Show on Lock screen'));
    expect(LockLyricsService.permissionHelp('redmi'), contains('Autostart'));
    expect(LockLyricsService.permissionHelp('poco'), contains('Autostart'));
    expect(LockLyricsService.permissionHelp('vivo'), contains('Display on lock screen'));
    expect(LockLyricsService.permissionHelp('iqoo'), contains('Display on lock screen'));
    expect(LockLyricsService.permissionHelp('realme'), contains('auto-launch'));
    expect(LockLyricsService.permissionHelp('oneplus'), contains('Unrestricted'));
    expect(LockLyricsService.permissionHelp('huawei'), contains('App launch'));
  });

  test('any other phone (or an unknown one) still gets general advice', () {
    for (final maker in ['samsung', 'google', '']) {
      expect(LockLyricsService.permissionHelp(maker), contains('Unrestricted'));
    }
  });
}
