// Tests for TerminalSession's agent-state surface: the snapshot it
// publishes, the poll that drives it, and the teardown that stops it.
//
// This layer shipped as a deliberate, test-free spike. What it exists to
// prevent is a SINGLE failure mode, and every test here is aimed at it:
// helm must never say "no agents are running" when the truth is "helm
// could not find out". An empty agent list is the most dangerous possible
// output of this code, because it is indistinguishable from good news.
//
// So the assertions below are deliberately two-sided. Each degradation
// case asserts both the honest variant it MUST publish and, explicitly,
// that it is NOT `AgentsKnown` — the one variant a reader is entitled to
// treat as authoritative.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_agent_adapter.dart';
import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';

class _SilentTerminal extends Terminal {
  _SilentTerminal() : super(maxLines: 200);

  @override
  void write(String data) {}
}

ConnectionProfile _profile({String? multiplexer}) => ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
  multiplexer: multiplexer,
);

SSHClient _buildFakeClient() => SSHClient(FakeSSHSocket(), username: 'tester');

/// A connected [TerminalSession] attached to [adapter], plus the attach
/// session behind it so a test can end it the way a real detach does.
///
/// `tmuxSessionName` is non-null on purpose: it is what makes agent
/// tracking meaningful at all (see `TerminalSession.connect`), so a
/// harness that omitted it would silently test the disabled path.
Future<({TerminalSession session, FakeSSHSession attach})> _connect({
  required MultiplexerAdapter adapter,
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
    muxAdapter: adapter,
    hostRunnerFactory: (_) => FakeHostCommandRunner(),
    attachOpener: (client, command, pty) async => attach,
  );
  await session.connect('key');
  expect(session.status, ConnectionStatus.connected);
  return (session: session, attach: attach);
}

/// Just the session, for the majority of tests that never end the attach.
Future<TerminalSession> _connectedSession({
  required MultiplexerAdapter adapter,
}) async => (await _connect(adapter: adapter)).session;

