import 'package:vinyl/data/models/jiosaavn_item.dart';
import 'package:vinyl/data/models/song_model.dart';

/// Kinds of tracks that should never follow unrelated music (e.g. an aarti or
/// a cartoon theme after a Bollywood song) unless the user listens to them.
enum ContentCategory { devotional, kids }

/// Detects devotional and kids content from a track's title / artist / album.
class ContentClassifier {
  static final RegExp _devotional = RegExp(
    r'\b(aarti|arti|aarati|bhajan|bhajans|chalisa|mantra|mantras|stotram|stotra|'
    r'kirtan|bhakti|amritwani|satsang|jaap|jap|vandana|stuti|aradhana|'
    r'om jai|jai jagdish|hanuman|ganpati aarti|shiv tandav|gayatri|sai baba|'
    r'krishna bhajan|mata ki|jai mata|jai ambe|shri ram jai|devotional)\b',
    caseSensitive: false,
  );

  static final RegExp _kids = RegExp(
    r'\b(rhymes?|nursery|lullaby|lori|cartoon|kids|children|baby shark|'
    r'motu patlu|chhota bheem|chota bheem|doraemon|shinchan|peppa|'
    r'bal geet|balgeet|poem for kids|theme song|kids song)\b',
    caseSensitive: false,
  );

  static ContentCategory? classify(String text) {
    if (text.trim().isEmpty) return null;
    if (_kids.hasMatch(text)) return ContentCategory.kids;
    if (_devotional.hasMatch(text)) return ContentCategory.devotional;
    return null;
  }

  static ContentCategory? ofItem(JioSaavnItem item) =>
      classify('${item.title} ${item.subtitle} ${item.music ?? ''}');

  static ContentCategory? ofSong(Song song) =>
      classify('${song.title} ${song.artist} ${song.album}');
}
