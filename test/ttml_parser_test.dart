import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/data/models/lyrics_model.dart';

void main() {
  // Apple Music marks background vocals with a wrapper span that holds the
  // word spans, so spans are nested.
  const nested = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
<p begin="20.100" end="25.000">
<span begin="20.100" end="20.500">Gotta</span> <span begin="20.500" end="20.900">get</span> <span begin="20.900" end="21.200">you</span> <span begin="21.200" end="22.000">home</span>
<span ttm:role="x-bg" begin="22.920" end="24.000"><span begin="22.920"
end="23.250">(Come</span> <span begin="23.300" end="23.800">on,</span> <span begin="23.800" end="24.000">Foxy)</span></span>
</p>
<p begin="26.000" end="28.000"><span begin="26.000" end="27.000">Hold</span> <span begin="27.000" end="28.000">up</span></p>
</div></body></tt>''';

  test('nested background-vocal spans never leak markup into the lyrics', () {
    final data = TtmlParser.parse(nested);
    expect(data.lines, hasLength(2));
    for (final line in data.lines) {
      expect(line.text, isNot(contains('<')));
      expect(line.text, isNot(contains('begin=')));
      for (final word in line.words) {
        expect(word.text, isNot(contains('<')));
      }
    }
    expect(data.lines.first.text, 'Gotta get you home (Come on, Foxy)');
  });

  test('every word keeps its own timing, wrapper span or not', () {
    final line = TtmlParser.parse(nested).lines.first;
    expect(line.words.map((w) => w.text.trim()), ['Gotta', 'get', 'you', 'home', '(Come', 'on,', 'Foxy)']);
    expect(line.words[4].begin, const Duration(milliseconds: 22920));
    expect(line.words[4].end, const Duration(milliseconds: 23250));
    expect(line.words[6].begin, const Duration(milliseconds: 23800));
  });

  test('plain, unnested spans still parse', () {
    final line = TtmlParser.parse(nested).lines.last;
    expect(line.text, 'Hold up');
    expect(line.words, hasLength(2));
  });

  test('stray tags inside a span (like a line break) are dropped', () {
    final data = TtmlParser.parse(
      '<tt><body><p begin="1.000" end="3.000"><span begin="1.000" end="2.000">Hello<br/></span> <span begin="2.000" end="3.000">world</span></p></body></tt>',
    );
    expect(data.lines.single.text, 'Hello world');
  });
}
