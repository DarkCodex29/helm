/// What helm is currently doing to keep a session attached.
///
/// The three values are deliberately not two. "Not holding" and "asked to
/// hold and the platform would not" are different situations for the user:
/// the first is the resting state and invites a tap, the second means the
/// tap already happened and produced nothing, and rendering them the same
/// would offer a button that silently does nothing every time.
enum SessionHoldStatus {
  /// No hold is in place. Backgrounding helm will drop the connection.
  released,

  /// A foreground service is running and naming a session.
  held,

  /// The platform refused to start or keep the service.
  ///
  /// Reached on a device whose OEM power manager overrode the request, and
  /// on any platform with no foreground services at all. Never a throw:
  /// helm works without a hold, it just reconnects on resume as it always
  /// did.
  unavailable,
}

/// The hold, as the UI needs to see it.
///
/// Carries [sessionName] rather than a bool because the notification and
/// the button must name the SAME session, and the only way to guarantee
/// that is for one value to feed both. A hold that knows it is on but not
/// what it is on is exactly the state Play's "perceptible" requirement
/// exists to forbid.
class SessionHoldState {
  const SessionHoldState._(this.status, this.sessionName);

  /// Nothing held.
  const SessionHoldState.released()
    : this._(SessionHoldStatus.released, null);

  /// [sessionName] is being held open.
  const SessionHoldState.held(String sessionName)
    : this._(SessionHoldStatus.held, sessionName);

  /// The platform would not hold anything.
  const SessionHoldState.unavailable()
    : this._(SessionHoldStatus.unavailable, null);

  final SessionHoldStatus status;

  /// The multiplexer session being held, and null unless [status] is
  /// [SessionHoldStatus.held].
  final String? sessionName;

  /// True only while a service is actually believed to be running.
  ///
  /// Named so that reading it out loud states the claim it makes, because
  /// this is the value a toggle renders from and an over-eager one would
  /// tell the user a dropped connection is still alive.
  bool get isHolding => status == SessionHoldStatus.held;

  @override
  bool operator ==(Object other) =>
      other is SessionHoldState &&
      other.status == status &&
      other.sessionName == sessionName;

  @override
  int get hashCode => Object.hash(status, sessionName);

  @override
  String toString() => sessionName == null
      ? 'SessionHoldState(${status.name})'
      : 'SessionHoldState(${status.name}, $sessionName)';
}
