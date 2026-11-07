/// Bounded memory of recent `requestId`s, for idempotent `send`.
///
/// An id moves through two stages. While its command is in flight it is
/// PINNED: it never counts against [capacity] and is never evicted, so a
/// retry of a slow command can never run twice however many other ids pass
/// meanwhile. Once the command completes, the id joins a bounded LRU of
/// finished ids. A failed command releases its id so the client can retry.
library;

class RequestIdCache {
  RequestIdCache({this.capacity = 256});

  /// Maximum number of COMPLETED ids remembered. In-flight ids are extra.
  final int capacity;

  final _inFlight = <String>{};
  // Insertion order doubles as recency order.
  final _completed = <String>{};

  int get length => _completed.length + _inFlight.length;

  /// Starts a command for [id]. True when it is new; false when it is in
  /// flight or already completed (a duplicate, which also refreshes its
  /// recency).
  bool begin(String id) {
    if (_inFlight.contains(id)) return false;
    if (_completed.remove(id)) {
      _completed.add(id);
      return false;
    }
    _inFlight.add(id);
    return true;
  }

  /// The command for [id] succeeded: remember it as a duplicate from now on.
  void complete(String id) {
    if (!_inFlight.remove(id)) return;
    _completed.add(id);
    if (_completed.length > capacity) _completed.remove(_completed.first);
  }

  /// The command for [id] failed: release it so the client can retry.
  void fail(String id) => _inFlight.remove(id);

  /// [begin] and [complete] in one step, for ids with no command to await.
  bool add(String id) {
    final isNew = begin(id);
    if (isNew) complete(id);
    return isNew;
  }

  /// Forgets [id] in either stage.
  void forget(String id) {
    _inFlight.remove(id);
    _completed.remove(id);
  }
}
