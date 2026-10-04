import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';

import '../../../helpers/fake_host_command_runner.dart';

// Exact command strings TmuxAdapter runs — empirically verified against a
// real local tmux (3.6a): `list-sessions` exits 1 with a stderr message
// when no server is running; `#{pane_dead}` correctly reports 1 for a
// session whose active pane's process has exited under `remain-on-exit`.
const _listSessionsCommand =
    "tmux list-sessions -F '#{session_name}\t#{pane_dead}'";
const _detectCommand = 'command -v tmux >/dev/null 2>&1 && tmux -V';
const _currentDirCommand =
    "tmux display-message -p '#{pane_current_path}' 2>/dev/null";

void main() {
  late FakeHostCommandRunner runner;
  late TmuxAdapter adapter;

  setUp(() {
    runner = FakeHostCommandRunner();
    adapter = TmuxAdapter(runner);
  });

  group('listSessions', () {
    test(
      'reports a typed server-not-running state, never an empty list',
      () async {
        runner.whenRun(
          _listSessionsCommand,
          const HostCommandResult(
            stderr: 'no server running on /private/tmp/tmux-501/default',
            exitCode: 1,
          ),
        );

        final result = await adapter.listSessions();

        expect(result, isA<MuxServerNotRunning>());
      },
    );

    test('reports an exited session instead of omitting it', () async {
      runner.whenRun(
        _listSessionsCommand,
        const HostCommandResult(stdout: 'work\t0\ndead-agent\t1\n', exitCode: 0),
      );

      final result = await adapter.listSessions();

      expect(result, isA<MuxSessionsAvailable>());
      final sessions = (result as MuxSessionsAvailable).sessions;
      expect(sessions, [
        (name: 'work', state: MuxSessionState.active),
        (name: 'dead-agent', state: MuxSessionState.exited),
      ]);
    });

    test('a genuinely empty session list is reported when the server IS running', () async {
      runner.whenRun(
        _listSessionsCommand,
        const HostCommandResult(stdout: '', exitCode: 0),
      );

      final result = await adapter.listSessions();

      expect(result, isA<MuxSessionsAvailable>());
      expect((result as MuxSessionsAvailable).sessions, isEmpty);
    });
  });

  group('agents capability', () {
    test('is null - TmuxAdapter does not support agent state', () {
      expect(adapter.agents, isNull);
    });

    test(
      'a caller resolving agent support gets a typed unsupported result, never []',
      () {
        final support = AgentSupport.resolve(adapter);

        expect(support, isA<AgentSupportUnsupported>());
        expect((support as AgentSupportUnsupported).muxId, MultiplexerId.tmux);
      },
    );
  });

  group('panes capability', () {
    test('is null - TmuxAdapter cannot report pane revision or cwd', () {
      expect(adapter.panes, isNull);
    });

    test('does not advertise paneListing', () {
      expect(adapter.capabilities, isNot(contains(MuxCapability.paneListing)));
    });
  });

  group('detect', () {
    test('reports installed and the version when the binary is found', () async {
      runner.whenRun(
        _detectCommand,
        const HostCommandResult(stdout: 'tmux 3.6a\n', exitCode: 0),
      );

      final detection = await adapter.detect();

      expect(detection.installed, isTrue);
      expect(detection.absPath, 'tmux');
      expect(detection.version, 'tmux 3.6a');
    });

    test('reports not installed when the binary is missing', () async {
      runner.whenRun(_detectCommand, const HostCommandResult(exitCode: 1));

      final detection = await adapter.detect();

      expect(detection.installed, isFalse);
      expect(detection.absPath, isNull);
      expect(detection.version, isNull);
    });
  });

  group('hasSession', () {
    test('returns true when tmux reports the session exists', () async {
      runner.whenRun(
        "tmux has-session -t 'work'",
        const HostCommandResult(exitCode: 0),
      );

      expect(await adapter.hasSession('work'), isTrue);
    });

    test('returns false when tmux reports no such session', () async {
      runner.whenRun(
        "tmux has-session -t 'missing'",
        const HostCommandResult(
          stderr: "can't find session: missing",
          exitCode: 1,
        ),
      );

      expect(await adapter.hasSession('missing'), isFalse);
    });
  });

  group('currentPaneDirectory', () {
    test(
      'runs the exact command previously hardcoded in RemoteFsService',
      () async {
        runner.whenRun(_currentDirCommand, const HostCommandResult());

        await adapter.currentPaneDirectory();

        expect(runner.runCalls, [_currentDirCommand]);
      },
    );

    test('returns the trimmed stdout on success', () async {
      runner.whenRun(
        _currentDirCommand,
        const HostCommandResult(stdout: '/home/gian/proyectos/metalpren\n'),
      );

      expect(
        await adapter.currentPaneDirectory(),
        '/home/gian/proyectos/metalpren',
      );
    });

    test('returns null when the output is empty', () async {
      runner.whenRun(_currentDirCommand, const HostCommandResult());

      expect(await adapter.currentPaneDirectory(), isNull);
    });

    test('returns null when the command times out', () async {
      runner.whenRun(
        _currentDirCommand,
        const HostCommandResult(
          stdout: '/home/gian/proyectos/metalpren',
          timedOut: true,
        ),
      );

      expect(await adapter.currentPaneDirectory(), isNull);
    });
  });
}
