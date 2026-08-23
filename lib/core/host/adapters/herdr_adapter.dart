import 'dart:convert';

import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/shell_quote.dart';

/// [MultiplexerAdapter] backed by the `herdr` CLI over a
/// [HostCommandRunner].
///
/// herdr is the only supported multiplexer that reports AI-agent state, so
/// this is the first (and only) adapter that advertises
/// [MuxCapability.agentState] and implements [AgentAwareMultiplexer]
/// itself. See design.md's adapter capability table and AD-2.
///
/// herdr has TWO DISTINCT wire contracts — this adapter does NOT parse one
/// by analogy to the other:
///
/// 1. SOCKET-backed commands (`agent list`) go through herdr's local unix
///    socket and use its schema-confirmed `{id, result}` / `{id, error:
///    {code, message}}` envelope, confirmed against a real herdr 0.8.0
///    binary's bundled schema (`herdr api schema --json`, protocol 19).
/// 2. LOCAL commands (`session list --json`) read the session/config
///    directory directly and use a bare `{sessions: [...]}` envelope with
///    NO `id`/`result` wrapper — confirmed by a real captured invocation,
///    not the schema. This command succeeds (exit 0) even with no server
///    running, unlike `agent list`.
///
/// See `test/core/host/adapters/herdr_adapter_test.dart`'s header comment
/// for exactly which facts are CONFIRMED versus this adapter's own
/// disclosed assumptions.
class HerdrAdapter implements MultiplexerAdapter, AgentAwareMultiplexer {
  HerdrAdapter(this._runner, {String absPath = 'herdr', String? sessionRef})
    : _absPath = absPath,
      _sessionRef = sessionRef;

  final HostCommandRunner _runner;

  /// The resolved absolute path of the herdr binary, or the bare `herdr`
  /// name when no probe-resolved path was supplied. See AD-3: commands
  /// that reach a remote shell use the resolved path, not a bare name.
  final String _absPath;

  /// The herdr session whose socket socket-backed commands must target, or
  /// null to let herdr pick its default session.
  ///
  /// MEASURED against a real herdr 0.8.0 host, not assumed: each herdr
  /// session owns its OWN api socket
  /// (`~/.config/herdr/sessions/<name>/herdr.sock` versus the default
  /// session's `~/.config/herdr/herdr.sock`), and `agent list` answers only
  /// for the socket it connects to. A bare `herdr agent list` issued while
  /// attached to session `helm-0` was observed returning `agents: []` at
  /// the same instant `herdr --session helm-0 agent list` returned a
  /// working agent — a confident, WRONG "no agents are running".
  ///
  /// That is precisely the failure [MuxAgentsAvailable] versus
  /// [MuxAgentServerNotRunning] exists to prevent, arriving through the
  /// command instead of through the parse, so it is closed here: an adapter
  /// built for a session reports THAT session's agents.
  ///
  /// Null keeps the pre-existing command byte-for-byte, so a caller that
  /// never had a session to scope to is no worse off than before.
  final String? _sessionRef;

  @override
  MultiplexerId get id => MultiplexerId.herdr;

  @override
  Set<MuxCapability> get capabilities => const {
    MuxCapability.agentState,
    MuxCapability.structuredOutput,
  };

  /// Always non-null: herdr is the only multiplexer that advertises
  /// [MuxCapability.agentState], and this adapter implements
  /// [AgentAwareMultiplexer] itself. See AD-2.
  @override
  AgentAwareMultiplexer? get agents => this;

  @override
  Future<MuxDetection> detect() async {
    final result = await _runner.run(
      'command -v $_absPath >/dev/null 2>&1 && $_absPath --version',
    );
    if (result.exitCode != 0) return const MuxDetection.notInstalled();
    return MuxDetection.installed(
      absPath: _absPath,
      version: result.stdout.trim(),
    );
  }

