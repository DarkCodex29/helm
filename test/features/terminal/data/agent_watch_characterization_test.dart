// Characterization of the agent watch, pinned through the PUBLIC surface of
// TerminalSession only: `agentsNotifier`, `refreshAgents`, `tracksAgents`
// and the calls an adapter fake records.
//
// These tests describe what the code does TODAY, value for value, so the
// extraction of the watch into its own class can be proven behavior-
// preserving. `terminal_session_agents_test.dart` pins the same ground with
// `isA<T>` in many places; each case here is the exact-value companion
// (identity of the const snapshot, exact lists, exact call counts), not a
// replacement.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/session_vitality.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:xterm/xterm.dart';

import '../../../helpers/fake_agent_adapter.dart';
import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';
import '../../../helpers/fake_ssh_session.dart';
import '../../../helpers/fake_waiting_agent_adapter.dart';

class _SilentTerminal extends Terminal {
  _SilentTerminal() : super(maxLines: 200);

  @override
  void write(String data) {}
}

SSHClient _buildFakeClient() => SSHClient(FakeSSHSocket(), username: 'tester');

class _Harness {
  _Harness(this.session, this.service, this.attaches);

  final TerminalSession session;
  final FakeSSHService service;
  final List<FakeSSHSession> attaches;

  /// Queues one more connection and connects again.
  Future<void> connectAgain() async {
    service.queueConnectSuccess(
      SSHConnectionResult(
        client: _buildFakeClient(),
        session: FakeSSHSession(),
      ),
    );
    await session.connect('key');
  }

  /// Ends the current attach the way a real detach does.
  Future<void> drop() async {
    await attaches.last.endWithExitCode(0);
    await pumpEventQueue();
  }
}

/// A connected session whose every (re)connect opens a FRESH attach, so a
/// disconnect followed by `connect` is a real reconnect.
Future<_Harness> _connect(
  MultiplexerAdapter adapter, {
  String? tmuxSessionName = 'helm-0',
}) async {
  final service = FakeSSHService();
  service.queueConnectSuccess(
    SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
  );
  final attaches = <FakeSSHSession>[];
  final session = TerminalSession(
    profile: const ConnectionProfile(
      id: 'profile-1',
      name: 'Test Host',
      host: 'example.test',
      username: 'tester',
    ),
    sshService: service,
    tmuxSessionName: tmuxSessionName,
    terminal: _SilentTerminal(),
    muxAdapter: adapter,
    hostRunnerFactory: (_) => FakeHostCommandRunner(),
    attachOpener: (client, command, pty) async {
      final attach = FakeSSHSession();
      attaches.add(attach);
      return attach;
    },
  );
  await session.connect('key');
  expect(session.status, ConnectionStatus.connected);
  return _Harness(session, service, attaches);
}

/// Builds and connects a session INSIDE the running [FakeAsync] zone, so
/// every timer the agent loop later arms is on the clock the test drives.
/// Mirrors [_connect], with `flushMicrotasks` instead of `await`.
_Harness _connectWithin(FakeAsync async, MultiplexerAdapter adapter) {
  final service = FakeSSHService();
  service.queueConnectSuccess(
    SSHConnectionResult(client: _buildFakeClient(), session: FakeSSHSession()),
  );
  final attaches = <FakeSSHSession>[];
  final session = TerminalSession(
    profile: const ConnectionProfile(
      id: 'profile-1',
      name: 'Test Host',
      host: 'example.test',
      username: 'tester',
    ),
    sshService: service,
    tmuxSessionName: 'helm-0',
    terminal: _SilentTerminal(),
    muxAdapter: adapter,
    hostRunnerFactory: (_) => FakeHostCommandRunner(),
    attachOpener: (client, command, pty) async {
      final attach = FakeSSHSession();
      attaches.add(attach);
      return attach;
    },
  );
  unawaited(session.connect('key'));
  async.flushMicrotasks();
  expect(session.status, ConnectionStatus.connected);
  return _Harness(session, service, attaches);
}

const _agentA = (
  target: 'w1:p1',
  label: 'claude',
  state: AgentState.blocked,
  tabId: 'tab-a',
  workspaceId: 'ws-1',
);
const _agentB = (
  target: 'w1:p2',
  label: 'codex',
  state: AgentState.working,
  tabId: null,
  workspaceId: null,
);
const _agentAWorking = (
  target: 'w1:p1',
  label: 'claude',
  state: AgentState.working,
  tabId: 'tab-a',
  workspaceId: 'ws-1',
);

