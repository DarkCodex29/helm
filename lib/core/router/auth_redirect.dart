import 'package:helm/features/auth/domain/auth_state.dart';
import 'package:helm/features/notifications/domain/session_alert.dart';

/// Locations the gate itself owns.
const String kAuthLocation = '/auth';
const String kHomeLocation = '/home';
const String kSetupLocation = '/setup';

/// Where the router should send a request for [location], or null to leave
/// it alone.
///
/// Pure on purpose, in the same spirit as `decideAutoConnect`: the five
/// inputs are everything the rule depends on, so every branch — including
/// the ones a notification reaches — is testable without a Riverpod
/// container, a biometric sensor, or a running `GoRouter`.
///
/// ## Why a notification needs a rule here at all
///
/// The gate DISCARDS the location it was asked for. An unauthenticated
/// request to anything is rewritten to [kAuthLocation], and on unlock the
/// user is sent to [kHomeLocation] or [kSetupLocation] — neither of which
/// remembers what was originally wanted. Setting the router's
/// `initialLocation` from a notification payload therefore does nothing at
/// all: the redirect overwrites it on the first pass.
///
/// So the request is held OUTSIDE the router, as [pendingAlert], and read
/// here on the way out of the gate. The gate is not weakened to do it:
/// [pendingAlert] is consulted only on the branch that was already going
/// to let the user through.
///
/// ## Why this does not clear the alert
///
/// A redirect runs more than once per navigation, and go_router asserts
/// when a redirect returns the location it was given. Clearing here would
/// make the outcome depend on which pass ran first. Instead the alert is
/// read as many times as needed and cleared exactly once, by the screen
/// that actually opens the session — see `HomeScreen.requestedSessionName`.
/// That is also why [location] is checked before returning: once the
/// router is ON the session route, this must answer null.
String? resolveAuthRedirect({
  required String location,
  required AuthState? authState,
  required bool isLoading,
  required bool hasSSHKey,
  required SessionAlert? pendingAlert,
}) {
  // Nothing is known yet. Redirecting on an unresolved answer would send
  // the user to the gate and then bounce them straight back out of it.
  if (isLoading) return null;

  final isAuthenticated = authState == AuthState.unlocked;
  final isUnavailable = authState == AuthState.unavailable;

  if (!isAuthenticated && !isUnavailable && location != kAuthLocation) {
    return kAuthLocation;
  }

  if ((isAuthenticated || isUnavailable) && location == kAuthLocation) {
    // Setup outranks the alert deliberately. Without a key there is
    // nothing to attach with, so honouring the notification would open a
    // tab that can only fail — and it would do so INSTEAD of showing the
    // screen that fixes the problem.
    if (!hasSSHKey) return kSetupLocation;

    return pendingAlert?.routeLocation ?? kHomeLocation;
  }

  // The warm-tap case: the app was already unlocked and sitting on Home
  // when the notification was tapped, so it never passes the gate at all.
  // Handled by the same rule rather than by a second navigation path, so
  // there is exactly one place a notification can decide where to go.
  //
  // Only from Home, and that asymmetry is deliberate. Home is where the
  // app puts the user, not where the user chose to be, so replacing it
  // costs nothing. Settings is reached by a deliberate tap, and an alert
  // that has been sitting unconsumed must not yank someone out of it.
  if (isAuthenticated || isUnavailable) {
    if (location == kHomeLocation && pendingAlert != null && hasSSHKey) {
      return pendingAlert.routeLocation;
    }
  }

  return null;
}
