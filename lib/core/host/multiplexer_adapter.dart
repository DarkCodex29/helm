/// Identifies a supported terminal multiplexer.
enum MultiplexerId { herdr, tmux, zellij }

/// A capability a [MultiplexerAdapter] may advertise beyond the five
/// uniform core operations.
///
/// See design.md AD-2: advertised capabilities are for REPORTING (e.g.
/// rendering "this host cannot tell you when an agent blocks"). Only
/// [agentState] has a matching type-enforced execution accessor
/// ([MultiplexerAdapter.agents]) in this slice; the others are reported but
/// have no execution surface here.
enum MuxCapability {
  agentState,

  /// The adapter's [AgentAwareMultiplexer.waitForAgent] genuinely blocks
  /// until the agent changes state, rather than answering about its
  /// current state and returning.
  ///
  /// Advertised by `HerdrAdapter`, backed by `herdr agent wait` —
  /// MEASURED as event-driven against a real herdr 0.8.0 host, not
  /// assumed: with the wait armed, flipping the host state after 5s of
  /// sleep returned the call at 5.055s, a 55ms reaction.
  ///
  /// This one is load-bearing rather than merely descriptive. A caller
  /// that loops "wait, then re-arm" against an adapter whose wait does
  /// NOT block would spin as fast as the transport allows, so
  /// `TerminalSession` checks this capability before entering that loop.
  /// See design.md AD-2.
  agentWait,
  structuredOutput,
  sessionWorkingDirectory,
  deadSessionResurrection,

  /// The adapter can enumerate the session's panes with enough detail to
  /// tell a pane that has been WORKED IN apart from one that was merely
  /// recreated — see [MuxPane].
  ///
  /// Advertised by `HerdrAdapter` only. tmux can report a pane's current
  /// path but has no per-pane revision counter, so it cannot answer the
  /// question this capability exists for and does not advertise it.
  paneListing,
}

/// Install state of a multiplexer, reported by [MultiplexerAdapter.detect].
class MuxDetection {
  const MuxDetection.installed({required this.absPath, required this.version})
    : installed = true;

  const MuxDetection.notInstalled()
    : installed = false,
      absPath = null,
      version = null;

  /// Whether the multiplexer binary was found on the host.
  final bool installed;

  /// Absolute path of the binary. Non-null only when [installed].
  final String? absPath;

  /// Version string reported by the binary. Non-null only when [installed].
  final String? version;
}

/// State of one multiplexer session, reported by
/// [MultiplexerAdapter.listSessions].
///
/// [unknown] exists for adapters that cannot distinguish active from
/// exited for a given entry; no adapter in this slice emits it.
enum MuxSessionState { active, exited, unknown }

/// One session reported by [MultiplexerAdapter.listSessions].
typedef MuxSession = ({String name, MuxSessionState state});

/// Result of [MultiplexerAdapter.listSessions].
///
/// A server/daemon that is not reachable is a distinct, explicit state —
/// never an empty [MuxSessionsAvailable.sessions] list. See the
/// multiplexer-abstraction spec's "Explicit State on List Failure, Never an
/// Empty List" requirement.
sealed class MuxSessionsResult {
  const MuxSessionsResult();
}

/// Sessions were successfully enumerated.
///
/// [sessions] may itself be empty when the server IS running and genuinely
/// has zero sessions — a different, valid case from [MuxServerNotRunning].
final class MuxSessionsAvailable extends MuxSessionsResult {
  const MuxSessionsAvailable(this.sessions);

  final List<MuxSession> sessions;
}

/// The multiplexer's server or daemon process is not reachable.
///
/// MUST NOT be confused with [MuxSessionsAvailable] carrying an empty list —
/// that reads as "no sessions exist", which is a different claim from "the
/// server cannot be reached to find out".
final class MuxServerNotRunning extends MuxSessionsResult {
  const MuxServerNotRunning();
}

/// One AI agent's reported state.
///
/// Populated only by adapters that advertise [MuxCapability.agentState]
/// (herdr only — slice 4). Declared here so [AgentAwareMultiplexer]'s
/// contract compiles and is unit-testable ahead of any implementation.
enum AgentState { idle, working, blocked, done, unknown }

/// See [AgentState].
typedef AgentStatus = ({String target, String label, AgentState state});

/// Result of [AgentAwareMultiplexer.listAgents].
///
/// Mirrors [MuxSessionsResult] for the same reason: an adapter's
/// agent-tracking server being unreachable is a distinct, explicit state,
/// never an empty [MuxAgentsAvailable.agents] list — the
/// multiplexer-abstraction spec's "Explicit State on List Failure, Never
/// an Empty List" requirement, applied here to agent state rather than
/// sessions. A thrown exception has the same defect a boolean guard has
/// per design.md AD-2's rationale for why [MultiplexerAdapter.agents] is
/// a nullable accessor rather than a `supports()` flag: invisible to the
/// type system, ignorable while compiling. This sealed result closes that
/// same gap for the CONTENT of an agent-aware call, not just for whether
/// the call is reachable at all. See the apply report's D5.
sealed class MuxAgentsResult {
  const MuxAgentsResult();
}

