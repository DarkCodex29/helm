import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/terminal/data/keyboard_geometry_store.dart';

@immutable
class KeyboardState {
  const KeyboardState({
    this.visible = true,
    this.ctrlHeld = false,
    this.shiftHeld = false,
    this.numLayer = false,
    this.geometry,
  });

  final bool visible;
  final bool ctrlHeld;
  final bool shiftHeld;
  final bool numLayer;
  final KeyboardGeometry? geometry;

  KeyboardState copyWith({
    bool? visible,
    bool? ctrlHeld,
    bool? shiftHeld,
    bool? numLayer,
    KeyboardGeometry? geometry,
    bool resetGeometry = false,
  }) {
    return KeyboardState(
      visible: visible ?? this.visible,
      ctrlHeld: ctrlHeld ?? this.ctrlHeld,
      shiftHeld: shiftHeld ?? this.shiftHeld,
      numLayer: numLayer ?? this.numLayer,
      geometry: resetGeometry ? null : geometry ?? this.geometry,
    );
  }
}

class KeyboardNotifier extends Notifier<KeyboardState> {
  Object _loadToken = Object();
  Future<void> _writes = Future.value();

  @override
  KeyboardState build() {
    final token = _loadToken = Object();
    final store = ref.watch(keyboardGeometryStoreProvider);
    ref.onDispose(() => _loadToken = Object());
    store.read().then((geometry) {
      if (identical(token, _loadToken) && geometry != null) {
        state = state.copyWith(geometry: geometry);
      }
    });
    return const KeyboardState();
  }

  void setGeometry(KeyboardGeometry geometry) {
    _loadToken = Object(); // A late read must not undo a user's drag/reset.
    state = state.copyWith(geometry: geometry);
  }

  Future<void> saveGeometry() {
    final geometry = state.geometry;
    final store = ref.read(keyboardGeometryStoreProvider);
    // Serialize gesture-end writes and reset so stale writes cannot win.
    return _writes = _writes.then((_) async {
      if (geometry != null) await store.write(geometry);
    });
  }

  Future<void> resetGeometry() {
    _loadToken = Object();
    state = state.copyWith(resetGeometry: true);
    final store = ref.read(keyboardGeometryStoreProvider);
    return _writes = _writes.then((_) => store.clear());
  }

  void toggleVisibility() => state = state.copyWith(visible: !state.visible);
  void toggleCtrl() => state = state.copyWith(ctrlHeld: !state.ctrlHeld);
  void toggleShift() => state = state.copyWith(shiftHeld: !state.shiftHeld);
  void toggleNumLayer() => state = state.copyWith(numLayer: !state.numLayer);
  void resetModifiers() =>
      state = state.copyWith(ctrlHeld: false, shiftHeld: false);
}

final keyboardProvider = NotifierProvider<KeyboardNotifier, KeyboardState>(
  KeyboardNotifier.new,
);
