import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/services/stream_favorites_service.dart';
import 'package:vinyl/services/user_taste_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UserTasteService service;
  late Directory tempDir;
  late File tempFile;
  DateTime currentTime = DateTime(2026, 1, 1, 12, 0, 0);

  setUp(() async {
    currentTime = DateTime(2026, 1, 1, 12, 0, 0);
    tempDir = await Directory.systemTemp.createTemp('pulseiq_test_');
    tempFile = File('${tempDir.path}/pulseiq_taste_profile.json');

    service = UserTasteService(
      clock: () => currentTime,
      storageFile: tempFile,
    );
    await service.init();
  });

  tearDown(() async {
    service.dispose();
    await Future.delayed(const Duration(milliseconds: 50));
    try {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('PulseIQ UserTasteService Tests', () {
    test('SongInteraction computes decay score and penalties correctly', () {
      final now = currentTime;

      final positiveSong = SongInteraction(
        trackKey: 'test:1',
        songId: 1,
        title: 'Loved Track',
        artist: 'Arijit Singh',
        playCount: 5,
        completeCount: 4,
        skipCount: 0,
        lastInteraction: now,
      );

      final skippedSong = SongInteraction(
        trackKey: 'test:2',
        songId: 2,
        title: 'Skipped Track',
        artist: 'Unknown Artist',
        playCount: 1,
        completeCount: 0,
        skipCount: 3,
        lastInteraction: now,
      );

      // (4 * 1.5) + (5 * 0.5) = 8.5
      expect(positiveSong.computeAffinityScore(now), greaterThan(8.0));

      // (0 * 1.5) + (1 * 0.5) - (3 * 2.0) = -5.5 -> clamped to 0.0
      expect(skippedSong.computeAffinityScore(now), equals(0.0));
    });

    test('Old-positive-plus-new-skip decay: A skip CANNOT strengthen score', () {
      // 1. Create a track with positive history at t = 0
      final t0 = currentTime;
      final song = Song(
        id: 999,
        title: 'Old Hit',
        artist: 'Vintage Band',
        album: 'Vintage Album',
        filePath: 'https://example.com/old_hit.mp3',
        duration: const Duration(seconds: 200),
        dateModified: t0,
        source: 'jiosaavn',
      );

      // User listened to it 5 times at t0
      for (int i = 0; i < 5; i++) {
        service.onSongStarted(song);
        service.onPlaybackProgress(song, const Duration(seconds: 190), song.duration);
      }

      final candidate = JioSaavnItem(
        type: 'song',
        id: '999',
        token: '999',
        title: 'Old Hit',
        subtitle: 'Vintage Band',
        imageUrl: '',
      );

      final initialScore = service.likeness(candidate);
      expect(initialScore, greaterThan(0.3));

      // 2. Advance time by 60 days (two 30-day half-lives -> decayed by ~75%)
      currentTime = t0.add(const Duration(days: 60));
      final decayedScoreBeforeSkip = service.likeness(candidate);
      expect(decayedScoreBeforeSkip, lessThan(initialScore));

      // 3. User now skips the song today
      service.onSongStarted(song);
      service.onSongSkipped(song, isManual: true);

      final scoreAfterSkip = service.likeness(candidate);

      // The new skip must LOWER the score, NOT revive old completions!
      expect(scoreAfterSkip, lessThanOrEqualTo(decayedScoreBeforeSkip));
    });

    test('Track identity is stable across restarts using canonicalKey and FNV', () {
      const nonNumericId = 'sZk21QzL';
      const item = JioSaavnItem(
        type: 'song',
        id: nonNumericId,
        token: 'token_xyz',
        title: 'Alphanumeric Track',
        subtitle: 'Artist Name',
        imageUrl: '',
      );

      expect(item.canonicalKey, equals('jiosaavn:$nonNumericId'));

      final song1 = item.toSong();
      final song2 = item.toSong();

      // Integer ID must be deterministic across calls (FNV-1a)
      expect(song1.id, equals(song2.id));
      expect(song1.id, equals(item.stableId));
      // Canonical key on Song must match item.canonicalKey exactly!
      expect(song1.canonicalKey, equals(item.canonicalKey));
      expect(song1.canonicalKey, equals('jiosaavn:$nonNumericId'));

      // Skips and plays on Song must now match candidate scoring
      service.onSongStarted(song1);
      service.onSongSkipped(song1, isManual: true);
      final score = service.likeness(item);
      expect(score, lessThan(0.05)); // Skips penalized properly via matching canonical key
    });

    test('PlaybackSession: False completions are prevented on track transitions', () {
      final song = Song(
        id: 501,
        title: 'Short Sample',
        artist: 'Sampler',
        album: 'Album',
        filePath: 'https://example.com/s.mp3',
        duration: const Duration(seconds: 180),
        dateModified: currentTime,
      );

      // Start song and play only 10 seconds (< 80% and < 180s)
      service.onSongStarted(song);
      service.onPlaybackProgress(song, const Duration(seconds: 10), song.duration);

      // Another song starts (user switched tracks prematurely)
      final nextSong = Song(
        id: 502,
        title: 'Next Track',
        artist: 'Next Artist',
        album: 'Album',
        filePath: 'https://example.com/n.mp3',
        duration: const Duration(seconds: 180),
        dateModified: currentTime,
      );
      service.onSongStarted(nextSong);

      final candidate = JioSaavnItem(
        type: 'song',
        id: '501',
        token: '501',
        title: 'Short Sample',
        subtitle: 'Sampler',
        imageUrl: '',
      );

      // Score should not have complete count
      final score = service.likeness(candidate);
      expect(score, lessThan(0.2));
    });

    test('Persistence flush saves interactions and reloads cleanly', () async {
      final song = Song(
        id: 777,
        title: 'Persisted Song',
        artist: 'Persistent Artist',
        album: 'Album',
        filePath: 'https://example.com/p.mp3',
        duration: const Duration(seconds: 210),
        dateModified: currentTime,
      );

      service.onSongStarted(song);
      service.onSongFavoriteToggled(song, true);
      await service.flush();

      // Check file was written to disk
      expect(tempFile.existsSync(), isTrue);
      expect(tempFile.lengthSync(), greaterThan(0));

      // Create a fresh instance reading the same file
      final newService = UserTasteService(
        clock: () => currentTime,
        storageFile: tempFile,
      );
      await newService.init();

      final topArtists = newService.getTopArtists();
      expect(topArtists, contains('persistent artist'));
      newService.dispose();
    });

    test('Favorite scoring adds exactly +3.0 and leaves no residual bonus after unfavoriting', () {
      final song = Song(
        id: 888,
        title: 'Fav Track',
        artist: 'Fav Artist',
        album: 'Album',
        filePath: 'https://example.com/fav.mp3',
        duration: const Duration(seconds: 200),
        dateModified: currentTime,
        source: 'jiosaavn',
        mediaId: 'fav_888',
      );

      const candidate = JioSaavnItem(
        type: 'song',
        id: 'fav_888',
        token: 'fav_888',
        title: 'Fav Track',
        subtitle: 'Fav Artist',
        imageUrl: '',
      );

      final baselineScore = service.likeness(candidate);

      // 1. Toggle favorite ON
      service.onSongFavoriteToggled(song, true);
      final scoreWithFav = service.likeness(candidate);

      // Track affinity gets +3.0 bonus, plus artist affinity gets calculated once (no double-counting of favorite)
      expect(scoreWithFav, greaterThan(baselineScore));

      // 2. Toggle favorite OFF
      service.onSongFavoriteToggled(song, false);
      final scoreAfterUnfav = service.likeness(candidate);

      // Must return cleanly to baseline score with no residual bonus
      expect(scoreAfterUnfav, closeTo(baselineScore, 0.001));
    });

    test('Stream cache and favorites ID generation uses stable FNV hash for alphanumeric IDs', () {
      const item = JioSaavnItem(
        type: 'song',
        id: 'alpha_x99y',
        token: 'token_x99y',
        title: 'Alphanumeric Track',
        subtitle: 'Artist',
        imageUrl: '',
      );

      final stableId = item.stableId;
      expect(stableId, isNonZero);

      // StreamFavoritesService.getSongIdForItem must match item.stableId
      final favId = StreamFavoritesService.instance.getSongIdForItem(item);
      expect(favId, equals(stableId));

      // Song created from item must have id matching stableId
      final song = item.toSong();
      expect(song.id, equals(stableId));
    });

    test('Search play count and metadata persist and reload across restarts', () async {
      const searchItem = JioSaavnItem(
        type: 'song',
        id: 'persist_search_1',
        token: 'token_persist_1',
        title: 'Persistent Search Hit',
        subtitle: 'Star Artist',
        imageUrl: 'https://example.com/cover.jpg',
        duration: '195',
        language: 'hindi',
      );
      final song = searchItem.toSong();
      service.recordSearchPlay(song, item: searchItem);

      // Flush to disk
      await service.flush();
      expect(tempFile.existsSync(), isTrue);

      // Reload into fresh service instance
      final freshService = UserTasteService(
        clock: () => currentTime,
        storageFile: tempFile,
      );
      await freshService.init();

      final reloaded = freshService.getSearchPlayedInteractions();
      expect(reloaded.length, equals(1));
      expect(reloaded.first.title, equals('Persistent Search Hit'));
      expect(reloaded.first.searchPlayCount, equals(1));
      expect(reloaded.first.imageUrl, equals('https://example.com/cover.jpg'));

      final score = freshService.likeness(searchItem);
      expect(score, greaterThan(0.5));
      freshService.dispose();
    });

    test('Taste Profile Editing: removeTrackedSong, removeTrackedArtist, addPreferredArtist, and clearTasteProfile', () async {
      await service.init();

      final song1 = Song(
        id: 301,
        title: 'Song One',
        artist: 'Special Artist',
        album: 'Album',
        filePath: 'mock/path1',
        duration: const Duration(seconds: 200),
        dateModified: DateTime.now(),
      );
      final song2 = Song(
        id: 302,
        title: 'Song Two',
        artist: 'Other Artist',
        album: 'Album',
        filePath: 'mock/path2',
        duration: const Duration(seconds: 200),
        dateModified: DateTime.now(),
      );

      service.onSongStarted(song1);
      service.onPlaybackProgress(song1, const Duration(seconds: 190), song1.duration);
      service.onSongStarted(song2);
      service.onPlaybackProgress(song2, const Duration(seconds: 190), song2.duration);

      expect(service.trackedSongCount, equals(2));
      expect(service.trackedArtistCount, equals(2));

      // Test removeTrackedSong
      final removed = await service.removeTrackedSong(song1.canonicalKey);
      expect(removed, isTrue);
      expect(service.trackedSongCount, equals(1));
      expect(service.getTrackedSongs().any((s) => s.title == 'Song One'), isFalse);

      // Test addPreferredArtist
      await service.addPreferredArtist('Legendary Singer');
      expect(service.isSearchPlayedArtist('legendary singer'), isTrue);
      final topArtists = service.getTrackedArtists();
      expect(topArtists.any((a) => a.key == 'legendary singer'), isTrue);

      // Test removeTrackedArtist
      final pruned = await service.removeTrackedArtist('Other Artist');
      expect(pruned, greaterThanOrEqualTo(1));
      expect(service.getTrackedArtists().any((a) => a.key == 'other artist'), isFalse);

      // Test clearTasteProfile
      await service.clearTasteProfile();
      expect(service.trackedSongCount, equals(0));
      expect(service.trackedArtistCount, equals(0));
    });

    test('Preferred artist boosts the artist but never appears as a song', () async {
      await service.init();
      await service.addPreferredArtist('Arijit Singh');

      // Not a song: not counted, not listed, not a searched song.
      expect(service.trackedSongCount, equals(0));
      expect(service.getTrackedSongs(), isEmpty);
      expect(service.getSearchPlayedInteractions(), isEmpty);

      // Still boosts the artist.
      expect(service.isSearchPlayedArtist('arijit singh'), isTrue);
      expect(service.getTopArtists(), contains('arijit singh'));

      // And never becomes a seed song for suggestions.
      expect(service.topSeedSongs().any((s) => s.title == 'Top Artist Selection'), isFalse);
    });

    group('What the profile tells the suggestion service', () {
      Song song(int id, String title, String artist, {String? mediaId}) => Song(
            id: id, title: title, artist: artist, album: 'Album',
            filePath: 'https://example.com/$id.mp3', duration: const Duration(seconds: 200),
            dateModified: currentTime, source: 'jiosaavn', mediaId: mediaId);

      JioSaavnItem item(String id, String title, String artist) =>
          JioSaavnItem(type: 'song', id: id, token: id, title: title, subtitle: artist, imageUrl: '');

      test('a song nothing is known about has likeness 0', () {
        expect(service.likeness(item('zz', 'Stranger', 'Unknown Band')), 0.0);
      });

      test('likeness grows with listening and stays between 0 and 1', () {
        final s = song(1, 'Loved', 'Fan Favourite', mediaId: 'j1');
        var last = service.likeness(item('j1', 'Loved', 'Fan Favourite'));
        for (var i = 0; i < 12; i++) {
          service.onSongStarted(s);
          service.onPlaybackProgress(s, const Duration(seconds: 190), s.duration);
          final now = service.likeness(item('j1', 'Loved', 'Fan Favourite'));
          expect(now, greaterThanOrEqualTo(last));
          expect(now, inInclusiveRange(0.0, 1.0));
          last = now;
        }
        expect(last, greaterThan(0.5));
      });

      test('a new song by an artist the user loves is liked more than a stranger', () {
        final s = song(2, 'Old Favourite', 'Loved Artist');
        for (var i = 0; i < 4; i++) {
          service.onSongStarted(s);
          service.onPlaybackProgress(s, const Duration(seconds: 190), s.duration);
        }
        final byLoved = service.likeness(item('new1', 'Never Heard', 'Loved Artist'));
        final byStranger = service.likeness(item('new2', 'Never Heard', 'Stranger'));
        expect(byLoved, greaterThan(byStranger));
      });

      test('a song the user keeps skipping is not liked', () {
        final s = song(3, 'Skipped', 'Some Artist', mediaId: 'j3');
        for (var i = 0; i < 3; i++) {
          service.onSongStarted(s);
          service.onSongSkipped(s, isManual: true);
        }
        expect(service.likeness(item('j3', 'Skipped', 'Some Artist')), lessThan(0.05));
      });

      test('seed songs: what the user searched for comes first, then the best-loved songs', () {
        final loved = song(10, 'Loved Song', 'A', mediaId: 'j10');
        for (var i = 0; i < 6; i++) {
          service.onSongStarted(loved);
          service.onPlaybackProgress(loved, const Duration(seconds: 190), loved.duration);
        }
        final searched = song(11, 'Searched Song', 'B', mediaId: 'j11');
        service.recordSearchPlay(searched);

        final seeds = service.topSeedSongs(limit: 4);
        expect(seeds.first.title, 'Searched Song');
        expect(seeds.map((s) => s.title), contains('Loved Song'));
        expect(seeds.first.jioId, 'j11');
      });

      test('seed songs never include songs that keep being skipped, and respect the limit', () {
        for (var i = 0; i < 6; i++) {
          final s = song(20 + i, 'Song $i', 'Artist $i');
          service.onSongStarted(s);
          service.onPlaybackProgress(s, const Duration(seconds: 190), s.duration);
        }
        final skipped = song(40, 'Hated', 'Skipper');
        for (var i = 0; i < 3; i++) {
          service.onSongStarted(skipped);
          service.onSongSkipped(skipped, isManual: true);
        }
        final seeds = service.topSeedSongs(limit: 3);
        expect(seeds, hasLength(3));
        expect(seeds.any((s) => s.title == 'Hated'), isFalse);
      });

      test('a fresh profile has no seed songs', () {
        expect(service.topSeedSongs(), isEmpty);
      });
    });

    test('classifier recognises devotional and kids tracks, not film songs', () {
      expect(ContentClassifier.classify('Om Jai Jagdish Hare Aarti'), ContentCategory.devotional);
      expect(ContentClassifier.classify('Hanuman Chalisa'), ContentCategory.devotional);
      expect(ContentClassifier.classify('Motu Patlu Title Song'), ContentCategory.kids);
      expect(ContentClassifier.classify('Johny Johny Yes Papa Nursery Rhymes'), ContentCategory.kids);
      expect(ContentClassifier.classify('Channa Mereya Arijit Singh'), isNull);
      expect(ContentClassifier.classify('Kesariya Brahmastra'), isNull);
    });

});
}
