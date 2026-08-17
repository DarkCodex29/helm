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
  agentWait,
  structuredOutput,
  sessionWorkingDirectory,
  deadSessionResurrection,
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

/// Execution surface for adapters that advertise [MuxCapability.agentState].
///
/// Reachable only through [MultiplexerAdapter.agents]: there is no
/// standalone way to obtain one, so a caller cannot invoke these methods
/// without first proving — via a null check — that the adapter supports
/// agent state. See design.md AD-2.
abstract interface class AgentAwareMultiplexer {
  Future<List<AgentStatus>> listAgents();

  Future<AgentStatus?> waitForAgent(
    String target, {
    required Set<AgentState> until,
    Duration? timeout,
  });
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
