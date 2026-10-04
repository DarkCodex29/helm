// Unit tests for HostProber — the thin, failure-hardened seam between a
// live HostCommandRunner and a parsed HostReport.
//
// The behavior worth pinning here is not the parsing (host_probe_parser_test
// covers that) but the DEGRADATION: every way the probe can fail must
// produce an explicitly unknown report, never an empty one that a caller
// could read as "this host has nothing installed".
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/probe/host_prober.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';

/// [HostCommandRunner] that throws from [runScript], standing in for a
/// transport that drops mid-probe.
class _ThrowingRunner implements HostCommandRunner {
  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async =>
      throw StateError('run() must not be called by HostProber');

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) async =>
      throw const SocketishFailure();
}

/// Stand-in for the transport-level exceptions dartssh2 can raise once a
/// channel is already open.
class SocketishFailure implements Exception {
  const SocketishFailure();
}

/// Records what was asked of it and replies with a fixed result.
class _ScriptedRunner implements HostCommandRunner {
  _ScriptedRunner(this._result);

  final HostCommandResult _result;
  final List<String> scripts = [];
  final List<Duration?> timeouts = [];

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async =>
      throw StateError('run() must not be called by HostProber');

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) async {
    scripts.add(script);
    timeouts.add(timeout);
    return _result;
  }
}

void main() {
  group('HostProber.probe - delivery', () {
    test('delivers the v1 script over runScript, never as a shell command', () {
      // AD-1: the script crosses zero shell-quoting layers because it is
      // fed to `/bin/sh -s` over stdin.
      final runner = _ScriptedRunner(
        const HostCommandResult(stdout: 'helm-probe/1\nend\tok\t12', exitCode: 0),
      );

      return const HostProber().probe(runner).then((_) {
        expect(runner.scripts, [probeScriptV1]);
      });
    });

    test('bounds the probe with a timeout so it cannot hang a connect', () async {
      final runner = _ScriptedRunner(
        const HostCommandResult(stdout: 'helm-probe/1\nend\tok\t12', exitCode: 0),
      );

      await const HostProber().probe(runner);

      expect(runner.timeouts.single, isNotNull);
      expect(runner.timeouts.single, kHostProbeTimeout);
    });

    test('parses a well-formed report', () async {
      final runner = _ScriptedRunner(
        const HostCommandResult(
          stdout:
              'helm-probe/1\n'
              'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.4\t1\n'
              'end\tok\t42',
          exitCode: 0,
        ),
      );

      final report = await const HostProber().probe(runner);

      expect(report.status, HostReportStatus.ok);
      expect(report.mux.single.absPath, '/usr/bin/tmux');
    });
  });

  group('HostProber.probe - degrades honestly', () {
    test('a thrown transport failure becomes an unknown report, not empty', () async {
      final report = await const HostProber().probe(_ThrowingRunner());

      // truncated == "we could not find out", which resolveMultiplexer
      // reads as unverified. An `ok` report with an empty mux list would
      // instead read as "this host has no multiplexers" — the exact lie
      // this fallback exists to avoid.
      expect(report.status, HostReportStatus.truncated);
      expect(report.mux, isEmpty);
    });

    test('a timed-out result becomes an unknown report', () async {
      final runner = _ScriptedRunner(
        const HostCommandResult(stdout: 'helm-probe/1\n', timedOut: true),
      );

      final report = await const HostProber().probe(runner);

      expect(report.status, HostReportStatus.truncated);
    });

    test('output from a host that is not running the probe is a mismatch', () async {
      final runner = _ScriptedRunner(
        const HostCommandResult(stdout: '/bin/sh: 1: Syntax error', exitCode: 2),
      );

      final report = await const HostProber().probe(runner);

      expect(report.status, HostReportStatus.versionMismatch);
    });
  });
}
