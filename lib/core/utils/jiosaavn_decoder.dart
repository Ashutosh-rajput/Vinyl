import 'dart:convert';
import 'package:dart_des/dart_des.dart';
import 'package:dio/dio.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';

class JioSaavnDecoder {
  // Key documented for JioSaavn DES-ECB media decryption
  static const String _desKey = '38346591';
  static const String apiBase = 'https://jiosaavn-api-eight-beryl.vercel.app';

  /// Decrypts the `encrypted_media_url` into a playable/downloadable HTTPS MP4/AAC stream URL.
  static String? decryptMediaUrl(String? encryptedUrl, {bool highQuality = true}) {
    if (encryptedUrl == null || encryptedUrl.trim().isEmpty) return null;
    try {
      final key = utf8.encode(_desKey);
      final des = DES(
        key: key,
        mode: DESMode.ECB,
        paddingType: DESPaddingType.PKCS7,
      );
      final decryptedBytes = des.decrypt(base64.decode(encryptedUrl.trim()));
      var decUrl = utf8.decode(decryptedBytes).trim();
      if (!decUrl.startsWith('http')) return null;
      if (decUrl.startsWith('http://')) {
        decUrl = decUrl.replaceFirst('http://', 'https://');
      }

      if (highQuality) {
        decUrl = decUrl.replaceAll(RegExp(r'_96\.mp4|_160\.mp4|_320\.mp4'), '_320.mp4');
      }
      return decUrl;
    } catch (_) {
      return null;
    }
  }

