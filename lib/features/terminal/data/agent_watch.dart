import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/observable_value_notifier.dart';
import 'package:helm/features/terminal/data/terminal_session_timings.dart';

/// The agent-tracking loop of one [TerminalSession]: the observer-gated
/// arming, the single held `agent wait`, and the list that stays the
/// authority.
///
/// Owned by the session, which keeps [agentsNotifier], [tracksAgents] and
/// [refreshAgents] as delegations. Everything it reads from the session
/// comes in as a getter, so it always sees the CURRENT adapter and
/// connection state. It creates no Timer and runs nothing at construction:
/// the loop starts only from [enable] or an observer, both reached from
/// [connect]'s call stack, so timers still bind to the zone of `connect()`.
class AgentWatch {
  AgentWatch({
    required this.profile,
    required MultiplexerAdapter Function() adapter,
    required bool Function() isConnected,
    required bool Function() isDisposed,
    required void Function() onReachable,
  }) : _adapter = adapter,
       _isConnected = isConnected,
       _isDisposed = isDisposed,
       _onReachable = onReachable;

  static final _log = HelmLogger('TerminalSession');

  final ConnectionProfile profile;
  final MultiplexerAdapter Function() _adapter;
  final bool Function() _isConnected;
  final bool Function() _isDisposed;
  final void Function() _onReachable;

  /// What this session last learned about the AI agents inside the
  /// multiplexer session it is attached to.
  ///
  /// Unlike [advisoriesNotifier], this is published while the session is
  /// HEALTHY — agent state is only useful live. It starts, and returns to,
  /// [AgentsNotProbed]: before the first poll answers, helm genuinely does
  /// not know, and saying so is cheaper than being wrong.
  late final ValueNotifier<AgentSnapshot> agentsNotifier =
      ObservableValueNotifier<AgentSnapshot>(
        const AgentsNotProbed(),
        onObservedChanged: (observed) {
          _agentsObserved = observed;
          _syncAgentTracking();
        },
      );

  /// Pending re-entry into [_trackAgents] when tracking could not be
  /// event-driven this cycle. Non-null only while a retry is genuinely
  /// owed — see [_scheduleAgentRetry].
  Timer? _agentRetryTimer;

  /// Invalidates in-flight tracking work. Bumped every time tracking
  /// disarms, so a wait or a retry that was already scheduled can tell
  /// that the session it belonged to has moved on.
  ///
  /// A held `agent wait` can outlive a disconnect, a dispose, or the last
  /// observer leaving, and it answers into whatever is left. Checking a
  /// generation counter is what makes that answer inert instead of
  /// resurrecting a loop nobody wants — the failure the first version of
  /// this code hit as "A Timer is still pending even after the widget tree
  /// was disposed".
  int _agentTrackingEpoch = 0;

  /// True while a tracking cycle is either running or has a retry pending,
  /// so arming twice cannot produce two loops.
  ///
  /// Defensive only: no reachable path arms twice while already armed
  /// today, because every entry point either transitions through a disarm
  /// first or is guarded elsewhere ([connect] refuses to run while already
  /// connected, and the observer callback fires only on transitions).
  /// Removing it therefore fails no test — verified by mutation — so it is
  /// kept as a cheap invariant for future callers, NOT presented as the
  /// thing that bounds the channel count. [_armOrJoinAgentWait] is what
  /// bounds that.
  bool _agentTrackingActive = false;

  /// The `agent wait` currently held open on the host, or null when none
  /// is. See [_armOrJoinAgentWait] — this is the single-channel budget.
  Future<MuxAgentWaitResult>? _agentWaitInFlight;

  /// True once this session is attached to a multiplexer and connected,
  /// i.e. asking about agents is meaningful at all.
  bool _agentTrackingEnabled = false;

  /// Whether this session can be told about agents at all.
  ///
  /// Exposed for one caller: the push-notification permission prompt.
  /// This flag is the first honest moment a notification permission has a
  /// purpose — there is a live connection, attached to a multiplexer that
  /// reports agent state, so there is finally something that could arrive
  /// while the phone is in a pocket. Asking earlier spends one of a very
  /// small, non-renewable supply of Android prompts on someone who has
  /// not yet seen helm connect to anything.
  ///
  /// Deliberately NOT [_agentsObserved]: that one means a widget is
  /// LOOKING at agent state right now, which is the opposite of the case
  /// notifications exist for.
  bool get tracksAgents => _agentTrackingEnabled;

  /// True while at least one widget listens to [agentsNotifier].
  bool _agentsObserved = false;

