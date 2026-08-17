import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';

import 'fake_host_command_runner.dart';

void main() {
  group('run', () {
    test('returns the exact result registered for that command', () async {
      final HostCommandRunner runner = FakeHostCommandRunner()
        ..whenRun(
          'pwd',
          const HostCommandResult(stdout: '/home/gian', exitCode: 0),
        );

      final result = await runner.run('pwd');

      expect(result.stdout, '/home/gian');
      expect(result.exitCode, 0);
      expect(result.timedOut, isFalse);
    });

    test('records every call in invocation order', () async {
      final fake = FakeHostCommandRunner()
        ..whenRun('a', const HostCommandResult(stdout: 'A'))
        ..whenRun('b', const HostCommandResult(stdout: 'B'));

      await fake.run('a');
      await fake.run('b');

      expect(fake.runCalls, ['a', 'b']);
    });

    test(
      'throws when a command has no scripted result, so an unexpected '
      'call fails loudly instead of returning empty output',
      () async {
        final fake = FakeHostCommandRunner();

        expect(() => fake.run('unregistered'), throwsStateError);
      },
    );
  });

  group('runScript', () {
    test('returns the exact result registered for that script', () async {
      final HostCommandRunner runner = FakeHostCommandRunner()
        ..whenRunScript(
          'probe-script',
          const HostCommandResult(stdout: 'helm-probe/1', exitCode: 0),
        );

      final result = await runner.runScript('probe-script');

      expect(result.stdout, 'helm-probe/1');
    });

    test(
      'throws when a script has no scripted result, matching run\'s '
      'fail-loudly contract',
      () async {
        final fake = FakeHostCommandRunner();

        expect(() => fake.runScript('unregistered'), throwsStateError);
      },
    );
  });

  test(
    'satisfies the HostCommandRunner contract so a caller behaves the '
    'same as it would against a live transport adapter given the same '
    'result (Swappable Transport Implementations)',
    () async {
      Future<String> useRunner(HostCommandRunner runner) async {
        final result = await runner.run('echo hi');
        return result.stdout;
      }

      final fake = FakeHostCommandRunner()
        ..whenRun('echo hi', const HostCommandResult(stdout: 'hi'));

      expect(await useRunner(fake), 'hi');
    },
  );
}