const _blockedAgent = (
  target: 't1',
  label: 'claude',
  state: AgentState.blocked,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('refreshAgents — never collapses "we do not know" into "nothing"', () {
    test(
      'a multiplexer that cannot track agents reports UNSUPPORTED, naming '
      'itself, and never an empty agent list',
      () async {
        final session = await _connectedSession(
          adapter: FakeAgentlessAdapter(id: MultiplexerId.tmux),
        );

        await session.refreshAgents();

        final snapshot = session.agentsNotifier.value;
        expect(snapshot, isA<AgentsUnsupported>());
        expect((snapshot as AgentsUnsupported).muxId, MultiplexerId.tmux);
        // The whole point: tmux having no answer is NOT tmux answering
        // "zero agents".
        expect(snapshot, isNot(isA<AgentsKnown>()));

        await session.dispose();
      },
    );

    test(
      'a dead agent server reports UNREACHABLE, never an empty agent list',
      () async {
        final adapter = FakeAgentAdapter()
          ..whenAgents(const MuxAgentServerNotRunning());
        final session = await _connectedSession(adapter: adapter);

        await session.refreshAgents();

        expect(session.agentsNotifier.value, isA<AgentsUnreachable>());
        expect(session.agentsNotifier.value, isNot(isA<AgentsKnown>()));

        await session.dispose();
      },
    );

    test(
      'a live server with zero agents is the ONLY case that reports a '
      'known, genuinely empty list',
      () async {
        final adapter = FakeAgentAdapter()
          ..whenAgents(const MuxAgentsAvailable([]));
        final session = await _connectedSession(adapter: adapter);

        await session.refreshAgents();

        final snapshot = session.agentsNotifier.value;
        expect(snapshot, isA<AgentsKnown>());
        expect((snapshot as AgentsKnown).agents, isEmpty);
        // Distinct from BOTH not-knowing cases, which is the distinction
        // the sealed type exists to force.
        expect(snapshot, isNot(isA<AgentsUnreachable>()));
        expect(snapshot, isNot(isA<AgentsUnsupported>()));

        await session.dispose();
      },
    );

    test('a successful query publishes the agents verbatim', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
      final session = await _connectedSession(adapter: adapter);

      await session.refreshAgents();

      final snapshot = session.agentsNotifier.value as AgentsKnown;
      expect(snapshot.agents, [_blockedAgent]);

      await session.dispose();
    });

    test(
      'the StateError listAgents raises for an unrecognized herdr error '
      'degrades to UNREACHABLE instead of escaping or reading as empty',
      () async {
        final adapter = FakeAgentAdapter()
          ..whenThrows(StateError('herdr agent list failed: internal_error'));
        final session = await _connectedSession(adapter: adapter);

        // Must not reject: this runs unawaited from a Timer, where a
        // rejection would surface as an unhandled async error.
        await expectLater(session.refreshAgents(), completes);

        expect(session.agentsNotifier.value, isA<AgentsUnreachable>());
        expect(session.agentsNotifier.value, isNot(isA<AgentsKnown>()));

        await session.dispose();
      },
    );

    test(
      'a query that never answers is abandoned at kAgentListTimeout and '
      'degrades to UNREACHABLE, never to no-agents',
      () async {
        final adapter = FakeAgentAdapter()..whenHangs();
        final session = await _connectedSession(adapter: adapter);

        // A virtual clock, so the real 8-second ceiling is exercised
        // rather than approximated by throwing a TimeoutException the
        // production code never actually raised. `.timeout()` arms its
        // Timer in the zone that calls it, so calling refreshAgents from
        // inside the FakeAsync zone is what makes that timer fake.
        FakeAsync().run((async) {
          var settled = false;
          unawaited(session.refreshAgents().then((_) => settled = true));

          async.elapse(kAgentListTimeout - const Duration(milliseconds: 1));
          async.flushMicrotasks();
          expect(
            settled,
            isFalse,
            reason: 'must not give up before the documented ceiling',
          );
          expect(session.agentsNotifier.value, isA<AgentsNotProbed>());

          async.elapse(const Duration(milliseconds: 2));
          async.flushMicrotasks();

          expect(settled, isTrue);
          expect(session.agentsNotifier.value, isA<AgentsUnreachable>());
          expect(session.agentsNotifier.value, isNot(isA<AgentsKnown>()));
        });

        adapter.release();
        await session.dispose();
      },
    );

    test('does not ask the host at all when the session is not connected', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
      final session = await _connectedSession(adapter: adapter);
      session.statusNotifier.value = ConnectionStatus.disconnected;

      await session.refreshAgents();

      expect(adapter.listAgentsCalls, 0);
      expect(session.agentsNotifier.value, isA<AgentsNotProbed>());

      await session.dispose();
    });

    test(
      'a second call while one is still in flight is dropped, so a slow '
      'host cannot accumulate a backlog of open channels',
      () async {
        final adapter = FakeAgentAdapter()..whenHangs();
        final session = await _connectedSession(adapter: adapter);

        unawaited(session.refreshAgents());
        await pumpEventQueue();
        await session.refreshAgents();

        expect(adapter.listAgentsCalls, 1);

        adapter.release();
        await session.dispose();
      },
    );

    test(
      'a query ABANDONED at the timeout still holds the in-flight guard, '
      'so a wedged host leaks at most ONE remote invocation, not one per '
      'poll until the SSH channel limit is hit',
      () async {
        final adapter = FakeAgentAdapter()..whenHangs();
        final session = await _connectedSession(adapter: adapter);

        FakeAsync().run((async) {
          unawaited(session.refreshAgents());
          async.flushMicrotasks();
          expect(adapter.listAgentsCalls, 1);

          // The call site gives up here. The REMOTE command does not: the
          // channel is still open and still buffering.
          async.elapse(kAgentListTimeout + const Duration(seconds: 1));
          async.flushMicrotasks();
          expect(session.agentsNotifier.value, isA<AgentsUnreachable>());

          // The next poll comes round. It must NOT open a second channel
          // on top of the one nobody closed — an 8s ceiling against a 10s
          // cadence would otherwise add one abandoned invocation every
          // interval, and OpenSSH's default MaxSessions of 10 would then
          // starve the connection of the channels a reconnect needs.
          unawaited(session.refreshAgents());
          async.flushMicrotasks();
          expect(adapter.listAgentsCalls, 1);
        });

        // Resuming is asserted OUTSIDE the virtual clock on purpose: the
        // gate's Completer was created in the root zone, so completing it
        // schedules a real microtask that `flushMicrotasks` cannot drive.
        adapter.release();
        await pumpEventQueue();

        adapter.whenAgents(const MuxAgentsAvailable([]));
        await session.refreshAgents();

        expect(
          adapter.listAgentsCalls,
          2,
          reason: 'the guard must lift once the host finally answers',
        );

        await session.dispose();
      },
    );
  });

  group('agent polling lifecycle — demand-gated, never orphaned', () {
    test(
      'a connected session with nothing observing asks the host NOTHING, '
      'however long it stays connected',
      () async {
        final adapter = FakeAgentAdapter()
          ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
        final session = await _connectedSession(adapter: adapter);

        await pumpEventQueue();
        expect(adapter.listAgentsCalls, 0);

        // And it is not merely slow to start: no timer exists to fire.
        FakeAsync().run((async) {
          async.elapse(kAgentPollInterval * 10);
          async.flushMicrotasks();
        });
        expect(adapter.listAgentsCalls, 0);

        await session.dispose();
      },
    );

    test(
      'the first observer arms the poll AND gets an immediate first '
      'reading, rather than waiting out a whole interval',
      () async {
        final adapter = FakeAgentAdapter()
          ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
        final session = await _connectedSession(adapter: adapter);

        void listener() {}
        session.agentsNotifier.addListener(listener);
        await pumpEventQueue();

        expect(adapter.listAgentsCalls, 1);
        expect(session.agentsNotifier.value, isA<AgentsKnown>());

        // Shut the timer down INSIDE the test body. `addTearDown` is too
        // late for the widget binding, whose pending-timer invariant runs
        // before teardown callbacks — the trap the spike hit.
        session.agentsNotifier.removeListener(listener);
        await session.dispose();
      },
    );

    test('the last observer leaving disarms the poll', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
      final session = await _connectedSession(adapter: adapter);

      void listener() {}
      session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      final whileObserved = adapter.listAgentsCalls;

      session.agentsNotifier.removeListener(listener);
      await pumpEventQueue();

      // Nothing further, no matter how much time passes.
      FakeAsync().run((async) {
        async.elapse(kAgentPollInterval * 5);
        async.flushMicrotasks();
      });
      expect(adapter.listAgentsCalls, whileObserved);

      await session.dispose();
    });

    test(
      'losing the connection stops the poll and reverts the snapshot to '
      '"we do not know" rather than leaving stale state on screen',
      () async {
        final adapter = FakeAgentAdapter()
          ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
        final connected = await _connect(adapter: adapter);
        final session = connected.session;

        void listener() {}
        session.agentsNotifier.addListener(listener);
        await pumpEventQueue();
        expect(session.agentsNotifier.value, isA<AgentsKnown>());
        final beforeDrop = adapter.listAgentsCalls;

        // The path a real detach takes: the attach session's `done`
        // completes, TerminalSession classifies the exit and disconnects.
        await connected.attach.endWithExitCode(0);
        await pumpEventQueue();

        expect(session.status, ConnectionStatus.disconnected);

        expect(session.agentsNotifier.value, isA<AgentsNotProbed>());
        FakeAsync().run((async) {
          async.elapse(kAgentPollInterval * 5);
          async.flushMicrotasks();
        });
        expect(adapter.listAgentsCalls, beforeDrop);

        session.agentsNotifier.removeListener(listener);
        await session.dispose();
      },
    );

    test('dispose stops the poll and leaves no pending timer', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
      final session = await _connectedSession(adapter: adapter);

      void listener() {}
      session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      final beforeDispose = adapter.listAgentsCalls;

      await session.dispose();

      FakeAsync().run((async) {
        async.elapse(kAgentPollInterval * 5);
        async.flushMicrotasks();
      });
      expect(adapter.listAgentsCalls, beforeDispose);
    });
  });

  group('disposal guards — an in-flight answer outliving its session', () {
    test(
      'a query that lands AFTER dispose is dropped instead of writing to a '
      'disposed notifier',
      () async {
        final adapter = FakeAgentAdapter()..whenHangs();
        final session = await _connectedSession(adapter: adapter);

        final inFlight = session.refreshAgents();
        await pumpEventQueue();

        await session.dispose();
        adapter.release();

        // The bug this guards is a throw from ValueNotifier, which the
        // spike already hit once on the advisory path.
        await expectLater(inFlight, completes);

        // `completes` alone would NOT prove the guard works: refreshAgents
        // wraps its publish in a try/catch, so a "used after being
        // disposed" assertion thrown by the notifier is caught there and
        // swallowed, and the future completes either way. Verified by
        // mutation — deleting the guards keeps this test green without the
        // assertion below.
        //
        // `ValueNotifier`'s setter assigns `_value` BEFORE it calls
        // `notifyListeners()` (which is what asserts), so an unguarded
        // write is still observable through `.value` after the fact. A
        // snapshot that never moved is proof no write was attempted.
        expect(
          session.agentsNotifier.value,
          isA<AgentsNotProbed>(),
          reason: 'a disposed session must not be written to at all',
        );
      },
    );

    test('refreshAgents on an already-disposed session is a silent no-op', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
      final session = await _connectedSession(adapter: adapter);
      await session.dispose();

      await expectLater(session.refreshAgents(), completes);
      expect(adapter.listAgentsCalls, 0);
    });
  });

  group('the session ref reaches herdr through the real wiring', () {
    // The end of the chain herdr_adapter_test.dart and
    // multiplexer_factory_test.dart pin the earlier links of. Dropping
    // `sessionRef: tmuxSessionName` from `_resolveMultiplexer` would leave
    // every one of those tests green while restoring, in the live app,
    // the exact "No agents running right now" lie told over a blocked
    // agent.
    const probeOutput =
        'helm-probe/1\n'
        'env\tpath_inherited\t/usr/local/bin:/usr/bin:/bin\n'
        'mux\therdr\t1\t/home/deployer/.local/bin/herdr\therdr 0.8.0\t0\n'
        'mux\ttmux\t0\t\t\t0\n'
        'mux\tzellij\t0\t\t\t0\n'
        'end\tok\t120';

    const scopedAgentList =
        "/home/deployer/.local/bin/herdr --session 'helm-0' agent list";

    test('refreshAgents queries the ATTACHED session, not herdr\'s default',
        () async {
      final runner = FakeHostCommandRunner();
      runner.whenRunScript(
        probeScriptV1,
        const HostCommandResult(stdout: probeOutput, exitCode: 0),
      );
      runner.whenRun(
        scopedAgentList,
        const HostCommandResult(
          stdout: '{"id":"x","result":{"type":"agent_list","agents":['
              '{"terminal_id":"t1","agent_status":"blocked","workspace_id":"w",'
              '"tab_id":"tb","pane_id":"p","focused":true,"revision":1}]}}',
          exitCode: 0,
        ),
      );
      // The unscoped spelling is registered too, answering with the empty
      // list herdr's default socket really returned on the measured host.
      // A regression therefore fails on the assertion below rather than on
      // a StateError from the fake.
      runner.whenRun(
        '/home/deployer/.local/bin/herdr agent list',
        const HostCommandResult(
          stdout: '{"id":"x","result":{"type":"agent_list","agents":[]}}',
          exitCode: 0,
        ),
      );

      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
      );
      final session = TerminalSession(
        profile: _profile(multiplexer: 'herdr'),
        sshService: service,
        tmuxSessionName: 'helm-0',
        terminal: _SilentTerminal(),
        hostRunnerFactory: (_) => runner,
        attachOpener: (client, command, pty) async => FakeSSHSession(),
      );
      await session.connect('key');

      await session.refreshAgents();

      expect(runner.runCalls, contains(scopedAgentList));
      final snapshot = session.agentsNotifier.value;
      expect(snapshot, isA<AgentsKnown>());
      expect((snapshot as AgentsKnown).agents.single.state, AgentState.blocked);

      await session.dispose();
    });
  });
}
