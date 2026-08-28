import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/session_hold/data/foreground_service_host.dart';
import 'package:helm/features/session_hold/domain/session_hold_state.dart';

/// How long a hold survives without the user coming back to helm.
///
/// ## Why a bound exists at all
///
/// Play requires a foreground service to stop when the work it names is
/// done, and "the user forgot" is the case with no natural end: an agent
/// session can emit output all night, so the connection being BUSY is not
/// evidence that anyone still wants it held. A hold with no deadline is
/// the shape reviewers reject, and the battery cost lands on someone who
/// is asleep.
///
/// ## Why four hours
///
/// The clock measures time since the user was last IN helm, not time since
/// the session was last active — see [SessionHoldController.onAppResumed].
/// That makes the question "how long an absence still means they are
/// coming back?"
///
///  * A meeting, a commute, a meal, a film — every ordinary reason to put
///    the phone down is comfortably under four hours, so the hold survives
///    all of them and does the job it was taken for.
///  * A night's sleep is not. An overnight hold tears itself down and the
///    user finds a normal app in the morning, which is the correct outcome:
///    the multiplexer session on the Mac is still there either way, so the
///    cost is one reconnect on a screen they were about to look at anyway.
///
/// It also sits under Android 15's six-hour cumulative cap on `dataSync`
/// and `mediaProcessing`. `connectedDevice` — the type helm declares — has
/// no timeout today, but choosing a value below the strictest cap the
/// platform currently applies to ANY type means a future Android that
/// extends caps would not silently start killing this feature daily.
///
/// The error is deliberately asymmetric. Expiring too early costs one
/// visible reconnect, which is exactly what the user has today and the
/// whole problem this feature exists to reduce. Expiring too late costs
/// battery on a phone in a drawer and a policy violation. So: err short.
const Duration kSessionHoldIdleTimeout = Duration(hours: 4);

/// The part of a live session a hold needs to see.
///
/// A record rather than `TerminalSession` on purpose. The controller needs
/// three facts — what the session is called, what host it is on, and
/// whether it is still up — and depending on the concrete class would drag
/// an SSH client, an SFTP service and a multiplexer probe into a unit test
/// that cares about none of them. `TerminalSession` satisfies this shape
/// as it already stands: `tmuxSessionName`, `profile.name`,
/// `statusNotifier`.
typedef HoldableSession = ({
  String sessionName,
  String hostName,
  ValueListenable<ConnectionStatus> status,
});

/// Keeps one session's connection alive while helm is in the background.
///
/// ## What is actually being held
///
/// Not the socket, and not a copy of it. The Android foreground service
/// behind [ForegroundServiceHost] runs in the app's own process, so
/// holding it holds the process, which holds the isolate that already owns
/// the `SSHClient`. See [PlatformForegroundServiceHost] for why that means
/// no second isolate and no second connection.
///
/// ## Every way a hold ends
///
/// All four are wired here, because a service that outlives its reason is
/// the precise thing Play rejects and the precise thing that drains a
/// battery:
///
///  1. The user taps the toggle — [release].
///  2. The user taps STOP in the notification — [ForegroundServiceHost.stopRequests].
///  3. Nobody comes back — [kSessionHoldIdleTimeout].
///  4. The session dies on its own — the [HoldableSession.status] listener.
///
/// And one way a hold ends WITHOUT this class being told: the OS takes the
/// service. [onAppResumed] exists for that, and is why [state] is asked of
/// the platform rather than remembered.
///
/// ## Two ways a hold STARTS, and why they are not one method
///
/// [hold] is the user asking, now, about the session in front of them.
/// [holdOnConnect] is a profile's stored preference being honoured on a
/// connect that just succeeded. They differ in exactly one rule — the
/// automatic one stands down for a session the user has turned off by
/// hand — and collapsing them would either lose that rule or apply it to
/// the tap that is supposed to override it.
class SessionHoldController {
  SessionHoldController({
    required ForegroundServiceHost host,
    Duration idleTimeout = kSessionHoldIdleTimeout,
  }) : _host = host,
       _idleTimeout = idleTimeout {
    _stopRequests = _host.stopRequests.listen((_) => _onStopRequested());
  }

  static final _log = HelmLogger('SessionHold');

  final ForegroundServiceHost _host;
  final Duration _idleTimeout;

  late final StreamSubscription<void> _stopRequests;

  final ValueNotifier<SessionHoldState> _state = ValueNotifier(
    const SessionHoldState.released(),
  );

  HoldableSession? _held;
  Timer? _idleTimer;
  var _disposed = false;

