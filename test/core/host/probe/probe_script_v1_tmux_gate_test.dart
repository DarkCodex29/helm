import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';

/// Proves the tmux-server detection gate (`_tmux_server_running()`) that
/// stops the probe from calling `tmux list-sessions` when no tmux server
/// exists.
///
/// This closes a violation of locked product decision 5 ("zero host
/// footprint... nothing is written, installed, or cached on the remote
/// host") and the `host-command-port` spec's "No file left behind on the
/// host" scenario: on a real Ubuntu 24.04 host, a bare `tmux list-sessions`
/// call unconditionally creates `/tmp/tmux-$UID` as a side effect --
/// even with no server running and even though the command itself then
/// fails with "no server running". The probe script contains no
/// file-writing primitive of its own; tmux's own client does the
/// writing. See `openspec/changes/host-session-contract/HANDOFF.md` for
/// the full empirical proof (marker-and-`find`, isolation via `rmdir`
/// then re-run, and culprit isolation to `list-sessions` alone).
///
/// This test proves the detection LOGIC in isolation, using a fake `ps`
/// on `PATH` to control what the gate observes -- it never depends on a
/// real tmux server, matching this suite's existing precedent
/// (`probe_script_v1_test.dart`) of never running the full probe
/// script's live host discovery under `flutter test`. The empirical
/// "no directory created" / "sessions still enumerated with a real
/// server, byte-for-byte identical output" measurements against the
/// real Linux host live outside `flutter test`, in the apply-progress
/// record and `HANDOFF.md`, because they require a live host with a
/// real tmux binary and cannot be faked without re-encoding the same
/// assumption the code makes (the failure shape `HANDOFF.md` §8
/// documents for slice 4).
///
/// The gate function is extracted verbatim from [probeScriptV1] -- never
/// retyped -- via [_extractTmuxGatePrelude], the same technique
/// `probe_script_v1_test.dart` uses for `_esc()`. Extraction of a marker
/// that does not yet exist in the script throws [StateError], which is
/// exactly today's failure: this is the genuine RED before
/// `_tmux_server_running` is added to `probe_script_v1.dart`.
///
/// ## Coverage extension: relocatable paths and non-invocation
///
/// Two verify-report gaps against the three `host-command-port` scenarios
/// this suite claims to cover are closed here, both without touching
/// `_tmux_server_running` or any other production code:
///
/// 1. "Detection is independent of relocatable paths" had zero coverage.
///    The three new tests in the first group below extend [_runGate] with
///    an optional relocated `TMUX_TMPDIR` (with a real socket-directory
///    artifact physically created on disk at that location, so the claim
///    is not merely "the env var is set with nothing behind it") and an
///    explicit `-S`-style `TMUX` client variable. Empirically confirmed
///    against a real Ubuntu 24.04 host (`ssh contabo`, tmux 3.4) before
///    writing these tests: a running server's `ps` comm field stays
///    exactly `tmux: server` whether the socket lives at its default
///    location, under a relocated `TMUX_TMPDIR`, or at an arbitrary `-S`
///    path -- confirming the gate's process-name detection genuinely does
///    not need, and must not depend on, any socket path. (macOS's `ps`
///    reports only `tmux`, not `tmux: server` -- a real local tmux server
///    would not exercise the Linux-only string this gate matches, which is
///    why these tests still fake `ps`, matching the existing five, rather
///    than spawning a real local tmux server.)
/// 2. "No command is invoked when there is nothing to report" was only
///    partially covered: three existing tests prove the branch condition,
///    but none proves the scenario's own THEN clauses -- that
///    `list-sessions` is genuinely never invoked, and that the emitted
///    session-record stream is identical to a host where the tool is
///    absent entirely. The second group below runs the REAL, complete,
///    unmodified [probeScriptV1] (not just the extracted gate) via
///    [_runFullProbe], delivered exactly as production delivers it --
///    `/bin/sh -s` over stdin, stdin closed, no PTY -- with a fake `tmux`
///    binary that records every invocation it receives, under a PATH
///    curated to exclude this development machine's real
///    tmux/herdr/zellij binaries so [tmuxInstalled] is the only fact the
///    script can observe. "Identical emitted records" is interpreted as
///    the `session`-record subset specifically: the `mux` record for tmux
///    legitimately differs between installed/absent (that is a separate,
///    already-covered concern -- install detection), and the `end`
///    record's elapsed-time field is never byte-stable across two
///    process runs regardless of tmux state. What the scenario's
///    non-invocation guarantee actually promises is that no `session`
///    line leaks from an installed-but-idle tool, which is exactly what
///    both tests assert.
void main() {
  final hasPosixShell = !Platform.isWindows;
  const skipReason =
      'Requires /bin/sh (POSIX shell), unavailable on Windows. Matches '
      'the platform decision already made in probe_script_v1_test.dart.';

  group('tmux server detection gate (_tmux_server_running)', () {
    test(
      'reports a running server when ps lists the exact tmux server '
      'process name for the current user',
      () async {
        final result = await _runGate(
          psOutputLines: ['bash', 'tmux: server', 'sshd'],
        );
        expect(result, 'SERVER_RUNNING');
      },
    );

    test(
      'reports no running server when ps lists no tmux server process '
      'at all',
      () async {
        final result = await _runGate(
          psOutputLines: ['bash', 'sshd', 'node'],
        );
        expect(result, 'SERVER_NOT_RUNNING');
      },
    );

    test(
      'does not treat a bare "tmux" comm (e.g. a transient attaching '
      'client) as a running server -- only the exact server name counts',
      () async {
        final result = await _runGate(
          psOutputLines: ['bash', 'tmux', 'sshd'],
        );
        expect(result, 'SERVER_NOT_RUNNING');
      },
    );

    test(
      'is scoped to the invoking user: a comm line does not need '
      'ownership simulated here because `ps -u` performs the OS-level '
      'filtering -- this test proves the gate parses ONLY what ps '
      'already scoped to us, i.e. an empty scoped list means no server, '
      'never a scan of every user on the host',
      () async {
        final result = await _runGate(psOutputLines: const <String>[]);
        expect(result, 'SERVER_NOT_RUNNING');
      },
    );

    test(
      'fails OPEN -- reports a possible server -- when ps is not '
      'available on PATH at all, so an undetectable server can never '
      'silently become "no sessions"',
      () async {
        final result = await _runGate(psAvailable: false);
        expect(result, 'SERVER_RUNNING');
      },
    );

    test(
      'still reports a running server when TMUX_TMPDIR relocates the '
      'socket directory away from its default, with a matching relocated '
      'socket artifact physically present on disk at that location',
      () async {
        final result = await _runGate(
          psOutputLines: ['bash', 'tmux: server', 'sshd'],
          withRelocatedSocketArtifact: true,
        );
        expect(result, 'SERVER_RUNNING');
      },
    );

    test(
      'still reports no running server when TMUX_TMPDIR relocates the '
      'socket directory away from its default, even though a relocated '
      'socket artifact exists on disk with no matching process -- proves '
      'the decision reads process state, never the filesystem at that '
      'path',
      () async {
        final result = await _runGate(
          psOutputLines: ['bash', 'sshd', 'node'],
          withRelocatedSocketArtifact: true,
        );
        expect(result, 'SERVER_NOT_RUNNING');
      },
    );

    test(
      'still reports a running server when an explicit -S-style client '
      'socket path is set via TMUX, pointing at a location outside any '
      'default or TMUX_TMPDIR-relocated directory',
      () async {
        final result = await _runGate(
          psOutputLines: ['bash', 'tmux: server', 'sshd'],
          extraEnv: const <String, String>{
            'TMUX': '/completely/unrelated/custom.sock,1234,0',
          },
        );
        expect(result, 'SERVER_RUNNING');
      },
    );
  }, skip: hasPosixShell ? false : skipReason);

  group('no command is invoked when there is nothing to report', () {
    test(
      'does not invoke tmux list-sessions when tmux is installed but no '
      'server is running',
      () async {
        final result = await _runFullProbe(
          tmuxInstalled: true,
          tmuxServerRunning: false,
        );
        expect(
          result.tmuxInvocations.any(
            (args) => args.contains('list-sessions'),
          ),
          isFalse,
          reason:
              'tmux list-sessions must never be invoked when the gate '
              'reports no server; recorded invocations: '
              '${result.tmuxInvocations}',
        );
      },
    );

    test(
      'emits the same session-record stream (none) whether tmux is '
      'installed with no server or entirely absent from the host',
      () async {
        final installedNoServer = await _runFullProbe(
          tmuxInstalled: true,
          tmuxServerRunning: false,
        );
        final absent = await _runFullProbe(
          tmuxInstalled: false,
          tmuxServerRunning: false,
        );

        expect(
          installedNoServer.sessionRecordLines,
          isEmpty,
          reason:
              'installed-but-idle host emitted unexpected session '
              'records: ${installedNoServer.sessionRecordLines}',
        );
        expect(
          absent.sessionRecordLines,
          isEmpty,
          reason:
              'tool-absent host emitted unexpected session records: '
              '${absent.sessionRecordLines}',
        );
        expect(
          installedNoServer.sessionRecordLines,
          absent.sessionRecordLines,
          reason:
              'session-record stream must be identical (both empty) '
              'whether the tool is installed but idle or entirely absent',
        );
      },
    );
  }, skip: hasPosixShell ? false : skipReason);
}

