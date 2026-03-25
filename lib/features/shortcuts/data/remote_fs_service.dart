import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

/// Provides remote filesystem exploration via one-shot SSH commands.
///
/// Uses an already-established [SSHClient] to detect projects and query
/// the current working directory without opening a full interactive shell.
class RemoteFsService {
  // ── Public API ────────────────────────────────────────────────────────────

  /// Detects projects on the remote machine by searching common directories
  /// for project marker files (pubspec.yaml, package.json, *.csproj, go.mod).
  ///
  /// Returns the unique, sorted list of parent directories for each found file.
  Future<List<String>> detectProjects(SSHClient client) async {
    const command =
        r'''find ~/Desktop ~/projects ~/proyectos ~/work -maxdepth 3 \( -name "pubspec.yaml" -o -name "package.json" -o -name "*.csproj" -o -name "go.mod" \) -not -path "*/node_modules/*" -not -path "*/.dart_tool/*" 2>/dev/null | head -50''';

    final output = await _runCommand(client, command);
    if (output.isEmpty) return [];

    final dirs =
        output
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .map(_dirname)
            .toSet()
            .toList()
          ..sort();

    return dirs;
  }

  /// Returns the current working directory of the active tmux pane.
  ///
  /// Returns null if the command fails or tmux is not running.
  Future<String?> getCurrentDirectory(SSHClient client) async {
    const command =
        "tmux display-message -p '#{pane_current_path}' 2>/dev/null";

    final output = await _runCommand(client, command);
    if (output.isEmpty) return null;
    return output;
  }

  // ── Private ───────────────────────────────────────────────────────────────

  /// Runs [command] on the remote via SSH exec and returns trimmed stdout.
  Future<String> _runCommand(SSHClient client, String command) async {
    try {
      final session = await client.execute(command);
      final stdout = await session.stdout.fold<List<int>>(
        [],
        (acc, data) => [...acc, ...data],
      );
      await session.done;
      return utf8.decode(stdout, allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }

  /// Returns the parent directory of [path] (equivalent to `dirname`).
  String _dirname(String path) {
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return path;
    return path.substring(0, idx);
  }
}
