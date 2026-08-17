import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/host_command_runner.dart';

/// Provides remote filesystem exploration via one-shot host commands.
///
/// Depends on [HostCommandRunner] rather than a specific transport, so a
/// scripted stand-in can exercise this service without a live connection.
class RemoteFsService {
  RemoteFsService(HostCommandRunner runner, {TmuxAdapter? muxAdapter})
    : _runner = runner,
      _muxAdapter = muxAdapter ?? TmuxAdapter(runner);

  final HostCommandRunner _runner;

  /// Backs [getCurrentDirectory]. Defaults to a [TmuxAdapter] wrapping the
  /// same [_runner] so existing single-argument construction is unchanged.
  final TmuxAdapter _muxAdapter;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Detects projects on the remote machine by searching common directories
  /// for project marker files (pubspec.yaml, package.json, *.csproj, go.mod).
  ///
  /// Returns the unique, sorted list of parent directories for each found file.
  Future<List<String>> detectProjects() async {
    const command =
        r'''find ~/Desktop ~/projects ~/proyectos ~/work -maxdepth 3 \( -name "pubspec.yaml" -o -name "package.json" -o -name "*.csproj" -o -name "go.mod" \) -not -path "*/node_modules/*" -not -path "*/.dart_tool/*" 2>/dev/null | head -50''';

    final output = await _runCommand(command);
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
  /// Returns null if the command fails or tmux is not running. Delegates
  /// to [TmuxAdapter.currentPaneDirectory] — the multiplexer abstraction
  /// now owns this command, but it is unchanged from the value this method
  /// previously ran directly. See design.md's File Changes entry for this
  /// file.
  Future<String?> getCurrentDirectory() => _muxAdapter.currentPaneDirectory();

  // ── Private ───────────────────────────────────────────────────────────────

  /// Runs [command] via the host command runner and returns trimmed stdout.
  Future<String> _runCommand(String command) async {
    try {
      final result = await _runner.run(command);
      if (result.timedOut) return '';
      return result.stdout.trim();
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
