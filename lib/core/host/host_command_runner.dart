/// Transport-neutral seam for running commands on a remote host.
///
/// Callers depend only on this port, never on a specific transport client.
/// See `openspec/changes/host-session-contract/specs/host-command-port/spec.md`.
abstract interface class HostCommandRunner {
  /// Executes one [command] over the configured transport.
  ///
  /// If [timeout] elapses before the command completes, the returned
  /// result has `timedOut = true` and MUST NOT be treated as a completed
  /// command with a usable exit code.
  Future<HostCommandResult> run(String command, {Duration? timeout});

  /// Delivers [script] to the host over the command channel's input stream.
  ///
  /// MUST NOT request a pseudo-terminal for the channel, and MUST NOT
  /// create, write, install, or cache any file on the remote host.
  Future<HostCommandResult> runScript(String script, {Duration? timeout});
}

/// Result of a [HostCommandRunner.run] or [HostCommandRunner.runScript] call.
class HostCommandResult {
  const HostCommandResult({
    this.stdout = '',
    this.stderr = '',
    this.exitCode,
    this.timedOut = false,
  });

  final String stdout;
  final String stderr;

  /// Nullable: a transport may not receive an exit-status message, and this
  /// is always null when [timedOut] is true.
  final int? exitCode;

  /// True when the call did not complete within its configured timeout.
  final bool timedOut;
}
