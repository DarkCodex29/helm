import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/adapters/zellij_adapter.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/shell_quote.dart';

import '../../../helpers/fake_host_command_runner.dart';

// Exact command string ZellijAdapter runs and its output shape — empirically
// verified against a real local zellij 0.44.3 install:
//
// - `list-sessions --no-formatting` (WITHOUT `--short`). `--short` was
//   tested and it strips the `(EXITED - attach to resurrect)` marker
//   entirely — a session confirmed exited via a killed server process still
//   prints only its bare name under `--short`, making it indistinguishable
//   from an active one. That is the exact "unreliable, do not depend on
//   it" case the task called out, so `--short` is deliberately not used.
// - No server / zero sessions: exit 1, stderr
//   "No active zellij sessions found.". zellij has no shared daemon —
//   each session is its own server process — so this is the zellij-specific
//   equivalent of "server not reachable" (there is no separate "server
//   running with zero sessions" state to distinguish it from, unlike tmux).
// - Line shape per session: "<name> [Created <time> ago] " when active, and
//   "<name> [Created <time> ago] (EXITED - attach to resurrect)" when
//   exited. Confirmed exit code is 0 for both — an exited entry does not
//   make the command fail.
// - Session names may contain embedded spaces (confirmed: "helm test 6"),
//   so parsing splits on the literal " [Created" marker, never on
//   whitespace tokens.
const _listSessionsCommand = 'zellij list-sessions --no-formatting';
const _detectCommand =
    'command -v zellij >/dev/null 2>&1 && zellij --version';

void main() {
  late FakeHostCommandRunner runner;
  late ZellijAdapter adapter;

  setUp(() {
    runner = FakeHostCommandRunner();
    adapter = ZellijAdapter(runner);
  });

  group('listSessions', () {
    test(
      'reports a typed server-not-running state, never an empty list',
      () async {
        runner.whenRun(
          _listSessionsCommand,
          const HostCommandResult(
            stderr: 'No active zellij sessions found.',
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
        const HostCommandResult(
          stdout:
              'work [Created 3s ago] \n'
              'dead-agent [Created 23s ago] (EXITED - attach to resurrect)\n',
          exitCode: 0,
        ),
      );

      final result = await adapter.listSessions();

      expect(result, isA<MuxSessionsAvailable>());
      final sessions = (result as MuxSessionsAvailable).sessions;
      expect(sessions, [
        (name: 'work', state: MuxSessionState.active),
        (name: 'dead-agent', state: MuxSessionState.exited),
      ]);
    });

    test('parses a session name containing embedded spaces', () async {
      runner.whenRun(
        _listSessionsCommand,
        const HostCommandResult(
          stdout: 'helm test 6 [Created 1s ago] \n',
          exitCode: 0,
        ),
      );

      final result = await adapter.listSessions();

      expect((result as MuxSessionsAvailable).sessions, [
        (name: 'helm test 6', state: MuxSessionState.active),
      ]);
    });

    test(
      'strips stray ANSI escape codes defensively, even though '
      '--no-formatting already omits them on the verified local install',
      () async {
        runner.whenRun(
          _listSessionsCommand,
          const HostCommandResult(
            stdout: '\x1B[32;1mwork\x1B[m [Created 3s ago] \n',
            exitCode: 0,
          ),
        );

        final result = await adapter.listSessions();

        expect((result as MuxSessionsAvailable).sessions, [
          (name: 'work', state: MuxSessionState.active),
        ]);
      },
    );
  });

  group('agents capability', () {
    test('is null - ZellijAdapter does not support agent state', () {
      expect(adapter.agents, isNull);
    });

    test(
      'a caller resolving agent support gets a typed unsupported result, '
      'never []',
      () {
        final support = AgentSupport.resolve(adapter);

        expect(support, isA<AgentSupportUnsupported>());
        expect(
          (support as AgentSupportUnsupported).muxId,
          MultiplexerId.zellij,
        );
      },
    );

    test('advertises deadSessionResurrection, not agentState', () {
      expect(adapter.capabilities, {MuxCapability.deadSessionResurrection});
    });
  });

  group('panes capability', () {
    test('is null - ZellijAdapter cannot report pane revision or cwd', () {
      expect(adapter.panes, isNull);
    });
  });

  group('detect', () {
    test(
      'reports installed and the version when the binary is found',
      () async {
        runner.whenRun(
          _detectCommand,
          const HostCommandResult(stdout: 'zellij 0.44.3\n', exitCode: 0),
        );

        final detection = await adapter.detect();

        expect(detection.installed, isTrue);
        expect(detection.absPath, 'zellij');
        expect(detection.version, 'zellij 0.44.3');
      },
    );

    test('reports not installed when the binary is missing', () async {
      runner.whenRun(_detectCommand, const HostCommandResult(exitCode: 1));

      final detection = await adapter.detect();

      expect(detection.installed, isFalse);
      expect(detection.absPath, isNull);
      expect(detection.version, isNull);
    });
  });

  group('hasSession', () {
    test('returns true when the session is active', () async {
      runner.whenRun(
        _listSessionsCommand,
        const HostCommandResult(
          stdout: 'work [Created 3s ago] \n',
          exitCode: 0,
        ),
      );

      expect(await adapter.hasSession('work'), isTrue);
    });

    test('returns true when the session exists but has exited', () async {
      runner.whenRun(
        _listSessionsCommand,
        const HostCommandResult(
          stdout: 'work [Created 3s ago] (EXITED - attach to resurrect)\n',
          exitCode: 0,
        ),
      );

      expect(await adapter.hasSession('work'), isTrue);
    });

    test('returns false when no session by that name is present', () async {
      runner.whenRun(
        _listSessionsCommand,
        const HostCommandResult(
          stdout: 'other [Created 3s ago] \n',
          exitCode: 0,
        ),
      );

      expect(await adapter.hasSession('work'), isFalse);
    });

    test('returns false when the server is not running', () async {
      runner.whenRun(
        _listSessionsCommand,
        const HostCommandResult(
          stderr: 'No active zellij sessions found.',
          exitCode: 1,
        ),
      );

      expect(await adapter.hasSession('work'), isFalse);
    });
  });

  group('attachCommand', () {
    test('uses attach --create for idempotent attach-or-create', () {
      expect(adapter.attachCommand('work'), "zellij attach --create 'work'");
    });

    test('uses the resolved absolute path, not a bare binary name', () {
      final resolved = ZellijAdapter(
        runner,
        absPath: '/opt/homebrew/bin/zellij',
      );

      expect(
        resolved.attachCommand('work'),
        "/opt/homebrew/bin/zellij attach --create 'work'",
      );
    });

    test('single-quotes a session name with a shell command separator', () {
      const name = 'x; rm -rf ~';
      expect(
        adapter.attachCommand(name),
        'zellij attach --create ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with command substitution', () {
      const name = r'$(id)';
      expect(
        adapter.attachCommand(name),
        'zellij attach --create ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with an embedded single quote', () {
      const name = "O'Brien";
      expect(
        adapter.attachCommand(name),
        'zellij attach --create ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with a leading dash', () {
      const name = '-rf';
      expect(
        adapter.attachCommand(name),
        'zellij attach --create ${shellQuote(name)}',
      );
    });
  });
}