  /// Sessions the user has turned the hold off on by hand.
  ///
  /// ## What this is for
  ///
  /// A profile preference says what should happen on the NEXT connect. It
  /// is not a policy the app gets to enforce against the user in the
  /// moment: someone who taps the pin off is answering a question about
  /// the session they are looking at, and an automatic path that put the
  /// service straight back would make that tap do nothing visible.
  ///
  /// ## Why the status listenable is the key
  ///
  /// The same reason [hold] compares `identical(_held?.status, ...)`
  /// rather than session names: a label is not an identity. Two unnamed
  /// tabs on one profile share a label, so keying on the name would let a
  /// refusal taken on one silently suppress the other. Every
  /// `TerminalSession` owns its own `statusNotifier`, so that object's
  /// identity IS the session's identity — and `ValueNotifier` does not
  /// override `==`, so this Set compares by identity for free.
  ///
  /// ## How long an entry lasts
  ///
  /// As long as the session it names. A `TerminalSession` is built once
  /// per tab and disposed with it, so closing the tab and opening a new
  /// one produces a new notifier, which is not in here, and the profile
  /// preference is honoured again — the refusal is scoped to the thing
  /// the user was actually looking at when they took it. A dropped
  /// connection is NOT the user declining, so a disconnect clears nothing
  /// and the next connect on the same session is held again.
  ///
  /// Nothing prunes this. Each entry costs one reference to a small
  /// object and is only ever added by a deliberate tap, so a run of the
  /// app accumulates a handful at most. The alternative — a second,
  /// long-lived listener per declined session, kept alive to notice the
  /// tab closing — would have to solve exactly the disposed-notifier
  /// ordering problem [_detach] documents, which is a far worse trade
  /// than a few bytes.
  final Set<ValueListenable<ConnectionStatus>> _declined = {};

  /// The hold, for a widget to render from.
  ValueListenable<SessionHoldState> get stateNotifier => _state;

  SessionHoldState get state => _state.value;

  /// Takes a hold on [session] because the user asked for it, now.
  ///
  /// There is deliberately no path here from resuming or from an agent
  /// arriving. The only automatic path is [holdOnConnect], and it exists
  /// solely to honour a preference the user set on a profile — which is
  /// the user-initiated action Play's rules are about. Nothing else may
  /// start a service.
  Future<void> hold(HoldableSession session) async {
    if (_disposed) return;

    // A hold on a dead connection holds a process open for nothing. The
    // caller should not offer the control in this state either (see
    // `SessionHoldAction`), but the guard belongs here too: the status can
    // change between the frame that drew the button and the tap.
    if (session.status.value != ConnectionStatus.connected) {
      _log.w('Not holding ${session.sessionName}: it is not connected');
      return;
    }

    // Asking for a hold by hand is the exact opposite of the gesture that
    // recorded a refusal, so it clears one. Without this, a user who
    // turned the hold off and then changed their mind would keep the
    // hold they just re-took, but lose it silently on the next connect —
    // the preference they set would look broken for that session forever.
    _declined.remove(session.status);

    // Identity of the status listenable, NOT equality of the name.
    //
    // [HoldableSession.sessionName] is a LABEL — what the notification
    // calls this thing — and two different sessions can share one: an
    // unnamed tab has no multiplexer session name, so it falls back to
    // its profile's, and two unnamed tabs on one profile are then
    // indistinguishable by name. Keying on the label would make the
    // second hold a silent no-op that left the FIRST session held under a
    // notification the user would read as the second.
    //
    // Every `TerminalSession` owns its own `statusNotifier`, so its
    // identity is the session's identity.
    if (identical(_held?.status, session.status) && state.isHolding) {
      // Already held. Restarting the service would redraw the same
      // notification for the same session and reset a timer the user did
      // nothing to earn.
      return;
    }

    // Whatever was held before stops being watched NOW, before anything
    // is awaited. A second hold replaces the first rather than stacking:
    // there is one service and one notification, so two holds could not
    // both be true, and the one the notification names must be the one
    // this object thinks it has.
    _detach();

    final started = await _host.start(
      sessionName: session.sessionName,
      hostName: session.hostName,
    );

    if (!started) {
      // Stopped rather than assumed-not-started. This path is also
      // reached when a REPLACING hold fails, where a service for the
      // previous session may still be running — and "nothing is left
      // running" is the invariant that keeps this honest and keeps Play
      // satisfied.
      await _host.stop();
      _setState(const SessionHoldState.unavailable());
      _log.w('The platform would not hold ${session.sessionName}');
      return;
    }

    _held = session;
    session.status.addListener(_onSessionStatusChanged);
    _restartIdleTimer();
    _setState(SessionHoldState.held(session.sessionName));
    _log.i('Holding ${session.sessionName} on ${session.hostName}');
  }

