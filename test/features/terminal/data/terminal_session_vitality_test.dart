// Tests for TerminalSession's session-vitality surface: the VIRGIN vs
// LIVED-IN verdict, the one-shot query that produces it, and the teardown
// that resets it.
//
// The failure this guards, measured on a real host: herdr restored the
// session SHAPE after a reboot but lost all CONTENT, and helm redrew the
// tabs as if nothing had happened. Reporting that is a serious claim, so
// the assertions below are two-sided in the same way the agent-snapshot
// ones are: every degradation case asserts both the honest variant it MUST
// publish AND, explicitly, that it is NOT [SessionVitalityKnown] — the one
// variant the UI is allowed to speak from.
//
// These drive the REAL HerdrAdapter over a scripted command runner rather
// than a hand-written fake adapter, and that is deliberate. The home
// directory this verdict needs comes from the PROBE, and
// `TerminalSession.connect` skips the probe entirely when a caller injects
// its own adapter — so a fake-adapter harness would silently test the
// home-is-unknown path and nothing else. Going through the real adapter
// also puts the emitted `pane list` command under test from the session
// down, which is where both of this adapter's shipped defects lived.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';
import 'package:helm/core/host/session_vitality.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

class _SilentTerminal extends Terminal {
  _SilentTerminal() : super(maxLines: 200);

  @override
  void write(String data) {}
}

/// Holds one command open until [release], so a consumer's own
/// `.timeout(...)` has to fire rather than the fake pre-emptively throwing
/// a [TimeoutException] the consumer never raised.
class _GatedHostCommandRunner implements HostCommandRunner {
  _GatedHostCommandRunner(this._inner, this._gatedCommand);

  final FakeHostCommandRunner _inner;
  final String _gatedCommand;
  final Completer<void> _gate = Completer<void>();

  int gatedCalls = 0;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async {
    if (command == _gatedCommand) {
      gatedCalls++;
      await _gate.future;
      return const HostCommandResult(stdout: '', exitCode: 1);
    }
    return _inner.run(command, timeout: timeout);
  }

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) =>
      _inner.runScript(script, timeout: timeout);
}

ConnectionProfile _profile() => ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
);

SSHClient _buildFakeClient() => SSHClient(FakeSSHSocket(), username: 'tester');

const _home = '/home/deployer';
const _herdrPath = '/home/deployer/.local/bin/herdr';
const _paneListCommand = "$_herdrPath --session 'helm-0' pane list";
const _agentListCommand = "$_herdrPath --session 'helm-0' agent list";

/// A probe report that DOES carry `env home`, which is where the reference
/// point for "is this pane still at its default?" comes from.
const _probeWithHome =
    'helm-probe/1\n'
    'env\tpath_inherited\t/usr/local/bin:/usr/bin:/bin\n'
    'env\thome\t$_home\n'
    'mux\therdr\t1\t$_herdrPath\therdr 0.8.0\t0\n'
    'session\therdr\thelm-0\tactive\t0\n'
    'end\tok\t120';

/// The same report with `env home` ABSENT — a host that could not tell us
/// where home is.
const _probeWithoutHome =
    'helm-probe/1\n'
    'env\tpath_inherited\t/usr/local/bin:/usr/bin:/bin\n'
    'mux\therdr\t1\t$_herdrPath\therdr 0.8.0\t0\n'
    'session\therdr\thelm-0\tactive\t0\n'
    'end\tok\t120';

/// A host with only tmux, which cannot report panes at all.
const _probeTmuxOnly =
    'helm-probe/1\n'
    'env\thome\t$_home\n'
    'mux\ttmux\t1\t/usr/bin/tmux\ttmux 3.4\t1\n'
    'session\ttmux\thelm-0\tactive\t0\n'
    'end\tok\t120';

String _paneListSuccess(List<Map<String, Object?>> panes) =>
    '{"id":"cli:pane:list","result":{"type":"pane_list","panes":'
    '${_encode(panes)}}}';

String _encode(List<Map<String, Object?>> panes) => '[${panes.map((p) {
  final fields = p.entries.map((e) {
    final value = e.value;
    return '"${e.key}":${value is String ? '"$value"' : value}';
  }).join(',');
  return '{$fields}';
}).join(',')}]';

/// One pane in the shape a resurrected-empty session reported: never
/// touched, sitting in $HOME.
Map<String, Object?> _pane({
  String paneId = 'w1:p1',
  int revision = 1,
  String cwd = _home,
}) => {'pane_id': paneId, 'revision': revision, 'cwd': cwd};

String _agentListSuccess(String agents) =>
    '{"id":"cli:agent:list","result":{"type":"agent_list","agents":[$agents]}}';

const _oneAgent =
    '{"agent":"claude","agent_status":"working","pane_id":"w1:p1",'
    '"terminal_id":"term_1"}';

