import 'dart:async';

/// Runs asynchronous edits of one shared thing (the player's playlist) strictly
/// one after another.
///
/// An edit like "remove everything after the current song, then add these"
/// takes several awaits. Two of them running at once interleave: both remove,
/// then both add, and the playlist ends up holding both lists. Run through an
/// [EditQueue], each edit starts only when the previous one has finished.
///
/// An edit that replaces the earlier ones (`latestWins`) is skipped if a newer
/// `latestWins` edit has been queued behind it, and can stop early by checking
/// `superseded()`, so a burst of replacements does the work only once.
class EditQueue {
  Future<void> _tail = Future<void>.value();
  int _latest = 0;

  Future<void> run(
    Future<void> Function(bool Function() superseded) edit, {
    bool latestWins = false,
  }) {
    final mine = latestWins ? ++_latest : _latest;
    bool superseded() => latestWins && mine != _latest;

    final done = _tail.then((_) async {
      if (superseded()) return;
      await edit(superseded);
    }).catchError((Object _) {}); // one failed edit must not block the next
    _tail = done;
    return done;
  }
}