  /// Takes a hold because [session]'s profile asked for one on connect.
  ///
  /// Call ONLY after a connect has actually succeeded. Everything [hold]
  /// refuses, this refuses too — a session that is not connected, a
  /// platform that says no — and it adds one rule of its own: a session
  /// the user has turned off by hand is left alone. See [_declined] for
  /// why that refusal is keyed on the session and how long it lasts.
  ///
  /// ### Why this is a start and never a restart
  ///
  /// Nothing here reacts to a session's status changing, or to the app
  /// resuming, or to a timer. It runs once, on the connect that just
  /// completed, and then has no further opinion. That is what keeps
  /// [kSessionHoldIdleTimeout] meaningful: a hold that re-armed itself
  /// after the bound expired would have deleted the bound while appearing
  /// to still have one.
  Future<void> holdOnConnect(HoldableSession session) async {
    if (_disposed) return;

    if (_declined.contains(session.status)) {
      _log.i(
        'Not holding ${session.sessionName}: the user turned this '
        'session\'s hold off by hand',
      );
      return;
    }

    await hold(session);
  }

  /// Drops the hold and stops the service at the user's request.
  ///
  /// This is the toolbar pin and the notification's STOP action — two
  /// surfaces for one gesture, so both record the same refusal. A control
  /// the user can reach from outside the app must not mean less than one
  /// they can only reach inside it.
  Future<void> release() => _release(declineFurtherAutoHolds: true);

  /// Reconciles this object's belief with the platform's reality.
  ///
  /// Call when helm returns to the foreground. Does two jobs that both
  /// depend on the user being present:
  ///
  ///  * Restarts the idle clock. They came back, so the hold did what it
  ///    was taken for and a fresh absence begins.
  ///  * Asks whether the service is still there. A foreground service is
  ///    hard to kill but not impossible, and nothing announces it when an
  ///    OEM power manager does. Without this, helm would keep drawing a
  ///    lit toggle over a connection that dropped hours ago — which is
  ///    worse than never having offered the hold, because the user would
  ///    have believed it.
  Future<void> onAppResumed() async {
    if (_disposed || !state.isHolding) return;

    if (await _host.isRunning()) {
      _restartIdleTimer();
      return;
    }

    _log.w('The hold on ${_held?.sessionName} is gone; the OS took it');
    _detach();
    _setState(const SessionHoldState.released());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stopRequests.cancel();
    _detach();
    // Every entry names a session that is going away with this object.
    _declined.clear();
    // The process is going away and the service would outlive it as a
    // notification for a session nothing is attached to any more.
    await _host.stop();
    _state.value = const SessionHoldState.released();
    _state.dispose();
  }

  // ── Private ────────────────────────────────────────────────────────────

  /// The user tapped STOP in the notification.
  ///
  /// The service has already stopped itself by the time this arrives —
  /// `SessionHoldService` handles its own action before telling Dart — so
  /// this is only state catching up. [release] is still the right call
  /// because its `stop` is idempotent, and going through one teardown path
  /// is what stops the two from drifting.
  void _onStopRequested() {
    if (_disposed || !state.isHolding) return;
    _log.i('STOP tapped in the notification; releasing the hold');
    unawaited(release());
  }

  /// The held session changed status. Anything but connected ends the hold.
  ///
  /// [_detach] runs SYNCHRONOUSLY here, and that ordering is load-bearing.
  /// `TerminalSession.dispose` sets `statusNotifier.value` to
  /// `disconnected` and then disposes the notifier in the same call. A
  /// listener that deferred its own removal to a microtask would call
  /// `removeListener` on a disposed `ChangeNotifier`, which throws in
  /// debug — turning an ordinary tab close into a crash.
  void _onSessionStatusChanged() {
    final held = _held;
    if (held == null) return;
    if (held.status.value == ConnectionStatus.connected) return;

    _log.i('${held.sessionName} disconnected; releasing the hold');
    _detach();
    _setState(const SessionHoldState.released());
    unawaited(_host.stop());
  }

  void _onIdleTimeout() {
    _log.i(
      'No one returned to helm in $_idleTimeout; releasing '
      'the hold on ${_held?.sessionName}',
    );
    // Records NO refusal: nobody declined anything here. helm gave up on
    // its own because the user was absent, and treating that as a decision
    // they took would silently disable their profile preference for a
    // session they never touched.
    unawaited(_release(declineFurtherAutoHolds: false));
  }

  /// The one teardown both public stop paths go through.
  ///
  /// [declineFurtherAutoHolds] separates "the user said stop" from "helm
  /// stopped by itself". Only the first may suppress a later automatic
  /// hold; see [_declined].
  Future<void> _release({required bool declineFurtherAutoHolds}) async {
    // Captured BEFORE `_detach` clears it — the refusal has to name the
    // session that was actually being held.
    final released = _held;

    _detach();
    await _host.stop();
    _setState(const SessionHoldState.released());

    if (declineFurtherAutoHolds && released != null) {
      _declined.add(released.status);
    }
  }

  /// Stops watching and stops counting. Does NOT touch the service, so it
  /// is safe to call from a synchronous listener.
  void _detach() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _held?.status.removeListener(_onSessionStatusChanged);
    _held = null;
  }

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, _onIdleTimeout);
  }

  void _setState(SessionHoldState next) {
    if (_disposed) return;
    _state.value = next;
  }
}
