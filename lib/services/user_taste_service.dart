import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vinyl/core/utils/song_dedupe.dart';
import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/data/models/song_model.dart';
import 'package:vinyl/services/suggestion/suggestion_models.dart';

export 'package:vinyl/core/utils/content_classifier.dart';

/// One terminal outcome per playback session.
enum SessionOutcome {
  inProgress,
  completed,
  skipped,
  abandoned,
}

/// Represents an ongoing track listening session.
class PlaybackSession {
  final String trackKey;
  final Song song;
  final DateTime startTime;
  Duration lastPosition;
  Duration duration;
  SessionOutcome outcome;

  PlaybackSession({
    required this.trackKey,
    required this.song,
    required this.startTime,
    Duration? initialDuration,
  })  : lastPosition = Duration.zero,
        duration = initialDuration ?? song.duration,
        outcome = SessionOutcome.inProgress;

  bool get isTerminal => outcome != SessionOutcome.inProgress;
}

/// Interaction metrics recorded implicitly and explicitly for a track.
/// Uses separately decayed positive and negative score accumulators to prevent
/// new skips from reviving decayed completions (Solves Finding 1).
class SongInteraction {
  final String trackKey;
  final int songId;
  final String title;
  final String artist;
  final String? genre;
  int playCount;
  int completeCount;
  int skipCount;
  bool isFavorite;
  DateTime lastInteraction;
  int searchPlayCount;

  // Separate decayed signal accumulators (30-day half-life continuous decay)
  double positiveScore;
  double negativeScore;

  // Candidate metadata cached for high-priority recommendation reconstruction
  String? imageUrl;
  String? token;
  String? duration;
  String? language;

  SongInteraction({
    required this.trackKey,
    required this.songId,
    required this.title,
    required this.artist,
    this.genre,
    this.playCount = 0,
    this.completeCount = 0,
    this.skipCount = 0,
    this.isFavorite = false,
    required this.lastInteraction,
    this.searchPlayCount = 0,
    double? positiveScore,
    double? negativeScore,
    this.imageUrl,
    this.token,
    this.duration,
    this.language,
  })  : positiveScore = positiveScore ??
            ((completeCount * 1.5) + (playCount * 0.5) + (searchPlayCount * 5.0) + (isFavorite ? 3.0 : 0.0)),
        negativeScore = negativeScore ?? (skipCount * 2.0);

  // 30-day half life decay: lambda = ln(2) / 30 ~= 0.0231049
  static const double _lambda = 0.0231049;

  /// Key prefix of entries created by "add preferred artist".
  static const String artistPreferencePrefix = 'artist_pref:';

  /// True for a manually added preferred artist. These only feed artist
  /// affinity; they are not real songs and must never be recommended,
  /// used as a seed, or counted as a tracked song.
  bool get isArtistPreference => trackKey.startsWith(artistPreferencePrefix);

  void _decayAccumulators(DateTime now) {
    if (now.isBefore(lastInteraction)) return;
    final days = now.difference(lastInteraction).inSeconds / 86400.0;
    final factor = exp(-_lambda * days);
    positiveScore *= factor;
    negativeScore *= factor;
    lastInteraction = now;
  }

  void recordPlay(DateTime now) {
    _decayAccumulators(now);
    playCount++;
    positiveScore += 0.5;
  }

  void recordSearchPlay(DateTime now, {JioSaavnItem? item}) {
    _decayAccumulators(now);
    searchPlayCount++;
    positiveScore += 5.0; // High explicit user intent boost
    if (item != null) {
      if (item.imageUrl.isNotEmpty) imageUrl = item.imageUrl;
      if (item.token.isNotEmpty) token = item.token;
      if (item.duration != null && item.duration!.isNotEmpty) duration = item.duration;
      if (item.language != null && item.language!.isNotEmpty) language = item.language;
    }
  }

  void recordComplete(DateTime now) {
    _decayAccumulators(now);
    completeCount++;
    positiveScore += 1.5;
  }

  void recordSkip(DateTime now) {
    _decayAccumulators(now);
    skipCount++;
    negativeScore += 2.0;
  }

  void recordFavorite(DateTime now, bool fav) {
    _decayAccumulators(now);
    isFavorite = fav;
  }

