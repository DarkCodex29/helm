import 'package:helm/features/auth/data/biometric_service.dart';

/// Scripted [BiometricService] stand-in for auth widget tests.
///
/// Subclassing the real type keeps the production provider signature honest:
/// `biometricServiceProvider` still exposes a [BiometricService], and every
/// method the auth gate calls is overridden here, so no `local_auth` platform
/// channel is ever touched.
///
/// [authenticateCallCount] is the assertion surface for the gate itself: the
/// screen must never prompt when biometrics are unavailable, and must prompt
/// exactly once per locked transition when they are.
class FakeBiometricService extends BiometricService {
  FakeBiometricService({
    this.available = true,
    this.authenticateResult = true,
  });

  /// Value returned by [isAvailable].
  bool available;

  /// Value returned by [authenticate].
  bool authenticateResult;

  /// Number of times [isAvailable] has been called.
  int isAvailableCallCount = 0;

  /// Number of times [authenticate] has been called.
  int authenticateCallCount = 0;

  @override
  Future<bool> isAvailable() async {
    isAvailableCallCount++;
    return available;
  }

  @override
  Future<bool> authenticate() async {
    authenticateCallCount++;
    return authenticateResult;
  }
}
