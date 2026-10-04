import 'dart:convert';
import 'package:dio/dio.dart';

/// Suggestion service using MetaBrainz (MusicBrainz + ListenBrainz collaborative filtering).
class MetaBrainzSuggestionService {
  final Dio _dio = Dio(
    BaseOptions(
      headers: {
        'User-Agent': 'VinylMusicApp/1.0.0 ( contact@example.com )',
        'Accept': 'application/json',
      },
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  static const String defaultRecordingAlgo =
      'session_based_days_7500_session_300_contribution_5_threshold_15_limit_50_skip_30_top_n_listeners_1000';

  static const String defaultArtistAlgo =
      'session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30';

  /// 1. Resolve track & artist to MusicBrainz IDs (MBID)
  Future<Map<String, dynamic>?> searchMusicBrainz({
    required String trackName,
    String? artistName,
  }) async {
    final query = artistName != null && artistName.isNotEmpty
        ? 'recording:"$trackName" AND artist:"$artistName"'
        : 'recording:"$trackName"';

    final url =
        'https://musicbrainz.org/ws/2/recording/?query=${Uri.encodeComponent(query)}&fmt=json&limit=5';

    try {
      final resp = await _dio.get(url, options: Options(validateStatus: (s) => true));
      if (resp.statusCode == 200 && resp.data is Map) {
        final recs = resp.data['recordings'] as List<dynamic>? ?? [];
        if (recs.isNotEmpty) {
          final first = recs.first as Map<String, dynamic>;
          final recordingMbid = first['id']?.toString();
          final credits = first['artist-credit'] as List<dynamic>? ?? [];
          String? artistMbid;
          String? artistTitle;
          if (credits.isNotEmpty) {
            final artistObj = credits.first['artist'] as Map<String, dynamic>?;
            artistMbid = artistObj?['id']?.toString();
            artistTitle = artistObj?['name']?.toString();
          }

          return {
            'recordingMbid': recordingMbid,
            'recordingTitle': first['title']?.toString(),
            'artistMbid': artistMbid,
            'artistName': artistTitle,
          };
        }
      }
    } catch (e) {
      print('MusicBrainz search error: $e');
    }
    return null;
  }

  /// 2. Query ListenBrainz similar-recordings
  Future<List<Map<String, dynamic>>> getSimilarRecordings({
    required String recordingMbid,
  }) async {
    const url = 'https://labs.api.listenbrainz.org/similar-recordings/json';
    try {
      final resp = await _dio.post(
        url,
        data: [
          {
            'recording_mbids': [recordingMbid],
            'algorithm': defaultRecordingAlgo,
          }
        ],
        options: Options(validateStatus: (s) => true),
      );
      if (resp.statusCode == 200 && resp.data is List) {
        final list = resp.data as List;
        return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (e) {
      print('ListenBrainz recordings error: $e');
    }
    return [];
  }

  /// 3. Query ListenBrainz similar-artists (fallback)
  Future<List<Map<String, dynamic>>> getSimilarArtists({
    required String artistMbid,
  }) async {
    const url = 'https://labs.api.listenbrainz.org/similar-artists/json';
    try {
      final resp = await _dio.post(
        url,
        data: [
          {
            'artist_mbids': [artistMbid],
            'algorithm': defaultArtistAlgo,
          }
        ],
        options: Options(validateStatus: (s) => true),
      );
      if (resp.statusCode == 200 && resp.data is List) {
        final list = resp.data as List;
        return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (e) {
      print('ListenBrainz artists error: $e');
    }
    return [];
  }

  /// 4. Complete suggestion pipeline
  Future<void> findSuggestions({
    required String trackName,
    String? artistName,
  }) async {
    print('========================================================');
    print('MetaBrainz Suggestions for: "$trackName"${artistName != null ? " by $artistName" : ""}');
    print('========================================================');

    final info = await searchMusicBrainz(trackName: trackName, artistName: artistName);
    if (info == null) {
      print('❌ Track not found in MusicBrainz.');
      return;
    }

    final recMbid = info['recordingMbid'] as String?;
    final artistMbid = info['artistMbid'] as String?;
    print('✓ Found in MusicBrainz: "${info['recordingTitle']}" by ${info['artistName']}');

    bool found = false;
    if (recMbid != null) {
      final simRecs = await getSimilarRecordings(recordingMbid: recMbid);
      if (simRecs.isNotEmpty) {
        found = true;
        print('\n✓ Found ${simRecs.length} directly similar recordings:');
        for (var i = 0; i < simRecs.length; i++) {
          final r = simRecs[i];
          print('  ${i + 1}. "${r['recording_name']}" by ${r['artist_credit_name']} (Score: ${r['score']})');
        }
      }
    }

    if (!found && artistMbid != null) {
      print('\n[Fallback] Querying similar artists...');
      final simArtists = await getSimilarArtists(artistMbid: artistMbid);
      if (simArtists.isNotEmpty) {
        print('✓ Found ${simArtists.length} similar artists:');
        for (var i = 0; i < simArtists.take(8).length; i++) {
          final a = simArtists[i];
          print('  ${i + 1}. ${a['similar_artist_name']} (Score: ${a['score']})');
        }
      } else {
        print('⚠️ No similar artists found in dataset.');
      }
    }
  }
}

void main() async {
  final service = MetaBrainzSuggestionService();

  // Test with "Nadaaniyan" by Akshath
  await service.findSuggestions(trackName: 'Nadaaniyan', artistName: 'Akshath');
}

