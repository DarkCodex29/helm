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
import '../../../helpers/fake_waiting_agent_adapter.dart';
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
  tabId: null,
  workspaceId: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('refreshAgents — never collapses "we do not know" into "nothing"', () {
    test('a multiplexer that cannot track agents reports UNSUPPORTED, naming '
        'itself, and never an empty agent list', () async {
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
    });

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

    test('a live server with zero agents is the ONLY case that reports a '
        'known, genuinely empty list', () async {
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
    });

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

    test('a query that never answers is abandoned at kAgentListTimeout and '
        'degrades to UNREACHABLE, never to no-agents', () async {
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
    });

    test(
      'does not ask the host at all when the session is not connected',
      () async {
        final adapter = FakeAgentAdapter()
          ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
        final session = await _connectedSession(adapter: adapter);
        session.statusNotifier.value = ConnectionStatus.disconnected;

        await session.refreshAgents();

        expect(adapter.listAgentsCalls, 0);
        expect(session.agentsNotifier.value, isA<AgentsNotProbed>());

        await session.dispose();
      },
    );

    test('a second call while one is still in flight is dropped, so a slow '
        'host cannot accumulate a backlog of open channels', () async {
      final adapter = FakeAgentAdapter()..whenHangs();
      final session = await _connectedSession(adapter: adapter);

      unawaited(session.refreshAgents());
      await pumpEventQueue();
      await session.refreshAgents();

      expect(adapter.listAgentsCalls, 1);

      adapter.release();
      await session.dispose();
    });

    test('a query ABANDONED at the timeout still holds the in-flight guard, '
        'so a wedged host leaks at most ONE remote invocation, not one per '
        'poll until the SSH channel limit is hit', () async {
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
    });
  });

  group('agent polling lifecycle — demand-gated, never orphaned', () {
    test('a connected session with nothing observing asks the host NOTHING, '
        'however long it stays connected', () async {
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
    });

    test('the first observer arms the poll AND gets an immediate first '
        'reading, rather than waiting out a whole interval', () async {
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
    });

    test('while observed, it re-asks once per kAgentPollInterval — the badge '
        'is the whole point, so a snapshot taken once at connect would be '
        'stale within seconds', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
      final session = await _connectedSession(adapter: adapter);

      void listener() {}
      // Armed INSIDE the virtual clock: Timer.periodic binds to the zone
      // that creates it, so a timer armed outside would never be driven
      // by `elapse`.
      FakeAsync().run((async) {
        session.agentsNotifier.addListener(listener);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 1, reason: 'immediate first read');

        async.elapse(kAgentPollInterval);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 2);

        async.elapse(kAgentPollInterval * 3);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 5, reason: 'one per interval');

        // Just short of the next tick, nothing extra fires.
        async.elapse(kAgentPollInterval - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 5);

        session.agentsNotifier.removeListener(listener);
      });

      await session.dispose();
    });

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

    test('losing the connection stops the poll and reverts the snapshot to '
        '"we do not know" rather than leaving stale state on screen', () async {
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
    });

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
    test('a query that lands AFTER dispose is dropped instead of writing to a '
        'disposed notifier', () async {
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
    });

    test(
      'refreshAgents on an already-disposed session is a silent no-op',
      () async {
        final adapter = FakeAgentAdapter()
          ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
        final session = await _connectedSession(adapter: adapter);
        await session.dispose();

        await expectLater(session.refreshAgents(), completes);
        expect(adapter.listAgentsCalls, 0);
      },
    );
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

    test(
      'refreshAgents queries the ATTACHED session, not herdr\'s default',
      () async {
        final runner = FakeHostCommandRunner();
        runner.whenRunScript(
          probeScriptV1,
          const HostCommandResult(stdout: probeOutput, exitCode: 0),
        );
        runner.whenRun(
          scopedAgentList,
          const HostCommandResult(
            stdout:
                '{"id":"x","result":{"type":"agent_list","agents":['
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
        expect(
          (snapshot as AgentsKnown).agents.single.state,
          AgentState.blocked,
        );

        await session.dispose();
      },
    );
  });

  // ── Event-driven tracking ────────────────────────────────────────────
  //
  // An adapter that advertises MuxCapability.agentWait can be ASKED to tell
  // us when an agent moves, instead of being interrogated every ten
  // seconds. The badge then changes in tens of milliseconds rather than in
  // up to a full interval — measured at 55ms of host-side reaction against
  // a real herdr 0.8.0.
  //
  // The danger this trades for is worse than a stale badge, so most of what
  // follows is aimed at it rather than at the happy path: a wait is a HELD
  // SSH exec channel. OpenSSH's default MaxSessions is 10, and commit
  // 773888f is the record of what channel accumulation costs a user — a
  // connection with no channel left for a reconnect to attach through, i.e.
  // losing the terminal in order to refresh a badge.
  group('event-driven agent tracking — exactly one held channel', () {
    /// An observed session, with the observer removed for the caller by
    /// [stop]. Removing it INSIDE the test body is mandatory: the widget
    /// binding's pending-timer invariant runs before `addTearDown`
    /// callbacks, which is the trap the first version of this poll hit.
    Future<({TerminalSession session, void Function() stop})> observed(
      FakeWaitingAgentAdapter adapter,
    ) async {
      final session = await _connectedSession(adapter: adapter);
      void listener() {}
      session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      return (
        session: session,
        stop: () => session.agentsNotifier.removeListener(listener),
      );
    }

    const blocked = (
      target: 'w1:p1',
      label: 'claude',
      state: AgentState.blocked,
      tabId: null,
      workspaceId: null,
    );
    const working = (
      target: 'w1:p1',
      label: 'claude',
      state: AgentState.working,
      tabId: null,
      workspaceId: null,
    );

    test(
      'holds exactly ONE wait, and never arms a second while the first is '
      'outstanding — a wait is a held channel, and MaxSessions is 10',
      () async {
        final adapter = FakeWaitingAgentAdapter()
          ..agentList = const MuxAgentsAvailable([blocked]);
        final harness = await observed(adapter);

        expect(adapter.waits, hasLength(1));
        expect(adapter.isWaiting, isTrue);

        // Drive several full cycles. Each answered wait must be replaced,
        // never accompanied.
        for (var i = 0; i < 5; i++) {
          adapter.completeWait(const MuxAgentWaitMatched(working));
          await pumpEventQueue();
        }

        expect(adapter.waits.length, 6, reason: 'one re-arm per answer');
        expect(
          adapter.maxConcurrentWaits,
          1,
          reason: 'two open waits means two held channels',
        );

        harness.stop();
        adapter.drainWaits();
        await pumpEventQueue();
        await harness.session.dispose();
      },
    );

    test(
      'arms the COMPLEMENT of the current state, never the state the agent '
      'is already in — herdr answers that instantly, so it would spin',
      () async {
        // MEASURED on a real host: against an agent already `blocked`,
        // `agent wait --until blocked` returned in 0.115s with a success
        // envelope — process startup, no waiting at all. A loop that armed
        // the current state would therefore re-arm as fast as the transport
        // allows, forever, on a session the user is also working on.
        final adapter = FakeWaitingAgentAdapter()
          ..agentList = const MuxAgentsAvailable([blocked]);
        final harness = await observed(adapter);

        final armed = adapter.waits.single;
        expect(armed.target, 'w1:p1');
        expect(
          armed.until,
          isNot(contains(AgentState.blocked)),
          reason: 'the current state would match immediately',
        );
        expect(armed.until, {
          AgentState.idle,
          AgentState.working,
          AgentState.done,
          AgentState.unknown,
        });
        expect(armed.timeout, kAgentWaitWindow);

        harness.stop();
        adapter.drainWaits();
        await pumpEventQueue();
        await harness.session.dispose();
      },
    );

    test('watches the agent that DRIVES THE BADGE, so the claim on screen is '
        'the claim being verified', () async {
      const idle = (
        target: 'w1:p2',
        label: 'codex',
        state: AgentState.idle,
        tabId: null,
        workspaceId: null,
      );
      final adapter = FakeWaitingAgentAdapter()
        // Deliberately listed with the urgent one LAST, so host order
        // cannot be mistaken for urgency.
        ..agentList = const MuxAgentsAvailable([idle, blocked]);
      final harness = await observed(adapter);

      expect(adapter.waits.single.target, 'w1:p1');

      harness.stop();
      adapter.drainWaits();
      await pumpEventQueue();
      await harness.session.dispose();
    });

    test('a state change publishes the new snapshot without waiting out an '
        'interval — this is the whole point of the wait', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([working]);
      final harness = await observed(adapter);

      expect(
        (harness.session.agentsNotifier.value as AgentsKnown)
            .agents
            .single
            .state,
        AgentState.working,
      );

      // The host says the agent moved. Nothing else advances: no timer
      // fires, no clock is elapsed.
      adapter.agentList = const MuxAgentsAvailable([blocked]);
      adapter.completeWait(const MuxAgentWaitMatched(blocked));
      await pumpEventQueue();

      expect(
        (harness.session.agentsNotifier.value as AgentsKnown)
            .agents
            .single
            .state,
        AgentState.blocked,
        reason: 'the badge must follow the host, not the clock',
      );

      harness.stop();
      adapter.drainWaits();
      await pumpEventQueue();
      await harness.session.dispose();
    });

    test('a timed-out wait simply re-arms and keeps the last known state — a '
        'window in which nothing changed is not a failure', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([blocked]);
      final harness = await observed(adapter);

      adapter.completeWait(const MuxAgentWaitTimedOut());
      await pumpEventQueue();

      expect(adapter.waits, hasLength(2), reason: 're-armed');
      expect(harness.session.agentsNotifier.value, isA<AgentsKnown>());
      expect(
        harness.session.agentsNotifier.value,
        isNot(isA<AgentsUnreachable>()),
        reason: 'nothing changed is not "we could not find out"',
      );

      harness.stop();
      adapter.drainWaits();
      await pumpEventQueue();
      await harness.session.dispose();
    });

    test('a FAILED wait degrades to a bounded retry, never to a hot re-arm '
        'and never to an empty agent list', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([blocked]);
      final harness = await observed(adapter);

      // The pane vanished, the socket died, herdr answered in a shape we
      // do not recognize — all of them mean "we cannot find out", and
      // none of them may be answered by immediately asking again.
      adapter.agentList = const MuxAgentServerNotRunning();
      adapter.completeWait(const MuxAgentWaitFailed('agent_not_found'));
      await pumpEventQueue();

      expect(
        adapter.waits,
        hasLength(1),
        reason: 'a broken wait must not be retried without a delay',
      );
      expect(harness.session.agentsNotifier.value, isA<AgentsUnreachable>());
      expect(
        harness.session.agentsNotifier.value,
        isNot(isA<AgentsKnown>()),
        reason: 'the one variant a reader may treat as authoritative',
      );

      harness.stop();
      adapter.drainWaits();
      await pumpEventQueue();
      await harness.session.dispose();
    });

    test('an adapter that does NOT advertise agentWait is never asked to '
        'wait — it would answer instantly and the loop would spin', () async {
      // FakeAgentAdapter's waitForAgent throws precisely so this cannot
      // pass by accident: the capability gate is the only thing keeping
      // the loop off it.
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_blockedAgent]));
      final session = await _connectedSession(adapter: adapter);

      void listener() {}
      FakeAsync().run((async) {
        session.agentsNotifier.addListener(listener);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 1);

        // Still polling, exactly as before, and still not waiting.
        async.elapse(kAgentPollInterval * 3);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 4);

        session.agentsNotifier.removeListener(listener);
      });

      expect(session.agentsNotifier.value, isA<AgentsKnown>());
      await session.dispose();
    });

    test('with no agents to watch it falls back to asking again later, so an '
        'agent that STARTS later is still noticed', () async {
      // `agent wait` takes one agent target, so an empty session gives it
      // nothing to arm. Losing discovery entirely would be a regression
      // against the poll this replaces.
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([]);
      final session = await _connectedSession(adapter: adapter);

      void listener() {}
      FakeAsync().run((async) {
        session.agentsNotifier.addListener(listener);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 1);
        expect(adapter.waits, isEmpty, reason: 'nothing to target');

        async.elapse(kAgentPollInterval);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 2);

        // An agent appears. The very next cycle switches to watching it.
        adapter.agentList = const MuxAgentsAvailable([blocked]);
        async.elapse(kAgentPollInterval);
        async.flushMicrotasks();
        expect(adapter.waits, hasLength(1));
        expect(adapter.waits.single.target, 'w1:p1');

        session.agentsNotifier.removeListener(listener);
      });

      adapter.drainWaits();
      await pumpEventQueue();
      await session.dispose();
    });

    test('nothing observing means no list AND no held channel, however long '
        'the session stays connected', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([blocked]);
      final session = await _connectedSession(adapter: adapter);

      await pumpEventQueue();
      FakeAsync().run((async) {
        async.elapse(kAgentWaitWindow * 3);
        async.flushMicrotasks();
      });

      expect(adapter.listAgentsCalls, 0);
      expect(adapter.waits, isEmpty);

      await session.dispose();
    });

    test('the last observer leaving releases the held channel and arms no '
        'replacement', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([blocked]);
      final harness = await observed(adapter);
      expect(adapter.waits, hasLength(1));

      harness.stop();
      await pumpEventQueue();

      // The wait that was already in flight answers after the observer
      // left. It must not start another one.
      adapter.completeWait(const MuxAgentWaitMatched(working));
      await pumpEventQueue();

      expect(adapter.waits, hasLength(1));

      await harness.session.dispose();
    });

    test(
      're-arming while a previous wait is STILL HELD joins it instead of '
      'opening a second channel — a wait cannot be cancelled from here',
      () async {
        // Found by mutation-testing the one-loop guard, and it is not
        // hypothetical: opening and closing the drawer is exactly this
        // sequence. Nothing on this side can cancel a wait already blocked
        // on the host, so it stays held until herdr's own window expires —
        // up to kAgentWaitWindow. Arming a fresh one per toggle would add a
        // held channel per toggle; measured at 6 concurrent for 6 toggles
        // before the join existed, and MaxSessions of 10 is four further
        // on. Same failure as 773888f, different trigger.
        final adapter = FakeWaitingAgentAdapter()
          ..agentList = const MuxAgentsAvailable([blocked]);
        final session = await _connectedSession(adapter: adapter);

        void listener() {}
        for (var i = 0; i < 6; i++) {
          session.agentsNotifier.addListener(listener);
          await pumpEventQueue();
          session.agentsNotifier.removeListener(listener);
          await pumpEventQueue();
        }

        expect(
          adapter.maxConcurrentWaits,
          1,
          reason: 'every toggle beyond the first must reuse the held wait',
        );
        expect(adapter.waits, hasLength(1));

        adapter.drainWaits();
        await pumpEventQueue();
        await session.dispose();
      },
    );

    test('a wait that keeps failing while the LIST still answers is retried on '
        'the interval, never re-armed on the spot', () async {
      // The narrow, dangerous case: herdr's socket is alive enough to
      // enumerate agents but the wait itself keeps breaking — a pane that
      // went away, a herdr-side fault. Re-arming straight from the
      // failure would then spin against a live host as fast as the
      // transport allows. The previous version of the failure test could
      // not see this, because it broke the list too, which happened to
      // stop the loop for an unrelated reason.
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([blocked]);
      final session = await _connectedSession(adapter: adapter);

      void listener() {}
      FakeAsync().run((async) {
        session.agentsNotifier.addListener(listener);
        async.flushMicrotasks();
        expect(adapter.waits, hasLength(1));

        adapter.completeWait(const MuxAgentWaitFailed('agent_not_found'));
        async.flushMicrotasks();

        expect(
          adapter.waits,
          hasLength(1),
          reason:
              'the list still answers, so nothing stops a spin but '
              'the deliberate delay',
        );
        // And the list is still the authority, so the snapshot stays
        // truthful rather than degrading to a lie in either direction.
        expect(session.agentsNotifier.value, isA<AgentsKnown>());

        async.elapse(kAgentPollInterval);
        async.flushMicrotasks();
        expect(adapter.waits, hasLength(2), reason: 'retried, not spun');

        session.agentsNotifier.removeListener(listener);
      });

      adapter.drainWaits();
      await pumpEventQueue();
      await session.dispose();
    });

    test('losing the connection stops the loop, and a wait answering after the '
        'drop neither re-arms nor republishes', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([blocked]);
      final service = FakeSSHService();
      service.queueConnectSuccess(
        SSHConnectionResult(
          client: _buildFakeClient(),
          session: FakeSSHSession(),
        ),
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
      void listener() {}
      session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      expect(adapter.waits, hasLength(1));

      await attach.endWithExitCode(0);
      await pumpEventQueue();
      expect(session.status, ConnectionStatus.disconnected);
      expect(session.agentsNotifier.value, isA<AgentsNotProbed>());

      adapter.completeWait(const MuxAgentWaitMatched(blocked));
      await pumpEventQueue();

      expect(adapter.waits, hasLength(1), reason: 'no resurrection');
      expect(
        session.agentsNotifier.value,
        isA<AgentsNotProbed>(),
        reason: 'a dead host must not be described as alive',
      );

      session.agentsNotifier.removeListener(listener);
      await session.dispose();
    });

    test('dispose leaves no pending timer, and a wait answering afterwards '
        'never touches the disposed notifier', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([blocked]);
      final harness = await observed(adapter);

      harness.stop();
      await harness.session.dispose();

      // The held wait answers into a session that no longer exists.
      adapter.completeWait(const MuxAgentWaitMatched(working));
      await pumpEventQueue();

      expect(adapter.waits, hasLength(1));
      // ValueNotifier assigns `_value` BEFORE asserting on disposal, so
      // an unguarded write stays observable even though the assertion is
      // swallowed. A snapshot that never moved is proof none was tried.
      expect(harness.session.agentsNotifier.value, isA<AgentsKnown>());

      FakeAsync().run((async) {
        async.elapse(kAgentWaitWindow * 3);
        async.flushMicrotasks();
      });
      expect(adapter.waits, hasLength(1));
    });
  });
}
