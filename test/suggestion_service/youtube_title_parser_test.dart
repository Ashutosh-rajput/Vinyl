import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/core/utils/song_dedupe.dart';
import 'package:vinyl/services/suggestion/providers/youtube_provider.dart';

ParsedYoutubeSong? parse(String title, [String channel = 'Some Channel']) =>
    YoutubeProvider.parseYoutubeTitle(title, channel);

void main() {
  group('YouTube titles are cleaned into (song, artist)', () {
    test('"Artist - Song | Official Music Video" keeps both parts, artist first', () {
      final p = parse('KR\$NA - Joota Japani | Official Music Video', 'KRSNA')!;
      expect(p.title, 'Joota Japani');
      expect(p.artist, 'KR\$NA');
    });

    test('a title with credits after "|" uses the channel as the artist', () {
      final p = parse('Casa Tupka Anthemo | @Yo Yo Honey Singh  feat. Priyanshi | Full Video', 'Yo Yo Honey Singh')!;
      expect(p.title, 'Casa Tupka Anthemo');
      expect(p.artist, 'Yo Yo Honey Singh');
    });

    test('upload labels in brackets and hashtags are removed', () {
      final p = parse('Dhanda Nyoliwala - Russian Bandana (Music Video) | Deepesh Goyal | VYRL Haryanvi', 'VYRL Haryanvi')!;
      expect(p.title, 'Russian Bandana');
      expect(p.artist, 'Dhanda Nyoliwala');
      expect(parse('Tum Hi Ho (Lyrics) #arijitsingh #trending', 'T-Series')!.title, 'Tum Hi Ho');
    });

    test('a film label that is part of the title stays, so it can still match', () {
      final p = parse('Do Numbari (From “Mirzapur The Movie”)', 'Prime Music')!;
      expect(p.title, contains('Do Numbari'));
    });

    test('"A - B" keeps the other reading as an alternative', () {
      final p = parse('Paisa Hai Toh - Farzi |Sachin-Jigar, Vishal Dadlani| Shahid Kapoor', 'SonyMusicIndiaVEVO')!;
      expect(p.title, 'Farzi'); // first reading: "Artist - Title"
      expect(p.alternatives.any((a) => a.title == 'Paisa Hai Toh'), isTrue);
    });

    test('videos that are not songs are thrown away', () {
      expect(parse("KR\$NA, Dhanda Nyoliwala 'Boom Shaka' 1st Time Reaction!", 'T HUBS 22'), isNull);
      expect(parse('Best of Arijit Singh | Top 20 Songs Jukebox', 'T-Series'), isNull);
      expect(parse('Tum Hi Ho (Slowed + Reverb)', 'Lofi'), isNull);
      expect(parse('Kesariya 8D Audio', 'X'), isNull);
      expect(parse('Arijit Singh Interview', 'X'), isNull);
    });

    test('empty and channel-less titles are handled', () {
      expect(parse('', 'X'), isNull);
      expect(parse('Just A Title', ''), isNull);
      expect(parse('Artist - Song', '')!.title, 'Song');
    });

    test('HTML escapes from the YouTube API are decoded', () {
      expect(parse('Ed Sheeran &amp; Justin Bieber - I Don&#39;t Care', 'Ed')!.title, "I Don't Care");
    });

    test('three-part titles take the last part as the song', () {
      final p = parse('Hanumankind, Kalmi - Hanumankind – Big Dawgs | Prod. Kalmi (Official Music Video) | Def Jam India', 'Hanumankind')!;
      expect(p.title, 'Big Dawgs');
      expect(p.artist, 'Hanumankind, Kalmi');
    });

    test('a part that is only an upload label is dropped', () {
      final p = parse('Aaya Sher - Lyrical | The Paradise | Nani', 'Saregama Telugu')!;
      expect(p.title, 'Aaya Sher');
      expect(p.artist, 'Saregama Telugu');
    });

    test('"x" between artists is a separator', () {
      expect(parseArtistNames('KR\$NA x Dhanda Nyoliwala'), ['krna', 'dhanda nyoliwala']);
    });
  });
}