  /// Guards against overlapping queries when one round-trip outlives
  /// [kAgentPollInterval] — a slow host must not accumulate a backlog of
  /// in-flight channels.
  bool _agentPollInFlight = false;

  /// Marks this session as attached to a multiplexer and connected, and
  /// arms the loop if someone is already looking.
  void enable() {
    _agentTrackingEnabled = true;
    _syncAgentTracking();
  }

  /// Arms or disarms agent tracking so that it runs when — and only when —
  /// it is both meaningful and wanted.
  ///
  /// WHY THIS SESSION OWNS IT, for the same reason the probe does (see
  /// [connect]): the only usable [HostCommandRunner] is the one bound to
  /// the [SSHClient] this class created, and it reuses that client's
  /// channels instead of opening a second connection.
  ///
  /// WHY IT IS GATED ON AN OBSERVER, not merely on being connected:
  ///
  /// "Do not hammer the host" is not satisfied by a slow cadence alone,
  /// and it is satisfied even less by an event-driven wait — a wait is a
  /// HELD channel, so an unobserved session would sit on one indefinitely
  /// to produce a value nothing renders. A tracker armed by [connect]
  /// would also outlive any caller that builds a session without tearing
  /// it down, which is precisely how the first version of this code leaked
  /// a pending timer past the end of a widget test. Gating on
  /// [_agentsObserved] makes both leaks structurally impossible rather
  /// than a discipline every future caller has to remember, and it drops
  /// host traffic to exactly zero when no widget is listening.
  ///
  /// Both conditions matter: [_agentTrackingEnabled] means asking is
  /// MEANINGFUL (connected, and attached to a multiplexer), while
  /// [_agentsObserved] means the answer is WANTED.
  void _syncAgentTracking() {
    final shouldTrack =
        _agentTrackingEnabled && _agentsObserved && !_isDisposed();

    if (!shouldTrack) {
      // Strand whatever is in flight BEFORE clearing the timer: a wait
      // already held on the host cannot be cancelled from here, so the
      // only way to stop it re-arming is to make its answer inert.
      _agentTrackingEpoch++;
      _agentRetryTimer?.cancel();
      _agentRetryTimer = null;
      _agentTrackingActive = false;
      return;
    }
    if (_agentTrackingActive) return;
    _agentTrackingActive = true;

    // Deferred by a microtask because the observed-transition that gets
    // here fires from a listener's `initState`, i.e. mid-build.
    // [refreshAgents] can publish synchronously on its unsupported-
    // multiplexer path, and notifying a [ValueListenableBuilder] during
    // build would mark a widget dirty while it is being built.
    final epoch = _agentTrackingEpoch;
    scheduleMicrotask(() => unawaited(_trackAgents(epoch)));
  }

  /// Keeps [agentsNotifier] current by asking the host to TELL US when an
  /// agent moves, rather than interrogating it on a clock.
  ///
  /// WHY THIS REPLACED A 10-SECOND POLL:
  ///
  /// The tab badge is the whole point — a user must learn that an agent
  /// needs them without opening anything — and a poll put up to a full
  /// interval between the agent blocking and the badge saying so. herdr's
  /// `agent wait` is MEASURED to be event-driven (55ms of host-side
  /// reaction), so the interval is now paid only when there is nothing to
  /// watch. The previous version of this comment claimed a real wait would
  /// need "an unverified CLI subcommand or an unverified polling
  /// protocol"; the subcommand is verified, and this is it.
  ///
  /// THE CHANNEL BUDGET, which is the constraint that shapes everything
  /// here:
  ///
  /// A blocking wait is a HELD SSH exec channel, and OpenSSH's default
  /// `MaxSessions` is 10. Commit 773888f is the record of what channel
  /// accumulation costs — a connection with no channel left for a
  /// reconnect to attach through, i.e. losing the terminal in order to
  /// refresh a badge. Exactly ONE channel is held, and that is structural
  /// rather than guarded:
  ///
  /// * this is a single sequential loop — the list and the wait are
  ///   awaited one after the other, never concurrently;
  /// * [_agentTrackingActive] admits only one loop per session;
  /// * the wait is bounded ON THE HOST (see [kAgentWaitWindow]), so it is
  ///   always awaited to completion and never abandoned. Abandonment is
  ///   what turns "one held channel" into "one per window".
  ///
  /// WHEN IT CANNOT BE EVENT-DRIVEN it degrades to [kAgentPollInterval]
  /// rather than to silence, in three cases: an adapter with no
  /// [MuxCapability.agentWait] (whose wait may answer instantly, making a
  /// re-arm loop a spin), no agent to target yet (so an agent that starts
  /// LATER is still discovered), and a wait that broke (retried on a
  /// delay, never immediately).
  Future<void> _trackAgents(int epoch) async {
    while (!_agentTrackingStale(epoch)) {
      await refreshAgents();
      if (_agentTrackingStale(epoch)) return;

      final plan = _planAgentWait();
      if (plan == null) {
        _scheduleAgentRetry(epoch);
        return;
      }

      MuxAgentWaitResult result;
      try {
        result = await _armOrJoinAgentWait(plan);
      } catch (e) {
        // An adapter is not supposed to throw here, but a throw must not
        // become an unhandled async error and must not be read as "no
        // agents" — it is one more way of not knowing.
        _log.w('Agent wait threw for ${profile.name}: $e');
        result = const MuxAgentWaitFailed(null);
      }
      if (_agentTrackingStale(epoch)) return;

      if (result is MuxAgentWaitFailed) {
        _log.w('Agent wait failed for ${profile.name}: ${result.code}');
        // Ask the LIST what is true before degrading: a wait can fail for
        // reasons the list can still answer around — a watched pane that
        // closed, say — and `refreshAgents` publishes the honest
        // [AgentsUnreachable] when the list cannot answer either. Then
        // wait out the interval rather than re-arming into the same
        // failure.
        await refreshAgents();
        if (_agentTrackingStale(epoch)) return;
        _scheduleAgentRetry(epoch);
        return;
      }
      // Matched or timed out: either way the next cycle re-reads the list,
      // which is the authority, and re-arms from what it finds.
    }
  }

