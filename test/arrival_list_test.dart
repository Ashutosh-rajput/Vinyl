import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/presentation/widgets/arrival_list.dart';

/// Rows are 50px tall, so positions are easy to reason about.
Widget host(List<String> ids, {bool animateInitial = false}) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ArrivalList<String>(
            items: ids,
            idOf: (id) => id,
            animateInitial: animateInitial,
            itemBuilder: (context, id) => SizedBox(key: Key('row-$id'), height: 50, child: Text(id)),
          ),
        ),
      ),
    );

Finder row(String id) => find.byKey(Key('row-$id'));

/// Advances the fake clock in 16ms frames, like a real device.
Future<void> advance(WidgetTester tester, int ms) async {
  for (var elapsed = 0; elapsed < ms; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('Songs that arrive later glide in', () {
    testWidgets('the first list appears at once, in place', (tester) async {
      await tester.pumpWidget(host(['b', 'c']));
      expect(tester.getTopLeft(row('b')).dy, 0);
      expect(tester.getTopLeft(row('c')).dy, 50);
      expect(tester.getSize(row('b')).height, 50);
    });

    testWidgets('a new row grows in at the top and pushes the others down smoothly', (tester) async {
      await tester.pumpWidget(host(['b', 'c']));
      await tester.pumpWidget(host(['a', 'b', 'c'])); // 'a' arrives
      await advance(tester, 16);

      // Just after arriving: the new row has hardly any room yet...
      final bEarly = tester.getTopLeft(row('b')).dy;
      expect(bEarly, lessThan(25));

      // ...partway through, the others have moved partway down...
      await advance(tester, 200);
      final bMid = tester.getTopLeft(row('b')).dy;
      expect(bMid, greaterThan(bEarly));
      expect(bMid, lessThan(50));

      // ...and when it has settled everything is in its final place.
      await advance(tester, 2000);
      expect(tester.getTopLeft(row('a')).dy, 0);
      expect(tester.getTopLeft(row('b')).dy, 50);
      expect(tester.getTopLeft(row('c')).dy, 100);
    });

    testWidgets('a new row can arrive in the middle, between existing rows', (tester) async {
      await tester.pumpWidget(host(['a', 'c']));
      final aTop = tester.getTopLeft(row('a')).dy;
      await tester.pumpWidget(host(['a', 'b', 'c']));
      await advance(tester, 200);
      expect(tester.getTopLeft(row('a')).dy, aTop); // rows above it do not move
      final cMid = tester.getTopLeft(row('c')).dy;
      expect(cMid, greaterThan(50));
      expect(cMid, lessThan(100)); // rows below it are on their way down
      await advance(tester, 2000);
      expect(tester.getTopLeft(row('c')).dy, 100);
    });

    testWidgets('the new row fades in', (tester) async {
      await tester.pumpWidget(host(['b']));
      await tester.pumpWidget(host(['a', 'b']));
      await advance(tester, 16);
      double opacityOfA() => tester.widget<FadeTransition>(find.ancestor(of: row('a'), matching: find.byType(FadeTransition)).first).opacity.value;
      final early = opacityOfA();
      await advance(tester, 400);
      final later = opacityOfA();
      expect(later, greaterThan(early));
      await advance(tester, 2000);
      expect(opacityOfA(), 1.0);
    });

    testWidgets('rows that were already there are not animated again', (tester) async {
      await tester.pumpWidget(host(['b', 'c']));
      await tester.pumpWidget(host(['a', 'b', 'c']));
      await advance(tester, 100);
      // b and c keep their own size and stay fully visible throughout.
      expect(tester.getSize(row('b')).height, 50);
      expect(tester.getSize(row('c')).height, 50);
      final fadeOfB = tester.widget<FadeTransition>(find.ancestor(of: row('b'), matching: find.byType(FadeTransition)).first);
      expect(fadeOfB.opacity.value, 1.0);
    });

    testWidgets('re-ordering the list does not re-animate rows it already showed', (tester) async {
      await tester.pumpWidget(host(['a', 'b', 'c']));
      await tester.pumpWidget(host(['c', 'a', 'b']));
      await advance(tester, 16);
      for (final id in ['a', 'b', 'c']) {
        expect(tester.getSize(row(id)).height, 50);
      }
      expect(tester.getTopLeft(row('c')).dy, 0);
    });

    testWidgets('several rows arriving together all animate in', (tester) async {
      await tester.pumpWidget(host(['z']));
      await tester.pumpWidget(host(['x', 'y', 'z']));
      await advance(tester, 3800);
      expect(tester.getTopLeft(row('x')).dy, 0);
      expect(tester.getTopLeft(row('y')).dy, 50);
      expect(tester.getTopLeft(row('z')).dy, 100);
    });

    testWidgets('a row that leaves the list is removed', (tester) async {
      await tester.pumpWidget(host(['a', 'b', 'c']));
      await tester.pumpWidget(host(['a', 'c']));
      await tester.pump();
      expect(row('b'), findsNothing);
      expect(tester.getTopLeft(row('c')).dy, 50);
    });

    testWidgets('with animateInitial, the first rows come in one after another', (tester) async {
      await tester.pumpWidget(host(['a', 'b', 'c'], animateInitial: true));
      await advance(tester, 16);
      // 'a' starts first, so it is further along than 'c'.
      double heightOf(String id) => tester.getSize(find.ancestor(of: row(id), matching: find.byType(SizeTransition)).first).height;
      await advance(tester, 150);
      expect(heightOf('a'), greaterThan(heightOf('c')));
      await advance(tester, 3000);
      expect(heightOf('a'), 50);
      expect(heightOf('c'), 50);
    });

    testWidgets('the glow behind a new row fades away', (tester) async {
      await tester.pumpWidget(host(['b']));
      await tester.pumpWidget(host(['a', 'b']));
      await advance(tester, 100);
      Color glow() {
        final rowStack = find.ancestor(of: row('a'), matching: find.byType(Stack)).first;
        final box = tester.widget<DecoratedBox>(
          find.descendant(of: rowStack, matching: find.byKey(const ValueKey('arrival-glow'))).first,
        );
        return (box.decoration as BoxDecoration).color!;
      }

      expect(glow().a, greaterThan(0.05));
      await advance(tester, 3800);
      expect(glow().a, lessThan(0.01));
    });
    testWidgets('rows with a ListTile do not trigger the "coloured ancestor" assertion', (tester) async {
      Widget tiles(List<String> ids) => MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ArrivalList<String>(
                  items: ids,
                  idOf: (id) => id,
                  animateInitial: true,
                  itemBuilder: (context, id) => ListTile(title: Text(id), onTap: () {}),
                ),
              ),
            ),
          );
      await tester.pumpWidget(tiles(['b', 'c']));
      await advance(tester, 1500);
      await tester.pumpWidget(tiles(['a', 'b', 'c'])); // a new row arrives, with its glow
      await advance(tester, 300);
      expect(tester.takeException(), isNull);
      await advance(tester, 3800);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap on an arriving row still works', (tester) async {
      var taps = 0;
      Widget tiles(List<String> ids) => MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ArrivalList<String>(
                  items: ids,
                  idOf: (id) => id,
                  itemBuilder: (context, id) => ListTile(title: Text(id), onTap: () => taps++),
                ),
              ),
            ),
          );
      await tester.pumpWidget(tiles(['b']));
      await tester.pumpWidget(tiles(['a', 'b']));
      await advance(tester, 3800);
      await tester.tap(find.text('a')); // the glow overlay must not swallow the tap
      expect(taps, 1);
    });
  });
}
