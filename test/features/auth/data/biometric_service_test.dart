import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/auth/data/biometric_service.dart';
import 'package:local_auth/local_auth.dart';

import '../../../helpers/fake_local_authentication.dart';

void main() {
  group('isAvailable', () {
    test('is true when a biometric is actually enrolled', () async {
      final auth = FakeLocalAuthentication(
        enrolled: const [BiometricType.face],
      );

      expect(await BiometricService(auth: auth).isAvailable(), isTrue);
    });

    test(
      'is false when biometric hardware exists but nothing is enrolled',
      () async {
        // The state that locks the user out. `local_auth_darwin` returns true
        // from deviceSupportsBiometrics() for LAError.biometryNotEnrolled --
        // "hardware is present" -- so canCheckBiometrics cannot gate the
        // prompt. Only the enrolled list distinguishes this from a device the
        // user can actually authenticate on.
        final auth = FakeLocalAuthentication(
          supportsBiometrics: true,
          deviceSupported: true,
          enrolled: const [],
        );

        expect(await BiometricService(auth: auth).isAvailable(), isFalse);
      },
    );

    test('is false when the device is not supported at all', () async {
      final auth = FakeLocalAuthentication(
        supportsBiometrics: false,
        deviceSupported: false,
        enrolled: const [],
      );

      expect(await BiometricService(auth: auth).isAvailable(), isFalse);
    });

    test(
      'is false when the device cannot fall back to device credentials',
      () async {
        final auth = FakeLocalAuthentication(
          deviceSupported: false,
          enrolled: const [BiometricType.fingerprint],
        );

        expect(await BiometricService(auth: auth).isAvailable(), isFalse);
      },
    );
  });

  group('getBiometricType', () {
    test('reports face when Face ID is enrolled', () async {
      final auth = FakeLocalAuthentication(
        enrolled: const [BiometricType.face],
      );

      expect(
        await BiometricService(auth: auth).getBiometricType(),
        HelmBiometricType.face,
      );
    });

    test('reports none when nothing is enrolled', () async {
      final auth = FakeLocalAuthentication(enrolled: const []);

      expect(
        await BiometricService(auth: auth).getBiometricType(),
        HelmBiometricType.none,
      );
    });
  });
}
