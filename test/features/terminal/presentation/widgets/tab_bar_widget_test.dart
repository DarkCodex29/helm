// Widget tests for the session tab strip.
//
// Two independent facts share a very small amount of pixels here — whether
// the SSH session is up, and whether an agent inside it needs a human —
// and each has its own failure mode:
//
//  * The connection dot must follow the LIVE status. It used to be read
//    once during build from `tab.isConnected`, with nothing listening, so
//    a tab that connected successfully kept showing a red dot until some
//    unrelated event happened to rebuild the provider. A red dot on a
//    working session is a lie the user sees on every single connect.
//  * The agent badge must be absent unless somebody measured a state.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:helm/features/terminal/presentation/widgets/agent_state_chip.dart';
import 'package:helm/features/terminal/presentation/widgets/tab_bar_widget.dart';

import '../../../../helpers/fake_ssh_service.dart';

const _profile = ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
);

/// An UNCONNECTED session whose notifiers a test drives directly.
///
/// Never routed through `connect()`, so agent tracking is never enabled
/// and no poll timer can exist — flipping [TerminalSession.statusNotifier]
/// by hand exercises the tab strip's reaction without any SSH machinery.
TerminalSession _session({
  ConnectionStatus status = ConnectionStatus.disconnected,
  AgentSnapshot agents = const AgentsNotProbed(),
}) {
  final session = TerminalSession(
    profile: _profile,
    sshService: FakeSSHService(),
  );
  session.statusNotifier.value = status;
  session.agentsNotifier.value = agents;
  return session;
}

TerminalTab _tab(TerminalSession session, {String id = 'tab-1'}) =>
    TerminalTab(id: id, title: id, session: session, profile: _profile);

Future<void> _pumpTabs(WidgetTester tester, List<TerminalTab> tabs) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: TerminalTabBar(
            tabs: tabs,
            activeIndex: 0,
            onTabTap: (_) {},
            onTabClose: (_) {},
            onAddTab: () {},
          ),
        ),
      ),
    ),
  );
}

/// The status dot of each tab, in tab order.
///
/// The dot is the only circular decoration in the strip — the agent badge
/// is a rounded rectangle — so shape identifies it without depending on
/// the palette.
List<Color> _dotColors(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .where(
      (c) =>
          c.decoration is BoxDecoration &&
          (c.decoration! as BoxDecoration).shape == BoxShape.circle,
    )
    .map((c) => (c.decoration! as BoxDecoration).color!)
    .toList();

void main() {
  group('connection dot - follows the live session, not a stale read', () {
    testWidgets('a connected tab and a disconnected tab do not look alike', (
      tester,
    ) async {
      final up = _session(status: ConnectionStatus.connected);
      final down = _session();

      await _pumpTabs(tester, [_tab(up, id: 'a'), _tab(down, id: 'b')]);

      final dots = _dotColors(tester);
      expect(dots, hasLength(2));
      expect(dots[0], isNot(dots[1]));

      await up.dispose();
      await down.dispose();
    });

    testWidgets('the dot turns to the connected colour the moment the session '
        'connects, with no other rebuild to prompt it', (tester) async {
      final subject = _session();
      // A reference tab that is already up, so the assertion names the
      // connected colour without hardcoding the palette.
      final reference = _session(status: ConnectionStatus.connected);

      await _pumpTabs(tester, [
        _tab(subject, id: 'a'),
        _tab(reference, id: 'b'),
      ]);

      final connectedColour = _dotColors(tester)[1];
      expect(_dotColors(tester)[0], isNot(connectedColour));

      // Exactly what a successful connect does — and nothing else. No
      // provider update, no setState, no new tab list.
      subject.statusNotifier.value = ConnectionStatus.connected;
      await tester.pump();

      expect(_dotColors(tester)[0], connectedColour);

      await subject.dispose();
      await reference.dispose();
    });

    testWidgets('the dot goes back when the session drops', (tester) async {
      final subject = _session(status: ConnectionStatus.connected);
      final reference = _session();

      await _pumpTabs(tester, [
        _tab(subject, id: 'a'),
        _tab(reference, id: 'b'),
      ]);
      final disconnectedColour = _dotColors(tester)[1];

      subject.statusNotifier.value = ConnectionStatus.disconnected;
      await tester.pump();

      expect(_dotColors(tester)[0], disconnectedColour);

      await subject.dispose();
      await reference.dispose();
    });

    testWidgets(
      'a failed connect is not shown as connected - only `connected` is',
      (tester) async {
        final subject = _session();
        final reference = _session(status: ConnectionStatus.connected);

        await _pumpTabs(tester, [
          _tab(subject, id: 'a'),
          _tab(reference, id: 'b'),
        ]);
        final connectedColour = _dotColors(tester)[1];

        for (final status in const [
          ConnectionStatus.connecting,
          ConnectionStatus.error,
          ConnectionStatus.disconnected,
        ]) {
          subject.statusNotifier.value = status;
          await tester.pump();

          expect(
            _dotColors(tester)[0],
            isNot(connectedColour),
            reason: '$status must not read as a working session',
          );
        }

        await subject.dispose();
        await reference.dispose();
      },
    );

    testWidgets('each tab tracks its own session, not its neighbour\'s', (
      tester,
    ) async {
      final first = _session();
      final second = _session();

      await _pumpTabs(tester, [_tab(first, id: 'a'), _tab(second, id: 'b')]);

      first.statusNotifier.value = ConnectionStatus.connected;
      await tester.pump();

      final dots = _dotColors(tester);
      expect(dots[0], isNot(dots[1]));

      await first.dispose();
      await second.dispose();
    });
  });

  group('agent badge - silent unless a state was measured', () {
    testWidgets('draws no badge for a snapshot nobody measured', (
      tester,
    ) async {
      const unmeasured = <AgentSnapshot>[
        AgentsNotProbed(),
        AgentsUnsupported(MultiplexerId.tmux),
        AgentsUnreachable(),
        AgentsKnown([]),
      ];

      for (final snapshot in unmeasured) {
        final session = _session(agents: snapshot);
        await _pumpTabs(tester, [_tab(session)]);

        expect(
          find.byType(AgentBadge),
          findsNothing,
          reason: '$snapshot is not a measured agent state',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
      }
    });

    testWidgets('draws the most urgent state when there is one to draw', (
      tester,
    ) async {
      final session = _session(
        agents: const AgentsKnown([
          (
            target: 'a',
            label: 'a',
            state: AgentState.idle,
            tabId: null,
            workspaceId: null,
          ),
          (
            target: 'b',
            label: 'b',
            state: AgentState.blocked,
            tabId: null,
            workspaceId: null,
          ),
        ]),
      );

      await _pumpTabs(tester, [_tab(session)]);

      expect(find.byType(AgentBadge), findsOneWidget);
      expect(
        tester.widget<AgentBadge>(find.byType(AgentBadge)).state,
        AgentState.blocked,
      );

      await session.dispose();
    });

    testWidgets('appears live when the first agent reading lands', (
      tester,
    ) async {
      final session = _session();

      await _pumpTabs(tester, [_tab(session)]);
      expect(find.byType(AgentBadge), findsNothing);

      session.agentsNotifier.value = const AgentsKnown([
        (
          target: 'a',
          label: 'a',
          state: AgentState.working,
          tabId: null,
          workspaceId: null,
        ),
      ]);
      await tester.pump();

      expect(find.byType(AgentBadge), findsOneWidget);

      await session.dispose();
    });
  });
}