const _gateFunctionMarker = '_tmux_server_running() {';

/// Extracts `_tmux_server_running()` as a byte-for-byte substring of
/// [probeScriptV1] -- no character of its logic is retyped here. The
/// function is self-contained (depends on no earlier script state), so
/// extraction starts exactly at the marker rather than from the top of
/// the script.
String _extractTmuxGatePrelude() {
  final start = probeScriptV1.indexOf(_gateFunctionMarker);
  if (start == -1) {
    throw StateError(
      'probeScriptV1 no longer defines `$_gateFunctionMarker` -- this '
      'extraction must be updated alongside the script.',
    );
  }
  final closeIdx = probeScriptV1.indexOf('\n}', start);
  if (closeIdx == -1) {
    throw StateError(
      'Could not find the closing brace of `_tmux_server_running()` in '
      'probeScriptV1.',
    );
  }
  return probeScriptV1.substring(start, closeIdx + 2);
}

/// Runs the real, extracted `_tmux_server_running()` under a real
/// `/bin/sh` with a fully controlled `PATH`, and returns which branch it
/// took.
///
/// When [psAvailable] is true, a fake `ps` executable is placed first on
/// `PATH` that ignores its arguments and prints [psOutputLines], one per
/// line -- simulating `ps -u "$(id -un)" -o comm=`'s output without
/// depending on real OS process state. The real `id`/`grep` from the
/// system `PATH` are still used, since the gate's own logic (not a
/// simulation of it) is what is under test.
///
/// When [psAvailable] is false, `PATH` is set to a directory containing
/// no executables at all, so `command -v ps` genuinely fails -- the gate
/// must reach its fail-open `return 0` without calling `id` or `grep`,
/// so neither needs to be reachable in this scenario.
Future<String> _runGate({
  List<String>? psOutputLines,
  bool psAvailable = true,
  Map<String, String> extraEnv = const <String, String>{},
  bool withRelocatedSocketArtifact = false,
}) async {
  final gatePrelude = _extractTmuxGatePrelude();
  final harness =
      '$gatePrelude\n'
      "if _tmux_server_running; then printf '%s' 'SERVER_RUNNING'; "
      "else printf '%s' 'SERVER_NOT_RUNNING'; fi\n";

  final tempDir = await Directory.systemTemp.createTemp('helm_probe_gate_');
  try {
    final env = <String, String>{};
    if (psAvailable) {
      final fakePs = File('${tempDir.path}/ps');
      final body = StringBuffer('#!/bin/sh\n');
      for (final line in psOutputLines ?? const <String>[]) {
        body.writeln("printf '%s\\n' '$line'");
      }
      await fakePs.writeAsString(body.toString());
      await _makeExecutable(fakePs);
      final systemPath = Platform.environment['PATH'] ?? '/usr/bin:/bin';
      env['PATH'] = '${tempDir.path}:$systemPath';
    } else {
      // An empty directory on PATH: `command -v ps` must fail. The gate
      // must return before needing `id` or `grep` in this scenario, so
      // nothing else needs to be reachable.
      env['PATH'] = tempDir.path;
    }

    if (withRelocatedSocketArtifact) {
      // Mimics a host that has relocated tmux's socket/state directory
      // via TMUX_TMPDIR, with tmux's own per-uid socket artifact
      // physically present at that relocated location -- not merely an
      // env var pointing nowhere. The gate must ignore this filesystem
      // state entirely and decide purely from `ps`.
      final relocatedDir = Directory('${tempDir.path}/relocated_tmux_tmpdir');
      final fakeSocketDir = Directory('${relocatedDir.path}/tmux-9999');
      await fakeSocketDir.create(recursive: true);
      await File('${fakeSocketDir.path}/default').writeAsString('');
      env['TMUX_TMPDIR'] = relocatedDir.path;
    }

    env.addAll(extraEnv);

    final result = await Process.run(
      '/bin/sh',
      ['-c', harness],
      environment: env,
      includeParentEnvironment: false,
    );

    final stdout = result.stdout as String;
    if (stdout != 'SERVER_RUNNING' && stdout != 'SERVER_NOT_RUNNING') {
      fail(
        'gate harness produced unexpected output: stdout=$stdout '
        'exitCode=${result.exitCode} stderr=${result.stderr}',
      );
    }
    return stdout;
  } finally {
    await tempDir.delete(recursive: true);
  }
}

