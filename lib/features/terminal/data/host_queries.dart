import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/host/session_vitality.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session_timings.dart';

/// The host questions a [TerminalSession] answers on demand: focus an
/// agent, read the workspace tree, focus a tab, and judge session vitality.
///
/// Owned by the session, which keeps the public methods as one-line
/// delegations. Everything it reads from the session comes in as a getter,
/// so it always sees the CURRENT adapter, status and host report; the
/// vitality notifier stays owned (and disposed) by the session.
class HostQueries {
  HostQueries({
    required MultiplexerAdapter Function() muxAdapter,
    required bool Function() isDisposed,
    required ConnectionStatus Function() status,
    required HostReport? Function() hostReport,
    required AgentSnapshot Function() agents,
    required String Function() profileName,
    required this.sessionVitalityNotifier,
  }) : _mux = muxAdapter,
       _isDisposed = isDisposed,
       _status = status,
       _hostReport = hostReport,
       _agents = agents,
       _profileNameOf = profileName;

  static final _log = HelmLogger('TerminalSession');

  final MultiplexerAdapter Function() _mux;
  final bool Function() _isDisposed;
  final ConnectionStatus Function() _status;
  final HostReport? Function() _hostReport;
  final AgentSnapshot Function() _agents;
  final String Function() _profileNameOf;
  final ValueNotifier<SessionVitality> sessionVitalityNotifier;

  String get _profileName => _profileNameOf();

  /// Guards against overlapping pane queries. Released by the query's own
  /// completion, never by a timeout — see [refreshSessionVitality].
  bool _vitalityQueryInFlight = false;

  /// Guards against overlapping focus requests. Released by the request's
  /// own completion, never by a timeout — see [focusAgent].
  bool _focusRequestInFlight = false;

  /// Guards against overlapping workspace-tree queries. Released by the
  /// query's own completion, never by a timeout — see
  /// [refreshWorkspaceTree].
  bool _workspaceTreeQueryInFlight = false;

  /// Guards against overlapping tab-focus requests. Released by the
  /// request's own completion, never by a timeout — see [focusTab].
  bool _tabFocusInFlight = false;

  /// Asks the host to bring [target]'s pane to the front, so the user is
  /// looking at that agent.
  ///
  /// [target] is an [AgentStatus.target] straight from the snapshot the
  /// caller is rendering — the pane id herdr's own focus accepts.
  ///
  /// Never throws and never rejects, because the caller is a tap handler
  /// and an error escaping one surfaces as an unhandled async error rather
  /// than as feedback. Every failure — a torn-down session, a dropped
  /// connection, a multiplexer that cannot focus, a wedged host, or an
  /// adapter that threw — becomes a [MuxAgentFocusResult] the caller must
  /// switch over. It NEVER degrades to [MuxAgentFocused], which is the one
  /// variant a caller is entitled to close its drawer on.
  ///
  /// The codes on [MuxAgentFocusFailed] are helm's OWN when the request
  /// never reached the multiplexer, and the multiplexer's when it did.
  /// They exist for logs and tests; nothing in the UI branches on them,
  /// which is why they are strings rather than a second enum nobody reads.
  ///
  /// THE ONE IN-FLIGHT REQUEST is the whole reason this is not a two-line
  /// pass-through. See [kAgentFocusTimeout]: the guard is released by the
  /// request settling, never by this call giving up on it, so a wedged
  /// host costs exactly one abandoned channel no matter how many times a
  /// frustrated user taps the row.
  Future<MuxAgentFocusResult> focusAgent(String target) async {
    if (_isDisposed()) return const MuxAgentFocusFailed('session_disposed');
    if (_status() != ConnectionStatus.connected) {
      return const MuxAgentFocusFailed('not_connected');
    }
    if (_focusRequestInFlight) {
      return const MuxAgentFocusFailed('focus_already_in_flight');
    }

    final support = AgentSupport.resolve(_mux());
    if (support is! AgentSupportAvailable) {
      return const MuxAgentFocusFailed('multiplexer_cannot_focus');
    }

    _focusRequestInFlight = true;
    final request = support.agents.focusAgent(target);
    // Released when the REQUEST settles, not when this call stops waiting —
    // the discipline [kAgentListTimeout] documents. The error is swallowed
    // here and handled on the awaited branch below: both observe the same
    // Future, and an unobserved rejection on this one would surface as an
    // unhandled async error.
    unawaited(
      request
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _focusRequestInFlight = false),
    );