  /// Returns the wait already held on the host, or arms a new one when
  /// none is.
  ///
  /// THE ONE CHANNEL IS ENFORCED HERE, and it has to be, because the epoch
  /// in [_agentTrackingStale] cannot do it. Disarming makes a held wait's
  /// ANSWER inert; it does not close the wait's channel, and nothing on
  /// this side can — herdr is blocked on it until its own `--timeout`
  /// expires, up to [kAgentWaitWindow]. So a loop that armed unconditionally
  /// would add a held channel every time tracking re-armed, and re-arming
  /// is not rare: opening and closing the drawer does it. Measured before
  /// this guard existed, six toggles held six channels at once — the
  /// 773888f failure with a different trigger, and OpenSSH's default
  /// `MaxSessions` of 10 is four toggles further on.
  ///
  /// Released by the wait's own completion rather than by whoever stopped
  /// waiting for it — the same discipline [kAgentListTimeout] describes for
  /// the list, and for the same reason: releasing on abandonment is what
  /// turns one held channel into one per attempt.
  ///
  /// A joining cycle may be watching for something slightly different from
  /// what the held wait was armed for — a different target, or a different
  /// complement. That is deliberate and it is never a lie: whatever the
  /// held wait reports, the joining cycle re-reads the list, which is the
  /// authority, and re-plans from what it finds. The cost is at most one
  /// window of reduced precision; the alternative costs the user their
  /// terminal.
  Future<MuxAgentWaitResult> _armOrJoinAgentWait(
    ({AgentAwareMultiplexer api, String target, Set<AgentState> until}) plan,
  ) {
    final held = _agentWaitInFlight;
    if (held != null) return held;

    final armed = plan.api.waitForAgent(
      plan.target,
      until: plan.until,
      timeout: kAgentWaitWindow,
    );
    _agentWaitInFlight = armed;
    // The error is swallowed HERE and handled by the awaiting cycle: both
    // observe the same future, and an unobserved rejection on this one
    // would surface as an unhandled async error.
    unawaited(
      armed.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (_agentWaitInFlight == armed) _agentWaitInFlight = null;
      }),
    );
    return armed;
  }

  /// True once the work started for [epoch] no longer belongs to anything.
  ///
  /// Checked after EVERY await in [_trackAgents], because each one is a
  /// point where a tab can be closed or a connection dropped underneath it.
  bool _agentTrackingStale(int epoch) =>
      _isDisposed() || epoch != _agentTrackingEpoch || !_isConnected();

  void _scheduleAgentRetry(int epoch) {
    _agentRetryTimer?.cancel();
    _agentRetryTimer = Timer(kAgentPollInterval, () {
      if (_agentTrackingStale(epoch)) return;
      unawaited(_trackAgents(epoch));
    });
  }

  /// Decides which agent to watch and for which states, or null when this
  /// cycle cannot be event-driven at all.
  ///
  /// [until] is the COMPLEMENT of the watched agent's current state, and
  /// that is not a refinement — it is what stops the loop spinning.
  /// MEASURED against herdr 0.8.0: a wait armed with the state an agent is
  /// ALREADY in returns immediately (0.115s, i.e. process startup). Arming
  /// "any state" would therefore re-arm as fast as the transport allows,
  /// forever, on a host the user is also working on.
  ///
  /// The watched agent is the one DRIVING THE BADGE (most urgent, ties
  /// broken by target so the choice is stable across cycles), because that
  /// is the claim currently on screen and therefore the claim most costly
  /// to leave stale.
  ///
  /// KNOWN LIMIT, stated rather than hidden: `agent wait` takes ONE target,
  /// and the channel budget allows one wait, so a second agent escalating
  /// while the badge agent holds still is not noticed until the badge agent
  /// moves or the wait window expires. Watching every agent would need
  /// either one channel per agent or herdr's `events.subscribe`, which has
  /// no CLI wrapper and is out of scope here.
  ({AgentAwareMultiplexer api, String target, Set<AgentState> until})?
  _planAgentWait() {
    if (!_adapter().capabilities.contains(MuxCapability.agentWait)) {
      return null;
    }
    final support = AgentSupport.resolve(_adapter());
    if (support is! AgentSupportAvailable) return null;

    final snapshot = agentsNotifier.value;
    if (snapshot is! AgentsKnown || snapshot.agents.isEmpty) return null;

    final watched = snapshot.agents.reduce((a, b) {
      final byUrgency = agentStateUrgency(
        b.state,
      ).compareTo(agentStateUrgency(a.state));
      if (byUrgency != 0) return byUrgency > 0 ? b : a;
      return b.target.compareTo(a.target) < 0 ? b : a;
    });

    return (
      api: support.agents,
      target: watched.target,
      until: AgentState.values.where((state) => state != watched.state).toSet(),
    );
  }

  void stop() {
    _agentTrackingEnabled = false;
    _syncAgentTracking();
  }

  /// Asks the host once for the current agent list and publishes the
  /// result on [agentsNotifier].
  ///
  /// Never throws and never rejects: every failure — an unsupported
  /// multiplexer, a dead agent server, a timeout, or the [StateError]
  /// `listAgents` raises for an unrecognized herdr error envelope —
  /// degrades to a variant that says we could not find out. It never
  /// degrades to [AgentsKnown] with an empty list, which would read as
  /// "no agents are running".
  Future<void> refreshAgents() async {
    if (_isDisposed() || _agentPollInFlight) return;
    if (!_isConnected()) return;

    final support = AgentSupport.resolve(_adapter());
    if (support is AgentSupportUnsupported) {
      agentsNotifier.value = AgentsUnsupported(support.muxId);
      return;
    }
    final agentApi = (support as AgentSupportAvailable).agents;

    _agentPollInFlight = true;
    final query = agentApi.listAgents();
    // Release the guard when the QUERY settles, not when this call stops
    // waiting for it.
    //
    // This is what bounds the timeout's leak. `.timeout` below abandons
    // the Future without closing the remote channel (see
    // [kAgentListTimeout]); releasing the guard on that abandonment would
    // let the next poll open a SECOND channel on top of the one nobody
    // closed, and an 8s ceiling against a 10s cadence adds one abandoned
    // invocation every interval, without limit. Holding the guard until
    // the host actually answers caps that at exactly one.
    //
    // The error is swallowed HERE and handled on the awaited branch
    // below: both branches observe the same Future, and an unobserved
    // rejection on this one would surface as an unhandled async error.
    unawaited(
      query
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _agentPollInFlight = false),
    );

    try {
      final result = await query.timeout(kAgentListTimeout);
      // The session can be torn down during the round-trip — closing a tab
      // disposes it while this is still in flight. Writing to a disposed
      // ValueNotifier throws; the previous unit hit exactly that with the
      // advisory collect, so disposal is checked rather than assumed
      // impossible.
      if (_isDisposed()) return;
      if (!_isConnected()) return;
      agentsNotifier.value = switch (result) {
        MuxAgentsAvailable(:final agents) => AgentsKnown(agents),
        MuxAgentServerNotRunning() => const AgentsUnreachable(),
      };
      _onReachable();
    } catch (e) {
      _log.w('Agent refresh failed for ${profile.name}: $e');
      if (_isDisposed()) return;
      if (!_isConnected()) return;
      agentsNotifier.value = const AgentsUnreachable();
    }
  }
}
