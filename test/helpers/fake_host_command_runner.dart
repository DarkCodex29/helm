import 'package:helm/core/host/host_command_runner.dart';

/// Scripted [HostCommandRunner] stand-in for unit tests.
///
/// Registers a canned [HostCommandResult] per exact command/script string
/// via [whenRun]/[whenRunScript]. Calling [run]/[runScript] for a string
/// with no registered result throws [StateError] so an unexpected call
/// fails loudly instead of silently returning empty output.
class FakeHostCommandRunner implements HostCommandRunner {
  final Map<String, HostCommandResult> _runResults = {};
  final Map<String, HostCommandResult> _runScriptResults = {};

  /// Commands passed to [run], in invocation order.
  final List<String> runCalls = [];

  /// Scripts passed to [runScript], in invocation order.
  final List<String> runScriptCalls = [];

  /// Registers the result [run] returns for the exact [command] string.
  void whenRun(String command, HostCommandResult result) {
    _runResults[command] = result;
  }

  /// Registers the result [runScript] returns for the exact [script] string.
  void whenRunScript(String script, HostCommandResult result) {
    _runScriptResults[script] = result;
  }

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async {
    runCalls.add(command);
    final result = _runResults[command];
    if (result == null) {
      throw StateError(
        'FakeHostCommandRunner: no result registered for run("$command")',
      );
    }
    return result;
  }

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) async {
    runScriptCalls.add(script);
    final result = _runScriptResults[script];
    if (result == null) {
      throw StateError(
        'FakeHostCommandRunner: no result registered for runScript(...)',
      );
    }
    return result;
  }
}
