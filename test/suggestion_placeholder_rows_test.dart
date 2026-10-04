import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/presentation/widgets/suggestion_placeholder_rows.dart';

Widget host({int? count}) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: count == null ? const SuggestionPlaceholderRows() : SuggestionPlaceholderRows(count: count),
        ),
      ),
    );

void main() {
  group('Suggestion placeholder rows (shown while the first songs are found)', () {
    testWidgets('they take up room straight away, so the page does not jump when songs arrive', (tester) async {
      await tester.pumpWidget(host());
      // 4 rows of about 62px each.
      expect(tester.getSize(find.byType(SuggestionPlaceholderRows)).height, greaterThan(200));
    });

    testWidgets('the number of rows can be chosen', (tester) async {
      await tester.pumpWidget(host(count: 2));
      final two = tester.getSize(find.byType(SuggestionPlaceholderRows)).height;
      await tester.pumpWidget(host(count: 6));
      final six = tester.getSize(find.byType(SuggestionPlaceholderRows)).height;
      expect(six, closeTo(two * 3, 1));
    });

    testWidgets('they pulse', (tester) async {
      await tester.pumpWidget(host());
      Color firstShade() {
        final box = tester.widget<Container>(find.descendant(of: find.byType(SuggestionPlaceholderRows), matching: find.byType(Container)).first);
        return (box.decoration as BoxDecoration).color!;
      }

      final before = firstShade();
      await tester.pump(const Duration(milliseconds: 550));
      expect(firstShade(), isNot(before));
    });

    testWidgets('they can be removed without errors (the songs arrived)', (tester) async {
      await tester.pumpWidget(host());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('songs'))));
      expect(tester.takeException(), isNull);
      expect(find.text('songs'), findsOneWidget);
    });
  });
}
