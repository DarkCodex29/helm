import 'dart:async';

import 'package:helm/core/host/multiplexer_adapter.dart';

/// One `waitForAgent` invocation, as the adapter received it.
typedef RecordedWait = ({
  String target,
  Set<AgentState> until,
  Duration timeout,
});

/// Scripted [MultiplexerAdapter] that advertises a GENUINE blocking wait,
/// so a consumer's event-driven loop can be driven a step at a time.
///
/// Unlike [FakeAgentAdapter], this one holds each wait open until the test
/// resolves it — which is the only way to observe the property that matters
/// most about the loop: that it never holds more than ONE wait at a time.
/// A wait is a HELD SSH exec channel, and OpenSSH's default `MaxSessions`
/// is 10, so a loop that armed a second wait before the first returned
/// would starve the connection of the channels a reconnect needs. See
/// commit 773888f for what that costs a user in practice.
class FakeWaitingAgentAdapter
    implements MultiplexerAdapter, AgentAwareMultiplexer {
  FakeWaitingAgentAdapter({this.id = MultiplexerId.herdr});

  @override
  final MultiplexerId id;

  /// Result handed to every [listAgents] call until reassigned.
  MuxAgentsResult agentList = const MuxAgentsAvailable([]);

  /// How many times [listAgents] has been entered.
  int listAgentsCalls = 0;

  /// Every [waitForAgent] invocation, in order, with its arguments.
  final List<RecordedWait> waits = [];

  /// The highest number of waits outstanding at the same instant.
  ///
  /// MUST stay at 1 for any consumer that respects the single-channel
  /// budget. This is the assertion the channel-accumulation constraint
  /// reduces to.
  int maxConcurrentWaits = 0;

  int _outstanding = 0;
  final List<Completer<MuxAgentWaitResult>> _pending = [];

  /// True while a wait is armed and unresolved.
  bool get isWaiting => _outstanding > 0;

  /// Resolves the oldest unresolved wait with [result].
  ///
  /// Throws when nothing is waiting, so a test that believes it is driving
  /// a loop which is in fact idle fails loudly instead of passing by
  /// coincidence.
  void completeWait(MuxAgentWaitResult result) {
    final pending = _pending.where((c) => !c.isCompleted).toList();
    if (pending.isEmpty) {
      throw StateError(
        'FakeWaitingAgentAdapter: completeWait() with no wait outstanding',
      );
    }
    pending.first.complete(result);
  }

  /// Resolves every outstanding wait, so a torn-down session leaves no
  /// future dangling in the test's zone.
  void drainWaits() {
    for (final completer in _pending) {
      if (!completer.isCompleted) {
        completer.complete(const MuxAgentWaitTimedOut());
      }
    }
  }

  @override
  Set<MuxCapability> get capabilities => const {
    MuxCapability.agentState,
    MuxCapability.agentWait,
  };

  @override
  AgentAwareMultiplexer? get agents => this;

  @override
  Future<MuxAgentsResult> listAgents() async {
    listAgentsCalls++;
    return agentList;
  }

  @override
  Future<MuxAgentWaitResult> waitForAgent(
    String target, {
    required Set<AgentState> until,
    required Duration timeout,
  }) {
    waits.add((target: target, until: until, timeout: timeout));
    _outstanding++;
    if (_outstanding > maxConcurrentWaits) maxConcurrentWaits = _outstanding;
    final completer = Completer<MuxAgentWaitResult>();
    _pending.add(completer);
    return completer.future.whenComplete(() => _outstanding--);
  }

  @override
  Future<MuxDetection> detect() async =>
      const MuxDetection.installed(absPath: 'fake', version: 'fake 1.0');

  @override
  Future<MuxSessionsResult> listSessions() async =>
      const MuxSessionsAvailable([]);

  @override
  Future<bool> hasSession(String name) async => true;

  @override
  String attachCommand(String sessionName) => 'fake-attach $sessionName';
}
