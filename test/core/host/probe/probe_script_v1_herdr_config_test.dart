import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/probe/herdr_mobile_config.dart';
import 'package:helm/core/host/probe/host_probe_parser.dart';
import 'package:helm/core/host/probe/host_report.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';

/// Runs the REAL, unmodified [probeScriptV1] against a synthetic HOME to
/// prove how it reports a herdr mobile config file.
///
/// Delivered exactly as the production `HostCommandRunner` delivers it —
/// fed to `/bin/sh -s` over stdin, stdin then closed, no pseudo-terminal —
/// so these claims hold against the genuine script text rather than a
/// reimplementation of its logic. This follows the harness precedent set
/// by `probe_script_v1_tmux_gate_test.dart`.
///
/// `HOME` is a throwaway temp directory and `includeParentEnvironment` is
/// false, so this developer's own `~/.config/herdr/config.mobile.toml` can
/// neither be read nor written by these tests.
void main() {
  final hasPosixShell = !Platform.isWindows;
  const skipReason =
      'Requires /bin/sh (POSIX shell), unavailable on Windows. Matches the '
      'skip precedent in probe_script_v1_test.dart.';

  group(
    'probe_script_v1 — herdr mobile config detection',
    () {
      test('emits an env record naming the file when it exists', () async {
        final run = await _runProbe(mobileConfigAt: _ConfigLocation.home);

        expect(run.mobileConfigValue, '${run.home}/.config/herdr/config.mobile.toml');
      });

      test('emits NOTHING when the file does not exist', () async {
        // Absence of the key IS the inert fallback: nothing downstream can
        // read a fact the probe never reported, so a host without a mobile
        // config cannot have its attach command changed.
        final run = await _runProbe(mobileConfigAt: _ConfigLocation.none);

        expect(run.mobileConfigLines, isEmpty);
        expect(run.mobileConfigValue, isNull);
      });

      test('emits NOTHING when the path is a directory, not a file', () async {
        // `-f`, never `-e`: a directory at that path is not a config herdr
        // could read, and pointing HERDR_CONFIG_PATH at one would put the
        // host in the undetermined-fallback state this slice avoids.
        final run = await _runProbe(mobileConfigAt: _ConfigLocation.directory);

        expect(run.mobileConfigLines, isEmpty);
      });

      test('honors XDG_CONFIG_HOME when it is set', () async {
        final run = await _runProbe(
          mobileConfigAt: _ConfigLocation.xdg,
          withXdgConfigHome: true,
        );

        expect(run.mobileConfigValue, '${run.home}/xdg/herdr/config.mobile.toml');
      });

      test(
        'with XDG_CONFIG_HOME set, a file under ~/.config is NOT reported',
        () async {
          // The reported path is the one that was actually tested, so the
          // value can always be handed straight to HERDR_CONFIG_PATH.
          final run = await _runProbe(
            mobileConfigAt: _ConfigLocation.home,
            withXdgConfigHome: true,
          );

          expect(run.mobileConfigLines, isEmpty);
        },
      );

      test('the emitted record is a well-formed 3-field env record', () async {
        final run = await _runProbe(mobileConfigAt: _ConfigLocation.home);

        expect(run.mobileConfigLines, hasLength(1));
        expect(run.mobileConfigLines.single.split('\t'), hasLength(3));
      });

      test(
        'the real script output parses into a path the reader accepts',
        () async {
          // End to end across the wire boundary: real sh -> real parser ->
          // real reader. A shape that only the test author agrees with
          // would pass an assertion on the raw line but fail here.
          final run = await _runProbe(mobileConfigAt: _ConfigLocation.home);
          final report = const HostProbeParser().parse(run.stdout);

          expect(report.status, HostReportStatus.ok);
          expect(
            herdrMobileConfigPath(report),
            '${run.home}/.config/herdr/config.mobile.toml',
          );
        },
      );
    },
    skip: hasPosixShell ? false : skipReason,
  );
}

/// Where the synthetic host has its `config.mobile.toml`, if anywhere.
enum _ConfigLocation {
  /// No file anywhere.
  none,

  /// A regular file at `$HOME/.config/herdr/config.mobile.toml`.
  home,

  /// A regular file at `$XDG_CONFIG_HOME/herdr/config.mobile.toml`.
  xdg,

  /// A DIRECTORY at `$HOME/.config/herdr/config.mobile.toml`.
  directory,
}

class _ProbeRun {
  const _ProbeRun({
    required this.stdout,
    required this.home,
    required this.mobileConfigLines,
  });

  final String stdout;
  final String home;

  /// Every `env herdr_mobile_config ...` line the script emitted.
  final List<String> mobileConfigLines;

  /// The decoded value of the single mobile-config record, or null when
  /// none was emitted.
  String? get mobileConfigValue {
    if (mobileConfigLines.length != 1) return null;
    final fields = mobileConfigLines.single.split('\t');
    return fields.length >= 3 ? fields[2] : null;
  }
}

Future<_ProbeRun> _runProbe({
  required _ConfigLocation mobileConfigAt,
  bool withXdgConfigHome = false,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('helm_probe_herdrcfg_');
  try {
    final home = tempDir.path;
    final xdgDir = '$home/xdg';

    const fileName = 'config.mobile.toml';
    switch (mobileConfigAt) {
      case _ConfigLocation.none:
        break;
      case _ConfigLocation.home:
        await Directory('$home/.config/herdr').create(recursive: true);
        await File('$home/.config/herdr/$fileName').writeAsString('');
      case _ConfigLocation.xdg:
        await Directory('$xdgDir/herdr').create(recursive: true);
        await File('$xdgDir/herdr/$fileName').writeAsString('');
      case _ConfigLocation.directory:
        await Directory('$home/.config/herdr/$fileName').create(recursive: true);
    }

    final env = <String, String>{
      // Deliberately minimal, matching _runFullProbe's isolation: the
      // script prepends its own repair entries to this.
      'PATH': '/usr/bin:/bin',
      'HOME': home,
      'USER': 'tester',
      'SHELL': '/bin/sh',
    };
    if (withXdgConfigHome) env['XDG_CONFIG_HOME'] = xdgDir;

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

    final lines = stdout
        .split('\n')
        .where((line) => line.startsWith('env\t$kHerdrMobileConfigEnvKey\t'))
        .toList();

    return _ProbeRun(stdout: stdout, home: home, mobileConfigLines: lines);
  } finally {
    await tempDir.delete(recursive: true);
  }
}
