import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/core/utils/jiosaavn_decoder.dart';

void main() {
  group('JioSaavn text is cleaned when it is read', () {
    test('HTML escapes in the title, artists and album become real characters', () {
      final item = JioSaavnDecoder.parseItem({
        'type': 'song',
        'id': 'abc',
        'title': 'Tera Mera Rishta (From &quot;Awarapan 2&quot;)',
        'subtitle': 'Mithoon &amp; Pritam',
        'more_info': {'album': 'Rock &#039;n&#039; Roll', 'duration': '200', 'artistMap': {}},
      });
      expect(item.title, 'Tera Mera Rishta (From "Awarapan 2")');
      expect(item.subtitle, 'Mithoon & Pritam');
      expect(item.album, "Rock 'n' Roll");
    });

    test('an already-escaped ampersand is not decoded twice', () {
      expect(JioSaavnDecoder.decodeHtmlEntities('A &amp;quot; B'), 'A &quot; B');
    });

    test('plain text is left alone', () {
      expect(JioSaavnDecoder.decodeHtmlEntities('Kesariya'), 'Kesariya');
    });

    test('album and explicit flag are read for songs', () {
      final item = JioSaavnDecoder.parseItem({
        'type': 'song',
        'id': 'abc',
        'title': 'Boom Shaka',
        'subtitle': '',
        'isExplicit': true,
        'more_info': {'album': 'Boom Shaka', 'duration': '218'},
      });
      expect(item.album, 'Boom Shaka');
      expect(item.explicit, isTrue);
    });
  });
  group('stream count', () {
    test('play_count is read as a number, and is 0 when missing', () {
      final withCount = JioSaavnDecoder.parseItem({'type': 'song', 'id': 'a', 'title': 'T', 'subtitle': 'S', 'play_count': '66204055', 'more_info': {}});
      final without = JioSaavnDecoder.parseItem({'type': 'song', 'id': 'b', 'title': 'T', 'subtitle': 'S', 'more_info': {}});
      expect(withCount.playCount, 66204055);
      expect(without.playCount, 0);
    });
  });
}