/// Collects every value the notifier publishes, in order.
List<AgentSnapshot> _record(TerminalSession session) {
  final seen = <AgentSnapshot>[];
  session.agentsNotifier.addListener(
    () => seen.add(session.agentsNotifier.value),
  );
  return seen;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('published snapshots - exact values', () {
    test('a fresh session publishes the const AgentsNotProbed', () async {
      final h = await _connect(FakeAgentAdapter());
      expect(
        identical(h.session.agentsNotifier.value, const AgentsNotProbed()),
        isTrue,
      );
      await h.session.dispose();
    });

    test('available: AgentsKnown carries the listed agents, in order, with '
        'every field intact', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_agentA, _agentB]));
      final h = await _connect(adapter);

      await h.session.refreshAgents();

      final snapshot = h.session.agentsNotifier.value as AgentsKnown;
      expect(snapshot.agents.length, 2);
      expect(snapshot.agents[0].target, 'w1:p1');
      expect(snapshot.agents[0].label, 'claude');
      expect(snapshot.agents[0].state, AgentState.blocked);
      expect(snapshot.agents[0].tabId, 'tab-a');
      expect(snapshot.agents[0].workspaceId, 'ws-1');
      expect(snapshot.agents[1].target, 'w1:p2');
      expect(snapshot.agents[1].label, 'codex');
      expect(snapshot.agents[1].state, AgentState.working);
      expect(snapshot.agents[1].tabId, isNull);
      expect(snapshot.agents[1].workspaceId, isNull);
      expect(adapter.listAgentsCalls, 1);

      await h.session.dispose();
    });

    test('server not running: the const AgentsUnreachable itself', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentServerNotRunning());
      final h = await _connect(adapter);

      await h.session.refreshAgents();

      expect(
        identical(h.session.agentsNotifier.value, const AgentsUnreachable()),
        isTrue,
      );
      await h.session.dispose();
    });

    test('a throwing adapter: the const AgentsUnreachable itself', () async {
      final adapter = FakeAgentAdapter()..whenThrows(StateError('boom'));
      final h = await _connect(adapter);

      await h.session.refreshAgents();

      expect(
        identical(h.session.agentsNotifier.value, const AgentsUnreachable()),
        isTrue,
      );
      await h.session.dispose();
    });

    test(
      'unsupported names the multiplexer the adapter reported, and is '
      'published synchronously, before the returned future settles',
      () async {
        final h = await _connect(
          FakeAgentlessAdapter(id: MultiplexerId.zellij),
        );

        unawaited(h.session.refreshAgents());

        final snapshot = h.session.agentsNotifier.value as AgentsUnsupported;
        expect(snapshot.muxId, MultiplexerId.zellij);

        await h.session.dispose();
      },
    );

    test('an observed session whose adapter has no wait publishes exactly '
        'ONE value for its first read, via a list and never a wait', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_agentA]));
      final h = await _connect(adapter);
      final seen = <AgentSnapshot>[];
      void listener() => seen.add(h.session.agentsNotifier.value);
      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();

      expect(seen.length, 1);
      expect((seen[0] as AgentsKnown).agents, [_agentA]);
      expect(adapter.listAgentsCalls, 1);
      expect(adapter.capabilities.contains(MuxCapability.agentWait), isFalse);

      h.session.agentsNotifier.removeListener(listener);
      await h.session.dispose();
    });

    test('a failed refresh after a good one replaces the agents with the '
        'const AgentsUnreachable, never keeps the stale list', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_agentA]));
      final h = await _connect(adapter);

      await h.session.refreshAgents();
      expect(h.session.agentsNotifier.value, isA<AgentsKnown>());

      adapter.whenThrows(StateError('gone'));
      await h.session.refreshAgents();

      expect(
        identical(h.session.agentsNotifier.value, const AgentsUnreachable()),
        isTrue,
      );
      await h.session.dispose();
    });

    test(
      'the vitality judge runs after a KNOWN answer only: a FakeAgentAdapter '
      '(no panes) ends as Unsupported(herdr); an unreachable answer leaves '
      'it NotProbed',
      () async {
        final known = FakeAgentAdapter()
          ..whenAgents(const MuxAgentsAvailable([_agentA]));
        final h1 = await _connect(known);
        expect(
          identical(
            h1.session.sessionVitalityNotifier.value,
            const SessionVitalityNotProbed(),
          ),
          isTrue,
        );
        await h1.session.refreshAgents();
        await pumpEventQueue();
        final verdict = h1.session.sessionVitalityNotifier.value;
        expect(verdict, isA<SessionVitalityUnsupported>());
        expect(
          (verdict as SessionVitalityUnsupported).muxId,
          MultiplexerId.herdr,
        );
        await h1.session.dispose();

        final down = FakeAgentAdapter()
          ..whenAgents(const MuxAgentServerNotRunning());
        final h2 = await _connect(down);
        await h2.session.refreshAgents();
        await pumpEventQueue();
        expect(
          identical(
            h2.session.sessionVitalityNotifier.value,
            const SessionVitalityNotProbed(),
          ),
          isTrue,
        );
        await h2.session.dispose();
      },
    );
  });

  group('wait arguments and call counts - exact', () {
    test('arms one wait on the badge agent (most urgent, not the first '
        'listed) with the exact complement and kAgentWaitWindow', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentB, _agentA]);
      final h = await _connect(adapter);
      void listener() {}
      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();

      expect(adapter.listAgentsCalls, 1);
      expect(adapter.waits.length, 1);
      expect(adapter.waits[0].target, 'w1:p1');
      expect(adapter.waits[0].timeout, kAgentWaitWindow);
      expect(
        adapter.waits[0].until,
        AgentState.values.where((s) => s != AgentState.blocked).toSet(),
      );

      h.session.agentsNotifier.removeListener(listener);
      adapter.drainWaits();
      await pumpEventQueue();
      await h.session.dispose();
    });

    test('equal urgency, agents listed in REVERSE target order: the wait is '
        'armed on the smaller target', () async {
      const p1 = (
        target: 'w1:p1',
        label: 'claude',
        state: AgentState.blocked,
        tabId: null,
        workspaceId: null,
      );
      const p2 = (
        target: 'w1:p2',
        label: 'codex',
        state: AgentState.blocked,
        tabId: null,
        workspaceId: null,
      );
      const p3 = (
        target: 'w1:p3',
        label: 'pi',
        state: AgentState.blocked,
        tabId: null,
        workspaceId: null,
      );
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([p3, p2, p1]);
      final h = await _connect(adapter);
      void listener() {}
      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();

      expect(adapter.waits.length, 1);
      expect(adapter.waits[0].target, 'w1:p1');
      expect(
        adapter.waits[0].until,
        AgentState.values.where((s) => s != AgentState.blocked).toSet(),
      );

      h.session.agentsNotifier.removeListener(listener);
      adapter.drainWaits();
      await pumpEventQueue();
      await h.session.dispose();
    });

    test('observe, unobserve, re-observe: 2 lists, still 1 wait (joined), '
        'and the held answer then drives the NEW loop only', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      final h = await _connect(adapter);
      void listener() {}

      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      expect((adapter.listAgentsCalls, adapter.waits.length), (1, 1));

      h.session.agentsNotifier.removeListener(listener);
      await pumpEventQueue();
      expect(
        (adapter.listAgentsCalls, adapter.waits.length),
        (1, 1),
        reason: 'unobserving asks nothing',
      );
      expect(adapter.isWaiting, isTrue, reason: 'the wait cannot be cancelled');

      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      expect(
        (adapter.listAgentsCalls, adapter.waits.length),
        (2, 1),
        reason: 're-observe lists again but joins the held wait',
      );

      adapter.agentList = const MuxAgentsAvailable([_agentAWorking]);
      adapter.completeWait(const MuxAgentWaitMatched(_agentAWorking));
      await pumpEventQueue();
      // One list from the new loop's next cycle, one new wait: the stale
      // loop that also awaited the held future did nothing.
      expect((adapter.listAgentsCalls, adapter.waits.length), (3, 2));
      expect(adapter.maxConcurrentWaits, 1);
      expect(
        adapter.waits[1].until,
        AgentState.values.where((s) => s != AgentState.working).toSet(),
      );
      expect((h.session.agentsNotifier.value as AgentsKnown).agents, [
        _agentAWorking,
      ]);

      h.session.agentsNotifier.removeListener(listener);
      adapter.drainWaits();
      await pumpEventQueue();
      await h.session.dispose();
    });

    test('toggling observation 12 times (past MaxSessions=10) never holds '
        'more than ONE wait, listing once per observe', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      final h = await _connect(adapter);
      void listener() {}

      for (var i = 0; i < 12; i++) {
        h.session.agentsNotifier.addListener(listener);
        await pumpEventQueue();
        h.session.agentsNotifier.removeListener(listener);
        await pumpEventQueue();
      }

      expect(adapter.maxConcurrentWaits, 1);
      expect(adapter.waits.length, 1);
      expect(adapter.listAgentsCalls, 12);

      adapter.drainWaits();
      await pumpEventQueue();
      await h.session.dispose();
    });

    test('toggling 12 times WITHOUT yielding collapses to a single loop: the '
        'stranded epochs never list, the last observe lists once', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      final h = await _connect(adapter);
      void listener() {}

      for (var i = 0; i < 12; i++) {
        h.session.agentsNotifier.addListener(listener);
        h.session.agentsNotifier.removeListener(listener);
      }
      await pumpEventQueue();
      expect((adapter.listAgentsCalls, adapter.waits.length), (0, 0));

      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      expect((adapter.listAgentsCalls, adapter.waits.length), (1, 1));
      expect(adapter.maxConcurrentWaits, 1);

      h.session.agentsNotifier.removeListener(listener);
      adapter.drainWaits();
      await pumpEventQueue();
      await h.session.dispose();
    });

    test('two simultaneous observers share ONE loop; removing one keeps it '
        'running, removing the last strands it', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      final h = await _connect(adapter);
      void one() {}
      void two() {}

      h.session.agentsNotifier.addListener(one);
      h.session.agentsNotifier.addListener(two);
      await pumpEventQueue();
      expect((adapter.listAgentsCalls, adapter.waits.length), (1, 1));

      h.session.agentsNotifier.removeListener(one);
      adapter.completeWait(const MuxAgentWaitTimedOut());
      await pumpEventQueue();
      expect(
        (adapter.listAgentsCalls, adapter.waits.length),
        (2, 2),
        reason: 'still observed by `two`, so the loop re-armed',
      );

      h.session.agentsNotifier.removeListener(two);
      adapter.completeWait(const MuxAgentWaitTimedOut());
      await pumpEventQueue();
      expect(
        (adapter.listAgentsCalls, adapter.waits.length),
        (2, 2),
        reason: 'last observer gone: the answer is inert',
      );

      await h.session.dispose();
    });

    test('retry cadence without a wait: lists at 0, 10, 20 seconds and not '
        'a millisecond earlier', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_agentA]));
      final h = await _connect(adapter);
      void listener() {}

      FakeAsync().run((async) {
        h.session.agentsNotifier.addListener(listener);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 1);

        async.elapse(kAgentPollInterval - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 1);

        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 2);

        async.elapse(kAgentPollInterval);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 3);

        h.session.agentsNotifier.removeListener(listener);
        async.elapse(kAgentPollInterval * 5);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 3);
      });

      await h.session.dispose();
    });

    test('a FAILED wait lists a second time right away (to publish the '
        'truth), then retries only after kAgentPollInterval', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      final h = await _connect(adapter);
      void listener() {}

      FakeAsync().run((async) {
        h.session.agentsNotifier.addListener(listener);
        async.flushMicrotasks();
        expect((adapter.listAgentsCalls, adapter.waits.length), (1, 1));

        adapter.completeWait(const MuxAgentWaitFailed('agent_not_found'));
        async.flushMicrotasks();
        expect((adapter.listAgentsCalls, adapter.waits.length), (2, 1));

        async.elapse(kAgentPollInterval - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect((adapter.listAgentsCalls, adapter.waits.length), (2, 1));

        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect((adapter.listAgentsCalls, adapter.waits.length), (3, 2));
        expect(adapter.maxConcurrentWaits, 1);

        h.session.agentsNotifier.removeListener(listener);
      });

      adapter.drainWaits();
      await pumpEventQueue();
      await h.session.dispose();
    });
  });

  group('refreshAgents in flight', () {
    test(
      'a second call while one is in flight returns without asking, '
      'publishes nothing, and the first still publishes exactly once',
      () async {
        final adapter = FakeAgentAdapter()..whenHangs();
        final h = await _connect(adapter);
        // A real listener: it is also the observer that arms the loop, whose
        // first refresh is the one held in flight.
        final seen = <AgentSnapshot>[];
        void listener() => seen.add(h.session.agentsNotifier.value);
        h.session.agentsNotifier.addListener(listener);
        await pumpEventQueue();
        expect(adapter.listAgentsCalls, 1);

        var secondDone = false;
        unawaited(h.session.refreshAgents().then((_) => secondDone = true));
        await pumpEventQueue();

        expect(secondDone, isTrue, reason: 'returns at once, does not queue');
        expect(adapter.listAgentsCalls, 1);
        expect(
          identical(h.session.agentsNotifier.value, const AgentsNotProbed()),
          isTrue,
        );
        expect(seen, isEmpty);

        adapter.release();
        await pumpEventQueue();
        expect(seen.length, 1, reason: 'the first publishes exactly once');
        expect(seen.single, isA<AgentsKnown>());
        expect((seen.single as AgentsKnown).agents, isEmpty);

        h.session.agentsNotifier.removeListener(listener);
        adapter.whenAgents(const MuxAgentsAvailable([_agentB]));
        final callsBefore = adapter.listAgentsCalls;
        await h.session.refreshAgents();
        expect(
          adapter.listAgentsCalls,
          callsBefore + 1,
          reason: 'guard lifted',
        );
        expect((h.session.agentsNotifier.value as AgentsKnown).agents, [
          _agentB,
        ]);

        await h.session.dispose();
      },
    );

    test('a refresh while NOT connected is a no-op even before any connect '
        'state change: nothing listed, nothing published', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_agentA]));
      final h = await _connect(adapter);
      await h.drop();

      await h.session.refreshAgents();

      expect(adapter.listAgentsCalls, 0);
      expect(
        identical(h.session.agentsNotifier.value, const AgentsNotProbed()),
        isTrue,
      );
      await h.session.dispose();
    });
  });

  group('connection lifecycle', () {
    test('tracksAgents: true once attached to a multiplexer, false after a '
        'drop, true again after reconnect, false after dispose', () async {
      final h = await _connect(FakeAgentAdapter());
      expect(h.session.tracksAgents, isTrue);

      await h.drop();
      expect(h.session.tracksAgents, isFalse);

      await h.connectAgain();
      expect(h.session.tracksAgents, isTrue);

      await h.session.dispose();
      expect(h.session.tracksAgents, isFalse);
    });

    test('a session with no multiplexer session name never tracks, even '
        'when observed', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_agentA]));
      final h = await _connect(adapter, tmuxSessionName: null);
      expect(h.session.tracksAgents, isFalse);

      void listener() {}
      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      expect(adapter.listAgentsCalls, 0);
      expect(
        identical(h.session.agentsNotifier.value, const AgentsNotProbed()),
        isTrue,
      );

      h.session.agentsNotifier.removeListener(listener);
      await h.session.dispose();
    });

    test('disconnect resets the notifier to the const AgentsNotProbed, '
        'publishes exactly that one value, and freezes every count', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      final h = await _connect(adapter);
      final seen = _record(h.session);
      await pumpEventQueue();
      expect(seen.length, 1);
      expect(seen[0], isA<AgentsKnown>());

      await h.drop();

      expect(seen.length, 2);
      expect(identical(seen[1], const AgentsNotProbed()), isTrue);
      expect(
        identical(h.session.agentsNotifier.value, const AgentsNotProbed()),
        isTrue,
      );
      expect(
        identical(
          h.session.sessionVitalityNotifier.value,
          const SessionVitalityNotProbed(),
        ),
        isTrue,
      );

      // The held wait answers into the dropped session: inert.
      adapter.completeWait(const MuxAgentWaitMatched(_agentAWorking));
      await pumpEventQueue();
      expect((adapter.listAgentsCalls, adapter.waits.length), (1, 1));
      expect(seen.length, 2);

      await h.session.dispose();
    });

    test('reconnect while STILL observed resumes the loop: a fresh list and '
        'a fresh wait once the old one has answered', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      final h = await _connect(adapter);
      void listener() {}
      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      await h.drop();
      adapter.completeWait(const MuxAgentWaitTimedOut());
      await pumpEventQueue();
      expect((adapter.listAgentsCalls, adapter.waits.length), (1, 1));

      await h.connectAgain();
      await pumpEventQueue();

      expect((adapter.listAgentsCalls, adapter.waits.length), (2, 2));
      expect(adapter.maxConcurrentWaits, 1);
      expect((h.session.agentsNotifier.value as AgentsKnown).agents, [_agentA]);

      h.session.agentsNotifier.removeListener(listener);
      adapter.drainWaits();
      await pumpEventQueue();
      await h.session.dispose();
    });

    test('reconnect while the OLD wait is still held joins it: one channel '
        'across the drop, never two', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      final h = await _connect(adapter);
      void listener() {}
      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      await h.drop();

      await h.connectAgain();
      await pumpEventQueue();

      expect((adapter.listAgentsCalls, adapter.waits.length), (2, 1));
      expect(adapter.maxConcurrentWaits, 1);

      h.session.agentsNotifier.removeListener(listener);
      adapter.drainWaits();
      await pumpEventQueue();
      await h.session.dispose();
    });

    test('reconnect with NO observer asks nothing and publishes nothing; the '
        'next observer then starts the loop', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      final h = await _connect(adapter);
      void listener() {}
      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      await h.drop();
      h.session.agentsNotifier.removeListener(listener);
      adapter.completeWait(const MuxAgentWaitTimedOut());
      await pumpEventQueue();

      await h.connectAgain();
      await pumpEventQueue();
      expect((adapter.listAgentsCalls, adapter.waits.length), (1, 1));
      expect(
        identical(h.session.agentsNotifier.value, const AgentsNotProbed()),
        isTrue,
      );
      expect(h.session.tracksAgents, isTrue);

      h.session.agentsNotifier.addListener(listener);
      await pumpEventQueue();
      expect((adapter.listAgentsCalls, adapter.waits.length), (2, 2));

      h.session.agentsNotifier.removeListener(listener);
      adapter.drainWaits();
      await pumpEventQueue();
      await h.session.dispose();
    });

    test('a pending retry timer dies with the drop: nothing is listed in the '
        'following minutes', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_agentA]));
      final h = await _connect(adapter);
      void listener() {}

      // The retry timer binds to the zone that runs the observer's
      // microtask, so the clock is created first and driven afterwards.
      final clock = FakeAsync();
      clock.run((_) => h.session.agentsNotifier.addListener(listener));
      clock.flushMicrotasks();
      expect(adapter.listAgentsCalls, 1);
      expect(clock.pendingTimers.length, 1);

      await h.drop();
      expect(clock.pendingTimers, isEmpty);
      clock.elapse(kAgentPollInterval * 6);
      clock.flushMicrotasks();
      expect(adapter.listAgentsCalls, 1);

      h.session.agentsNotifier.removeListener(listener);
      await h.session.dispose();
    });
  });

  group('dispose', () {
    test('polling loop: dispose while observed kills the retry timer, and '
        'no adapter call follows in any later window', () async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([_agentA]));
      FakeAsync().run((async) {
        final h = _connectWithin(async, adapter);
        void listener() {}
        h.session.agentsNotifier.addListener(listener);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 1);
        async.elapse(kAgentPollInterval);
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 2, reason: 'the loop is really live');
        expect(async.pendingTimers, isNotEmpty);

        // Still observed: the listener is NOT removed before dispose.
        unawaited(h.session.dispose());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);

        async.elapse(kAgentWaitWindow * 3);
        async.flushMicrotasks();
        unawaited(h.session.refreshAgents());
        async.flushMicrotasks();
        expect(adapter.listAgentsCalls, 2);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('event-driven loop: dispose with a wait held, then the answer '
        'arriving and time passing: no adapter call, no timer', () async {
      final adapter = FakeWaitingAgentAdapter()
        ..agentList = const MuxAgentsAvailable([_agentA]);
      FakeAsync().run((async) {
        final h = _connectWithin(async, adapter);
        void listener() {}
        h.session.agentsNotifier.addListener(listener);
        async.flushMicrotasks();
        expect((adapter.listAgentsCalls, adapter.waits.length), (1, 1));

        // Still observed while disposing.
        unawaited(h.session.dispose());
        async.flushMicrotasks();

        adapter.completeWait(const MuxAgentWaitMatched(_agentAWorking));
        async.flushMicrotasks();
        unawaited(h.session.refreshAgents());
        async.elapse(kAgentWaitWindow * 3);
        async.flushMicrotasks();

        expect((adapter.listAgentsCalls, adapter.waits.length), (1, 1));
        expect(async.pendingTimers, isEmpty);
        expect((h.session.agentsNotifier.value as AgentsKnown).agents, [
          _agentA,
        ]);
      });
    });

    test('dispose with a refresh in flight: the late answer is dropped and '
        'the value never moves', () async {
      final adapter = FakeAgentAdapter()..whenHangs();
      final h = await _connect(adapter);
      final pending = h.session.refreshAgents();
      await pumpEventQueue();
      expect(adapter.listAgentsCalls, 1);

      await h.session.dispose();
      adapter.release();
      await pending;

      expect(
        identical(h.session.agentsNotifier.value, const AgentsNotProbed()),
        isTrue,
      );
      expect(adapter.listAgentsCalls, 1);
    });
  });
}
