import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/router/auth_redirect.dart';
import 'package:helm/features/auth/domain/auth_state.dart';
import 'package:helm/features/notifications/domain/session_alert.dart';

void main() {
  group('resolveAuthRedirect - the gate itself, unchanged', () {
    test('holds still while the biometric answer is still loading', () {
      expect(
        resolveAuthRedirect(
          location: '/auth',
          authState: null,
          isLoading: true,
          hasSSHKey: true,
          pendingAlert: null,
        ),
        isNull,
      );
    });

    test('sends a locked user back to the gate from anywhere else', () {
      expect(
        resolveAuthRedirect(
          location: '/home',
          authState: AuthState.locked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: null,
        ),
        '/auth',
      );
    });

    test('sends an unlocked user with a key to home', () {
      expect(
        resolveAuthRedirect(
          location: '/auth',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: null,
        ),
        '/home',
      );
    });

    test('sends an unlocked user without a key to setup', () {
      expect(
        resolveAuthRedirect(
          location: '/auth',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: false,
          pendingAlert: null,
        ),
        '/setup',
      );
    });

    test('lets a device with no biometrics past the gate', () {
      expect(
        resolveAuthRedirect(
          location: '/auth',
          authState: AuthState.unavailable,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: null,
        ),
        '/home',
      );
    });

    test('leaves an already-legal location alone', () {
      expect(
        resolveAuthRedirect(
          location: '/settings',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: null,
        ),
        isNull,
      );
    });
  });

  group('resolveAuthRedirect - a notification survives the gate', () {
    const alert = SessionAlert(sessionName: 'helm-a1b2c3d4');

    test('lands on the session the notification named, not on home', () {
      // This is the whole defect the pending alert exists to fix. The gate
      // discards any location it is handed, so the request has to be held
      // OUTSIDE the router and read on the way out.
      expect(
        resolveAuthRedirect(
          location: '/auth',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: alert,
        ),
        '/session/helm-a1b2c3d4',
      );
    });

    test('a device with no biometrics reaches the session too', () {
      expect(
        resolveAuthRedirect(
          location: '/auth',
          authState: AuthState.unavailable,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: alert,
        ),
        '/session/helm-a1b2c3d4',
      );
    });

    test('a still-locked user is not let through early by a pending alert',
        () {
      // A notification must never become a way around the biometric gate.
      expect(
        resolveAuthRedirect(
          location: '/home',
          authState: AuthState.locked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: alert,
        ),
        '/auth',
      );
    });

    test('setup outranks the alert when there is no SSH key yet', () {
      // Without a key there is nothing to attach with, so the session
      // route would open a tab that cannot connect. Setup first.
      expect(
        resolveAuthRedirect(
          location: '/auth',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: false,
          pendingAlert: alert,
        ),
        '/setup',
      );
    });

    test('percent-encodes a session name that would reshape the path', () {
      expect(
        resolveAuthRedirect(
          location: '/auth',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: const SessionAlert(sessionName: 'team/build'),
        ),
        '/session/team%2Fbuild',
      );
    });

    test('does not re-redirect once it is already on the session route', () {
      // The alert is cleared by the screen that consumes it, not by this
      // function, so it is still set on the next pass. Returning the
      // current location from a redirect is what makes go_router assert.
      expect(
        resolveAuthRedirect(
          location: '/session/helm-a1b2c3d4',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: alert,
        ),
        isNull,
      );
    });

    test('a warm tap on Home reaches the session without a second path', () {
      // The app was already unlocked when the notification was tapped, so
      // it never passes the gate. Same rule, so there is exactly one place
      // a notification decides where to go.
      expect(
        resolveAuthRedirect(
          location: '/home',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: alert,
        ),
        '/session/helm-a1b2c3d4',
      );
    });

    test('Home is left alone when nothing is pending', () {
      expect(
        resolveAuthRedirect(
          location: '/home',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: null,
        ),
        isNull,
      );
    });

    test('a warm tap without an SSH key does not leave Home', () {
      expect(
        resolveAuthRedirect(
          location: '/home',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: false,
          pendingAlert: alert,
        ),
        isNull,
      );
    });

    test('does not hijack a location the user navigated to themselves', () {
      // Settings is reachable only by a deliberate tap. An alert that has
      // not been consumed yet must not yank the user out of it.
      expect(
        resolveAuthRedirect(
          location: '/settings',
          authState: AuthState.unlocked,
          isLoading: false,
          hasSSHKey: true,
          pendingAlert: alert,
        ),
        isNull,
      );
    });
  });
}
