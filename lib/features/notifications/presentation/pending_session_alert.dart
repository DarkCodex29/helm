import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/notifications/domain/session_alert.dart';

/// The session a notification asked for, held until something can honour it.
///
/// ## Why this exists outside the router
///
/// `GoRouter`'s redirect discards the location it is given: an
/// unauthenticated request to anything becomes `/auth`, and unlocking
/// sends the user to `/home` or `/setup`. Nothing in that path remembers
/// what was originally wanted, so setting `initialLocation` from a
/// notification payload has no effect whatsoever — the redirect overwrites
/// it on its first pass, before a single frame is drawn.
///
/// The request therefore has to live somewhere the gate cannot reach, be
/// READ on the way out of the gate, and be cleared exactly once by
/// whatever finally acts on it. That is this provider.
///
/// ## Read by two, cleared by one
///
/// `resolveAuthRedirect` reads it — repeatedly, because a redirect runs
/// more than once per navigation — and never clears it. `HomeScreen`
/// clears it with [take] when it has actually opened the session. Putting
/// the clear in the redirect would make the outcome depend on which pass
/// happened to run first.
class PendingSessionAlert extends Notifier<SessionAlert?> {
  @override
  SessionAlert? build() => null;

  /// Records [alert] as the thing to open next.
  ///
  /// A newer alert replaces an older one that was never consumed. Two
  /// notifications arriving before either is honoured means the second is
  /// the current situation, and opening the stale one would be answering
  /// a question that has already moved on.
  void remember(SessionAlert alert) => state = alert;

  /// Returns the pending alert and clears it, so it is honoured once.
  SessionAlert? take() {
    final alert = state;
    state = null;
    return alert;
  }
}

final pendingSessionAlertProvider =
    NotifierProvider<PendingSessionAlert, SessionAlert?>(
      PendingSessionAlert.new,
    );
