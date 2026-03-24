/// Authentication state for the app biometric gate.
enum AuthState {
  /// Biometric check not yet performed.
  initial,

  /// User has successfully authenticated.
  unlocked,

  /// User is locked out — not yet authenticated.
  locked,

  /// Device has no biometric hardware or it is not enrolled.
  unavailable,
}
