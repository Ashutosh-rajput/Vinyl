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
  group('lyrics appear on the lock screen only when the main player shows them', () {
    bool show({bool enabled = true, bool lyrics = true, bool playing = true, bool showing = false}) =>
        LockLyricsService.shouldShow(
          enabled: enabled,
          lyricsShownInPlayer: lyrics,
          playing: playing,
          alreadyShowing: showing,
        );

    test('setting on, song playing, lyrics on in the player: shown', () => expect(show(), isTrue));
    test('lyrics off in the main player (album art showing): not shown', () => expect(show(lyrics: false), isFalse));
    test('setting off: not shown', () => expect(show(enabled: false), isFalse));
    test('nothing playing: not shown', () => expect(show(playing: false), isFalse));
    test('already on screen: not opened twice', () => expect(show(showing: true), isFalse));
  });
}
