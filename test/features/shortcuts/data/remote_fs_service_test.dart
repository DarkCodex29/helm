import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/features/shortcuts/data/remote_fs_service.dart';

import '../../../helpers/fake_host_command_runner.dart';

// Exact command strings from RemoteFsService — must stay byte-for-byte
// identical to production. In particular, the tmux command MUST NOT change
// in this slice (it is only replaced once the multiplexer adapter lands).
const _detectProjectsCommand =
    r'''find ~/Desktop ~/projects ~/proyectos ~/work -maxdepth 3 \( -name "pubspec.yaml" -o -name "package.json" -o -name "*.csproj" -o -name "go.mod" \) -not -path "*/node_modules/*" -not -path "*/.dart_tool/*" 2>/dev/null | head -50''';
const _currentDirectoryCommand =
    "tmux display-message -p '#{pane_current_path}' 2>/dev/null";

void main() {
  late FakeHostCommandRunner runner;
  late RemoteFsService service;

  setUp(() {
    runner = FakeHostCommandRunner();
    service = RemoteFsService(runner);
  });

  group('detectProjects', () {
    test('runs the exact find command unchanged', () async {
      runner.whenRun(_detectProjectsCommand, const HostCommandResult());

      await service.detectProjects();

      expect(runner.runCalls, [_detectProjectsCommand]);
    });

    test(
      'returns the unique, sorted parent directories of found marker files',
      () async {
        runner.whenRun(
          _detectProjectsCommand,
          const HostCommandResult(
            stdout:
                '/home/gian/proyectos/zeta/pubspec.yaml\n'
                '/home/gian/proyectos/alpha/package.json\n'
                '/home/gian/proyectos/alpha/sub/go.mod\n',
          ),
        );

        final projects = await service.detectProjects();

        expect(projects, [
          '/home/gian/proyectos/alpha',
          '/home/gian/proyectos/alpha/sub',
          '/home/gian/proyectos/zeta',
        ]);
      },
    );

    test('returns an empty list when no markers are found', () async {
      runner.whenRun(_detectProjectsCommand, const HostCommandResult());

      expect(await service.detectProjects(), isEmpty);
    });

    test(
      'returns an empty list when the command fails (unregistered/throws)',
      () async {
        // No whenRun registered — FakeHostCommandRunner.run throws
        // StateError, exercising the same catch-and-empty path a real
        // transport failure would hit.
        expect(await service.detectProjects(), isEmpty);
      },
    );
  });

  group('getCurrentDirectory', () {
    test('runs the exact tmux display-message command unchanged', () async {
      runner.whenRun(_currentDirectoryCommand, const HostCommandResult());

      await service.getCurrentDirectory();

      expect(runner.runCalls, [_currentDirectoryCommand]);
    });

    test('returns the trimmed stdout on success', () async {
      runner.whenRun(
        _currentDirectoryCommand,
        const HostCommandResult(stdout: '/home/gian/proyectos/metalpren\n'),
      );

      expect(
        await service.getCurrentDirectory(),
        '/home/gian/proyectos/metalpren',
      );
    });

    test('returns null when the output is empty', () async {
      runner.whenRun(_currentDirectoryCommand, const HostCommandResult());

      expect(await service.getCurrentDirectory(), isNull);
    });

    test('returns null when the command times out', () async {
      runner.whenRun(
        _currentDirectoryCommand,
        const HostCommandResult(
          stdout: '/home/gian/proyectos/metalpren',
          timedOut: true,
        ),
      );

      expect(await service.getCurrentDirectory(), isNull);
    });
  });
}