/// Agents were successfully enumerated.
///
/// [agents] may itself be empty when the agent-tracking server IS running
/// and genuinely has zero agents — a different, valid case from
/// [MuxAgentServerNotRunning].
final class MuxAgentsAvailable extends MuxAgentsResult {
  const MuxAgentsAvailable(this.agents);

  final List<AgentStatus> agents;
}

/// The adapter's agent-tracking server or daemon process is not reachable.
///
/// MUST NOT be confused with [MuxAgentsAvailable] carrying an empty list —
/// that reads as "no agents are working", a different claim from "the
/// server cannot be reached to find out".
final class MuxAgentServerNotRunning extends MuxAgentsResult {
  const MuxAgentServerNotRunning();
}

/// One pane reported by [PaneAwareMultiplexer.listPanes].
///
/// Deliberately THREE fields out of the twelve herdr sends. This type is
/// consumed by exactly one question — has this pane been worked in, or was
/// it merely recreated? — and only these three answer it:
///
/// * [revision] is the multiplexer's own per-pane change counter. A pane
///   that has never been written to sits at its initial value; anything
///   past 1 is the host's own record that something happened there.
/// * [cwd] compared against the user's home directory distinguishes a
///   shell someone navigated somewhere from one that opened at its
///   default.
/// * [paneId] identifies which pane a verdict is about.
///
/// Parsing `foreground_cwd`, `scroll`, `terminal_title` and the rest would
/// be storing fields no caller reads, and every stored field is a field a
/// future reader has to work out whether they may trust.
typedef MuxPane = ({String paneId, int revision, String cwd});

/// Result of [PaneAwareMultiplexer.listPanes].
///
/// Mirrors [MuxSessionsResult] and [MuxAgentsResult] for the third time and
/// for the same reason, which is not ceremony: an empty pane list is a
/// CLAIM — "this session has no panes" — and a caller about to tell a user
/// their session came back empty must not be able to reach that conclusion
/// from a query that simply failed. See the
/// multiplexer-abstraction spec's "Explicit State on List Failure, Never an
/// Empty List" requirement.
sealed class MuxPanesResult {
  const MuxPanesResult();
}

/// Panes were successfully enumerated.
///
/// [panes] may itself be empty when the server IS running and the session
/// genuinely has no panes — a different, valid case from
/// [MuxPaneServerNotRunning].
final class MuxPanesAvailable extends MuxPanesResult {
  const MuxPanesAvailable(this.panes);

  final List<MuxPane> panes;
}

/// The adapter's server or daemon process is not reachable, so nothing is
/// known about this session's panes.
///
/// MUST NOT be confused with [MuxPanesAvailable] carrying an empty list.
final class MuxPaneServerNotRunning extends MuxPanesResult {
  const MuxPaneServerNotRunning();
}

/// Execution surface for adapters that advertise [MuxCapability.paneListing].
///
/// Reachable only through [MultiplexerAdapter.panes], for the same
/// type-enforcement reason [AgentAwareMultiplexer] is reachable only
/// through [MultiplexerAdapter.agents]: a caller cannot enumerate panes
/// without first proving, via a null check, that the multiplexer can
/// report them. See design.md AD-2.
abstract interface class PaneAwareMultiplexer {
  Future<MuxPanesResult> listPanes();
}

/// Result of [AgentAwareMultiplexer.waitForAgent].
///
/// THREE variants because a nullable [AgentStatus] cannot keep the two
/// no-match cases apart, and they demand opposite reactions: a wait that
/// simply ran out of time means "nothing changed, ask again", while a wait
/// that broke means "we could not find out". Collapsing them into `null`
/// would let a caller re-arm forever against a host that can no longer
/// answer, publishing a stale agent state the whole time — the same class
/// of lie [MuxAgentsResult] exists to prevent for the LIST, applied here
/// to the WAIT.
sealed class MuxAgentWaitResult {
  const MuxAgentWaitResult();
}

/// The agent reached one of the requested states. [agent] is its state as
/// of the moment the wait returned.
final class MuxAgentWaitMatched extends MuxAgentWaitResult {
  const MuxAgentWaitMatched(this.agent);

  final AgentStatus agent;
}

