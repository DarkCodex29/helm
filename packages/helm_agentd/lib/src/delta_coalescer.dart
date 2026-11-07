/// Joins streamed text deltas per message and releases them in batches.
///
/// The first buffered delta arms one timer (`interval`); when it fires, or
/// when [flush] is called, every buffer goes out in first-seen order. Text is
/// concatenated in arrival order and never dropped.
library;

import 'dart:async';

import 'pi_supervisor.dart' show TimerFactory;

class DeltaCoalescer {
  DeltaCoalescer({
    required this.onFlush,
    TimerFactory? timerFactory,
    this.interval = const Duration(milliseconds: 50),
  }) : _timer = timerFactory ?? Timer.new;

  final void Function(String messageId, String text) onFlush;
  final Duration interval;
  final TimerFactory _timer;

  // Map literals keep insertion order.
  final _buffers = <String, StringBuffer>{};
  Timer? _armed;
  var _disposed = false;

  void add(String messageId, String delta) {
    if (_disposed) return;
    (_buffers[messageId] ??= StringBuffer()).write(delta);
    _armed ??= _timer(interval, flush);
  }

  /// Emits everything buffered now.
  void flush() {
    _armed?.cancel();
    _armed = null;
    if (_buffers.isEmpty) return;
    final batch = Map.of(_buffers);
    _buffers.clear();
    for (final e in batch.entries) {
      onFlush(e.key, e.value.toString());
    }
  }

  void dispose() {
    _disposed = true;
    _armed?.cancel();
    _armed = null;
    _buffers.clear();
  }
}
