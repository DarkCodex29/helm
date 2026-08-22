import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:helm/core/host/host_command_runner.dart';

/// The subset of an open SSH exec channel that [SshHostCommandRunner] needs
/// to drain a result.
///
/// [SSHSession] cannot be constructed outside dartssh2, so this interface is
/// the seam tests use to avoid a live SSH connection — [_SshSessionChannel]
/// adapts a real [SSHSession] to it in production.
abstract interface class SshCommandChannel {
  StreamSink<Uint8List> get stdin;
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  int? get exitCode;
  Future<void> get done;
}

/// Opens an exec channel for [command] against a live transport.
typedef SshChannelOpener = Future<SshCommandChannel> Function(String command);

/// [HostCommandRunner] backed by a dartssh2 [SSHClient].
///
/// See design's AD-1: [runScript] delivers its script over the channel's
/// stdin to a fixed `/bin/sh -s` command and never requests a
/// pseudo-terminal, so script bytes cross zero shell-quoting layers.
class SshHostCommandRunner implements HostCommandRunner {
  SshHostCommandRunner(SSHClient client) : _openChannel = _defaultOpener(client);

  /// For tests: bypasses the live [SSHClient] and drives a scripted
  /// [SshChannelOpener] directly.
  SshHostCommandRunner.withOpener(this._openChannel);

  final SshChannelOpener _openChannel;

  static SshChannelOpener _defaultOpener(SSHClient client) {
    return (command) async {
      final session = await client.execute(command);
      return _SshSessionChannel(session);
    };
  }

  // ── Public API ─────────────────────────────────────────────────────────

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async {
    final channel = await _openChannel(command);
    return _drain(channel, timeout: timeout);
  }

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) async {
    final channel = await _openChannel('/bin/sh -s');
    channel.stdin.add(utf8.encode(script));
    await channel.stdin.close();
    return _drain(channel, timeout: timeout);
  }

  // ── Private ────────────────────────────────────────────────────────────

  Future<HostCommandResult> _drain(
    SshCommandChannel channel, {
    Duration? timeout,
  }) async {
    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    final stdoutSub = channel.stdout.listen(
      stdoutBytes.addAll,
      onDone: () => _completeOnce(stdoutDone),
      onError: (_) => _completeOnce(stdoutDone),
      cancelOnError: true,
    );
    final stderrSub = channel.stderr.listen(
      stderrBytes.addAll,
      onDone: () => _completeOnce(stderrDone),
      onError: (_) => _completeOnce(stderrDone),
      cancelOnError: true,
    );

    var timedOut = false;
    try {
      // Wait for the OUTPUT STREAMS to close, not just for the channel.
      //
      // dartssh2 2.16.0 documents the difference on SSHSession.done
      // (ssh_session.dart:31-33): "This Future completes when the channel
      // is closed. More data may still be available on the stdout and
      // stderr streams at this time." The stdout/stderr controllers are
      // closed separately, in _handleChannelDataDone.
      //
      // Awaiting only `done` and then cancelling the subscriptions
      // therefore discards whatever was still buffered. Measured against a
      // real host: a 699-byte probe report came back as 687 bytes, losing
      // exactly the trailing `end` record — the one that tells the parser
      // the report is complete — so every probe parsed as truncated.
      final drained = Future.wait([
        channel.done,
        stdoutDone.future,
        stderrDone.future,
      ]);
      if (timeout != null) {
        await drained.timeout(timeout);
      } else {
        await drained;
      }
    } on TimeoutException {
      // Keeps whatever arrived before the deadline, and still reports the
      // result as timed out so no caller reads a partial body as complete.
      timedOut = true;
    } finally {
      await stdoutSub.cancel();
      await stderrSub.cancel();
    }

    return HostCommandResult(
      stdout: utf8.decode(stdoutBytes, allowMalformed: true),
      stderr: utf8.decode(stderrBytes, allowMalformed: true),
      exitCode: timedOut ? null : channel.exitCode,
      timedOut: timedOut,
    );
  }

  /// A stream can signal completion through either [onDone] or [onError];
  /// both paths mean "nothing more is coming", and completing an already
  /// completed [Completer] throws.
  static void _completeOnce(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }
}

/// Adapts a real [SSHSession] to [SshCommandChannel].
class _SshSessionChannel implements SshCommandChannel {
  _SshSessionChannel(this._session);

  final SSHSession _session;

  @override
  StreamSink<Uint8List> get stdin => _session.stdin;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  int? get exitCode => _session.exitCode;

  @override
  Future<void> get done => _session.done;
}
