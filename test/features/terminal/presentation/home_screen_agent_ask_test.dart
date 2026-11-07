@Timeout(Duration(seconds: 30))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_asks.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm/features/agentd/domain/agentd_connection_state.dart';
import 'package:helm/features/agentd/domain/agent_state.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/auto_connect_decision.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:helm/features/terminal/presentation/home_screen.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:helm/features/terminal/presentation/widgets/agent_ask_banner.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_view_widget.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';

const _a = ConnectionProfile(
  id: 'pa',
  name: 'A',
  host: 'a.test',
  username: 'u',
);
const _b = ConnectionProfile(
  id: 'pb',
  name: 'B',
  host: 'b.test',
  username: 'u',
);

class _Tabs extends TabsNotifier {
  _Tabs(this.tabs, this.activeIndex);
  final List<TerminalTab> tabs;
  final int activeIndex;

  @override
  TabsState build() => TabsState(tabs: tabs, activeIndex: activeIndex);

  @override
  Future<AutoConnectDecision> autoConnectDefault({
    required bool recoveryPending,
  }) async => const AutoConnectSkip(AutoConnectSkipReason.alreadyOpen);
}

void main() {
  testWidgets('the banner follows the ACTIVE tab and leaves the terminal', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    TerminalTab tab(String id, ConnectionProfile p) {
      final s = TerminalSession(
        profile: p,
        sshService: FakeSSHService(),
        hostRunnerFactory: (_) => FakeHostCommandRunner(),
      );
      addTearDown(s.dispose);
      return TerminalTab(id: id, title: p.name, session: s, profile: p);
    }

    final tabs = [tab('ta', _a), tab('tb', _b)];
    final ask = proto.AskMessage(
      requestId: 'x1',
      method: 'confirm',
      title: 'Question for B',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tabsProvider.overrideWith(() => _Tabs(tabs, 0)),
          agentdClientStatesProvider.overrideWith(
            (ref, id) => Stream.value(const AgentdConnected(AgentState.idle)),
          ),
          agentdAsksProvider.overrideWith(
            (ref, id) => Stream.value(id == 'pb' ? [ask] : const []),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Question for B'), findsNothing);
    expect(find.byType(HelmTerminalView), findsOneWidget);

    ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    ).read(tabsProvider.notifier).setActiveTab(1);
    await tester.pumpAndSettle();
    expect(find.byType(AgentAskBanner), findsOneWidget);
    expect(find.text('Question for B'), findsOneWidget);
    expect(find.byType(HelmTerminalView), findsOneWidget);
  });
}
