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
      final chmod = await Process.run('chmod', ['+x', fakePs.path]);
      if (chmod.exitCode != 0) {
        fail('chmod +x on the fake ps failed: ${chmod.stderr}');
      }
      final systemPath = Platform.environment['PATH'] ?? '/usr/bin:/bin';
      env['PATH'] = '${tempDir.path}:$systemPath';
    } else {
      // An empty directory on PATH: `command -v ps` must fail. The gate
      // must return before needing `id` or `grep` in this scenario, so
      // nothing else needs to be reachable.
      env['PATH'] = tempDir.path;
    }

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
