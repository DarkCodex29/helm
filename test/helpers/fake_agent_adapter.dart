import 'dart:async';

import 'package:helm/core/host/multiplexer_adapter.dart';

/// Scripted [MultiplexerAdapter] that DOES advertise agent state, so a test
/// can drive every branch of a consumer's agent handling without a herdr
/// binary or a live socket.
///
/// The result of the next [listAgents] is chosen by exactly one of
/// [whenAgents], [whenThrows], or [whenHangs]. There is no default: an
/// unscripted call throws, so a consumer that queries when it should not
/// fails loudly instead of silently reading a canned empty list — the same
/// discipline [FakeHostCommandRunner] applies to commands.
class FakeAgentAdapter implements MultiplexerAdapter, AgentAwareMultiplexer {
  FakeAgentAdapter({this.id = MultiplexerId.herdr});

  @override
  final MultiplexerId id;

  /// How many times [listAgents] has been entered.
  int listAgentsCalls = 0;

  MuxAgentsResult? _result;
  Object? _error;
  Completer<void>? _gate;

  /// Next [listAgents] answers with [result].
  void whenAgents(MuxAgentsResult result) {
    _reset();
    _result = result;
  }

  /// Next [listAgents] throws [error].
  void whenThrows(Object error) {
    _reset();
    _error = error;
  }

  /// Next [listAgents] never completes until [release] is called.
  ///
  /// This is what makes a genuine timeout testable: the consumer's own
  /// `.timeout(...)` has to fire, rather than the fake pre-emptively
  /// throwing a [TimeoutException] the consumer never actually raised.
  void whenHangs() {
    _reset();
    _gate = Completer<void>();
  }

  /// Lets a [whenHangs] call finish with an empty agent list.
  void release() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void _reset() {
    _result = null;
    _error = null;
    _gate = null;
  }

  @override
  Set<MuxCapability> get capabilities => const {MuxCapability.agentState};

  @override
  AgentAwareMultiplexer? get agents => this;

  @override
  Future<MuxAgentsResult> listAgents() async {
    listAgentsCalls++;
    final gate = _gate;
    if (gate != null) {
      await gate.future;
      return const MuxAgentsAvailable([]);
    }
    final error = _error;
    if (error != null) throw error;
    final result = _result;
    if (result == null) {
      throw StateError(
        'FakeAgentAdapter: listAgents() called with nothing scripted',
      );
    }
    return result;
  }

  /// Deliberately loud. This fake does NOT advertise
  /// [MuxCapability.agentWait], so nothing is entitled to loop on its
  /// wait — a consumer that does anyway would spin against a real adapter,
  /// and must fail here instead of silently working.
  @override
  Future<MuxAgentWaitResult> waitForAgent(
    String target, {
    required Set<AgentState> until,
    required Duration timeout,
  }) async => throw StateError(
    'FakeAgentAdapter: waitForAgent() called on an adapter that does not '
    'advertise MuxCapability.agentWait',
  );

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

/// Scripted [MultiplexerAdapter] that does NOT advertise agent state —
/// what tmux and zellij genuinely are.
///
/// [listAgents] is unreachable through this type by construction ([agents]
/// is null), which is the whole point of design.md AD-2: a consumer cannot
/// read agent state from it without first admitting it does not have any.
class FakeAgentlessAdapter implements MultiplexerAdapter {
  FakeAgentlessAdapter({this.id = MultiplexerId.tmux});

  @override
  final MultiplexerId id;

  @override
  Set<MuxCapability> get capabilities => const {};

  @override
  AgentAwareMultiplexer? get agents => null;

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
