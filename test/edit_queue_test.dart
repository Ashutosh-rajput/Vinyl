import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vinyl/core/utils/edit_queue.dart';

void main() {
  /// A playlist edited the way syncUpcoming does: remove the old upcoming
  /// songs (a pause), then add the new list (another pause).
  Future<void> replaceUpcoming(EditQueue queue, List<String> playlist, List<String> upcoming, {bool latestWins = true}) =>
      queue.run((superseded) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        playlist.removeRange(1, playlist.length);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (superseded()) return;
        playlist.addAll(upcoming);
      }, latestWins: latestWins);

  test('without the queue, overlapping replacements leave both lists in the playlist (the bug)', () async {
    final playlist = ['now'];
    Future<void> raw(List<String> upcoming) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      playlist.removeRange(1, playlist.length);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      playlist.addAll(upcoming);
    }

    await Future.wait([raw(['a1', 'a2']), raw(['b1', 'b2'])]);
    expect(playlist, ['now', 'a1', 'a2', 'b1', 'b2']); // two lists mixed
  });

  test('through the queue, overlapping replacements leave exactly the last list', () async {
    final queue = EditQueue();
    final playlist = ['now'];
    await Future.wait([
      replaceUpcoming(queue, playlist, ['a1', 'a2']),
      replaceUpcoming(queue, playlist, ['b1', 'b2']),
      replaceUpcoming(queue, playlist, ['c1', 'c2']),
    ]);
    expect(playlist, ['now', 'c1', 'c2']);
  });

  test('edits that are not replacements all run, in order', () async {
    final queue = EditQueue();
    final log = <String>[];
    Future<void> edit(String name) => queue.run((_) async {
          log.add('$name start');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          log.add('$name end');
        });
    await Future.wait([edit('a'), edit('b')]);
    expect(log, ['a start', 'a end', 'b start', 'b end']);
  });

  test('an append waits for a replacement already running, and survives it', () async {
    final queue = EditQueue();
    final playlist = ['now'];
    final replace = replaceUpcoming(queue, playlist, ['r1']);
    final append = queue.run((_) async => playlist.add('extra'));
    await Future.wait([replace, append]);
    expect(playlist, ['now', 'r1', 'extra']);
  });

  test('a failing edit does not block the ones behind it', () async {
    final queue = EditQueue();
    final ran = <String>[];
    await queue.run((_) async => throw StateError('boom'));
    await queue.run((_) async => ran.add('next'));
    expect(ran, ['next']);
  });

  test('replacements queued together: only the newest runs', () async {
    final queue = EditQueue();
    final ran = <String>[];
    final all = [
      for (final name in ['first', 'second', 'third'])
        queue.run((_) async => ran.add(name), latestWins: true),
    ];
    await Future.wait(all);
    expect(ran, ['third']);
  });

  test('a replacement already running finishes, then only the newest follows', () async {
    final queue = EditQueue();
    final ran = <String>[];
    final first = queue.run((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ran.add('first');
    }, latestWins: true);
    await Future<void>.delayed(const Duration(milliseconds: 2)); // 'first' has started
    final second = queue.run((_) async => ran.add('second'), latestWins: true);
    final third = queue.run((_) async => ran.add('third'), latestWins: true);
    await Future.wait([first, second, third]);
    expect(ran, ['first', 'third']);
  });
}