    try {
      return await request.timeout(kAgentFocusTimeout);
    } catch (e) {
      _log.w('Agent focus failed for $_profileName ($target): $e');
      return const MuxAgentFocusFailed(null);
    }
  }

  /// Asks the host once for its workspace tree — the user's clients and the
  /// projects inside them.
  ///
  /// Returned rather than published on a notifier, unlike [agentsNotifier].
  /// Agent state is a LIVE fact worth tracking while nobody asked; the tree
  /// is structure the user edits by hand in herdr, and it is read at the
  /// one instant somebody opens the drawer to look at it. A notifier would
  /// buy a cadence nothing needs and would have to be kept honest across
  /// disconnects for a value no widget renders in between.
  ///
  /// Never throws and never rejects. Every failure — a torn-down session, a
  /// dropped connection, a multiplexer with no workspaces, a wedged host,
  /// or the [StateError] `listWorkspaceTree` raises for an unrecognized
  /// herdr error envelope — becomes a variant the caller must switch over.
  /// It NEVER degrades to [MuxWorkspaceTreeAvailable], which is the only
  /// variant a caller may draw a tree from.
  ///
  /// [MuxWorkspaceTreeUnsupported] is reached ONLY past the connected
  /// check, and that ordering matters: before [connect] resolves a
  /// multiplexer, `_muxAdapter` is still the unconnected tmux fallback, and
  /// naming it here would be a fabricated claim about a multiplexer this
  /// session never selected — the trap [connect]'s own agent-tracking guard
  /// is written about.
  Future<MuxWorkspaceTreeResult> refreshWorkspaceTree() async {
    if (_isDisposed()) return const MuxWorkspaceTreeUnreachable();
    if (_status() != ConnectionStatus.connected) {
      return const MuxWorkspaceTreeUnreachable();
    }
    if (_workspaceTreeQueryInFlight) {
      return const MuxWorkspaceTreeUnreachable();
    }

    final treeApi = _mux().workspaces;
    if (treeApi == null) return MuxWorkspaceTreeUnsupported(_mux().id);

    _workspaceTreeQueryInFlight = true;
    final query = treeApi.listWorkspaceTree();
    // Released when the QUERY settles, not when this call stops waiting —
    // the discipline [kAgentListTimeout] documents. `.timeout` abandons the
    // Future without closing the remote channel, so releasing on
    // abandonment would let the next drawer-open stack a second channel on
    // top of one nobody closed.
    //
    // The error is swallowed here and handled on the awaited branch below:
    // both observe the same Future, and an unobserved rejection on this one
    // would surface as an unhandled async error.
    unawaited(
      query
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _workspaceTreeQueryInFlight = false),
    );

    try {
      final result = await query.timeout(kWorkspaceTreeTimeout);
      // The session can be torn down or dropped during the round-trip.
      // Handing back a tree then would describe a host this session is no
      // longer attached to.
      if (_isDisposed()) return const MuxWorkspaceTreeUnreachable();
      if (_status() != ConnectionStatus.connected) {
        return const MuxWorkspaceTreeUnreachable();
      }
      return result;
    } catch (e) {
      _log.w('Workspace tree query failed for $_profileName: $e');
      return const MuxWorkspaceTreeUnreachable();
    }
  }

  /// Asks the host to switch to [tabId], so the user is looking at that
  /// project.
  ///
  /// [tabId] is a [MuxTab.tabId] straight from the tree the caller is
  /// rendering. This is [focusAgent] aimed at a different target, and every
  /// word of that method's doc comment applies here — including the reason
  /// the in-flight guard is released by the request settling rather than by
  /// this call giving up on it.
  Future<MuxTabFocusResult> focusTab(String tabId) async {
    if (_isDisposed()) return const MuxTabFocusFailed('session_disposed');
    if (_status() != ConnectionStatus.connected) {
      return const MuxTabFocusFailed('not_connected');
    }
    if (_tabFocusInFlight) {
      return const MuxTabFocusFailed('focus_already_in_flight');
    }

    final treeApi = _mux().workspaces;
    if (treeApi == null) {
      return const MuxTabFocusFailed('multiplexer_cannot_focus_tabs');
    }

    _tabFocusInFlight = true;
    final request = treeApi.focusTab(tabId);
    unawaited(
      request
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _tabFocusInFlight = false),
    );

    try {
      return await request.timeout(kTabFocusTimeout);
    } catch (e) {
      _log.w('Tab focus failed for $_profileName ($tabId): $e');
      return const MuxTabFocusFailed(null);
    }
  }

  /// Asks for the vitality verdict the first time an AUTHORITATIVE agent
  /// snapshot makes one reachable.
  ///
  /// Gated on [AgentsKnown] because a VIRGIN verdict requires the absence
  /// of agents to have been MEASURED — see [judgeSessionVitality]. Any
  /// other snapshot could only ever produce
  /// [SessionVitalityIndeterminate], so spending a host round-trip on it
  /// would buy nothing.
  ///
  /// Gated on [SessionVitalityNotProbed] because this is a ONE-SHOT
  /// question, and that is what keeps the agent poll from becoming a pane
  /// poll. A session does not become virgin while you are connected to it:
  /// the verdict describes how the session came back, which is settled
  /// before helm ever attaches. Re-asking every ten seconds would hammer a
  /// host the user is also working on — the constraint
  /// [kAgentPollInterval] was written about — to re-derive a constant.
  ///
  /// KNOWN LIMIT, stated rather than hidden: a query that fails publishes
  /// [SessionVitalityUnreachable] and is never retried for the life of the
  /// connection. The UI draws nothing for that variant, so the cost is a
  /// missing signal rather than a wrong one — which is the correct side to
  /// fail on for a claim this loud.
  void maybeJudgeSessionVitality() {
    if (_agents() is! AgentsKnown) return;
    if (sessionVitalityNotifier.value is! SessionVitalityNotProbed) return;
    unawaited(refreshSessionVitality());
  }

  /// Asks the host once whether this session has been worked in, and
  /// publishes the verdict on [sessionVitalityNotifier].
  ///
  /// Never throws and never rejects. Every failure degrades to a variant
  /// that says we could not find out; it never degrades to
  /// [SessionVitalityKnown], which is the only variant the UI speaks from.
  Future<void> refreshSessionVitality() async {
    if (_isDisposed() || _vitalityQueryInFlight) return;
    if (_status() != ConnectionStatus.connected) return;

    final paneApi = _mux().panes;
    if (paneApi == null) {
      sessionVitalityNotifier.value = SessionVitalityUnsupported(_mux().id);
      return;
    }

    // Checked BEFORE the round-trip, not inside the judge. Home comes from
    // the probe, which already ran for this connection — if it is missing
    // now it will still be missing later, so the panes could only ever
    // feed an indeterminate verdict. Asking anyway would spend a channel
    // to learn nothing.
    final home = _hostReport()?.env['home'];
    if (home == null) {
      sessionVitalityNotifier.value = const SessionVitalityIndeterminate();
      return;
    }

    _vitalityQueryInFlight = true;
    final query = paneApi.listPanes();
    // Released when the QUERY settles, not when this call stops waiting —
    // the discipline [kAgentListTimeout] documents. `.timeout` abandons the
    // Future without closing the remote channel, so releasing on
    // abandonment would let a later call stack a second channel on top of
    // one nobody closed.
    unawaited(
      query
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _vitalityQueryInFlight = false),
    );

    try {
      final result = await query.timeout(kPaneListTimeout);
      // The session can be torn down during the round-trip — closing a tab
      // disposes it while this is still in flight, and writing to a
      // disposed ValueNotifier throws.
      if (_isDisposed()) return;
      if (_status() != ConnectionStatus.connected) return;
      sessionVitalityNotifier.value = switch (result) {
        MuxPanesAvailable(:final panes) => judgeSessionVitality(
          panes: panes,
          agents: _agents(),
          homeDirectory: home,
        ),
        MuxPaneServerNotRunning() => const SessionVitalityUnreachable(),
      };
    } catch (e) {
      _log.w('Session vitality check failed for $_profileName: $e');
      if (_isDisposed()) return;
      if (_status() != ConnectionStatus.connected) return;
      sessionVitalityNotifier.value = const SessionVitalityUnreachable();
    }
  }
}
