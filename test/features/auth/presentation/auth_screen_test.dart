import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/auth/presentation/auth_provider.dart';
import 'package:helm/features/auth/presentation/auth_screen.dart';

import '../../../helpers/fake_biometric_service.dart';

void main() {
  /// Mounts [AuthScreen] alone -- no router -- so these tests observe the
  /// screen's own decision to prompt, not the redirect that follows it.
  Future<void> pumpAuthScreen(
    WidgetTester tester,
    FakeBiometricService service,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [biometricServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: AuthScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  final authenticateButton = find.widgetWithText(
    ElevatedButton,
    'Authenticate',
  );

  group('AuthScreen biometric gate', () {
    testWidgets(
      'never prompts when biometrics are unavailable',
      (tester) async {
        final service = FakeBiometricService(available: false);

        await pumpAuthScreen(tester, service);

        expect(
          service.isAvailableCallCount,
          greaterThan(0),
          reason: 'availability must have been resolved for this to be a '
              'meaningful assertion',
        );
        expect(
          service.authenticateCallCount,
          0,
          reason: 'prompting with no biometric enrolled falls back to the '
              'device passcode, stranding the user behind a modal they '
              'cannot satisfy; the router redirect must run instead',
        );
      },
    );

    testWidgets(
      'prompts exactly once when biometrics are available',
      (tester) async {
        final service = FakeBiometricService(authenticateResult: true);

        await pumpAuthScreen(tester, service);

        expect(service.authenticateCallCount, 1);
      },
    );

    testWidgets(
      'does not re-prompt in a loop after a failed attempt',
      (tester) async {
        // A failed attempt lands the notifier back on AuthState.locked. A
        // trigger that reacts to every emission -- rather than to the first
        // locked resolution -- would prompt again here, forever.
        final service = FakeBiometricService(authenticateResult: false);

        await pumpAuthScreen(tester, service);
        await tester.pumpAndSettle();
        await tester.pumpAndSettle();

        expect(service.authenticateCallCount, 1);
      },
    );

    testWidgets(
      'prompts again when the retry button is tapped after a failure',
      (tester) async {
        final service = FakeBiometricService(authenticateResult: false);

        await pumpAuthScreen(tester, service);
        expect(service.authenticateCallCount, 1);
        expect(authenticateButton, findsOneWidget);

        await tester.tap(authenticateButton);
        await tester.pumpAndSettle();

        expect(service.authenticateCallCount, 2);
      },
    );

    testWidgets(
      'offers no retry button when biometrics are unavailable',
      (tester) async {
        final service = FakeBiometricService(available: false);

        await pumpAuthScreen(tester, service);

        expect(find.text('No biometrics available'), findsOneWidget);
        expect(authenticateButton, findsNothing);
      },
    );

    testWidgets(
      'prompts once when the notifier already resolved before it mounts',
      (tester) async {
        // The router reads authProvider in its redirect, and `lock()` can put
        // the notifier back on AuthState.locked while the screen is unmounted.
        // Either way the screen can mount onto an already-resolved provider,
        // so the trigger cannot rely on observing a later transition.
        final service = FakeBiometricService(authenticateResult: false);
        final scope = ProviderScope(
          overrides: [biometricServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(authProvider);
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        await tester.pumpWidget(scope);
        await tester.pumpAndSettle();
        expect(service.authenticateCallCount, 0);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [biometricServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(home: AuthScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(service.authenticateCallCount, 1);
      },
    );
  });
}
