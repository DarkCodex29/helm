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
    final stdoutSub = channel.stdout.listen(stdoutBytes.addAll);
    final stderrSub = channel.stderr.listen(stderrBytes.addAll);

    var timedOut = false;
    try {
      if (timeout != null) {
        await channel.done.timeout(timeout);
      } else {
        await channel.done;
      }
    } on TimeoutException {
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
