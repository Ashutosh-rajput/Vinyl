class LyricWord {
  final Duration begin;
  final Duration end;
  final String text;

  const LyricWord({
    required this.begin,
    required this.end,
    required this.text,
  });

  bool isSungAt(Duration position) => position >= begin;
  bool isActiveAt(Duration position) => position >= begin && (end == Duration.zero || position < end);

  @override
  String toString() => '$text(${begin.inMilliseconds}-${end.inMilliseconds}ms)';
}

class LyricLine {
  final Duration timestamp;
  final Duration? endTime;
  final String text;
  final List<LyricWord> words;

  const LyricLine({
    required this.timestamp,
    this.endTime,
    required this.text,
    this.words = const [],
  });

  bool get hasWords => words.isNotEmpty;

  /// Returns text with guaranteed proper spacing between words,
  /// even if original raw text was parsed/joined without spaces.
  String get formattedText {
    if (words.isEmpty) return text;
    final trimmed = text.trim();
    // If text already has spaces between words, return it directly
    if (trimmed.contains(' ') && trimmed.split(RegExp(r'\s+')).length > 1) {
      return trimmed;
    }
    // Otherwise construct the line from its words with proper spacing
    final buffer = StringBuffer();
    for (int i = 0; i < words.length; i++) {
      final w = words[i].text.trim();
      if (w.isEmpty) continue;
      if (buffer.isNotEmpty && !RegExp(r"^[,.:;?!')\]}]").hasMatch(w)) {
        buffer.write(' ');
      }
      buffer.write(w);
    }
    final reconstructed = buffer.toString().trim();
    return reconstructed.isNotEmpty ? reconstructed : text;
  }

  @override
  String toString() => '[${timestamp.inMinutes}:${(timestamp.inSeconds % 60).toString().padLeft(2, '0')}] $text';
}

class LyricsData {
  final bool isSynced;
  final bool isWordSynced;
  final bool isInstrumental;
  final List<LyricLine> lines;
  final String? plainLyrics;
  final String source; // 'binimum', 'lrclib', 'local_lrc', 'cache', 'manual'
  final String? format; // 'ttml_word', 'ttml_line', 'lrc', 'plain', 'instrumental'
  final String rawContent;

  const LyricsData({
    required this.isSynced,
    this.isWordSynced = false,
    this.isInstrumental = false,
    this.lines = const [],
    this.plainLyrics,
    this.source = 'lrclib',
    this.format,
    this.rawContent = '',
  });

  factory LyricsData.instrumental({String source = 'lrclib'}) {
    return LyricsData(
      isSynced: false,
      isWordSynced: false,
      isInstrumental: true,
      lines: const [],
      source: source,
      format: 'instrumental',
    );
  }

  factory LyricsData.empty() {
    return const LyricsData(
      isSynced: false,
      isWordSynced: false,
      isInstrumental: false,
      lines: [],
      source: 'none',
      format: 'none',
    );
  }

  bool get isEmpty =>
      !isInstrumental && lines.isEmpty && (plainLyrics == null || plainLyrics!.trim().isEmpty);

  /// Find active line index based on playback position
  int findActiveIndex(Duration position) {
    if (!isSynced || lines.isEmpty) return -1;
    if (position < lines.first.timestamp) return -1;

    for (int i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      if (position >= line.timestamp) {
        if (line.endTime != null && position > line.endTime! + const Duration(milliseconds: 500)) {
          // If past line endTime with a bit of tolerance and there's no next line active yet, keep it or check next
          if (i == lines.length - 1) return i;
        }
        return i;
      }
    }
    return -1;
  }
}

class TtmlParser {
  static Duration parseTime(String str) {
    var s = str.trim().replaceAll('s', '');
    final parts = s.split(':');
    if (parts.length == 3) {
      final hours = int.tryParse(parts[0]) ?? 0;
      final mins = int.tryParse(parts[1]) ?? 0;
      final secs = double.tryParse(parts[2]) ?? 0.0;
      final totalMillis = (hours * 3600000) + (mins * 60000) + (secs * 1000).round();
      return Duration(milliseconds: totalMillis);
    } else if (parts.length == 2) {
      final mins = int.tryParse(parts[0]) ?? 0;
      final secs = double.tryParse(parts[1]) ?? 0.0;
      final totalMillis = (mins * 60000) + (secs * 1000).round();
      return Duration(milliseconds: totalMillis);
    } else if (parts.length == 1) {
      final secs = double.tryParse(parts[0]) ?? 0.0;
      return Duration(milliseconds: (secs * 1000).round());
    }
    return Duration.zero;
  }