  /// Reconstructs a JioSaavnItem candidate from interaction profile.
  JioSaavnItem toJioSaavnItem() {
    final idStr = trackKey.startsWith('jiosaavn:')
        ? trackKey.substring('jiosaavn:'.length)
        : songId.toString();
    return JioSaavnItem(
      type: 'song',
      id: idStr,
      token: (token != null && token!.isNotEmpty) ? token! : idStr,
      title: title,
      subtitle: artist,
      imageUrl: imageUrl ?? '',
      duration: duration,
      language: language,
    );
  }

  /// Computes dynamic score using separately decayed positive and negative signals.
  double computeAffinityScore(DateTime now) {
    final days = max(0.0, now.difference(lastInteraction).inSeconds / 86400.0);
    final factor = exp(-_lambda * days);
    final favBonus = isFavorite ? 3.0 : 0.0;
    final decayedPos = positiveScore * factor;
    final decayedNeg = negativeScore * factor;
    return max(0.0, (decayedPos + favBonus) - decayedNeg);
  }

  Map<String, dynamic> toJson() => {
        'trackKey': trackKey,
        'songId': songId,
        'title': title,
        'artist': artist,
        'genre': genre,
        'playCount': playCount,
        'completeCount': completeCount,
        'skipCount': skipCount,
        'isFavorite': isFavorite == true,
        'lastInteraction': lastInteraction.toIso8601String(),
        'searchPlayCount': searchPlayCount,
        'positiveScore': positiveScore,
        'negativeScore': negativeScore,
        'imageUrl': imageUrl,
        'token': token,
        'duration': duration,
        'language': language,
      };

  factory SongInteraction.fromJson(Map<String, dynamic> json) {
    final parsedSongId = (json['songId'] is int)
        ? json['songId'] as int
        : int.tryParse(json['songId']?.toString() ?? '0') ?? 0;
    final trackKey = json['trackKey']?.toString() ??
        (parsedSongId != 0 ? 'legacy:$parsedSongId' : 'unknown:${json['title']}');
    final playCount = (json['playCount'] is int)
        ? json['playCount'] as int
        : int.tryParse(json['playCount']?.toString() ?? '0') ?? 0;
    final completeCount = (json['completeCount'] is int)
        ? json['completeCount'] as int
        : int.tryParse(json['completeCount']?.toString() ?? '0') ?? 0;
    final skipCount = (json['skipCount'] is int)
        ? json['skipCount'] as int
        : int.tryParse(json['skipCount']?.toString() ?? '0') ?? 0;
    final isFavorite = json['isFavorite'] == true;
    final searchPlayCount = (json['searchPlayCount'] is int)
        ? json['searchPlayCount'] as int
        : int.tryParse(json['searchPlayCount']?.toString() ?? '0') ?? 0;
    final lastInteraction =
        DateTime.tryParse(json['lastInteraction']?.toString() ?? '') ?? DateTime.now();

    final positiveScore = (json['positiveScore'] is num)
        ? (json['positiveScore'] as num).toDouble()
        : ((completeCount * 1.5) + (playCount * 0.5) + (searchPlayCount * 5.0) + (isFavorite ? 3.0 : 0.0));
    final negativeScore = (json['negativeScore'] is num)
        ? (json['negativeScore'] as num).toDouble()
        : (skipCount * 2.0);

    return SongInteraction(
      trackKey: trackKey,
      songId: parsedSongId,
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      genre: json['genre']?.toString(),
      playCount: playCount,
      completeCount: completeCount,
      skipCount: skipCount,
      isFavorite: isFavorite,
      lastInteraction: lastInteraction,
      searchPlayCount: searchPlayCount,
      positiveScore: positiveScore,
      negativeScore: negativeScore,
      imageUrl: json['imageUrl']?.toString(),
      token: json['token']?.toString(),
      duration: json['duration']?.toString(),
      language: json['language']?.toString(),
    );
  }
}

/// PulseIQ: the on-device taste profile.
///
/// It watches what the user plays, finishes, skips, favourites and searches
/// for, and remembers it (decaying over time). It only learns and answers
/// questions about taste; it does not fetch or rank suggestions.
class UserTasteService {
  static const String _storageFileName = 'pulseiq_taste_profile.json';
  static UserTasteService? _instance;
  static UserTasteService get instance => _instance ??= UserTasteService();

  final DateTime Function() _clock;
  File? _storageFile;