/// The wait ran its full duration without the agent entering any requested
/// state. NOT an error: the agent is simply still where it was, and a
/// caller may re-arm immediately.
final class MuxAgentWaitTimedOut extends MuxAgentWaitResult {
  const MuxAgentWaitTimedOut();
}

/// The wait could not be performed or did not survive: the agent-tracking
/// server was unreachable, the target no longer exists, the transport gave
/// up, or the multiplexer answered in a shape this adapter does not
/// recognize.
///
/// MUST NOT be treated as [MuxAgentWaitTimedOut]. [code] carries the
/// multiplexer's machine-readable error code when it gave one, and is null
/// when it did not — an unrecognized failure is reported as unrecognized,
/// never mapped onto a known code.
final class MuxAgentWaitFailed extends MuxAgentWaitResult {
  const MuxAgentWaitFailed(this.code);

  final String? code;
}

/// Result of [AgentAwareMultiplexer.focusAgent].
///
/// THREE variants, and a `bool` would have been wrong for the same reason
/// an empty list is wrong for [MuxAgentsResult]: `false` reads as one fact
/// while covering two, and the caller here acts on the difference. A user
/// tapped an agent in a list they are looking at RIGHT NOW. If that agent
/// is gone, the honest answer is that the list is stale — a claim about
/// helm's own screen. If the host could not be reached, nothing at all is
/// known about that agent, including whether it is still there. Telling a
/// person "that agent is gone" when the truth is "we could not ask" is the
/// same lie [AgentSnapshot] exists to prevent, arriving through an ACTION
/// instead of through a reading.
///
/// The consumer is a UI gesture, so nothing here throws: a tap handler is
/// not a place an unhandled error may surface from. Every outcome is a
/// value the caller must switch over.
sealed class MuxAgentFocusResult {
  const MuxAgentFocusResult();
}

/// The multiplexer raised the agent's pane.
///
/// Carries NOTHING deliberately. herdr answers with the focused agent's
/// full `AgentInfo`, and storing it would be storing a field no caller
/// reads — the reason [MuxPane] drops nine of herdr's twelve pane fields.
/// It also keeps the success path free of a parse: this variant is decided
/// by the exit status, so a response body helm never reads cannot break
/// the one operation the user is waiting on.
final class MuxAgentFocused extends MuxAgentFocusResult {
  const MuxAgentFocused();
}

/// The multiplexer has no such agent: the pane closed, or the agent exited,
/// between the list being drawn and the row being tapped.
///
/// MUST NOT be collapsed into [MuxAgentFocusFailed]. This one is a fact
/// about the HOST that helm can act on — the list on screen is out of
/// date — while a failure means helm could not find out anything.
final class MuxAgentFocusTargetNotFound extends MuxAgentFocusResult {
  const MuxAgentFocusTargetNotFound();
}

/// The focus could not be performed or its outcome is unknown: the
/// agent-tracking server was unreachable, the transport gave up, or the
/// multiplexer failed in a way this adapter does not recognize.
///
/// MUST NOT be treated as [MuxAgentFocused]. [code] carries the
/// multiplexer's machine-readable error code when it gave one, and is null
/// when it did not, so an unrecognized failure is reported as unrecognized
/// rather than mapped onto a known one — the discipline
/// [MuxAgentWaitFailed] states, for the same reason.
///
/// `server_not_running` deliberately does NOT get its own variant the way
/// it does in [MuxAgentsResult] and [MuxPanesResult]. Those are LISTS,
/// where the whole hazard is an unreachable server being read as "nothing
/// there"; this is a single action with no empty answer to be confused
/// with, and no caller reacts to a dead socket differently from any other
/// way of not knowing. A variant nobody switches on is a variant every
/// future reader has to justify, so the code is carried instead.
final class MuxAgentFocusFailed extends MuxAgentFocusResult {
  const MuxAgentFocusFailed(this.code);

  final String? code;
}

/// Execution surface for adapters that advertise [MuxCapability.agentState].
///
/// Reachable only through [MultiplexerAdapter.agents]: there is no
/// standalone way to obtain one, so a caller cannot invoke these methods
/// without first proving — via a null check — that the adapter supports
/// agent state. See design.md AD-2.
abstract interface class AgentAwareMultiplexer {
  Future<MuxAgentsResult> listAgents();

