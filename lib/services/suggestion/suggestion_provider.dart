import 'package:vinyl/services/suggestion/suggestion_models.dart';

/// One source of "songs like this one".
///
/// A provider never throws and never blocks for long: when its service is
/// down, slow, or simply has nothing for this song, it returns an empty list.
/// The suggestion service relies on that to mix several sources.
abstract class SuggestionProvider {
  SuggestionSource get source;

  /// Songs similar to [seed], best first.
  Future<List<SuggestionCandidate>> suggest(SeedSong seed, {int limit = 25});
}

/// A provider whose answer is slow, so it can start working before the answer
/// is needed (when a song starts playing rather than when the queue runs out).
abstract interface class WarmableProvider {
  void warmUp(SeedSong seed);
}

/// A provider so slow that its answer usually arrives long after the others
/// (MetaBrainz). It can give what it already knows without waiting, and can
/// also be waited on for the full answer.
abstract interface class SlowProvider implements WarmableProvider {
  /// The answer for [seed] if it is already known, else null (and the lookup is
  /// started). An empty list is an answer: it means "no data for this song".
  List<SuggestionCandidate>? cachedFor(SeedSong seed);

  /// Waits, up to [patience], for the full answer for [seed].
  Future<List<SuggestionCandidate>> suggestPatiently(SeedSong seed, {int limit = 25, Duration? patience});
}