  // Stored by canonical trackKey
  final Map<String, SongInteraction> _interactions = {};
  // Secondary lookup by integer songId for legacy migrations
  final Map<int, String> _songIdToTrackKey = {};
  final Map<String, double> _artistAffinities = {};
  final Set<String> _searchPlayedArtists = {};

  Timer? _saveDebounceTimer;
  bool _isInitialized = false;

  // Active playback session carrying single terminal outcome
  PlaybackSession? _activeSession;

  UserTasteService({
    DateTime Function()? clock,
    File? storageFile,
  })  : _clock = clock ?? DateTime.now,
        _storageFile = storageFile {
    _instance = this;
  }

  /// Splits and normalizes artist names into exact clean tokens.
  static List<String> parseArtistTokens(String artistsString) => parseArtistNames(artistsString);

  static String _canonicalKeyForSong(Song song) {
    return song.canonicalKey;
  }

  Future<File> _resolveStorageFile() async {
    if (_storageFile != null) return _storageFile!;
    Directory baseDir;
    try {
      baseDir = await getApplicationDocumentsDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    _storageFile = File('${baseDir.path}/$_storageFileName');
    return _storageFile!;
  }

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final file = await _resolveStorageFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic> && decoded['interactions'] is List) {
            for (final item in decoded['interactions'] as List) {
              if (item is Map<String, dynamic>) {
                try {
                  final interaction = SongInteraction.fromJson(item);
                  _interactions[interaction.trackKey] = interaction;
                  if (interaction.songId != 0) {
                    _songIdToTrackKey[interaction.songId] = interaction.trackKey;
                  }
                } catch (e) {
                  debugPrint('PulseIQ: Skipped corrupt item in taste profile: $e');
                }
              }
            }
          }
        }
      }
      _recalculateArtistAffinities();
      _isInitialized = true;
    } catch (e) {
      debugPrint('PulseIQ UserTasteService init error: $e');
    }
  }

  void _recalculateArtistAffinities() {
    _artistAffinities.clear();
    _searchPlayedArtists.clear();
    final now = _clock();

    for (final inter in _interactions.values) {
      final tokens = parseArtistTokens(inter.artist);
      if (tokens.isEmpty) continue;

      if (inter.searchPlayCount > 0) {
        for (final token in tokens) {
          _searchPlayedArtists.add(token);
        }
      }

      final songScore = inter.computeAffinityScore(now);
      if (songScore <= 0.0) continue;

      // Primary artist receives full score; collaborators receive half
      for (int i = 0; i < tokens.length; i++) {
        final token = tokens[i];
        final weight = i == 0 ? 1.0 : 0.5;
        _artistAffinities[token] = (_artistAffinities[token] ?? 0.0) + (songScore * weight);
      }
    }
  }

  SongInteraction? _getInteraction(String trackKey, [dynamic fallbackId]) {
    var interaction = _interactions[trackKey];
    if (interaction != null) return interaction;

    if (fallbackId != null) {
      final intId = (fallbackId is int) ? fallbackId : int.tryParse(fallbackId.toString());
      if (intId != null && _songIdToTrackKey.containsKey(intId)) {
        return _interactions[_songIdToTrackKey[intId]];
      }
    }
    return null;
  }

  SongInteraction _getOrCreateInteraction(Song song, {JioSaavnItem? item}) {
    final trackKey = _canonicalKeyForSong(song);
    var interaction = _getInteraction(trackKey, song.id);
    if (interaction == null) {
      interaction = SongInteraction(
        trackKey: trackKey,
        songId: song.id,
        title: song.title,
        artist: song.artist,
        genre: song.genre,
        lastInteraction: _clock(),
        imageUrl: item?.imageUrl ?? ((song.albumArt?.isNotEmpty ?? false) ? song.albumArt : null),
        token: item?.token,
        duration: item?.duration,
        language: item?.language,
      );
      _interactions[trackKey] = interaction;
      _songIdToTrackKey[song.id] = trackKey;
    } else {
      if (item != null) {
        if (item.imageUrl.isNotEmpty) interaction.imageUrl = item.imageUrl;
        if (item.token.isNotEmpty) interaction.token = item.token;
        if (item.duration != null && item.duration!.isNotEmpty) interaction.duration = item.duration;
        if (item.language != null && item.language!.isNotEmpty) interaction.language = item.language;
      }
    }
    return interaction;
  }

  /// Explicitly records high-intent playback initiated when user searches and selects a song.
  void recordSearchPlay(Song song, {JioSaavnItem? item}) {
    final now = _clock();
    final interaction = _getOrCreateInteraction(song, item: item);
    interaction.recordSearchPlay(now, item: item);

    _recalculateArtistAffinities();
    _scheduleSave();
    debugPrint('PulseIQ: High-intent search play recorded for "${song.title}" (searchCount: ${interaction.searchPlayCount})');
  }

  /// Returns all songs that have been searched and played, ordered by recency.
  List<SongInteraction> getSearchPlayedInteractions() {
    return _interactions.values
        .where((i) => i.searchPlayCount > 0 && !i.isArtistPreference)
        .toList()
      ..sort((a, b) => b.lastInteraction.compareTo(a.lastInteraction));
  }

  // --- Real-Time Implicit Signal Capture with PlaybackSession ---

  /// Called when a song begins playback. Starts a new PlaybackSession.
  void onSongStarted(Song song) {
    final now = _clock();

    // Check if previous session was abandoned or skipped early
    if (_activeSession != null && !_activeSession!.isTerminal) {
      final prev = _activeSession!;
      final elapsed = now.difference(prev.startTime).inSeconds;
      if (elapsed < 15 && prev.lastPosition.inSeconds < 15) {
        prev.outcome = SessionOutcome.skipped;
        _recordSkipInternal(prev.trackKey);
      } else {
        prev.outcome = SessionOutcome.abandoned;
      }
    }

    final key = _canonicalKeyForSong(song);
    _activeSession = PlaybackSession(
      trackKey: key,
      song: song,
      startTime: now,
      initialDuration: song.duration,
    );

    final interaction = _getOrCreateInteraction(song);
    interaction.recordPlay(now);

    _recalculateArtistAffinities();
    _scheduleSave();
    debugPrint('PulseIQ: Started playing "${song.title}" by "${song.artist}" (plays: ${interaction.playCount})');
  }

  /// Called on playback progress stream. Transitions session to completed once
  /// listening threshold (>= 80% or >= 3 minutes) is crossed.
  void onPlaybackProgress(Song song, Duration position, Duration duration) {
    if (_activeSession == null || _activeSession!.song.id != song.id) {
      _activeSession = PlaybackSession(
        trackKey: _canonicalKeyForSong(song),
        song: song,
        startTime: _clock(),
        initialDuration: duration,
      );
    }

    final session = _activeSession!;
    if (session.isTerminal) return;

    session.lastPosition = position;
    if (duration > Duration.zero) session.duration = duration;

    // Spotify rule: Listening past 80% or 3 minutes counts as an intentional complete play
    if (session.duration > Duration.zero) {
      final ratio = position.inMilliseconds / session.duration.inMilliseconds;
      if (ratio >= 0.80 || position.inSeconds >= 180) {
        session.outcome = SessionOutcome.completed;
        _recordCompletionInternal(session.trackKey, song);
      }
    }
  }

  /// Explicitly called when user initiates a manual skip before song naturally completes.
  void onSongSkipped(Song song, {bool isManual = true}) {
    final session = _activeSession;
    if (session != null && session.song.id == song.id) {
      if (session.outcome == SessionOutcome.completed) return; // Not a negative skip if completed
      if (session.outcome == SessionOutcome.skipped) return;
      session.outcome = SessionOutcome.skipped;
    }
    _recordSkipInternal(_canonicalKeyForSong(song));
  }

  /// Called when audio reaches natural completion (e.g. ProcessingState.completed).
  void onSongCompleted(Song song) {
    final session = _activeSession;
    if (session != null && session.song.id == song.id) {
      if (session.outcome == SessionOutcome.completed) return;
      session.outcome = SessionOutcome.completed;
    }
    _recordCompletionInternal(_canonicalKeyForSong(song), song);
  }

  /// Explicitly records when a track is marked or unmarked as favorite.
  void onSongFavoriteToggled(Song song, bool isFav) {
    final now = _clock();
    final interaction = _getOrCreateInteraction(song);
    interaction.recordFavorite(now, isFav);

    _recalculateArtistAffinities();
    _scheduleSave();
    debugPrint('PulseIQ: Recorded favorite=$isFav for "${song.title}" by "${song.artist}"');
  }

  void _recordCompletionInternal(String trackKey, Song song) {
    final now = _clock();
    final interaction = _getOrCreateInteraction(song);
    interaction.recordComplete(now);

    _recalculateArtistAffinities();
    _scheduleSave();
    debugPrint('PulseIQ: Recorded completion for "${song.title}" by "${song.artist}" (completed: ${interaction.completeCount} times)');
  }

  void _recordSkipInternal(String trackKey) {
    final now = _clock();
    final interaction = _interactions[trackKey];
    if (interaction != null) {
      interaction.recordSkip(now);
      _recalculateArtistAffinities();
      _scheduleSave();
      debugPrint('PulseIQ: Recorded skip penalty for "${interaction.title}" (skips: ${interaction.skipCount})');
    }
  }

  // --- Taste Metrics & Candidate Scoring ---

  int get trackedSongCount =>
      _interactions.values.where((i) => !i.isArtistPreference).length;
  int get trackedArtistCount {
    _recalculateArtistAffinities();
    return _artistAffinities.length;
  }

  /// Returns tracked songs sorted by affinity score descending.
  List<SongInteraction> getTrackedSongs({String? query}) {
    final now = _clock();
    var list = _interactions.values.where((i) => !i.isArtistPreference).toList()
      ..sort((a, b) => b.computeAffinityScore(now).compareTo(a.computeAffinityScore(now)));

    if (query != null && query.trim().isNotEmpty) {
      final q = query.trim().toLowerCase();
      list = list.where((i) =>
        i.title.toLowerCase().contains(q) ||
        i.artist.toLowerCase().contains(q)
      ).toList();
    }
    return list;
  }

  /// Returns tracked artists paired with their affinity score.
  List<MapEntry<String, double>> getTrackedArtists({String? query}) {
    _recalculateArtistAffinities();
    var list = _artistAffinities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (query != null && query.trim().isNotEmpty) {
      final q = query.trim().toLowerCase();
      list = list.where((e) => e.key.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  bool isSearchPlayedArtist(String artistToken) {
    return _searchPlayedArtists.contains(artistToken.toLowerCase().trim());
  }

  /// Removes an individual song interaction from taste recommendations.
  Future<bool> removeTrackedSong(String trackKey) async {
    final removed = _interactions.remove(trackKey);
    if (removed != null) {
      if (removed.songId != 0) {
        _songIdToTrackKey.remove(removed.songId);
      }
      _recalculateArtistAffinities();
      await flush();
      return true;
    }
    return false;
  }

  /// Removes all tracked interactions and affinity for an artist.
  Future<int> removeTrackedArtist(String artistName) async {
    final tokens = parseArtistTokens(artistName);
    if (tokens.isEmpty) return 0;

    int removedCount = 0;
    final keysToRemove = <String>[];

    for (final inter in _interactions.values) {
      final songTokens = parseArtistTokens(inter.artist);
      if (songTokens.any((t) => tokens.contains(t))) {
        keysToRemove.add(inter.trackKey);
      }
    }

    for (final key in keysToRemove) {
      final inter = _interactions.remove(key);
      if (inter != null && inter.songId != 0) {
        _songIdToTrackKey.remove(inter.songId);
      }
      removedCount++;
    }

    for (final token in tokens) {
      _artistAffinities.remove(token);
      _searchPlayedArtists.remove(token);
    }

    _recalculateArtistAffinities();
    await flush();
    return removedCount;
  }

  /// Manually adds or boosts a preferred artist in the taste profile.
  Future<void> addPreferredArtist(String artistName) async {
    final tokens = parseArtistTokens(artistName);
    if (tokens.isEmpty) return;

    final primaryToken = tokens.first;
    final dummyKey = '${SongInteraction.artistPreferencePrefix}$primaryToken';
    final now = _clock();

    _interactions[dummyKey] = SongInteraction(
      trackKey: dummyKey,
      songId: 0,
      title: 'Top Artist Selection',
      artist: artistName.trim(),
      playCount: 10,
      completeCount: 8,
      searchPlayCount: 3,
      lastInteraction: now,
      positiveScore: 35.0,
      negativeScore: 0.0,
    );

    for (final token in tokens) {
      _searchPlayedArtists.add(token);
      _artistAffinities[token] = (_artistAffinities[token] ?? 0.0) + 15.0;
    }

    _recalculateArtistAffinities();
    await flush();
  }

  /// Completely clears all tracked taste history, resetting recommendations.
  Future<void> clearTasteProfile() async {
    _interactions.clear();
    _songIdToTrackKey.clear();
    _artistAffinities.clear();
    _searchPlayedArtists.clear();
    _activeSession = null;
    try {
      final file = await _resolveStorageFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    debugPrint('PulseIQ: Taste profile cleared completely.');
  }

  /// Returns top artists sorted by dynamic affinity score.
  List<String> getTopArtists({int limit = 10}) {
    _recalculateArtistAffinities();
    final sorted = _artistAffinities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }

  // --- What the profile knows -------------------------------------------------
  //
  // PulseIQ only learns and remembers the user's taste. It does not fetch or
  // rank suggestions: that is the SuggestionService's job, which asks PulseIQ
  // the two questions below.

  /// How much the user is likely to like [item], from 0 (nothing known, or
  /// disliked) to 1, judged from their listening: the artist's affinity, what
  /// they played, finished, skipped, favourited, or searched for on purpose.
  double likeness(JioSaavnItem item) {
    final now = _clock();
    final tokens = parseArtistTokens(item.subtitle);
    var score = 0.0;

    // Artist: saturating, so one favourite artist cannot dominate everything.
    var artist = 0.0;
    for (final token in tokens) {
      artist = max(artist, _artistAffinities[token] ?? 0.0);
    }
    score += (artist / (artist + 6.0)) * 0.45;

    // This exact song.
    final interaction = _getInteraction(item.canonicalKey, item.id);
    if (interaction != null) {
      final affinity = interaction.computeAffinityScore(now);
      score += (affinity / (affinity + 6.0)) * 0.35;
      if (interaction.skipCount > interaction.completeCount) score -= 0.3;
      if (interaction.searchPlayCount > 0) score += 0.2; // chosen on purpose
    }

    if (tokens.any(_searchPlayedArtists.contains)) score += 0.1;
    return score.clamp(0.0, 1.0);
  }

  /// The songs that best describe the user's taste, to use as the "songs in"
  /// of the suggestion service: what they searched for and played first, then
  /// the songs they like most. At most [limit].
  List<SeedSong> topSeedSongs({int limit = 4}) {
    final now = _clock();
    final candidates = _interactions.values.where((i) {
      if (i.isArtistPreference || i.title.trim().isEmpty) return false;
      return i.skipCount <= i.completeCount; // not a song they keep skipping
    }).toList();

    int byTaste(SongInteraction a, SongInteraction b) {
      // Searched-and-played songs first, most recent first; then by affinity.
      final aSearched = a.searchPlayCount > 0 ? 1 : 0;
      final bSearched = b.searchPlayCount > 0 ? 1 : 0;
      if (aSearched != bSearched) return bSearched.compareTo(aSearched);
      if (aSearched == 1) return b.lastInteraction.compareTo(a.lastInteraction);
      return b.computeAffinityScore(now).compareTo(a.computeAffinityScore(now));
    }

    candidates.sort(byTaste);
    final seen = <String>{};
    final out = <SeedSong>[];
    for (final i in candidates) {
      if (i.computeAffinityScore(now) <= 0 && i.searchPlayCount == 0) continue;
      if (!seen.add(i.trackKey)) continue;
      out.add(SeedSong(
        title: i.title,
        artist: i.artist,
        durationSecs: int.tryParse(i.duration ?? '') ?? 0,
        jioId: i.trackKey.startsWith('jiosaavn:') ? i.trackKey.substring('jiosaavn:'.length) : null,
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  // --- Persistence & Lifecycle Flush (Finding 12) ---

  void _scheduleSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(seconds: 3), flush);
  }

  /// Immediately writes pending taste profile interactions to disk.
  Future<void> flush() async {
    _saveDebounceTimer?.cancel();
    try {
      final file = await _resolveStorageFile();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final interactionList = _interactions.values.map((i) => i.toJson()).toList();
      final data = {
        'interactions': interactionList,
      };
      await file.writeAsString(jsonEncode(data));
      _recalculateArtistAffinities();
    } catch (e, st) {
      debugPrint('PulseIQ: Failed to flush taste profile: $e\n$st');
    }
  }

  void dispose() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
  }
}
