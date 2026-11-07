import 'package:flutter/foundation.dart';

/// [ValueNotifier] that reports when it goes from unobserved to observed
/// and back, so its owner can start and stop the work that produces its
/// value.
///
/// Its arm/disarm transitions are covered through
/// [TerminalSession.agentsNotifier] in
/// `test/features/terminal/data/terminal_session_agents_test.dart`.
///
/// Exists so agent polling is driven by demand rather than by the mere
/// existence of a connection: a session no widget is rendering must not
/// keep asking the host questions nobody reads. See
/// [TerminalSession._syncAgentPolling].
class ObservableValueNotifier<T> extends ValueNotifier<T> {
  ObservableValueNotifier(super.value, {required this.onObservedChanged});

  /// Called with true on the first listener and false when the last one
  /// leaves. Never called from [dispose], which clears listeners without
  /// routing through [removeListener].
  final void Function(bool observed) onObservedChanged;

  @override
  void addListener(VoidCallback listener) {
    final wasObserved = hasListeners;
    super.addListener(listener);
    if (!wasObserved && hasListeners) onObservedChanged(true);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) onObservedChanged(false);
  }
}