  static String _decodeEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&#38;', '&');
  }

  /// Parses a TTML string from binimum or Apple Music into [LyricsData].
  static LyricsData parse(String ttmlContent, {String source = 'binimum'}) {
    if (ttmlContent.trim().isEmpty) return LyricsData.empty();

    final lines = <LyricLine>[];
    bool anyWordTiming = false;

    // Match each <p ...>...</p> block
    final pRegex = RegExp(r'<p\b([^>]*)>(.*?)</p>', dotAll: true);
    // Only the innermost spans: Apple wraps background vocals in a span that
    // itself holds the word spans, and matching the wrapper would put the
    // inner opening tag into the lyrics text.
    final spanRegex = RegExp(r'<span\b([^>]*)>((?:(?!<span\b).)*?)</span>', dotAll: true);
    final tagRegex = RegExp(r'<[^>]*>');
    final beginAttrRegex = RegExp(r'begin=["\x27]([^"\x27]*)["\x27]');
    final endAttrRegex = RegExp(r'end=["\x27]([^"\x27]*)["\x27]');

    for (final pMatch in pRegex.allMatches(ttmlContent)) {
      final pAttrs = pMatch.group(1) ?? '';
      final pInner = pMatch.group(2) ?? '';

      final pBeginMatch = beginAttrRegex.firstMatch(pAttrs);
      final pEndMatch = endAttrRegex.firstMatch(pAttrs);

      final pBegin = pBeginMatch != null ? parseTime(pBeginMatch.group(1)!) : null;
      final pEnd = pEndMatch != null ? parseTime(pEndMatch.group(1)!) : null;

      final spanMatches = spanRegex.allMatches(pInner).toList();
      final words = <LyricWord>[];

      if (spanMatches.isNotEmpty) {
        for (final span in spanMatches) {
          final spanAttrs = span.group(1) ?? '';
          final spanText = _decodeEntities((span.group(2) ?? '').replaceAll(tagRegex, ''));

          final sBeginMatch = beginAttrRegex.firstMatch(spanAttrs);
          final sEndMatch = endAttrRegex.firstMatch(spanAttrs);

          if (sBeginMatch != null) {
            final sBegin = parseTime(sBeginMatch.group(1)!);
            final sEnd = sEndMatch != null ? parseTime(sEndMatch.group(1)!) : Duration.zero;
            words.add(LyricWord(begin: sBegin, end: sEnd, text: spanText));
          } else {
            words.add(LyricWord(
              begin: pBegin ?? Duration.zero,
              end: pEnd ?? Duration.zero,
              text: spanText,
            ));
          }
        }
      }

      String lineText;
      if (words.isNotEmpty) {
        anyWordTiming = true;
        final buffer = StringBuffer();
        for (int i = 0; i < words.length; i++) {
          final w = words[i].text.trim();
          if (w.isEmpty) continue;
          if (buffer.isNotEmpty && !RegExp(r"^[,.:;?!')\]}]").hasMatch(w)) {
            buffer.write(' ');
          }
          buffer.write(w);
        }
        lineText = buffer.toString().trim();
        if (lineText.isEmpty) {
          lineText = words.map((w) => w.text).join(' ').trim();
        }
      } else {
        lineText = _decodeEntities(pInner.replaceAll(RegExp(r'<[^>]*>'), '')).trim();
      }

      if (lineText.isNotEmpty) {
        final timestamp = pBegin ?? (words.isNotEmpty ? words.first.begin : Duration.zero);
        final end = pEnd ?? (words.isNotEmpty ? words.last.end : null);
        lines.add(LyricLine(
          timestamp: timestamp,
          endTime: end,
          text: lineText,
          words: words,
        ));
      }
    }

    final hasTimestamps = lines.any((l) => l.timestamp > Duration.zero || l.words.isNotEmpty);

    if (hasTimestamps) {
      lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return LyricsData(
        isSynced: true,
        isWordSynced: anyWordTiming,
        lines: lines,
        plainLyrics: lines.map((l) => l.text).join('\n'),
        source: source,
        format: anyWordTiming ? 'ttml_word' : 'ttml_line',
        rawContent: ttmlContent,
      );
    }

    // Fallback as plain lyrics
    final plainText = lines.map((l) => l.text).join('\n');
    return LyricsData(
      isSynced: false,
      isWordSynced: false,
      lines: lines,
      plainLyrics: plainText,
      source: source,
      format: 'plain',
      rawContent: ttmlContent,
    );
  }
}

class LrcParser {
  static final RegExp _timeRegex = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]');

  /// Parses an LRC string or plain lyrics into a structured [LyricsData].
  static LyricsData parse(String rawText, {String source = 'lrclib'}) {
    final text = rawText.trim();
    if (text.isEmpty) return LyricsData.empty();

    if (text.toLowerCase() == '[instrumental]' || text.toLowerCase() == 'instrumental') {
      return LyricsData.instrumental(source: source);
    }

    // Check if content is actually TTML XML
    if (text.contains('<tt') || text.contains('<timedtext')) {
      return TtmlParser.parse(text, source: source);
    }

    final parsedLines = <LyricLine>[];
    final plainLines = <String>[];
    bool hasTimeTags = false;

    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Ignore ID tags like [ar:Artist], [ti:Title], [al:Album], [length:...]
      if (RegExp(r'^\[[a-zA-Z]+:[^\]]*\]$').hasMatch(trimmed)) {
        continue;
      }

      final matches = _timeRegex.allMatches(trimmed).toList();
      if (matches.isNotEmpty) {
        hasTimeTags = true;
        final cleanText = trimmed.replaceAll(_timeRegex, '').trim();

        for (final match in matches) {
          final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
          final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
          final millisStr = match.group(3);

          int millis = 0;
          if (millisStr != null) {
            if (millisStr.length == 1) {
              millis = int.parse(millisStr) * 100;
            } else if (millisStr.length == 2) {
              millis = int.parse(millisStr) * 10;
            } else {
              millis = int.parse(millisStr.substring(0, 3));
            }
          }

          final timestamp = Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: millis,
          );

          parsedLines.add(LyricLine(timestamp: timestamp, text: cleanText));
        }
      } else {
        plainLines.add(trimmed);
      }
    }

    if (hasTimeTags && parsedLines.isNotEmpty) {
      parsedLines.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      return LyricsData(
        isSynced: true,
        isWordSynced: false,
        lines: parsedLines,
        plainLyrics: parsedLines.map((e) => e.text).where((s) => s.isNotEmpty).join('\n'),
        source: source,
        format: 'lrc',
        rawContent: text,
      );
    }

    final allPlain = plainLines.join('\n');
    return LyricsData(
      isSynced: false,
      isWordSynced: false,
      lines: plainLines.map((t) => LyricLine(timestamp: Duration.zero, text: t)).toList(),
      plainLyrics: allPlain,
      source: source,
      format: 'plain',
      rawContent: text,
    );
  }
}
