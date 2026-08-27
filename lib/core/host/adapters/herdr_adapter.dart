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
class HerdrAdapter
    implements MultiplexerAdapter, AgentAwareMultiplexer, PaneAwareMultiplexer {
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
    // Backed by a genuinely blocking `herdr agent wait` — see
    // [waitForAgent] for the live measurements this rests on.
    MuxCapability.agentWait,
    MuxCapability.structuredOutput,
    // herdr is the only multiplexer with a per-pane revision counter, which
    // is the one field that makes "worked in" versus "merely recreated"
    // answerable at all. See [listPanes].
    MuxCapability.paneListing,
  };

  /// Always non-null: herdr is the only multiplexer that advertises
  /// [MuxCapability.agentState], and this adapter implements
  /// [AgentAwareMultiplexer] itself. See AD-2.
  @override
  AgentAwareMultiplexer? get agents => this;

  /// Always non-null, for the same reason [agents] is.
  @override
  PaneAwareMultiplexer? get panes => this;

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

  /// Enumerates the scoped session's panes via `herdr pane list`.
  ///
  /// SOCKET-backed, like [listAgents] and unlike [listSessions]: it reports
  /// LIVE pane state rather than reading the session directory, so it uses
  /// herdr's `{id, result}` / `{id, error: {code, message}}` envelope and
  /// fails with `server_not_running` when no server is up. The response
  /// carries `{"panes": [...], "type": "pane_list"}`.
  ///
  /// Each pane object carries twelve fields — `pane_id`, `tab_id`,
  /// `workspace_id`, `terminal_id`, `revision`, `cwd`, `foreground_cwd`,
  /// `focused`, `agent_status`, `terminal_title`,
  /// `terminal_title_stripped`, `scroll` — and this reads THREE. See
  /// [MuxPane] for why the other nine are deliberately dropped.
  ///
  /// Error handling is [listAgents]', not a variation on it: the only
  /// recognized failure is `server_not_running`, and any other
  /// machine-readable code — or stderr that is not the JSON envelope at
  /// all — is thrown rather than collapsed into it. Collapsing here would
  /// be worse than it is for agents: this result feeds a verdict the user
  /// reads as "your session came back empty", and a misclassified failure
  /// would be the evidence for that claim.
  @override
  Future<MuxPanesResult> listPanes() async {
    final result = await _runner.run(_paneListCommand);
    if (result.exitCode != 0) {
      final code = _parseErrorCode(result.stderr);
      if (code == 'server_not_running') return const MuxPaneServerNotRunning();
      throw StateError(
        'herdr pane list failed with an unrecognized error '
        '(exit code ${result.exitCode}): '
        '${code ?? 'no machine-readable error.code in stderr'}',
      );
    }
    final envelope = jsonDecode(result.stdout) as Map<String, dynamic>;
    final panesJson =
        (envelope['result'] as Map<String, dynamic>)['panes'] as List;
    return MuxPanesAvailable(
      panesJson.cast<Map<String, dynamic>>().map(_parsePaneInfo).toList(),
    );
  }

  /// Blocks on `herdr agent wait` until [target] enters one of [until], or
  /// until herdr's own `--timeout` expires.
  ///
  /// MEASURED against a real herdr 0.8.0 host — this subcommand was
  /// previously documented here as unverified and out of scope, and this
  /// method faked the wait with [listAgents] plus a filter. Every claim
  /// below now comes from a live invocation:
  ///
  /// * `agent wait <TARGET> [--until <STATUS>]... [--timeout <MS>]`, where
  ///   `--until` repeats and accepts idle|working|blocked|done|unknown.
  /// * It is EVENT-DRIVEN, not internally polled: with the wait armed, the
  ///   host state was flipped after 5s of sleep and the call returned at
  ///   5.055s — a 55ms reaction.
  /// * Success exits 0 with `{id, result: {agent, type: "agent_info"}}` —
  ///   one AGENT, not the `agents` LIST that `agent list` returns.
  /// * A timeout exits 1 with `{error: {code: "timeout", ...}}` on stderr.
  /// * A wait armed with the state the agent is ALREADY in returns
  ///   immediately (0.115s — process startup). A caller that wants to hear
  ///   about CHANGE must arm the complement of the current state.
  ///
  /// [timeout] is spent on the HOST, via `--timeout`, and is deliberately
  /// NOT also applied to [HostCommandRunner.run] as a transport deadline.
  /// The distinction is the one [kAgentListTimeout] was written about:
  /// herdr's own flag CANCELS the work — the remote process exits and its
  /// channel closes — whereas a transport deadline merely ABANDONS the
  /// future, leaving the channel held. Since a caller re-arms after every
  /// return, abandonment would stack one held channel per window until
  /// OpenSSH's `MaxSessions` starved the connection. Awaiting a
  /// self-terminating remote command keeps the ceiling at exactly one
  /// channel by construction rather than by a guard flag.
  ///
  /// The residual case that buys: a herdr that ignores its own `--timeout`
  /// holds one channel indefinitely, and this method never notices. That is
  /// the same single-channel exposure the previous implementation bounded,
  /// and a genuinely dead transport is still caught a layer up, where the
  /// SSH client's own teardown disconnects the session.
  @override
  Future<MuxAgentWaitResult> waitForAgent(
    String target, {
    required Set<AgentState> until,
    required Duration timeout,
  }) async {
    if (until.isEmpty) {
      // herdr does not treat "no --until" as "no states": it substitutes
      // its own documented default of idle|done|blocked. Emitting the
      // command anyway would silently wait for states the caller never
      // asked for, so an empty set fails here instead.
      throw ArgumentError.value(
        until,
        'until',
        'must name at least one state: herdr substitutes its own default '
            '(idle|done|blocked) when no --until is given',
      );
    }

    final result = await _runner.run(_agentWaitCommand(target, until, timeout));

    if (result.timedOut || result.exitCode == null) {
      // The TRANSPORT gave up, which is not herdr reporting a timeout: no
      // exit status was read, so nothing is known about the agent. Reported
      // as a failure so a caller does not read it as "nothing changed".
      return const MuxAgentWaitFailed('transport_incomplete');
    }
    if (result.exitCode != 0) {
      final code = _parseErrorCode(result.stderr);
      // `timeout` is the ONLY code that means "nothing changed"; every
      // other one — agent_not_found for a pane that vanished,
      // server_not_running for a dead socket, or stderr that is not the
      // JSON envelope at all — means we could not find out.
      if (code == 'timeout') return const MuxAgentWaitTimedOut();
      return MuxAgentWaitFailed(code);
    }

    final envelope = jsonDecode(result.stdout) as Map<String, dynamic>;
    final agentJson =
        (envelope['result'] as Map<String, dynamic>)['agent']
            as Map<String, dynamic>;
    return MuxAgentWaitMatched(_parseAgentInfo(agentJson));
  }

  /// Raises [target]'s pane via `herdr agent focus`.
  ///
  /// MEASURED against a real herdr 0.8.2 binary, not assumed:
  ///
  /// ```text
  /// $ herdr agent focus --help
  ///   Focus an agent
  ///   Usage: herdr agent focus <target>
  /// ```
  ///
  /// The target is POSITIONAL — there is no `--target` flag — and it is
  /// the pane id, the identifier [_parseAgentInfo] already puts in
  /// [AgentStatus.target]. Three outcomes were observed, all three
  /// separable from the exit code plus `error.code`:
  ///
  /// * exit 0, stdout `{id, result: {agent, type: "agent_info"}}` — herdr
  ///   echoes the agent it focused, in `agent wait`'s envelope rather than
  ///   `agent list`'s.
  /// * exit 1, stderr `{"error":{"code":"agent_not_found", ...}}`.
  /// * exit 1, stderr `{"error":{"code":"server_not_running", ...}}`.
  ///
  /// The success body is deliberately NOT parsed. Nothing downstream reads
  /// it (see [MuxAgentFocused]), and a parse of a payload no caller wants
  /// would be one more way for this operation to fail while the host in
  /// fact did the thing that was asked. Success is the exit status.
  ///
  /// Error handling is [listAgents]' in substance and [waitForAgent]'s in
  /// shape: the machine-readable `error.code` decides the outcome, and a
  /// code this adapter does not recognize is never silently collapsed into
  /// one it does. It is RETURNED rather than thrown — unlike [listAgents],
  /// which has nowhere to put it — because the only caller is a tap
  /// handler, and a [StateError] escaping into a button callback would
  /// surface as an unhandled async error instead of as feedback.
  @override
  Future<MuxAgentFocusResult> focusAgent(String target) async {
    final result = await _runner.run(_agentFocusCommand(target));
    if (result.timedOut || result.exitCode == null) {
      // No exit status was read, so nothing is known about whether the
      // pane moved. Never reported as success.
      return const MuxAgentFocusFailed('transport_incomplete');
    }
    if (result.exitCode != 0) {
      final code = _parseErrorCode(result.stderr);
      // The ONLY code that means "the agent is not there"; everything
      // else — a dead socket, an unrecognized code, or stderr that is not
      // the JSON envelope at all — means we could not find out.
      if (code == 'agent_not_found') return const MuxAgentFocusTargetNotFound();
      return MuxAgentFocusFailed(code);
    }
    return const MuxAgentFocused();
  }

  // ── Private ────────────────────────────────────────────────────────────

  /// Builds the `agent focus` invocation.
  ///
  /// [target] is shell-quoted because it reaches a remote shell and is
  /// host-supplied (AD-3), and `--session` precedes the subcommand because
  /// it is a GLOBAL option. See [_agentListCommand].
  String _agentFocusCommand(String target) =>
      '$_absPath${_sessionScope}agent focus ${shellQuote(target)}';

  /// Builds the `agent wait` invocation.
  ///
  /// [until] is emitted in [AgentState] declaration order rather than in
  /// set-iteration order, so the emitted string does not depend on the
  /// order a caller happened to build its set in — the command is what
  /// tests assert on, because both of this adapter's shipped defects lived
  /// in the command while the parse stayed green.
  String _agentWaitCommand(
    String target,
    Set<AgentState> until,
    Duration timeout,
  ) {
    final states = AgentState.values
        .where(until.contains)
        .map((state) => '--until ${state.name}')
        .join(' ');
    return '$_absPath${_sessionScope}agent wait ${shellQuote(target)} '
        '$states --timeout ${timeout.inMilliseconds}';
  }

  /// `--session` is a GLOBAL option and MUST precede the subcommand —
  /// verified against the real binary, where `herdr --session helm-0 agent
  /// list` succeeds and the trailing-flag spellings are rejected outright.
  String get _agentListCommand => '$_absPath${_sessionScope}agent list';

  /// Scoped for the same MEASURED reason [_agentListCommand] is: each herdr
  /// session owns its own api socket, and a socket-backed query answers
  /// only for the socket it connects to. An unscoped `pane list` would
  /// describe the DEFAULT session's panes while the verdict was published
  /// against the attached one.
  ///
  /// `--session` precedes the subcommand because it is a GLOBAL option —
  /// verified against the real binary, where the trailing spellings are
  /// rejected outright. See [_agentListCommand].
  String get _paneListCommand => '$_absPath${_sessionScope}pane list';

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
  /// [AgentStatus.target] carries `pane_id`, NOT `terminal_id`, because
  /// `target` is named after the one operation that consumes it —
  /// [waitForAgent] — and MEASURED against a real herdr 0.8.0 host, that
  /// operation accepts only the pane id:
  ///
  /// ```text
  /// agent wait w1:p1               → blocks, then returns the agent
  /// agent wait term_659ab3dc3a8541 → {"error":{"code":"agent_not_found",
  ///                                  "message":"agent target ... not
  ///                                  found"}}
  /// ```
  ///
  /// A field named `target` holding an identifier the only target-taking
  /// method rejects is a lie encoded in the type, so the pane id wins the
  /// name. Nothing else needed the terminal id: its only other uses were
  /// this label fallback and a widget key, and a pane id is equally
  /// unique and stable for both.
  ///
  /// `pane_id`, `terminal_id` and `agent_status` are all schema-required
  /// (protocol 19). `name`, `title` and `agent` are all schema-optional, so
  /// [label] falls back through name → title → agent → terminal_id rather
  /// than assuming any of them exists.
  ///
  /// `agent` earns its place in that chain from a MEASURED fact, not from
  /// the schema: a real `agent list` against herdr 0.8.0 carries NEITHER
  /// `name` NOR `title`, but it does carry `agent` ("claude"). A chain
  /// that stopped at `title` therefore fell through to the terminal id on
  /// every real agent, and the user read `term_659ab3dc3a8541` where the
  /// host knew the answer was `claude`. `terminal_id` stays as the last
  /// resort because it is the only one of the four the schema guarantees.
  AgentStatus _parseAgentInfo(Map<String, dynamic> json) {
    final terminalId = json['terminal_id'] as String;
    final label =
        (json['name'] as String?) ??
        (json['title'] as String?) ??
        (json['agent'] as String?) ??
        terminalId;
    return (
      target: json['pane_id'] as String,
      label: label,
      state: _parseAgentState(json['agent_status'] as String),
    );
  }

  /// Parses one `pane list` entry into a [MuxPane].
  ///
  /// `revision` is read as an `int` rather than coerced from `num`: herdr
  /// emits it as a JSON integer, and a silent `.toInt()` would hide a wire
  /// contract that had changed underneath the one comparison the verdict
  /// depends on.
  MuxPane _parsePaneInfo(Map<String, dynamic> json) => (
    paneId: json['pane_id'] as String,
    revision: json['revision'] as int,
    cwd: json['cwd'] as String,
  );

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
