// Tests for TerminalSession's workspace-tree surface.
//
// The tree answers the question the drawer exists for — which client,
// which project — and it is read at the instant a thumb opens the drawer.
// That makes it the second host command in this app whose rate is set by a
// human rather than by a cadence, and it inherits the whole of commit
// 773888f's lesson: `.timeout` ABANDONS a Future without closing the
// remote channel, so a guard released on abandonment hands every repeat
// open a fresh channel until OpenSSH's default MaxSessions of 10 leaves
// none for a reconnect to attach through.
//
// The other half of what these tests defend is the refusal to compose a
// lie. The tree is ONE claim — "these are your clients and their
// projects" — so any variant that is not [MuxWorkspaceTreeAvailable] must
// stay un-renderable as a tree, and no failure may ever degrade INTO
// Available, which is the only variant the drawer draws rows from.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
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

const _profile = ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
);

const _tree = MuxWorkspaceTreeAvailable(
  workspaces: [
    (
      workspaceId: 'w1',
      label: 'EBIM',
      agentState: AgentState.working,
      activeTabId: null,
    ),
  ],
  tabs: [
    (
      tabId: 'w1:t1',
      workspaceId: 'w1',
      label: 'Calera',
      number: 1,
      focused: false,
      agentState: AgentState.working,
    ),
  ],
);

SSHClient _buildFakeClient() => SSHClient(FakeSSHSocket(), username: 'tester');

