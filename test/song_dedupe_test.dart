import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/core/utils/song_dedupe.dart';

SongFingerprint fp(String id, String title, String artist, int secs) =>
    SongFingerprint.of(identity: id, title: title, artist: artist, durationSecs: secs);

void main() {
  group('normalizeSongTitle', () {
    test('drops source labels but keeps version markers', () {
      expect(normalizeSongTitle('Kesariya'), 'kesariya');
      expect(normalizeSongTitle('Kesariya (From "Brahmastra")'), 'kesariya');
      expect(normalizeSongTitle('Kesariya - From &quot;Brahmastra&quot;'), 'kesariya');
      expect(normalizeSongTitle('Kesariya (feat. Pritam)'), 'kesariya');
      expect(normalizeSongTitle('Tum Hi Ho [Lyric Video]'), 'tum hi ho');
      // Different recordings keep their marker.
      expect(normalizeSongTitle('Kesariya (Remix)'), isNot(normalizeSongTitle('Kesariya')));
      expect(normalizeSongTitle('Tum Hi Ho (Reprise)'), isNot(normalizeSongTitle('Tum Hi Ho')));
    });
  });

  group('SongFingerprint.isSameSongAs — the same song listed twice', () {
    test('same id is always the same song', () {
      expect(fp('a', 'X', 'Y', 100).isSameSongAs(fp('a', 'Totally Different', 'Z', 300)), isTrue);
    });

    test('one listing credits one artist, the other credits two', () {
      expect(
        fp('1', 'Kesariya', 'Arijit Singh', 268).isSameSongAs(fp('2', 'Kesariya', 'Arijit Singh, Pritam', 268)),
        isTrue,
      );
    });

    test('title carries an album label on one listing', () {
      expect(
        fp('1', 'Kesariya', 'Arijit Singh', 268)
            .isSameSongAs(fp('2', 'Kesariya (From "Brahmastra")', 'Arijit Singh', 267)),
        isTrue,
      );
    });

    test('credited to different names but the very same recording (same length)', () {
      expect(
        fp('1', 'Tum Hi Ho', 'Arijit Singh', 262).isSameSongAs(fp('2', 'Tum Hi Ho', 'Mithoon', 262)),
        isTrue,
      );
    });
  });

  group('SongFingerprint.isSameSongAs — different songs that share a title', () {
    test('another artist\'s song with the same name and a different length', () {
      expect(
        fp('1', 'Kesariya', 'Arijit Singh', 268).isSameSongAs(fp('2', 'Kesariya', 'Sid Sriram', 240)),
        isFalse,
      );
    });

    test('a remix, live take or extended cut by the same artist', () {
      expect(
        fp('1', 'Kesariya', 'Arijit Singh', 268).isSameSongAs(fp('2', 'Kesariya', 'Arijit Singh', 330)),
        isFalse,
      );
      expect(
        fp('1', 'Kesariya', 'Arijit Singh', 268).isSameSongAs(fp('2', 'Kesariya (Remix)', 'Arijit Singh', 268)),
        isFalse,
      );
    });

    test('a dub in another language: same composer, clearly different recording', () {
      expect(
        fp('1', 'Kesariya', 'Arijit Singh, Pritam', 268)
            .isSameSongAs(fp('2', 'Kesariya', 'Sid Sriram, Pritam', 255)),
        isFalse,
      );
    });

    test('different titles are never the same song', () {
      expect(
        fp('1', 'Kesariya', 'Arijit Singh', 268).isSameSongAs(fp('2', 'Kesariya Balam', 'Arijit Singh', 268)),
        isFalse,
      );
    });
  });
  group('artist credits from JioSaavn', () {
    test('the album glued on after " - " is not an artist', () {
      expect(parseArtistNames('Nadeem-Shravan - Kasoor'), ['nadeemshravan']);
      expect(parseArtistNames('Babul Supriyo, Alka Yagnik, Himesh Reshammiya - Vaada'),
          ['babul supriyo', 'alka yagnik', 'himesh reshammiya']);
      expect(parseArtistNames("Udit Narayan, Alka Yagnik - Kyon Ki - It's Fate"), ['udit narayan', 'alka yagnik']);
    });

    test('hyphenated names are not cut (only a SPACED hyphen separates the album)', () {
      expect(splitArtistCredit('Nadeem-Shravan'), ['Nadeem-Shravan']);
      expect(splitArtistCredit('Sachin-Jigar, Arijit Singh'), ['Sachin-Jigar', 'Arijit Singh']);
    });

    test('display names keep their punctuation', () {
      expect(splitArtistCredit('KR\$NA, Dhanda Nyoliwala - Boom Shaka'), ['KR\$NA', 'Dhanda Nyoliwala']);
    });

    test('stripAlbumSuffix and albumSuffixOf', () {
      expect(stripAlbumSuffix('Nadeem-Shravan - Kasoor'), 'Nadeem-Shravan');
      expect(albumSuffixOf('Nadeem-Shravan - Kasoor'), 'Kasoor');
      expect(albumSuffixOf('Nadeem-Shravan'), isNull);
      expect(albumSuffixOf("A - Kyon Ki - It's Fate"), "Kyon Ki - It's Fate");
    });
  });
}
