/// Bounded memory of recent `requestId`s, for idempotent `send`.
library;

class RequestIdCache {
  RequestIdCache({this.capacity = 256});

  final int capacity;
  // Insertion order doubles as recency order.
  final _ids = <String>{};

  int get length => _ids.length;

  /// True when [id] was not known (and is now remembered); false for a
  /// duplicate, which also becomes the most recent.
  bool add(String id) {
    if (_ids.remove(id)) {
      _ids.add(id);
      return false;
    }
    _ids.add(id);
    if (_ids.length > capacity) _ids.remove(_ids.first);
    return true;
  }

  /// Releases [id], e.g. after a failed send, so the client can retry it.
  void forget(String id) => _ids.remove(id);
}
