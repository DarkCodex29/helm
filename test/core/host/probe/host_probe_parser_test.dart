import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/probe/host_probe_parser.dart';
import 'package:helm/core/host/probe/host_report.dart';

void main() {
  const parser = HostProbeParser();

  group('Version Gate', () {
    test('matching version marker proceeds to remaining records', () {
      final report = parser.parse(
        'helm-probe/1\nenv\tuser\tdev\nend\tok\t5\n',
      );

      expect(report.status, HostReportStatus.ok);
      expect(report.env['user'], 'dev');
    });

    test('mismatched major version is refused, no record parsed', () {
      final report = parser.parse(
        'helm-probe/2\nenv\tuser\tdev\nend\tok\t5\n',
      );

      expect(report.status, HostReportStatus.versionMismatch);
      expect(report.env, isEmpty);
    });
  });

  group('Truncation Is Explicit', () {
    test('a complete stream reflects the end record status', () {
      final report = parser.parse('helm-probe/1\nend\tpartial\t9\n');

      expect(report.status, HostReportStatus.partial);
      expect(report.elapsedMs, 9);
    });

    test('a stream missing the end record is truncated, not empty', () {
      final report = parser.parse(
        'helm-probe/1\nmux\ttmux\t1\t/usr/bin/tmux\ttmux 3.3a\t1\n',
      );

      expect(report.status, HostReportStatus.truncated);
      expect(report.mux, hasLength(1));
    });
  });

  group('Forward-Compatible Record Reading', () {
    test('an unknown kind is skipped, siblings still parse', () {
      final report = parser.parse(
        'helm-probe/1\nfuture-kind\tsome\tfields\nenv\tuser\tdev\nend\tok\t1\n',
      );

      expect(report.status, HostReportStatus.ok);
      expect(report.env['user'], 'dev');
    });

    test('extra trailing fields on a known kind are ignored', () {
      final report = parser.parse(
        'helm-probe/1\n'
        'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.3a\t1\tunexpected-extra-field\n'
        'end\tok\t1\n',
      );

      expect(report.status, HostReportStatus.ok);
      expect(report.mux.single.id, 'tmux');
      expect(report.mux.single.onInheritedPath, isTrue);
    });
  });

  group('Record-Level Fault Isolation', () {
    test('one malformed record does not block its siblings', () {
      final report = parser.parse(
        'helm-probe/1\n'
        'env\tshell\t/bin/bash\n'
        'mux\ttmux\n' // malformed: mux requires 5 fields, has 1
        'env\tuser\tdev\n'
        'end\tok\t10\n',
      );

      expect(report.status, HostReportStatus.ok);
      expect(report.mux, isEmpty);
      expect(report.env['shell'], '/bin/bash');
      expect(report.env['user'], 'dev');
    });
  });

  group('Escaping Round-Trip', () {
    test('each reserved byte class round-trips exactly', () {
      // Wire bytes for a session name whose ORIGINAL value contains a
      // literal backslash, TAB, LF, and CR, encoded per the escape table
      // in docs/host-contract/v1.md: \ -> \\, TAB -> \t, LF -> \n, CR -> \r.
      // Real TAB/LF characters below are field/record delimiters, never
      // part of a value.
      const wire =
          'helm-probe/1\n'
          'session\ttmux\tname\\\\weird\\ttab\\nline\\rcr\tactive\t0\n'
          'end\tok\t1\n';
      final decoded = parser.parse(wire);

      expect(decoded.status, HostReportStatus.ok);
      expect(decoded.sessions.single.name, 'name\\weird\ttab\nline\rcr');
    });
  });

  group('Installed-but-Off-PATH Is Distinguishable From Not-Installed', () {
    test('binary found only via repaired PATH', () {
      final report = parser.parse(
        'helm-probe/1\n'
        'mux\therdr\t1\t/opt/homebrew/bin/herdr\therdr 0.1\t0\n'
        'end\tok\t1\n',
      );

      final herdr = report.mux.single;
      expect(herdr.found, isTrue);
      expect(herdr.absPath, '/opt/homebrew/bin/herdr');
      expect(herdr.onInheritedPath, isFalse);
    });

    test('binary genuinely absent has no resolved path', () {
      final report = parser.parse(
        'helm-probe/1\nmux\tzellij\t0\t\t\t0\nend\tok\t1\n',
      );

      final zellij = report.mux.single;
      expect(zellij.found, isFalse);
      expect(zellij.absPath, isEmpty);
    });
  });

  group('parseResult — bounded traversal', () {
    test(
      'a timed-out command result is never accepted as a partial report',
      () {
        const timedOutResult = HostCommandResult(
          stdout: 'helm-probe/1\nenv\tuser\tdev\nend\tok\t5\n',
          timedOut: true,
        );

        final report = parser.parseResult(timedOutResult);

        expect(report.status, HostReportStatus.truncated);
        expect(report.env, isEmpty);
      },
    );

    test('a completed command result is parsed normally', () {
      const result = HostCommandResult(
        stdout: 'helm-probe/1\nenv\tuser\tdev\nend\tok\t5\n',
      );

      final report = parser.parseResult(result);

      expect(report.status, HostReportStatus.ok);
      expect(report.env['user'], 'dev');
    });
  });
}
