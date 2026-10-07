import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/presentation/bloc/player/player_bloc.dart';
import 'package:vinyl/presentation/bloc/player/player_event.dart';
import 'package:vinyl/presentation/bloc/player/player_state.dart';
import 'package:vinyl/presentation/widgets/swipe_to_skip.dart';

/// Records the events the widget sends, without any audio behind it.
class RecordingPlayerBloc extends Cubit<PlayerState> implements PlayerBloc {
  RecordingPlayerBloc() : super(const PlayerInitial());

  final List<PlayerEvent> events = [];

  @override
  void add(PlayerEvent event) => events.add(event);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late RecordingPlayerBloc bloc;
  late ValueNotifier<int> songId; // what the tile is showing
  int taps = 0;

  Future<void> pumpBar(WidgetTester tester, {Duration timeout = const Duration(milliseconds: 900)}) async {
    taps = 0;
    songId = ValueNotifier<int>(1);
    bloc = RecordingPlayerBloc();
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider<PlayerBloc>.value(
          value: bloc,
          child: Scaffold(
            body: Center(
              child: ValueListenableBuilder<int>(
                valueListenable: songId,
                builder: (context, id, _) => SwipeToSkip(
                  contentKey: id,
                  maxTravel: 90,
                  changeTimeout: timeout,
                  child: GestureDetector(
                    onTap: () => taps++,
                    child: SizedBox(
                      key: const Key('bar'),
                      width: 300,
                      height: 60,
                      child: ColoredBox(color: Colors.grey, child: Text('song $id')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  final bar = find.byKey(const Key('bar'));
  double barX(WidgetTester tester) => tester.getTopLeft(bar).dx;

  // A real finger sends many small moves, with real timestamps; one big jump
  // only crosses the touch-slop threshold, and time-zero events look
  // motionless to the velocity tracker.
  Future<void> moveInSteps(WidgetTester tester, TestGesture gesture, double totalDx) async {
    final steps = (totalDx.abs() / 5).ceil();
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(totalDx.sign * 5, 0), timeStamp: Duration(milliseconds: 8 * (i + 1)));
      await tester.pump(const Duration(milliseconds: 8));
    }
  }

  Future<void> swipe(WidgetTester tester, double dx) async {
    final gesture = await tester.startGesture(tester.getCenter(bar));
    await moveInSteps(tester, gesture, dx);
    await gesture.up();
  }

  // Advances the fake clock in 16ms frames, like a real device. A single big
  // pump would not do: an animation only starts moving on the frame after the
  // one that created it, and code that runs after an `await` (the wait for the
  // new song) needs frames in between to get its turn.
  Future<void> advance(WidgetTester tester, int ms) async {
    for (var elapsed = 0; elapsed < ms; elapsed += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  // Lets every slide and the wait-for-new-song timeout finish.
  Future<void> settle(WidgetTester tester) => advance(tester, 2500);

  testWidgets('swipe left asks for the next song', (tester) async {
    await pumpBar(tester);
    await swipe(tester, -150);
    expect(bloc.events, hasLength(1));
    expect(bloc.events.single, isA<NextSongEvent>());
    expect((bloc.events.single as NextSongEvent).isManualSkip, isTrue);
    await settle(tester);
  });

  testWidgets('a drag that starts at the screen edge is the back gesture and skips nothing', (tester) async {
    tester.view.physicalSize = const Size(300, 600); // the bar fills the screen width
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpBar(tester);
    final gesture = await tester.startGesture(Offset(5, tester.getCenter(bar).dy)); // at the left edge
    await moveInSteps(tester, gesture, 200);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(bloc.events, isEmpty);
    expect(barX(tester), moreOrLessEquals(tester.getTopLeft(bar).dx));
  });

  testWidgets('swipe right asks for the previous song', (tester) async {
    await pumpBar(tester);
    await swipe(tester, 150);
    expect(bloc.events.single, isA<PreviousSongEvent>());
    await settle(tester);
  });

  testWidgets('a quick flick counts even when the drag is short', (tester) async {
    await pumpBar(tester);
    await swipe(tester, -45); // 45px in ~70ms = ~640px/s
    expect(bloc.events.single, isA<NextSongEvent>());
    await settle(tester);
  });

  testWidgets('a small slow drag springs back and does nothing', (tester) async {
    await pumpBar(tester);
    final start = barX(tester);
    final gesture = await tester.startGesture(tester.getCenter(bar));
    await moveInSteps(tester, gesture, -45);
    expect(barX(tester), lessThan(start - 20)); // follows the finger
    await moveInSteps(tester, gesture, 20); // finish well under the swipe distance
    await gesture.up();
    await settle(tester);
    expect(barX(tester), closeTo(start, 0.5));
    expect(bloc.events, isEmpty);
  });

  testWidgets('while dragging, the bar never travels past maxTravel', (tester) async {
    await pumpBar(tester);
    final start = barX(tester);
    final gesture = await tester.startGesture(tester.getCenter(bar));
    await moveInSteps(tester, gesture, -60);
    await moveInSteps(tester, gesture, 20); // back off, still short of a swipe
    expect(start - barX(tester), lessThanOrEqualTo(90.5));
    await gesture.up();
    await settle(tester);
  });

  testWidgets('after a swipe the old tile slides fully out, the new one slides in and settles', (tester) async {
    await pumpBar(tester);
    final start = barX(tester);
    await swipe(tester, -150);

    // 1. the old tile leaves to the left, past the edge of its own box
    await advance(tester, 250);
    expect(barX(tester), lessThan(start - 250));

    // 2. the new song arrives: the new tile starts on the RIGHT...
    songId.value = 2;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(barX(tester), greaterThan(start + 100));
    expect(find.text('song 2'), findsOneWidget);

    // 3. ...glides in and sits exactly where the tile belongs
    await advance(tester, 150);
    final midway = barX(tester);
    expect(midway, lessThan(start + 290));
    expect(midway, greaterThan(start));
    await settle(tester);
    expect(barX(tester), closeTo(start, 0.5));
  });

  testWidgets('swiping right brings the new tile in from the LEFT', (tester) async {
    await pumpBar(tester);
    final start = barX(tester);
    await swipe(tester, 150);
    await advance(tester, 250);
    expect(barX(tester), greaterThan(start + 250)); // left the screen to the right
    songId.value = 0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(barX(tester), lessThan(start - 100)); // enters from the left
    await settle(tester);
    expect(barX(tester), closeTo(start, 0.5));
  });

  testWidgets('if no new song arrives, the tile slides back in with its current content', (tester) async {
    await pumpBar(tester, timeout: const Duration(milliseconds: 300));
    final start = barX(tester);
    await swipe(tester, -150);
    await advance(tester, 250);
    expect(barX(tester), lessThan(start - 250)); // out
    await advance(tester, 400); // timeout passes
    await settle(tester);
    expect(barX(tester), closeTo(start, 0.5)); // back in place
    expect(find.text('song 1'), findsOneWidget);
  });

  testWidgets('a song change with no swipe (autoplay) glides in from the right', (tester) async {
    await pumpBar(tester);
    final start = barX(tester);
    songId.value = 2;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(barX(tester), greaterThan(start + 40));
    expect(bloc.events, isEmpty);
    await settle(tester);
    expect(barX(tester), closeTo(start, 0.5));
  });

  testWidgets('swiping again while a slide is running is ignored', (tester) async {
    await pumpBar(tester);
    await swipe(tester, -150);
    await advance(tester, 100);
    await swipe(tester, -150); // mid-slide
    expect(bloc.events, hasLength(1));
    await settle(tester);
  });

  testWidgets('a tap still reaches the child (opens the player)', (tester) async {
    await pumpBar(tester);
    await tester.tap(bar);
    expect(taps, 1);
    expect(bloc.events, isEmpty);
  });
}
