import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/shell_quote.dart';

/// [MultiplexerAdapter] backed by the `tmux` CLI over a [HostCommandRunner].
///
/// Does not advertise [MuxCapability.agentState]: tmux has no concept of an
/// AI agent's state, so [agents] is always null. See design.md's adapter
/// capability table.
class TmuxAdapter implements MultiplexerAdapter {
  TmuxAdapter(this._runner, {String absPath = 'tmux'}) : _absPath = absPath;

  final HostCommandRunner _runner;

  /// The resolved absolute path of the tmux binary, or the bare `tmux`
  /// name when no probe-resolved path was supplied. See AD-3: commands
  /// that reach a remote shell use the resolved path, not a bare name.
  final String _absPath;

  @override
  MultiplexerId get id => MultiplexerId.tmux;

  @override
  Set<MuxCapability> get capabilities => const {
    MuxCapability.sessionWorkingDirectory,
  };

  @override
  AgentAwareMultiplexer? get agents => null;

  /// Always null. `display-message -p '#{pane_current_path}'` would give a
  /// pane's cwd, but tmux has no per-pane revision counter, so it cannot
  /// tell a pane that was worked in apart from one that was recreated —
  /// half the evidence is not a weaker answer, it is no answer. See
  /// [MuxPane].
  @override
  PaneAwareMultiplexer? get panes => null;

  /// Always null. tmux has sessions and windows, but no workspace layer and
  /// no per-workspace agent roll-up, so mapping its vocabulary onto
  /// [MuxWorkspace] would invent a hierarchy this host does not have.
  @override
  WorkspaceAwareMultiplexer? get workspaces => null;

  @override
  Future<MuxDetection> detect() async {
    final result = await _runner.run(
      'command -v $_absPath >/dev/null 2>&1 && $_absPath -V',
    );
    if (result.exitCode != 0) return const MuxDetection.notInstalled();
    return MuxDetection.installed(
      absPath: _absPath,
      version: result.stdout.trim(),
    );
  }

  @override
  Future<MuxSessionsResult> listSessions() async {
    final result = await _runner.run(_listSessionsCommand);
    // tmux with no server writes to stderr and exits non-zero — see
    // design.md's "Degraded-state handling" note. That MUST map here, not
    // to an empty MuxSessionsAvailable list.
    if (result.exitCode != 0) return const MuxServerNotRunning();

    final sessions = result.stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map(_parseSessionLine)
        .toList();
    return MuxSessionsAvailable(sessions);
  }

  @override
  Future<bool> hasSession(String name) async {
    final result = await _runner.run(
      '$_absPath has-session -t ${shellQuote(name)}',
    );
    return result.exitCode == 0;
  }

  @override
  String attachCommand(String sessionName) {
    // `-A` makes new-session behave like attach-session when the name
    // already exists, and create it otherwise — idempotent attach-or-create.
    return '$_absPath new-session -A -s ${shellQuote(sessionName)}';
  }

  /// Returns the current working directory of tmux's most recently active
  /// pane, or null if it cannot be determined.
  ///
  /// Preserves — byte-for-byte, at the default [_absPath] — the exact
  /// command that was previously hardcoded in
  /// `RemoteFsService.getCurrentDirectory` before this slice moved it
  /// behind [MultiplexerAdapter]. This is a refactor, not a behavior
  /// change.
  Future<String?> currentPaneDirectory() async {
    try {
      final result = await _runner.run(
        "$_absPath display-message -p '#{pane_current_path}' 2>/dev/null",
      );
      if (result.timedOut) return null;
      final output = result.stdout.trim();
      return output.isEmpty ? null : output;
    } catch (_) {
      return null;
    }
  }

  // ── Private ────────────────────────────────────────────────────────────

  String get _listSessionsCommand =>
      "$_absPath list-sessions -F '#{session_name}\t#{pane_dead}'";

  /// Parses one TAB-delimited `session_name`/`pane_dead` line.
  ///
  /// `pane_dead=1` — verified against a real tmux 3.6a with
  /// `remain-on-exit on` — means the active pane's process has exited;
  /// that maps to [MuxSessionState.exited] rather than silently omitting
  /// the session. See the "Explicit State on List Failure" spec
  /// requirement.
  MuxSession _parseSessionLine(String line) {
    final fields = line.split('\t');
    final name = fields.isNotEmpty ? fields[0] : '';
    final dead = fields.length > 1 && fields[1] == '1';
    return (
      name: name,
      state: dead ? MuxSessionState.exited : MuxSessionState.active,
    );
  }
}
