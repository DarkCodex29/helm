// Does the agent surface populate on OPEN, with no user interaction?
//
// Agent tracking is demand-driven: TerminalSession only asks the host who
// is running while something is actually observing `agentsNotifier` (see
// `_ObservableValueNotifier` and `_syncAgentTracking`). That gate is
// load-bearing — it is what keeps host traffic at zero when nothing is
// watching, and removing it re-opens the channel-exhaustion incident that
// cost a user their terminal.
//
// Auto-connect-on-launch changes WHO arms it first. Before, the earliest
// observer was whatever the user opened. Now a session exists on the
// first frame, so the question is whether the always-built tab strip arms
// the gate by itself, or whether the drawer's refresh-on-open is secretly
// what was making agents appear.
//
// The tab strip is the right place to pin this: HomeScreen renders it as
// the AppBar title whenever a tab exists, while the drawer's subtree is
// not built at all until it is opened. If the badge arms the gate, then
// both surfaces are populated before any interaction, and the drawer's
// refresh is a top-up rather than the thing that starts it.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:helm/features/terminal/presentation/widgets/agent_state_chip.dart';
import 'package:helm/features/terminal/presentation/widgets/tab_bar_widget.dart';
import 'package:xterm/xterm.dart';

import '../../../../helpers/fake_agent_adapter.dart';
import '../../../../helpers/fake_ssh_service.dart';
import '../../../../helpers/fake_ssh_session.dart';

class _SilentTerminal extends Terminal {
  _SilentTerminal() : super(maxLines: 200);

  @override
  void write(String data) {}
}

const _profile = ConnectionProfile(
  id: 'p1',
  name: 'VPS',
  host: 'example.test',
  username: 'deployer',
);

/// A connected session on [adapter]. `tmuxSessionName` is non-null on
/// purpose — it is what makes agent tracking meaningful at all, so a
/// harness omitting it would silently exercise the disabled path.
Future<TerminalSession> _connected(FakeAgentAdapter adapter) async {
  final service = FakeSSHService();
  service.queueConnectSuccess(
    SSHConnectionResult(
      client: SSHClient(FakeSSHSocket(), username: 'deployer'),
      session: FakeSSHSession(),
    ),
  );
  final session = TerminalSession(
    profile: _profile,
    sshService: service,
    tmuxSessionName: 'helm-0',
    terminal: _SilentTerminal(),
    muxAdapter: adapter,
    attachOpener: (client, command, pty) async => FakeSSHSession(),
  );
  await session.connect('key');
  addTearDown(session.dispose);
  return session;
}

Widget _tabStrip(TerminalSession session) => MaterialApp(
  home: Scaffold(
    appBar: AppBar(
      title: TerminalTabBar(
        tabs: [
          TerminalTab(
            id: 't1',
            title: 'VPS',
            session: session,
            profile: _profile,
          ),
        ],
        activeIndex: 0,
        onTabTap: (_) {},
        onTabClose: (_) {},
        onAddTab: () {},
      ),
    ),
    body: const SizedBox.shrink(),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'merely RENDERING the tab strip asks the host who is running — no '
    'drawer opened, no tap, no gesture of any kind',
    (tester) async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(
          const MuxAgentsAvailable([
            (target: 'w1:p1', label: 'claude', state: AgentState.blocked),
          ]),
        );
      final session = await _connected(adapter);

      expect(
        adapter.listAgentsCalls,
        0,
        reason: 'nothing is observing yet, so nothing may be asked',
      );

      await tester.pumpWidget(_tabStrip(session));
      await tester.pumpAndSettle();

      expect(adapter.listAgentsCalls, greaterThan(0));
    },
  );

  testWidgets(
    'and the answer reaches the badge, so the agent surface is populated '
    'before the user touches anything',
    (tester) async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(
          const MuxAgentsAvailable([
            (target: 'w1:p1', label: 'claude', state: AgentState.blocked),
          ]),
        );
      final session = await _connected(adapter);

      await tester.pumpWidget(_tabStrip(session));
      await tester.pumpAndSettle();

      expect(find.byType(AgentBadge), findsOneWidget);
      expect(
        session.agentsNotifier.value,
        isA<AgentsKnown>().having(
          (s) => s.agents.single.label,
          'label',
          'claude',
        ),
      );
    },
  );

  testWidgets(
    'the gate still holds: with NOTHING rendering the session, the host is '
    'never asked — this is what keeps traffic at zero when unobserved and '
    'must not be traded away for populating on open',
    (tester) async {
      final adapter = FakeAgentAdapter()
        ..whenAgents(const MuxAgentsAvailable([]));
      // Connected and tracking-eligible, but deliberately never handed to
      // a widget: the session is alive and nothing is looking at it.
      await _connected(adapter);

      // A frame passes, and more, with no widget observing the session.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();

      expect(adapter.listAgentsCalls, 0);
    },
  );
}
