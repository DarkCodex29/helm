import 'package:local_auth/local_auth.dart';
import 'package:helm/core/utils/logger.dart';

/// Biometric authentication types Helm distinguishes.
enum HelmBiometricType { face, fingerprint, none }

/// Wraps [LocalAuthentication] for biometric gate logic.
class BiometricService {
  BiometricService({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;
  static final _log = HelmLogger('BiometricService');

  // ── Public API ─────────────────────────────────────────────────────────

  /// Returns true if the device supports biometric authentication
  /// and has at least one biometric enrolled.
  ///
  /// Enrollment is read from [LocalAuthentication.getAvailableBiometrics], not
  /// from `canCheckBiometrics`. The latter answers "is biometric hardware
  /// present", and `local_auth_darwin` returns true from it even for
  /// `LAError.biometryNotEnrolled`. Gating on it would report a device with an
  /// unenrolled Face ID sensor as available, and — because [authenticate] is
  /// allowed to fall back to the device passcode — strand the user behind a
  /// modal they may have no way to satisfy.
  Future<bool> isAvailable() async {
    try {
      final isDeviceSupported = await _auth.isDeviceSupported();
      final enrolled = await _auth.getAvailableBiometrics();
      return isDeviceSupported && enrolled.isNotEmpty;
    } catch (e) {
      _log.e('isAvailable() error', e);
      return false;
    }
  }

  /// Returns the primary biometric type enrolled on the device.
  Future<HelmBiometricType> getBiometricType() async {
    try {
      final available = await _auth.getAvailableBiometrics();
      if (available.contains(BiometricType.face)) return HelmBiometricType.face;
      if (available.contains(BiometricType.fingerprint)) {
        return HelmBiometricType.fingerprint;
      }
      if (available.contains(BiometricType.strong)) {
        return HelmBiometricType.fingerprint;
      }
      return HelmBiometricType.none;
    } catch (e) {
      _log.e('getBiometricType() error', e);
      return HelmBiometricType.none;
    }
  }

  /// Prompts the user to authenticate.
  ///
  /// Returns true if authentication succeeded, false otherwise.
  Future<bool> authenticate() async {
    _log.i('Requesting biometric authentication');
    try {
      return await _auth.authenticate(
        localizedReason: 'Authenticate to access Helm',
        options: const AuthenticationOptions(
          biometricOnly: false, // fall back to PIN/passcode if needed
          stickyAuth: true,
        ),
      );
    } catch (e) {
      _log.e('authenticate() error', e);
      return false;
    }
  }
}
