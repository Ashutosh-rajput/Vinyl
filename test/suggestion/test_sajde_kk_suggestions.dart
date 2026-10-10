import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/services/suggestion/jio_resolver.dart';
import 'package:vinyl/services/suggestion/providers/deezer_provider.dart';
import 'package:vinyl/services/suggestion/providers/jiosaavn_provider.dart';
import 'package:vinyl/services/suggestion/providers/metabrainz_provider.dart';
import 'package:vinyl/services/suggestion/providers/youtube_provider.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';
import 'package:vinyl/services/suggestion/suggestion_service.dart';

void main() {
  test('test suggestion for Sajde by KK', () async {
    print('=== TESTING SUGGESTIONS FOR: Sajde by KK ===\n');

    const seed = SeedSong(
      title: 'Sajde',
      artist: 'KK',
    );

    final metaBrainz = MetaBrainzProvider(maxWait: const Duration(seconds: 35));
    final deezer = DeezerProvider();
    final youtube = YoutubeProvider();
    final resolver = JioResolver(youtubeLength: YoutubeProvider.videoLength);
    final jiosaavn = JioSaavnProvider(resolver: resolver);

    final suggestionService = SuggestionService(
      resolver: resolver,
      providers: [metaBrainz, deezer, youtube, jiosaavn],
    );

    print('SEED SONG: "${seed.title}" by "${seed.artist}"');
    print('----------------------------------------------------');

    // 1. MetaBrainz
    stdout.write('Testing MetaBrainz... ');
    final mbWatch = Stopwatch()..start();
    try {
      metaBrainz.warmUp(seed);
      final mbResults = await metaBrainz.suggest(seed, limit: 10);
      mbWatch.stop();
      print('Done in ${mbWatch.elapsedMilliseconds}ms (${mbResults.length} candidates)');
      for (var i = 0; i < mbResults.length; i++) {
        print('   [$i] ${mbResults[i].title} - ${mbResults[i].artist}');
      }
    } catch (e) {
      print('Error: $e');
    }

    // 2. Deezer
    stdout.write('\nTesting Deezer... ');
    final deezerWatch = Stopwatch()..start();
    try {
      final dzResults = await deezer.suggest(seed, limit: 10);
      deezerWatch.stop();
      print('Done in ${deezerWatch.elapsedMilliseconds}ms (${dzResults.length} candidates)');
      for (var i = 0; i < dzResults.length; i++) {
        print('   [$i] ${dzResults[i].title} - ${dzResults[i].artist}');
      }
    } catch (e) {
      print('Error: $e');
    }

    // 3. YouTube
    stdout.write('\nTesting YouTube... ');
    final ytWatch = Stopwatch()..start();
    try {
      final ytResults = await youtube.suggest(seed, limit: 10);
      ytWatch.stop();
      print('Done in ${ytWatch.elapsedMilliseconds}ms (${ytResults.length} candidates)');
      for (var i = 0; i < ytResults.length; i++) {
        print('   [$i] ${ytResults[i].title} - ${ytResults[i].artist}');
      }
    } catch (e) {
      print('Error: $e');
    }

    // 4. JioSaavn
    stdout.write('\nTesting JioSaavn... ');
    final jioWatch = Stopwatch()..start();
    try {
      final jioResults = await jiosaavn.suggest(seed, limit: 10);
      jioWatch.stop();
      print('Done in ${jioWatch.elapsedMilliseconds}ms (${jioResults.length} candidates)');
      for (var i = 0; i < jioResults.length; i++) {
        print('   [$i] ${jioResults[i].title} - ${jioResults[i].artist}');
      }
    } catch (e) {
      print('Error: $e');
    }

    // 5. Merged SuggestionService
    stdout.write('\nTesting Full SuggestionService (Ranked + Resolved)... ');
    final fullWatch = Stopwatch()..start();
    try {
      final fullResults = await suggestionService.suggest([seed], limit: 10);
      fullWatch.stop();
      print('Done in ${fullWatch.elapsedMilliseconds}ms (${fullResults.length} recommendations)');
      for (var i = 0; i < fullResults.length; i++) {
        final r = fullResults[i];
        print('   [$i] ${r.item.title} - ${r.item.subtitle} [Sources: ${r.sources.map((s) => s.label).join(', ')}, Score: ${r.score.toStringAsFixed(2)}]');
      }
    } catch (e) {
      print('Error: $e');
    }

    print('\n=== TEST COMPLETED ===');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