  /// Blocks until [target]'s agent enters one of [until], or until
  /// [timeout] elapses.
  ///
  /// [timeout] is REQUIRED, and the reason is not style. The implementation
  /// is expected to bound the wait ON THE HOST — `herdr agent wait` takes
  /// its own `--timeout` and exits — because a deadline applied on this
  /// side would only stop LISTENING: `Future.timeout` abandons the future
  /// without closing the remote channel, and a caller that re-armed after
  /// each abandonment would stack one held channel per attempt until
  /// OpenSSH's `MaxSessions` starved the connection. A required parameter
  /// makes that deadline impossible to forget; see [kAgentListTimeout]'s
  /// doc comment in `terminal_session.dart` for the incident this rule
  /// comes from.
  ///
  /// A caller MUST check [MuxCapability.agentWait] before looping on this
  /// method: an adapter that does not advertise it may answer instantly,
  /// and "wait, then re-arm" would become a spin.
  ///
  /// Note that a wait armed with the state the agent is ALREADY in returns
  /// immediately — measured against herdr 0.8.0. A caller that wants to be
  /// told about CHANGE must therefore arm the complement of the current
  /// state.
  Future<MuxAgentWaitResult> waitForAgent(
    String target, {
    required Set<AgentState> until,
    required Duration timeout,
  });

  /// Brings [target]'s pane to the front on the HOST, so the user is
  /// looking at that agent.
  ///
  /// [target] is the same identifier [AgentStatus.target] carries — the
  /// PANE id, not the terminal id. That is not an assumption: MEASURED
  /// against herdr 0.8.2, `agent focus term_65a07c99f57a51` answers
  /// `agent_not_found` exactly as `agent wait` does with the same input.
  ///
  /// Unlike [waitForAgent] this takes no timeout, and the asymmetry is the
  /// point rather than an omission. A wait is armed to BLOCK, so it needs
  /// a deadline the host itself will honour or it holds a channel until
  /// `MaxSessions` starves the connection (see [kAgentListTimeout]'s doc
  /// comment in `terminal_session.dart`). A focus is a one-shot command
  /// that returns as soon as the multiplexer has moved the pane, so there
  /// is no host-side deadline to hand it. Bounding a wedged one is the
  /// CALLER's job, and it is a transport concern, not a herdr flag — see
  /// `TerminalSession.focusAgent`.
  Future<MuxAgentFocusResult> focusAgent(String target);
}

/// One adapter contract across every supported multiplexer.
///
/// Only five operations are uniform across herdr/tmux/zellij: [detect],
/// [listSessions], [hasSession], [attachCommand], and the install/version
/// state reported by [detect]. Everything else — agent state, dead-session
/// resurrection, structured output — is an advertised [MuxCapability],
/// negotiated explicitly rather than assumed present everywhere. See
/// design.md's Technical Approach and AD-2.
abstract interface class MultiplexerAdapter {
  MultiplexerId get id;

  /// Advertised for REPORTING — e.g. "this host cannot tell you when an
  /// agent blocks". Does not gate execution; see [agents].
  Set<MuxCapability> get capabilities;

  /// Non-null only when [MuxCapability.agentState] is advertised.
  ///
  /// This is the EXECUTION guard, not [capabilities]: the type system
  /// forces a null check before agent-state methods are reachable, so a
  /// caller cannot skip the check and still compile. See AD-2.
  AgentAwareMultiplexer? get agents;

  /// Non-null only when [MuxCapability.paneListing] is advertised.
  ///
  /// Same execution guard as [agents], for a second, INDEPENDENT fact: a
  /// multiplexer that can list agents is not thereby able to say whether
  /// its panes have been worked in. Keeping the two accessors separate is
  /// what stops one capability being read as evidence for the other.
  PaneAwareMultiplexer? get panes;

  Future<MuxDetection> detect();

  Future<MuxSessionsResult> listSessions();

  Future<bool> hasSession(String name);

  /// Pure — no I/O. Quotes [sessionName] via `shellQuote` because session
  /// names are user-controlled and reach a remote shell. See AD-3.
  String attachCommand(String sessionName);
}

/// Resolves whether a caller can reach agent state on [adapter].
///
/// A caller that needs agent state MUST use [resolve] rather than treating
/// a null [MultiplexerAdapter.agents] as "no agents are working" — see the
/// multiplexer-abstraction spec's "Agent-State Capability Is Advertised,
/// Not Assumed" requirement.
sealed class AgentSupport {
  const AgentSupport();

  static AgentSupport resolve(MultiplexerAdapter adapter) {
    final agents = adapter.agents;
    if (agents == null) return AgentSupportUnsupported(adapter.id);
    return AgentSupportAvailable(agents);
  }
}

/// [MultiplexerAdapter.agents] was null: the adapter does not advertise
/// agent-state support. Never mistake this for "no agents are working".
final class AgentSupportUnsupported extends AgentSupport {
  const AgentSupportUnsupported(this.muxId);

  final MultiplexerId muxId;
}

/// [MultiplexerAdapter.agents] was non-null and is ready to use.
final class AgentSupportAvailable extends AgentSupport {
  const AgentSupportAvailable(this.agents);

  final AgentAwareMultiplexer agents;
}
