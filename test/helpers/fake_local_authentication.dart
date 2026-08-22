import 'package:local_auth/local_auth.dart';

/// Scripted [LocalAuthentication] stand-in for [BiometricService] tests.
///
/// Subclassing the real type exercises the production constructor injection:
/// `BiometricService` still depends on [LocalAuthentication], and no platform
/// channel is reached.
///
/// The three signals are deliberately independent, because on iOS they
/// disagree: `deviceSupportsBiometrics` (behind [canCheckBiometrics]) reports
/// true when biometric hardware exists but nothing is enrolled, while
/// `getEnrolledBiometrics` (behind [getAvailableBiometrics]) reports the empty
/// list for that same device.
class FakeLocalAuthentication extends LocalAuthentication {
  FakeLocalAuthentication({
    this.supportsBiometrics = true,
    this.deviceSupported = true,
    this.enrolled = const <BiometricType>[],
  });

  /// Value returned by [canCheckBiometrics].
  bool supportsBiometrics;

  /// Value returned by [isDeviceSupported].
  bool deviceSupported;

  /// Biometrics actually enrolled, returned by [getAvailableBiometrics].
  List<BiometricType> enrolled;

  @override
  Future<bool> get canCheckBiometrics async => supportsBiometrics;

  @override
  Future<bool> isDeviceSupported() async => deviceSupported;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => enrolled;
}
