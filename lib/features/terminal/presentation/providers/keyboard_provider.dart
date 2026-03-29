import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class KeyboardState {
  const KeyboardState({
    this.visible = true,
    this.ctrlHeld = false,
    this.shiftHeld = false,
    this.numLayer = false,
  });

  final bool visible;
  final bool ctrlHeld;
  final bool shiftHeld;
  final bool numLayer;

  KeyboardState copyWith({
    bool? visible,
    bool? ctrlHeld,
    bool? shiftHeld,
    bool? numLayer,
  }) {
    return KeyboardState(
      visible: visible ?? this.visible,
      ctrlHeld: ctrlHeld ?? this.ctrlHeld,
      shiftHeld: shiftHeld ?? this.shiftHeld,
      numLayer: numLayer ?? this.numLayer,
    );
  }
}

class KeyboardNotifier extends Notifier<KeyboardState> {
  @override
  KeyboardState build() => const KeyboardState();

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