  @override
  Future<MuxSessionsResult> listSessions() async {
    final result = await _runner.run(_sessionListCommand);
    if (result.exitCode != 0) {
      // CONFIRMED: `session list --json` is a LOCAL operation (it reads
      // the session/config directory) and exits 0 even when no herdr
      // server is running — a real captured invocation with no server
      // returns exit code 0 and a default session with `running: false`.
      // Because of that, [MuxServerNotRunning] is NOT reachable here for
      // a genuine "no server" case the way it is for herdr's socket-
      // backed `agent list`, or for tmux/zellij's own server checks. A
      // non-zero exit still needs a defined outcome (a corrupted session
      // directory, a permission error, or some other unclassified
      // failure — a missing binary is already caught by [detect]), and
      // [MuxSessionsResult] has only two variants. [MuxServerNotRunning]
      // is returned here as the best available typed signal — callers
      // still get an explicit failure state rather than a crash or a
      // silently empty list — but for herdr specifically it should be
      // read as "the list command itself failed", not literally "no
      // server is running". No verified failure sample exists for this
      // branch; widening [MuxSessionsResult] to add a third variant was
      // out of scope for this fix.
      return const MuxServerNotRunning();
    }

    return MuxSessionsAvailable(_parseSessions(result.stdout));
  }

  @override
  Future<bool> hasSession(String name) async {
    final result = await listSessions();
    return switch (result) {
      MuxSessionsAvailable(:final sessions) => sessions.any(
        (s) => s.name == name,
      ),
      MuxServerNotRunning() => false,
    };
  }

  @override
  String attachCommand(String sessionName) {
    return '$_absPath session attach ${shellQuote(sessionName)}';
  }

  @override
  Future<MuxAgentsResult> listAgents() async {
    final result = await _runner.run(_agentListCommand);
    if (result.exitCode != 0) {
      final code = _parseErrorCode(result.stderr);
      if (code == 'server_not_running') {
        // CONFIRMED: no server running exits non-zero with stderr
        // {"error":{"code":"server_not_running", ...}} and empty stdout.
        // This MUST report a typed state rather than silently return an
        // empty list — an empty list here would read as "no agents are
        // working", the exact trap the spec's list-failure requirement
        // warns against for sessions, extended here to a capability
        // herdr advertises as genuinely live.
        return const MuxAgentServerNotRunning();
      }
      // CONFIRMED: herdr's error envelope always carries a machine-
      // readable `error.code`. A code other than `server_not_running` —
      // or stderr that is not the expected JSON error envelope at all —
      // is a genuinely unexpected failure and MUST NOT be silently
      // collapsed into the common, expected "server not running" state.
      // There is no third [MuxAgentsResult] variant for it, so it is
      // surfaced loudly here instead of swallowed. See the apply
      // report's D6.
      throw StateError(
        'herdr agent list failed with an unrecognized error '
        '(exit code ${result.exitCode}): '
        '${code ?? 'no machine-readable error.code in stderr'}',
      );
    }
    final envelope = jsonDecode(result.stdout) as Map<String, dynamic>;
    final agentsJson =
        (envelope['result'] as Map<String, dynamic>)['agents'] as List;
    return MuxAgentsAvailable(
      agentsJson.cast<Map<String, dynamic>>().map(_parseAgentInfo).toList(),
    );
  }

  @override
  Future<AgentStatus?> waitForAgent(
    String target, {
    required Set<AgentState> until,
  }) async {
    // Single-shot check against the agent's CURRENT state — does not poll
    // or block. This adapter does not advertise [MuxCapability.agentWait]
    // (see [capabilities]): a real blocking wait would need either the
    // unverified `herdr agent wait` CLI subcommand (explicitly out of
    // scope for this slice) or an unverified polling protocol against a
    // live host, and advertising a capability this method does not back
    // would be dishonest. See the apply report's D4.
    final result = await listAgents();
    final agents = switch (result) {
      MuxAgentsAvailable(:final agents) => agents,
      MuxAgentServerNotRunning() => const <AgentStatus>[],
    };
    for (final agent in agents) {
      if (agent.target == target && until.contains(agent.state)) {
        return agent;
      }
    }
    return null;
  }

  // ── Private ────────────────────────────────────────────────────────────

  /// `--session` is a GLOBAL option and MUST precede the subcommand —
  /// verified against the real binary, where `herdr --session helm-0 agent
  /// list` succeeds and the trailing-flag spellings are rejected outright.
  String get _agentListCommand => '$_absPath${_sessionScope}agent list';

