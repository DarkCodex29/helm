import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/utils/logger.dart';

/// Provides tmux session management commands over an active SSH connection.
///
/// Uses the already-established [SSHClient] to run one-off tmux commands
/// without opening a full interactive shell.
class TmuxService {
  TmuxService({required SSHClient client}) : _client = client;

  final SSHClient _client;
  static final _log = HelmLogger('TmuxService');

  // ── Public API ─────────────────────────────────────────────────────────

  /// Returns the names of all running tmux sessions.
  ///
  /// Runs: `tmux list-sessions -F '#{session_name}'`
  Future<List<String>> listSessions() async {
    final output = await _runCommand(
      "tmux list-sessions -F '#{session_name}' 2>/dev/null || true",
    );
    if (output.isEmpty) return [];
    return output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  /// Creates a new detached tmux session with [name].
  ///
  /// Runs: `tmux new-session -d -s {name}`
  Future<void> createSession(String name) async {
    await _runCommand('tmux new-session -d -s "$name"');
    _log.i('Created tmux session: $name');
  }

  /// Kills the tmux session with [name].
  ///
  /// Runs: `tmux kill-session -t {name}`
  Future<void> killSession(String name) async {
    await _runCommand('tmux kill-session -t "$name"');
    _log.i('Killed tmux session: $name');
  }

  /// Returns true if a session named [name] exists.
  Future<bool> hasSession(String name) async {
    final output = await _runCommand(
      'tmux has-session -t "$name" 2>&1; echo \$?',
    );
    return output.trim() == '0';
  }

  // ── Private ─────────────────────────────────────────────────────────────

  /// Runs [command] on the remote machine via SSH exec.
  /// Returns stdout as a trimmed string.
  Future<String> _runCommand(String command) async {
    try {
      final session = await _client.execute(command);
      final stdout = await session.stdout.fold<List<int>>(
        [],
        (acc, data) => [...acc, ...data],
      );
      final stderr = await session.stderr.fold<List<int>>(
        [],
        (acc, data) => [...acc, ...data],
      );

      await session.done;

      if (stderr.isNotEmpty) {
        final errStr = utf8.decode(stderr, allowMalformed: true).trim();
        if (errStr.isNotEmpty) {
          _log.w('tmux command stderr: $errStr');
        }
      }

      return utf8.decode(stdout, allowMalformed: true).trim();
    } catch (e) {
      _log.e('tmux command failed: $command', e);
      return '';
    }
  }
}
