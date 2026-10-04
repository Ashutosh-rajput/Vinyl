import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/presentation/widgets/stream_home_skeleton.dart';

void main() {
  testWidgets('the skeleton shows an outline of the page, not a spinner or text', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StreamHomeSkeleton())));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Text), findsNothing);
    expect(find.byType(Container), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('it pulses (the shade changes over time)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StreamHomeSkeleton())));
    Color shade() {
      final box = tester.widget<Container>(find.byType(Container).first);
      return (box.decoration as BoxDecoration).color!;
    }

    await tester.pump();
    final a = shade();
    await tester.pump(const Duration(milliseconds: 600));
    expect(shade(), isNot(a));
  });
}