  /// Fetches track media URLs for an album using the JioSaavn API.
  static Future<List<Map<String, String>>> fetchAlbumTracks(String albumToken) async {
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/album',
        queryParameters: {'token': albumToken},
      );
      final data = resp.data;
      if (data is Map && data['songs'] is List) {
        final list = <Map<String, String>>[];
        final albumTitle = data['title']?.toString();
        final albumArt = (data['image']?.toString() ?? '').replaceAll('150x150', '500x500');
        for (final song in data['songs'] as List) {
          final s = Map<String, dynamic>.from(song as Map);
          final title = s['title']?.toString() ?? 'Track';
          final moreInfo = s['more_info'] as Map<String, dynamic>?;
          final encUrl = s['encrypted_media_url']?.toString() ??
              moreInfo?['encrypted_media_url']?.toString();
          final directUrl = decryptMediaUrl(encUrl);
          final artist = s['subtitle']?.toString();
          if (directUrl != null) {
            list.add({
              'title': title,
              'url': directUrl,
              if (artist != null) 'artist': artist,
              if (albumTitle != null) 'album': albumTitle,
              if (albumArt.isNotEmpty) 'albumArt': albumArt,
            });
          }
        }
        return list;
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Fetches track media URLs for a playlist using the JioSaavn API.
  static Future<List<Map<String, String>>> fetchPlaylistTracks(String playlistToken) async {
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/playlist',
        queryParameters: {'token': playlistToken},
      );
      final data = resp.data;
      final songList = data is Map ? (data['list'] ?? data['songs']) : null;
      if (data is Map && songList is List) {
        final list = <Map<String, String>>[];
        final playlistTitle = data['title']?.toString();
        final playlistArt = (data['image']?.toString() ?? '').replaceAll('150x150', '500x500');
        for (final song in songList) {
          final s = Map<String, dynamic>.from(song as Map);
          final title = s['title']?.toString() ?? 'Track';
          final moreInfo = s['more_info'] as Map<String, dynamic>?;
          final encUrl = s['encrypted_media_url']?.toString() ??
              moreInfo?['encrypted_media_url']?.toString();
          final directUrl = decryptMediaUrl(encUrl);
          final artist = s['subtitle']?.toString();
          if (directUrl != null) {
            list.add({
              'title': title,
              'url': directUrl,
              if (artist != null) 'artist': artist,
              if (playlistTitle != null) 'album': playlistTitle,
              if (playlistArt.isNotEmpty) 'albumArt': playlistArt,
            });
          }
        }
        return list;
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Fetches complete JioSaavnItem objects for all tracks in an album.
  static Future<List<JioSaavnItem>> fetchAlbumSongs(String albumToken) async {
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/album',
        queryParameters: {'token': albumToken},
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final data = resp.data;
      if (data is Map && data['songs'] is List) {
        final list = <JioSaavnItem>[];
        final albumArt = (data['image']?.toString() ?? '').replaceAll('150x150', '500x500');
        final albumTitle = data['title']?.toString() ?? 'Album';
        for (final song in data['songs'] as List) {
          final s = Map<String, dynamic>.from(song as Map);
          Map<String, dynamic>? moreInfo;
          if (s['more_info'] is Map) {
            moreInfo = Map<String, dynamic>.from(s['more_info'] as Map);
          }
          final encUrl = s['encrypted_media_url']?.toString() ??
              moreInfo?['encrypted_media_url']?.toString();
          final directUrl = decryptMediaUrl(encUrl);
          final songId = s['id']?.toString() ?? s['token']?.toString() ?? '';
          final durationSecs = s['duration']?.toString() ?? moreInfo?['duration']?.toString();
          final songArt = (s['image']?.toString() ?? '').replaceAll('150x150', '500x500');
          list.add(JioSaavnItem(
            type: 'song',
            id: songId,
            token: s['token']?.toString() ?? songId,
            title: s['title']?.toString() ?? 'Track',
            subtitle: s['subtitle']?.toString() ?? albumTitle,
            imageUrl: songArt.isNotEmpty ? songArt : albumArt,
            encryptedMediaUrl: encUrl,
            directMediaUrl: directUrl,
            duration: durationSecs,
            quality: '320 kbps',
          ));
        }
        return list;
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Fetches complete JioSaavnItem objects for all tracks in a playlist.
  static Future<List<JioSaavnItem>> fetchPlaylistSongs(String playlistToken) async {
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/playlist',
        queryParameters: {'token': playlistToken},
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final data = resp.data;
      final songList = data is Map ? (data['list'] ?? data['songs']) : null;
      if (data is Map && songList is List) {
        final list = <JioSaavnItem>[];
        final playlistArt = (data['image']?.toString() ?? '').replaceAll('150x150', '500x500');
        final playlistTitle = data['title']?.toString() ?? 'Playlist';
        for (final song in songList) {
          final s = Map<String, dynamic>.from(song as Map);
          Map<String, dynamic>? moreInfo;
          if (s['more_info'] is Map) {
            moreInfo = Map<String, dynamic>.from(s['more_info'] as Map);
          }
          final encUrl = s['encrypted_media_url']?.toString() ??
              moreInfo?['encrypted_media_url']?.toString();
          final directUrl = decryptMediaUrl(encUrl);
          final songId = s['id']?.toString() ?? s['token']?.toString() ?? '';
          final durationSecs = s['duration']?.toString() ?? moreInfo?['duration']?.toString();
          final songArt = (s['image']?.toString() ?? '').replaceAll('150x150', '500x500');
          list.add(JioSaavnItem(
            type: 'song',
            id: songId,
            token: s['token']?.toString() ?? songId,
            title: s['title']?.toString() ?? 'Track',
            subtitle: s['subtitle']?.toString() ?? playlistTitle,
            imageUrl: songArt.isNotEmpty ? songArt : playlistArt,
            encryptedMediaUrl: encUrl,
            directMediaUrl: directUrl,
            duration: durationSecs,
            quality: '320 kbps',
          ));
        }
        return list;
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Parses any JioSaavn JSON item into a JioSaavnItem
  /// JioSaavn sends text with HTML escapes ("From &quot;Film&quot;"); this
  /// turns them back into the characters they stand for.
  static String decodeHtmlEntities(String s) {
    if (!s.contains('&')) return s;
    return s
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&'); // last, so "&amp;quot;" is not double-decoded
  }

  static JioSaavnItem parseItem(Map<String, dynamic> item) {
    final type = item['type']?.toString().toLowerCase() ?? 'album';
    final id = item['id']?.toString() ?? '';
    final token = item['token']?.toString() ?? id;
    final title = decodeHtmlEntities((item['title'] ?? item['name'])?.toString() ?? '');
    var subtitle = decodeHtmlEntities(item['subtitle']?.toString() ?? '');
    if (subtitle.isEmpty && type == 'artist') {
      subtitle = 'Artist';
    }
    final image = (item['image']?.toString() ?? '')
        .replaceAll('50x50', '500x500')
        .replaceAll('150x150', '500x500');
    Map<String, dynamic>? moreInfo;
    if (item['more_info'] is Map) {
      moreInfo = Map<String, dynamic>.from(item['more_info'] as Map);
    }
    if (subtitle.isEmpty && moreInfo != null) {
      final artistMap = moreInfo['artistMap'];
      if (artistMap is Map && artistMap['primary_artists'] is List) {
        final names = (artistMap['primary_artists'] as List)
            .whereType<Map>()
            .map((a) => a['name']?.toString() ?? '')
            .where((n) => n.isNotEmpty)
            .toList();
        if (names.isNotEmpty) {
          subtitle = names.join(', ');
        }
      }
      if (subtitle.isEmpty && moreInfo['music'] != null) {
        subtitle = moreInfo['music'].toString();
      } else if (subtitle.isEmpty && moreInfo['album'] != null) {
        subtitle = moreInfo['album'].toString();
      }
    }
    final encUrl = item['encrypted_media_url']?.toString() ??
        moreInfo?['encrypted_media_url']?.toString();
    final direct = decryptMediaUrl(encUrl);
    final duration = item['duration']?.toString() ?? moreInfo?['duration']?.toString();
    final songCount = item['song_count']?.toString() ?? moreInfo?['song_count']?.toString();

    return JioSaavnItem(
      type: type,
      id: id,
      token: token,
      title: title,
      subtitle: subtitle,
      imageUrl: image,
      language: item['language']?.toString(),
      year: item['year']?.toString(),
      music: moreInfo?['music']?.toString(),
      encryptedMediaUrl: encUrl,
      directMediaUrl: direct,
      duration: duration,
      songCount: songCount,
      quality: '320 kbps',
      album: type == 'song' ? (moreInfo?['album'] == null ? null : decodeHtmlEntities(moreInfo!['album'].toString())) : null,
      explicit: item['isExplicit'] == true ||
          item['explicit_content']?.toString() == '1' ||
          item['explicit']?.toString() == 'true',
      playCount: type == 'song' ? int.tryParse((item['play_count'] ?? moreInfo?['play_count'] ?? '').toString()) ?? 0 : 0,
    );
  }

  /// Fetches related albums for an album ID
  static Future<List<JioSaavnItem>> fetchRelatedAlbums(String albumId) async {
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/related',
        queryParameters: {'id': albumId},
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      final data = resp.data;
      final results = data is Map ? data['results'] : (data is List ? data : null);
      if (results is List) {
        return results
            .whereType<Map>()
            .map((e) => parseItem(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Fetches new releases for language
  static Future<List<JioSaavnItem>> fetchNewReleases({String lang = 'hindi'}) async {
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/new',
        queryParameters: {'lang': lang},
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      final data = resp.data;
      final results = data is List ? data : (data is Map ? (data['results'] ?? data['data']) : null);
      if (results is List) {
        return results
            .whereType<Map>()
            .map((e) => parseItem(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Fetches home feed for language (e.g. Trending Now, Top Charts, Editorial Picks)
  static Future<Map<String, List<JioSaavnItem>>> fetchHomeFeed({String lang = 'hindi'}) async {
    final dio = Dio();
    final feed = <String, List<JioSaavnItem>>{};
    try {
      final resp = await dio.get(
        '$apiBase/api/home',
        queryParameters: {'lang': lang},
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      final data = resp.data;
      if (data is Map) {
        // 1. Process 'modules' list which contains categorized sections
        final modules = data['modules'];
        if (modules is List) {
          for (final m in modules) {
            if (m is Map) {
              final modTitle = m['title']?.toString();
              if (modTitle != null && modTitle.trim().toLowerCase() == 'new releases') {
                // Skip duplicate "New Releases" since it is already fetched via /api/new
                continue;
              }
              final itemsList = m['items'];
              if (modTitle != null && modTitle.isNotEmpty && itemsList is List && itemsList.isNotEmpty) {
                final list = itemsList
                    .whereType<Map>()
                    .map((e) => parseItem(Map<String, dynamic>.from(e)))
                    .where((item) => item.title.isNotEmpty)
                    .toList();
                if (list.isNotEmpty) {
                  feed[modTitle] = list;
                }
              }
            }
          }
        }

        // 2. Also process any direct top-level list keys
        for (final entry in data.entries) {
          final key = entry.key.toString();
          if (key == 'modules' || key == 'language' || key.toLowerCase() == 'new_releases') continue;
          final val = entry.value;
          if (val is List && val.isNotEmpty) {
            final list = val
                .whereType<Map>()
                .map((e) => parseItem(Map<String, dynamic>.from(e)))
                .where((item) => item.title.isNotEmpty)
                .toList();
            if (list.isNotEmpty) {
              final formattedTitle = key
                  .replaceAll('_', ' ')
                  .split(' ')
                  .map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '')
                  .join(' ');
              feed[formattedTitle] = list;
            }
          }
        }
      }
    } catch (_) {} finally {
      dio.close();
    }
    return feed;
  }

  /// Search songs by query
  static Future<List<JioSaavnItem>> searchSongs(String query) async {
    if (query.trim().isEmpty) return [];
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/songs',
        queryParameters: {'q': query.trim()},
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      final data = resp.data;
      if (data is Map && data['results'] is List) {
        return (data['results'] as List)
            .whereType<Map>()
            .map((e) => parseItem(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Search playlists by query
  static Future<List<JioSaavnItem>> searchPlaylists(String query) async {
    if (query.trim().isEmpty) return [];
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/playlists',
        queryParameters: {'q': query.trim()},
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      final data = resp.data;
      if (data is Map && data['results'] is List) {
        return (data['results'] as List)
            .whereType<Map>()
            .map((e) => parseItem(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Search albums by query
  static Future<List<JioSaavnItem>> searchAlbums(String query) async {
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/albums',
        queryParameters: {'q': query},
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      final data = resp.data;
      if (data is Map && data['results'] is List) {
        return (data['results'] as List)
            .whereType<Map>()
            .map((e) => parseItem(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Search artists by query
  static Future<List<JioSaavnItem>> searchArtists(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/artists',
        queryParameters: {'q': q},
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      final data = resp.data;
      if (data is Map && data['results'] is List) {
        return (data['results'] as List)
            .whereType<Map>()
            .map((e) => parseItem(Map<String, dynamic>.from(e)))
            .where((it) => it.title.isNotEmpty)
            .toList();
      }
    } catch (_) {} finally {
      dio.close();
    }
    return [];
  }

  /// Fetches top tracks/releases for an artist
  static Future<List<JioSaavnItem>> fetchArtistSongs(String tokenOrName) async {
    final t = tokenOrName.trim();
    if (t.isEmpty) return [];
    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/artist',
        queryParameters: {'token': t},
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      final data = resp.data;
      if (data is Map && data['topSongs'] is List) {
        final list = (data['topSongs'] as List)
            .whereType<Map>()
            .map((e) => parseItem(Map<String, dynamic>.from(e)))
            .where((it) => it.title.isNotEmpty)
            .toList();
        if (list.isNotEmpty) return list;
      }
    } catch (_) {} finally {
      dio.close();
    }
    // Fallback: search songs by artist name
    return searchSongs(t);
  }

  /// Fetches complete details and direct stream URL for a single song.
  ///
  /// [tokenOrId] may be the song's perma token (what `/api/song` expects) or
  /// its JioSaavn id (what the app stores as `Song.mediaId`). The token lookup
  /// answers "Song not found" for an id, which used to make every song
  /// resolved by id unplayable, so an id falls back to `song.getDetails`.
  static Future<JioSaavnItem?> fetchSongDetails(String tokenOrId) async {
    final key = tokenOrId.trim();
    if (key.isEmpty) return null;

    // A "Song not found" reply parses into an empty item; only a song with a
    // title and a playable URL counts as found.
    JioSaavnItem? usable(JioSaavnItem? item) {
      if (item == null || item.title.isEmpty) return null;
      final hasUrl = (item.directMediaUrl?.isNotEmpty ?? false) ||
          (item.encryptedMediaUrl?.isNotEmpty ?? false);
      return hasUrl ? item : null;
    }

    final dio = Dio();
    try {
      final resp = await dio.get(
        '$apiBase/api/song',
        queryParameters: {'token': key},
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      final data = resp.data;
      if (data is Map) {
        final item = usable(parseItem(Map<String, dynamic>.from(data)));
        if (item != null) return item;
      }
    } catch (_) {} finally {
      dio.close();
    }

    // Not a token: look it up as an id.
    try {
      final data = await _callApiPhp({'__call': 'song.getDetails', 'pids': key}, timeoutSecs: 10);
      Map? song;
      if (data is Map) {
        song = data[key] is Map
            ? data[key] as Map
            : (data['songs'] is List && (data['songs'] as List).isNotEmpty ? (data['songs'] as List).first as Map? : null);
      }
      if (song != null) return usable(parseItem(Map<String, dynamic>.from(song)));
    } catch (_) {}
    return null;
  }

  static const String _apiPhp = 'https://www.jiosaavn.com/api.php';

  static Future<dynamic> _callApiPhp(Map<String, dynamic> params, {int timeoutSecs = 8}) async {
    final dio = Dio();
    try {
      final resp = await dio.get(
        _apiPhp,
        queryParameters: {
          'api_version': '4',
          '_format': 'json',
          '_marker': '0',
          'ctx': 'android',
          ...params,
        },
        options: Options(receiveTimeout: Duration(seconds: timeoutSecs)),
      );
      final raw = resp.data;
      return raw is String ? jsonDecode(raw) : raw;
    } finally {
      dio.close();
    }
  }

  /// The primary and featured artists credited on a song (`song.getDetails`),
  /// with the ids needed to look up their other songs.
  static Future<List<({String id, String name})>> fetchSongArtists(String songId) async {
    if (songId.trim().isEmpty) return const [];
    try {
      final data = await _callApiPhp({'__call': 'song.getDetails', 'pids': songId.trim()});
      final Map? song = data is Map
          ? (data[songId.trim()] is Map
              ? data[songId.trim()] as Map
              : (data['songs'] is List && (data['songs'] as List).isNotEmpty
                  ? (data['songs'] as List).first as Map?
                  : null))
          : null;
      final artistMap = (song?['more_info'] as Map?)?['artistMap'] as Map?;
      if (artistMap == null) return const [];
      final seen = <String>{};
      final out = <({String id, String name})>[];
      for (final key in const ['primary_artists', 'featured_artists']) {
        for (final a in (artistMap[key] as List? ?? const []).whereType<Map>()) {
          final id = a['id']?.toString() ?? '';
          if (id.isNotEmpty && seen.add(id)) {
            out.add((id: id, name: a['name']?.toString() ?? ''));
          }
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Other songs by one artist (`search.artistOtherTopSongs`), newest first.
  static Future<List<JioSaavnItem>> fetchArtistOtherSongs(
    String artistId,
    String songId, {
    String lang = 'hindi',
  }) async {
    if (artistId.trim().isEmpty) return const [];
    try {
      final data = await _callApiPhp({
        '__call': 'search.artistOtherTopSongs',
        'artist_ids': artistId.trim(),
        'song_id': songId.trim(),
        'language': lang,
        'category': 'latest',
        'sort_order': 'asc',
        'page': '1',
        'n': '20',
      });
      final list = data is List ? data : (data is Map ? data['songs'] : null);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((e) => parseItem(Map<String, dynamic>.from(e)))
          .where((i) => i.title.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Fetches song suggestions/recommendations based on a song ID
  /// using JioSaavn's reco.getreco recommendation engine.
  static Future<List<JioSaavnItem>> fetchSongSuggestions(String songId, {int limit = 10}) async {
    if (songId.trim().isEmpty) return [];
    final dio = Dio();
    try {
      final directResp = await dio.get(
        'https://www.jiosaavn.com/api.php',
        queryParameters: {
          '__call': 'reco.getreco',
          'api_version': '4',
          '_format': 'json',
          '_marker': '0',
          'ctx': 'android',
          'pid': songId.trim(),
          'n': limit,
        },
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      final rawData = directResp.data;
      final dynamic parsed = rawData is String ? jsonDecode(rawData) : rawData;
      List rawList = [];
      if (parsed is List) {
        rawList = parsed;
      } else if (parsed is Map) {
        final val = parsed[songId.trim()];
        if (val is List) {
          rawList = val;
        } else if (parsed.isNotEmpty && parsed.values.first is List) {
          rawList = parsed.values.first as List;
        }
      }

      if (rawList.isNotEmpty) {
        return rawList
            .whereType<Map>()
            .map((e) => parseItem(Map<String, dynamic>.from(e)))
            .where((item) => item.title.isNotEmpty)
            .take(limit)
            .toList();
      }
    } catch (_) {
    } finally {
      dio.close();
    }
    return [];
  }
}