/// Result of one [_runFullProbe] run: the complete stdout, every argument
/// line the fake `tmux` binary recorded being invoked with (in order),
/// and just the `session\t...` lines from stdout.
class _ProbeRunResult {
  const _ProbeRunResult({
    required this.stdout,
    required this.tmuxInvocations,
    required this.sessionRecordLines,
  });

  final String stdout;
  final List<String> tmuxInvocations;
  final List<String> sessionRecordLines;
}

/// The fake `tmux` executable's body. `$HELM_TEST_TMUX_LOG` is an
/// environment variable the harness sets, rather than a path embedded in
/// this template via string interpolation, so no shell-quoting of an
/// arbitrary filesystem path is ever needed here.
const _fakeTmuxTemplate = r'''
#!/bin/sh
printf '%s\n' "$*" >> "$HELM_TEST_TMUX_LOG"
case "$1" in
  --version) printf '%s\n' 'tmux fake 9.9.9' ;;
  list-sessions) printf '%s\t%s\n' 'fake-session' '0' ;;
esac
exit 0
''';

/// Runs the REAL, unmodified [probeScriptV1] -- delivered exactly as the
/// production `HostCommandRunner` delivers it: fed to `/bin/sh -s` over
/// stdin, stdin then closed, no pseudo-terminal -- so the "no command
/// invoked" and "identical emitted records" claims are proven against the
/// genuine script text, not a reimplementation of it.
///
/// `PATH` is curated to `<tempDir>:/usr/bin:/bin`, deliberately excluding
/// this development machine's Homebrew/user-local directories where a
/// real tmux/herdr/zellij may be installed, so [tmuxInstalled] is the
/// only fact about tmux the script can observe. `ps` is always faked so
/// [tmuxServerRunning] is deterministic and never depends on this
/// machine's real process table, matching [_runGate]'s isolation
/// principle.
Future<_ProbeRunResult> _runFullProbe({
  required bool tmuxInstalled,
  required bool tmuxServerRunning,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('helm_probe_full_');
  try {
    final fakePs = File('${tempDir.path}/ps');
    final psBody = StringBuffer('#!/bin/sh\n');
    psBody.writeln(
      tmuxServerRunning
          ? "printf '%s\\n' 'tmux: server'"
          : "printf '%s\\n' 'sshd'",
    );
    await fakePs.writeAsString(psBody.toString());
    await _makeExecutable(fakePs);

    final invocationLog = File('${tempDir.path}/tmux_invocations.log');
    await invocationLog.writeAsString('');

    if (tmuxInstalled) {
      final fakeTmux = File('${tempDir.path}/tmux');
      await fakeTmux.writeAsString(_fakeTmuxTemplate);
      await _makeExecutable(fakeTmux);
    }

    const minimalSystemPath = '/usr/bin:/bin';
    final env = <String, String>{
      'PATH': '${tempDir.path}:$minimalSystemPath',
      'HELM_TEST_TMUX_LOG': invocationLog.path,
    };

    final process = await Process.start(
      '/bin/sh',
      ['-s'],
      environment: env,
      includeParentEnvironment: false,
    );
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    process.stdin.write(probeScriptV1);
    await process.stdin.close();
    final exitCode = await process.exitCode;
    final stdout = await stdoutFuture;
    final stderr = await stderrFuture;

    if (exitCode != 0) {
      fail('probe script exited with code $exitCode: stderr=$stderr');
    }

    final invocations = (await invocationLog.readAsLines())
        .where((line) => line.isNotEmpty)
        .toList();

    final sessionLines = stdout
        .split('\n')
        .where((line) => line.startsWith('session\t'))
        .toList();

    return _ProbeRunResult(
      stdout: stdout,
      tmuxInvocations: invocations,
      sessionRecordLines: sessionLines,
    );
  } finally {
    await tempDir.delete(recursive: true);
  }
}

/// Marks [file] as executable, matching the `chmod +x` step already
/// established by [_runGate]'s fake `ps` executable.
Future<void> _makeExecutable(File file) async {
  final chmod = await Process.run('chmod', ['+x', file.path]);
  if (chmod.exitCode != 0) {
    fail('chmod +x on ${file.path} failed: ${chmod.stderr}');
  }
}