  /// Deliberately NOT scoped. `session list --json` enumerates every herdr
  /// session by reading the config directory (see [listSessions]); pinning
  /// it to one session would be asking a global question through a local
  /// lens.
  String get _sessionListCommand => '$_absPath session list --json';

  String get _sessionScope =>
      _sessionRef == null ? ' ' : ' --session ${shellQuote(_sessionRef)} ';

  /// Extracts `error.code` from herdr's socket-backed error envelope
  /// (`{id, error: {code, message}}` — CONFIRMED, `code` always present
  /// as a string). Returns null when [stderr] is not valid JSON or does
  /// not have the expected shape, so a genuinely malformed or unexpected
  /// failure is never misread as a recognized code. See the apply
  /// report's D6.
  String? _parseErrorCode(String stderr) {
    try {
      final envelope = jsonDecode(stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>?;
      return error?['code'] as String?;
    } on FormatException {
      return null;
    }
  }

  /// Parses one herdr `AgentInfo` JSON object into an [AgentStatus].
  ///
  /// `terminal_id` and `agent_status` are schema-required. `name`/`title`
  /// are schema-optional, so [label] falls back through name → title →
  /// terminal_id rather than assuming either exists.
  AgentStatus _parseAgentInfo(Map<String, dynamic> json) {
    final terminalId = json['terminal_id'] as String;
    final label =
        (json['name'] as String?) ?? (json['title'] as String?) ?? terminalId;
    return (
      target: terminalId,
      label: label,
      state: _parseAgentState(json['agent_status'] as String),
    );
  }

  /// Maps a herdr `agent_status` string to [AgentState]. Unrecognized
  /// values map to [AgentState.unknown] rather than throwing, matching the
  /// probe wire contract's forward-compatible-reading spirit for a value
  /// domain that may grow.
  AgentState _parseAgentState(String raw) => switch (raw) {
    'idle' => AgentState.idle,
    'working' => AgentState.working,
    'blocked' => AgentState.blocked,
    'done' => AgentState.done,
    _ => AgentState.unknown,
  };

  /// Parses `herdr session list --json`'s stdout into [MuxSession]s.
  ///
  /// CONFIRMED against a real captured invocation: this is a bare
  /// `{sessions: [...]}` envelope — there is NO `id` key and NO `result`
  /// key wrapping it, unlike the socket-backed `agent list`'s `{id,
  /// result: {...}}` shape. Each session reports a `running` boolean, not
  /// a `status` string; there is no `active`/`exited` field at all. See
  /// [_mapSessionState] for the `running` → [MuxSessionState] mapping
  /// decision.
  List<MuxSession> _parseSessions(String stdout) {
    final envelope = jsonDecode(stdout) as Map<String, dynamic>;
    final sessionsJson = envelope['sessions'] as List;
    return sessionsJson.cast<Map<String, dynamic>>().map((json) {
      final name = json['name'] as String;
      final running = json['running'] as bool;
      return (name: name, state: _mapSessionState(running));
    }).toList();
  }

  /// Maps herdr's per-session `running` boolean to [MuxSessionState].
  ///
  /// herdr has no `active`/`exited` status string — only `running`
  /// (CONFIRMED). A session herdr still lists with `running: false` is a
  /// known session that is currently stopped, not one that has been
  /// deleted — herdr has explicit `session stop`/`session delete`
  /// subcommands, so "known but stopped" and "gone entirely" are
  /// different things, and a stopped-but-known session must still be
  /// reported rather than silently dropped, per the spec's "session that
  /// has exited is reported as exited, not omitted" requirement.
  /// [MuxSessionState.exited] is the closest existing value for that
  /// case. [MuxSessionState.unknown] is deliberately NOT used here:
  /// herdr's `running` field is unambiguous, unlike an adapter that
  /// genuinely cannot tell active apart from exited for a given entry.
  MuxSessionState _mapSessionState(bool running) =>
      running ? MuxSessionState.active : MuxSessionState.exited;
}
