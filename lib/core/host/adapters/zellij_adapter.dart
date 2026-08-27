import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/shell_quote.dart';

/// [MultiplexerAdapter] backed by the `zellij` CLI over a
/// [HostCommandRunner].
///
/// Does not advertise [MuxCapability.agentState]: zellij has no concept of
/// an AI agent's state, so [agents] is always null. See design.md's adapter
/// capability table.
///
/// Empirically verified against a real local zellij 0.44.3 install (see
/// `test/core/host/adapters/zellij_adapter_test.dart` header comment for
/// the exact commands and output shapes this class relies on). Two findings
/// from that verification shape this implementation:
///
/// 1. `--short` strips the `(EXITED - attach to resurrect)` marker
///    entirely, making an exited session indistinguishable from an active
///    one. This adapter deliberately does NOT use `--short` for that
///    reason — the task's own hazard note permits this: "if it is
///    unreliable, do not depend on it."
/// 2. zellij has no shared daemon the way tmux does — each session is its
///    own server process. A non-zero exit from `list-sessions` (observed:
///    "No active zellij sessions found." on stderr) is therefore the
///    zellij-specific equivalent of "server not reachable"; there is no
///    separate "server running with zero sessions" state to distinguish it
///    from, unlike tmux.
class ZellijAdapter implements MultiplexerAdapter {
  ZellijAdapter(this._runner, {String absPath = 'zellij'}) : _absPath = absPath;

  final HostCommandRunner _runner;

  /// The resolved absolute path of the zellij binary, or the bare `zellij`
  /// name when no probe-resolved path was supplied. See AD-3: commands
  /// that reach a remote shell use the resolved path, not a bare name.
  final String _absPath;

  @override
  MultiplexerId get id => MultiplexerId.zellij;

  @override
  Set<MuxCapability> get capabilities => const {
    MuxCapability.deadSessionResurrection,
  };

  @override
  AgentAwareMultiplexer? get agents => null;

  /// Always null. zellij exposes no per-pane revision counter, so it
  /// cannot say whether a pane has been worked in — see [MuxPane].
  @override
  PaneAwareMultiplexer? get panes => null;

  /// Always null. zellij has sessions and tabs, but no workspace layer and
  /// no per-workspace agent roll-up, so mapping its vocabulary onto
  /// [MuxWorkspace] would invent a hierarchy this host does not have.
  @override
  WorkspaceAwareMultiplexer? get workspaces => null;

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
    final result = await _runner.run(_listSessionsCommand);
    // Non-zero exit means there is nothing to report — see class doc
    // comment finding 2. MUST map here, never to an empty
    // MuxSessionsAvailable list.
    if (result.exitCode != 0) return const MuxServerNotRunning();

    final sessions = _stripAnsi(result.stdout)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map(_parseSessionLine)
        .toList();
    return MuxSessionsAvailable(sessions);
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
    // `--create` makes attach behave like create-if-missing — idempotent
    // attach-or-create, the zellij equivalent of tmux's `-A`.
    return '$_absPath attach --create ${shellQuote(sessionName)}';
  }

  // ── Private ────────────────────────────────────────────────────────────

  String get _listSessionsCommand => '$_absPath list-sessions --no-formatting';

  /// Strips ANSI SGR escape sequences from [text].
  ///
  /// `--no-formatting` reliably omits these on the verified local install,
  /// but stripping defensively guards against a host running a different
  /// zellij build or a terminal-capability probe that re-enables color.
  /// See design.md's threat matrix "Untrusted host output" — ANSI escapes
  /// from zellij.
  static final _ansiEscape = RegExp('\x1B\\[[0-9;]*m');

  String _stripAnsi(String text) => text.replaceAll(_ansiEscape, '');

  /// Parses one `--no-formatting` line:
  /// `"<name> [Created <time> ago] "` or, when exited,
  /// `"<name> [Created <time> ago] (EXITED - attach to resurrect)"`.
  ///
  /// Splits on the literal `" [Created"` marker rather than whitespace
  /// tokens because session names may contain embedded spaces (confirmed
  /// empirically: `"helm test 6"`).
  MuxSession _parseSessionLine(String line) {
    const marker = ' [Created';
    final markerIndex = line.indexOf(marker);
    final name = markerIndex >= 0 ? line.substring(0, markerIndex) : line;
    final exited = line.contains('(EXITED');
    return (
      name: name,
      state: exited ? MuxSessionState.exited : MuxSessionState.active,
    );
  }
}
