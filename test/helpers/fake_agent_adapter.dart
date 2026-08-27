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

  /// Every [focusAgent] target, in invocation order.
  final List<String> focusTargets = [];

  MuxAgentsResult? _result;
  Object? _error;
  Completer<void>? _gate;

  MuxAgentFocusResult _focusResult = const MuxAgentFocused();
  Completer<void>? _focusGate;

  /// Next [focusAgent] answers with [result].
  void whenFocus(MuxAgentFocusResult result) {
    _focusGate = null;
    _focusResult = result;
  }

  /// Next [focusAgent] never completes until [releaseFocus] is called, so a
  /// consumer's own `.timeout(...)` has to fire rather than the fake
  /// pre-emptively throwing a [TimeoutException] the consumer never raised.
  void whenFocusHangs() {
    _focusGate = Completer<void>();
  }

  /// Lets a [whenFocusHangs] call finish.
  void releaseFocus() {
    final gate = _focusGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

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

  /// Null by default: this fake exists to drive AGENT branches, and a
  /// consumer that reads pane state from it must say so by using
  /// [FakePaneAwareAdapter] instead.
  @override
  PaneAwareMultiplexer? get panes => null;

  /// Null by default, for the same reason [panes] is: a consumer that
  /// reads the workspace tree must say so by using
  /// [FakeWorkspaceAwareAdapter] instead.
  @override
  WorkspaceAwareMultiplexer? get workspaces => null;

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
  }  ) async => throw StateError(
    'FakeAgentAdapter: waitForAgent() called on an adapter that does not '
    'advertise MuxCapability.agentWait',
  );

  /// Records the target, then answers with whatever [whenFocus] scripted.
  ///
  /// Defaults to [MuxAgentFocused] rather than throwing, unlike
  /// [listAgents]. Focus is a USER-INITIATED action, so the interesting
  /// assertions are "was it called, and with which target" — a fake that
  /// demanded scripting for the happy path would make every consumer test
  /// restate the same line.
  @override
  Future<MuxAgentFocusResult> focusAgent(String target) async {
    focusTargets.add(target);
    final gate = _focusGate;
    if (gate != null) await gate.future;
    return _focusResult;
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
  PaneAwareMultiplexer? get panes => null;

  @override
  WorkspaceAwareMultiplexer? get workspaces => null;

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

/// Scripted [MultiplexerAdapter] that advertises BOTH agent state and pane
/// listing — what `HerdrAdapter` genuinely is.
///
/// Extends [FakeAgentAdapter] so a vitality test can script the agent list
/// and the pane list independently, which is the point: the two facts are
/// independent, and a test that could not disagree with itself about them
/// would not be testing that independence.
class FakePaneAwareAdapter extends FakeAgentAdapter
    implements PaneAwareMultiplexer {
  /// How many times [listPanes] has been entered.
  int listPanesCalls = 0;

  MuxPanesResult? _paneResult;
  Object? _paneError;
  Completer<void>? _paneGate;

  /// Next [listPanes] answers with [result].
  void whenPanes(MuxPanesResult result) {
    _resetPanes();
    _paneResult = result;
  }

  /// Next [listPanes] throws [error].
  void whenPanesThrow(Object error) {
    _resetPanes();
    _paneError = error;
  }

  /// Next [listPanes] never completes until [releasePanes] is called, so a
  /// consumer's own `.timeout(...)` has to fire.
  void whenPanesHang() {
    _resetPanes();
    _paneGate = Completer<void>();
  }

  void releasePanes() {
    final gate = _paneGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void _resetPanes() {
    _paneResult = null;
    _paneError = null;
    _paneGate = null;
  }

  @override
  Set<MuxCapability> get capabilities => const {
    MuxCapability.agentState,
    MuxCapability.paneListing,
  };

  @override
  PaneAwareMultiplexer? get panes => this;

  @override
  Future<MuxPanesResult> listPanes() async {
    listPanesCalls++;
    final gate = _paneGate;
    if (gate != null) {
      await gate.future;
      return const MuxPanesAvailable([]);
    }
    final error = _paneError;
    if (error != null) throw error;
    final result = _paneResult;
    if (result == null) {
      throw StateError(
        'FakePaneAwareAdapter: listPanes() called with nothing scripted',
      );
    }
    return result;
  }
}

/// Scripted [MultiplexerAdapter] that advertises the WORKSPACE TREE — the
/// third capability `HerdrAdapter` genuinely has, and the only one that
/// answers "which client, which project".
///
/// Extends [FakeAgentAdapter] rather than standing alone because herdr
/// advertises both, and a consumer that reads the tree may legitimately
/// read agents in the same breath.
class FakeWorkspaceAwareAdapter extends FakeAgentAdapter
    implements WorkspaceAwareMultiplexer {
  /// How many times [listWorkspaceTree] has been entered. The channel
  /// budget is asserted on this, so it counts ENTRIES, not completions.
  int listTreeCalls = 0;

  /// Every [focusTab] target, in invocation order.
  final List<String> focusedTabs = [];

  MuxWorkspaceTreeResult? _treeResult;
  Object? _treeError;
  Completer<void>? _treeGate;

  MuxTabFocusResult _tabFocusResult = const MuxTabFocused();
  Completer<void>? _tabFocusGate;

  /// Next [listWorkspaceTree] answers with [result].
  void whenTree(MuxWorkspaceTreeResult result) {
    _resetTree();
    _treeResult = result;
  }

  /// Next [listWorkspaceTree] throws [error].
  void whenTreeThrows(Object error) {
    _resetTree();
    _treeError = error;
  }

  /// Next [listWorkspaceTree] never completes until [releaseTree] is
  /// called, so a consumer's own `.timeout(...)` has to fire rather than
  /// this fake pre-emptively throwing a [TimeoutException] the consumer
  /// never raised.
  void whenTreeHangs() {
    _resetTree();
    _treeGate = Completer<void>();
  }

  void releaseTree() {
    final gate = _treeGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void _resetTree() {
    _treeResult = null;
    _treeError = null;
    _treeGate = null;
  }

  /// Next [focusTab] answers with [result].
  void whenTabFocus(MuxTabFocusResult result) {
    _tabFocusGate = null;
    _tabFocusResult = result;
  }

  /// Next [focusTab] never completes until [releaseTabFocus] is called.
  void whenTabFocusHangs() {
    _tabFocusGate = Completer<void>();
  }

  void releaseTabFocus() {
    final gate = _tabFocusGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Set<MuxCapability> get capabilities => const {
    MuxCapability.agentState,
    MuxCapability.workspaceTree,
  };

  @override
  WorkspaceAwareMultiplexer? get workspaces => this;

  @override
  Future<MuxWorkspaceTreeResult> listWorkspaceTree() async {
    listTreeCalls++;
    final gate = _treeGate;
    if (gate != null) {
      await gate.future;
      return const MuxWorkspaceTreeAvailable(workspaces: [], tabs: []);
    }
    final error = _treeError;
    if (error != null) throw error;
    final result = _treeResult;
    if (result == null) {
      throw StateError(
        'FakeWorkspaceAwareAdapter: listWorkspaceTree() called with nothing '
        'scripted',
      );
    }
    return result;
  }

  /// Records the target, then answers with whatever [whenTabFocus]
  /// scripted. Defaults to [MuxTabFocused] for the same reason
  /// [focusAgent] does: focus is user-initiated, and the interesting
  /// assertion is which target was asked for.
  @override
  Future<MuxTabFocusResult> focusTab(String tabId) async {
    focusedTabs.add(tabId);
    final gate = _tabFocusGate;
    if (gate != null) await gate.future;
    return _tabFocusResult;
  }
}