FakeHostCommandRunner _runner({
  String probeOutput = _probeWithHome,
  String? paneListStdout,
  String? paneListStderr,
  int paneListExit = 0,
  String agents = '',
}) {
  final runner = FakeHostCommandRunner()
    ..whenRunScript(
      probeScriptV1,
      HostCommandResult(stdout: probeOutput, exitCode: 0),
    )
    ..whenRun(
      _agentListCommand,
      HostCommandResult(stdout: _agentListSuccess(agents), exitCode: 0),
    );
  if (paneListStdout != null || paneListStderr != null) {
    runner.whenRun(
      _paneListCommand,
      HostCommandResult(
        stdout: paneListStdout ?? '',
        stderr: paneListStderr ?? '',
        exitCode: paneListExit,
      ),
    );
  }
  return runner;
}

/// A connected session plus the attach session behind it, so a test can end
/// the attach the way a real detach does.
Future<({TerminalSession session, FakeSSHSession attach})> _connect({
  required HostCommandRunner runner,
}) async {
  final service = FakeSSHService();
  service.queueConnectSuccess(
    SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
  );
  final attach = FakeSSHSession();
  final session = TerminalSession(
    profile: _profile(),
    sshService: service,
    tmuxSessionName: 'helm-0',
    terminal: _SilentTerminal(),
    hostRunnerFactory: (_) => runner,
    attachOpener: (client, command, pty) async => attach,
  );
  await session.connect('key');
  expect(session.status, ConnectionStatus.connected);
  return (session: session, attach: attach);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('refreshSessionVitality — reachability', () {
    test(
      'a multiplexer that cannot list panes reports UNSUPPORTED naming '
      'itself, never a verdict',
      () async {
        final connected = await _connect(
          runner: _runner(probeOutput: _probeTmuxOnly),
        );
        final session = connected.session;

        await session.refreshSessionVitality();

        final vitality = session.sessionVitalityNotifier.value;
        expect(vitality, isA<SessionVitalityUnsupported>());
        expect(
          (vitality as SessionVitalityUnsupported).muxId,
          MultiplexerId.tmux,
        );
        expect(vitality, isNot(isA<SessionVitalityKnown>()));

        await session.dispose();
      },
    );

    test('a dead pane server reports UNREACHABLE, never a verdict', () async {
      final connected = await _connect(
        runner: _runner(
          paneListStderr:
              '{"id":"cli:pane:list","error":{"code":"server_not_running",'
              '"message":"no herdr server is running at socket"}}',
          paneListExit: 1,
        ),
      );
      final session = connected.session;

      await session.refreshSessionVitality();

      expect(
        session.sessionVitalityNotifier.value,
        isA<SessionVitalityUnreachable>(),
      );
      expect(
        session.sessionVitalityNotifier.value,
        isNot(isA<SessionVitalityKnown>()),
      );

      await session.dispose();
    });

    test(
      'the StateError listPanes raises for an unrecognized herdr error '
      'degrades to UNREACHABLE instead of escaping',
      () async {
        final connected = await _connect(
          runner: _runner(
            paneListStderr:
                '{"id":"cli:pane:list","error":{"code":"session_not_found",'
                '"message":"no such session"}}',
            paneListExit: 1,
          ),
        );
        final session = connected.session;

        await session.refreshSessionVitality();

        expect(
          session.sessionVitalityNotifier.value,
          isA<SessionVitalityUnreachable>(),
        );

        await session.dispose();
      },
    );

    test(
      'a second call while one is still in flight does NOT open a second '
      'channel — the guard is what bounds the leak `.timeout` would '
      'otherwise create, exactly as it does for the agent poll',
      () async {
        final gated = _GatedHostCommandRunner(_runner(), _paneListCommand);
        final connected = await _connect(runner: gated);
        final session = connected.session;

        final first = session.refreshSessionVitality();
        await session.refreshSessionVitality();
        expect(gated.gatedCalls, 1);

        gated.release();
        await first;

        // The gate answers with a bare non-zero exit and no error envelope,
        // which is an unrecognized failure — it must degrade, not escape.
        expect(
          session.sessionVitalityNotifier.value,
          isA<SessionVitalityUnreachable>(),
        );

        await session.dispose();
      },
    );

    test('an unconnected session publishes nothing at all', () async {
      final runner = _runner(paneListStdout: _paneListSuccess([_pane()]));
      final connected = await _connect(runner: runner);
      final session = connected.session;
      await connected.attach.endWithExitCode(0);

      await session.refreshSessionVitality();

      expect(
        session.sessionVitalityNotifier.value,
        isA<SessionVitalityNotProbed>(),
      );
      expect(runner.runCalls, isNot(contains(_paneListCommand)));

      await session.dispose();
    });
  });

  group('refreshSessionVitality — the verdict', () {
    test(
      'the measured resurrected-empty session reads as VIRGIN: untouched '
      'panes at home, and an authoritative empty agent list',
      () async {
        final connected = await _connect(
          runner: _runner(
            paneListStdout: _paneListSuccess([
              _pane(),
              _pane(paneId: 'w1:p2'),
            ]),
          ),
        );
        final session = connected.session;
        await session.refreshAgents();

        await session.refreshSessionVitality();

        final vitality = session.sessionVitalityNotifier.value;
        expect(vitality, isA<SessionVitalityKnown>());
        expect((vitality as SessionVitalityKnown).shape, SessionShape.virgin);

        await session.dispose();
      },
    );

    test('a pane past its initial revision reads as LIVED-IN', () async {
      final connected = await _connect(
        runner: _runner(
          paneListStdout: _paneListSuccess([_pane(revision: 9)]),
        ),
      );
      final session = connected.session;
      await session.refreshAgents();

      await session.refreshSessionVitality();

      final vitality = session.sessionVitalityNotifier.value;
      expect((vitality as SessionVitalityKnown).shape, SessionShape.livedIn);

      await session.dispose();
    });

    test('a live agent reads as LIVED-IN even with untouched panes', () async {
      final connected = await _connect(
        runner: _runner(
          paneListStdout: _paneListSuccess([_pane()]),
          agents: _oneAgent,
        ),
      );
      final session = connected.session;
      await session.refreshAgents();

      await session.refreshSessionVitality();

      final vitality = session.sessionVitalityNotifier.value;
      expect((vitality as SessionVitalityKnown).shape, SessionShape.livedIn);

      await session.dispose();
    });

    test(
      'the query is scoped to the attached session, so the verdict cannot '
      'describe herdr\'s default session instead',
      () async {
        final runner = _runner(paneListStdout: _paneListSuccess([_pane()]));
        final connected = await _connect(runner: runner);
        final session = connected.session;
        await session.refreshAgents();

        await session.refreshSessionVitality();

        expect(runner.runCalls, contains(_paneListCommand));

        await session.dispose();
      },
    );

    test(
      'a host that never reported its home directory is INDETERMINATE — and '
      'costs NO round-trip, because home cannot arrive later on a '
      'connection that already probed',
      () async {
        final runner = _runner(
          probeOutput: _probeWithoutHome,
          paneListStdout: _paneListSuccess([_pane()]),
        );
        final connected = await _connect(runner: runner);
        final session = connected.session;
        await session.refreshAgents();

        await session.refreshSessionVitality();

        expect(
          session.sessionVitalityNotifier.value,
          isA<SessionVitalityIndeterminate>(),
        );
        expect(runner.runCalls, isNot(contains(_paneListCommand)));

        await session.dispose();
      },
    );
  });

  group('the one-shot trigger', () {
    test(
      'an authoritative agent snapshot drives the verdict exactly once per '
      'connection — a later poll must not re-ask a question whose answer '
      'cannot change',
      () async {
        final runner = _runner(paneListStdout: _paneListSuccess([_pane()]));
        final connected = await _connect(runner: runner);
        final session = connected.session;

        await session.refreshAgents();
        await pumpEventQueue();
        expect(runner.runCalls.where((c) => c == _paneListCommand), hasLength(1));

        await session.refreshAgents();
        await pumpEventQueue();
        expect(runner.runCalls.where((c) => c == _paneListCommand), hasLength(1));

        await session.dispose();
      },
    );

    test(
      'an agent snapshot that is NOT authoritative never triggers the '
      'query: a verdict built on it could not be VIRGIN anyway',
      () async {
        final runner = FakeHostCommandRunner()
          ..whenRunScript(
            probeScriptV1,
            HostCommandResult(stdout: _probeWithHome, exitCode: 0),
          )
          ..whenRun(
            _agentListCommand,
            HostCommandResult(
              stderr:
                  '{"id":"cli:agent:list","error":'
                  '{"code":"server_not_running","message":"no server"}}',
              exitCode: 1,
            ),
          );
        final connected = await _connect(runner: runner);
        final session = connected.session;

        await session.refreshAgents();
        await pumpEventQueue();

        expect(runner.runCalls, isNot(contains(_paneListCommand)));
        expect(
          session.sessionVitalityNotifier.value,
          isA<SessionVitalityNotProbed>(),
        );

        await session.dispose();
      },
    );

    test(
      'disconnecting reverts the verdict to NOT PROBED — a stale VIRGIN on '
      'screen would keep asserting something about a host nobody can ask',
      () async {
        final connected = await _connect(
          runner: _runner(paneListStdout: _paneListSuccess([_pane()])),
        );
        final session = connected.session;
        await session.refreshAgents();
        await pumpEventQueue();
        expect(
          session.sessionVitalityNotifier.value,
          isA<SessionVitalityKnown>(),
        );

        await connected.attach.endWithExitCode(0);

        expect(
          session.sessionVitalityNotifier.value,
          isA<SessionVitalityNotProbed>(),
        );

        await session.dispose();
      },
    );
  });
}