Future<TerminalSession> _session({
  required MultiplexerAdapter adapter,
  bool connect = true,
}) async {
  final service = FakeSSHService();
  final session = TerminalSession(
    profile: _profile,
    sshService: service,
    tmuxSessionName: 'helm-0',
    terminal: _SilentTerminal(),
    muxAdapter: adapter,
    hostRunnerFactory: (_) => FakeHostCommandRunner(),
    attachOpener: (client, command, pty) async => FakeSSHSession(),
  );
  if (connect) {
    service.queueConnectSuccess(
      SSHConnectionResult(
        client: _buildFakeClient(),
        session: FakeSSHSession(),
      ),
    );
    await session.connect('key');
    expect(session.status, ConnectionStatus.connected);
  }
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('refreshWorkspaceTree — what the host said, passed through', () {
    test('publishes the tree the multiplexer reported, intact', () async {
      final adapter = FakeWorkspaceAwareAdapter()..whenTree(_tree);
      final session = await _session(adapter: adapter);

      final result = await session.refreshWorkspaceTree();

      expect(result, isA<MuxWorkspaceTreeAvailable>());
      final tree = result as MuxWorkspaceTreeAvailable;
      expect(tree.workspaces.single.label, 'EBIM');
      expect(tree.tabs.single.tabId, 'w1:t1');

      await session.dispose();
    });

    test('a host that genuinely has no workspaces still reports AVAILABLE — '
        'an empty tree is a measurement, and it must stay distinguishable '
        'from every way of not knowing', () async {
      final adapter = FakeWorkspaceAwareAdapter()
        ..whenTree(const MuxWorkspaceTreeAvailable(workspaces: [], tabs: []));
      final session = await _session(adapter: adapter);

      final result = await session.refreshWorkspaceTree();

      expect(result, isA<MuxWorkspaceTreeAvailable>());
      expect((result as MuxWorkspaceTreeAvailable).workspaces, isEmpty);

      await session.dispose();
    });
  });

  group('refreshWorkspaceTree — every refusal says it did not find out', () {
    test('a multiplexer with no workspaces NAMES itself rather than reporting '
        'an empty tree, and is never asked in the first place', () async {
      final adapter = FakeAgentlessAdapter(id: MultiplexerId.tmux);
      final session = await _session(adapter: adapter);

      final result = await session.refreshWorkspaceTree();

      expect(
        result,
        isA<MuxWorkspaceTreeUnsupported>().having(
          (u) => u.muxId,
          'muxId',
          MultiplexerId.tmux,
        ),
      );
      expect(result, isNot(isA<MuxWorkspaceTreeAvailable>()));

      await session.dispose();
    });

    test('a disconnected session never touches the host', () async {
      final adapter = FakeWorkspaceAwareAdapter()..whenTree(_tree);
      final session = await _session(adapter: adapter, connect: false);

      final result = await session.refreshWorkspaceTree();

      expect(result, isNot(isA<MuxWorkspaceTreeAvailable>()));
      expect(adapter.listTreeCalls, 0);

      await session.dispose();
    });

    test('a disposed session never touches the host', () async {
      final adapter = FakeWorkspaceAwareAdapter()..whenTree(_tree);
      final session = await _session(adapter: adapter);
      await session.dispose();

      final result = await session.refreshWorkspaceTree();

      expect(result, isNot(isA<MuxWorkspaceTreeAvailable>()));
      expect(adapter.listTreeCalls, 0);
    });

    test('an adapter that THREW — which is how herdr reports an error code '
        'this app does not recognize — degrades to unreachable, never to an '
        'empty tree', () async {
      final adapter = FakeWorkspaceAwareAdapter()
        ..whenTreeThrows(StateError('unrecognized herdr error'));
      final session = await _session(adapter: adapter);

      final result = await session.refreshWorkspaceTree();

      expect(result, isA<MuxWorkspaceTreeUnreachable>());
      expect(result, isNot(isA<MuxWorkspaceTreeAvailable>()));

      await session.dispose();
    });
  });

  group('refreshWorkspaceTree — the channel budget', () {
    test('a wedged host is abandoned at kWorkspaceTreeTimeout, so the drawer '
        'is never left waiting on an answer that never comes', () async {
      final adapter = FakeWorkspaceAwareAdapter()..whenTreeHangs();
      final session = await _session(adapter: adapter);

      FakeAsync().run((async) {
        MuxWorkspaceTreeResult? settled;
        unawaited(session.refreshWorkspaceTree().then((r) => settled = r));

        async.elapse(kWorkspaceTreeTimeout - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(
          settled,
          isNull,
          reason: 'must not give up before the documented ceiling',
        );

        async.elapse(const Duration(milliseconds: 2));
        async.flushMicrotasks();

        expect(settled, isA<MuxWorkspaceTreeUnreachable>());
        expect(settled, isNot(isA<MuxWorkspaceTreeAvailable>()));
      });

      adapter.releaseTree();
      await session.dispose();
    });

    test('a query ABANDONED at the timeout still holds the guard, so a wedged '
        'host leaks at most ONE remote invocation however often the drawer '
        'is reopened', () async {
      final adapter = FakeWorkspaceAwareAdapter()..whenTreeHangs();
      final session = await _session(adapter: adapter);

      FakeAsync().run((async) {
        unawaited(session.refreshWorkspaceTree());
        async.flushMicrotasks();
        expect(adapter.listTreeCalls, 1);

        // The call site gives up here. The REMOTE command does not.
        async.elapse(kWorkspaceTreeTimeout + const Duration(seconds: 1));
        async.flushMicrotasks();

        // Five more opens after the abandonment.
        for (var i = 0; i < 5; i++) {
          unawaited(session.refreshWorkspaceTree());
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
        }

        expect(
          adapter.listTreeCalls,
          1,
          reason:
              'the guard is released by the QUERY settling, never by '
              'the caller giving up on it',
        );
      });

      adapter.releaseTree();
      await session.dispose();
    });

    test('the guard is released once the host answers, so a slow-but-alive '
        'host does not permanently blank the tree', () async {
      final adapter = FakeWorkspaceAwareAdapter()..whenTreeHangs();
      final session = await _session(adapter: adapter);

      final first = session.refreshWorkspaceTree();
      await pumpEventQueue();
      adapter.releaseTree();
      expect(await first, isA<MuxWorkspaceTreeAvailable>());

      adapter.whenTree(_tree);
      expect(
        await session.refreshWorkspaceTree(),
        isA<MuxWorkspaceTreeAvailable>(),
      );
      expect(adapter.listTreeCalls, 2);

      await session.dispose();
    });
  });

  group('focusTab', () {
    test('passes the tab id through to the multiplexer verbatim', () async {
      final adapter = FakeWorkspaceAwareAdapter();
      final session = await _session(adapter: adapter);

      final result = await session.focusTab('w2:t3');

      expect(result, isA<MuxTabFocused>());
      expect(adapter.focusedTabs, ['w2:t3']);

      await session.dispose();
    });

    test('a vanished tab is reported as such and NOT as a failure to reach '
        'the host — the drawer showed a project that is gone, which is a '
        'different thing to tell the user', () async {
      final adapter = FakeWorkspaceAwareAdapter()
        ..whenTabFocus(const MuxTabFocusTargetNotFound());
      final session = await _session(adapter: adapter);

      final result = await session.focusTab('w9:t9');

      expect(result, isA<MuxTabFocusTargetNotFound>());
      expect(result, isNot(isA<MuxTabFocused>()));

      await session.dispose();
    });

    test(
      'a multiplexer that cannot focus tabs FAILS rather than pretending',
      () async {
        final adapter = FakeAgentlessAdapter(id: MultiplexerId.zellij);
        final session = await _session(adapter: adapter);

        final result = await session.focusTab('w1:t1');

        expect(result, isA<MuxTabFocusFailed>());
        expect(result, isNot(isA<MuxTabFocused>()));

        await session.dispose();
      },
    );

    test('a disconnected session never touches the host', () async {
      final adapter = FakeWorkspaceAwareAdapter();
      final session = await _session(adapter: adapter, connect: false);

      final result = await session.focusTab('w1:t1');

      expect(result, isA<MuxTabFocusFailed>());
      expect(adapter.focusedTabs, isEmpty);

      await session.dispose();
    });

    test('a disposed session never touches the host', () async {
      final adapter = FakeWorkspaceAwareAdapter();
      final session = await _session(adapter: adapter);
      await session.dispose();

      final result = await session.focusTab('w1:t1');

      expect(result, isA<MuxTabFocusFailed>());
      expect(adapter.focusedTabs, isEmpty);
    });

    test('an adapter that throws degrades to FAILED instead of blowing up '
        'inside a button callback', () async {
      final adapter = _ThrowingTabFocusAdapter();
      final session = await _session(adapter: adapter);

      final result = await session.focusTab('w1:t1');

      expect(result, isA<MuxTabFocusFailed>());
      expect(result, isNot(isA<MuxTabFocused>()));

      await session.dispose();
    });

    test('a repeated tap on a wedged host opens NO second channel, and the '
        'drop is never reported as success', () async {
      final adapter = FakeWorkspaceAwareAdapter()..whenTabFocusHangs();
      final session = await _session(adapter: adapter);

      unawaited(session.focusTab('w1:t1'));
      await pumpEventQueue();
      final second = await session.focusTab('w1:t1');

      expect(adapter.focusedTabs, ['w1:t1']);
      expect(second, isA<MuxTabFocusFailed>());
      expect(second, isNot(isA<MuxTabFocused>()));

      adapter.releaseTabFocus();
      await session.dispose();
    });

    test(
      'a wedged focus is abandoned at kTabFocusTimeout and reports FAILED',
      () async {
        final adapter = FakeWorkspaceAwareAdapter()..whenTabFocusHangs();
        final session = await _session(adapter: adapter);

        FakeAsync().run((async) {
          MuxTabFocusResult? settled;
          unawaited(session.focusTab('w1:t1').then((r) => settled = r));

          async.elapse(kTabFocusTimeout + const Duration(milliseconds: 1));
          async.flushMicrotasks();

          expect(settled, isA<MuxTabFocusFailed>());
          expect(settled, isNot(isA<MuxTabFocused>()));
        });

        adapter.releaseTabFocus();
        await session.dispose();
      },
    );
  });
}

/// A workspace-aware adapter whose tab focus throws, to prove the session
/// absorbs it rather than letting it escape into a tap handler.
class _ThrowingTabFocusAdapter extends FakeWorkspaceAwareAdapter {
  @override
  Future<MuxTabFocusResult> focusTab(String tabId) async =>
      throw StateError('boom');
}
