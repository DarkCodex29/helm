@Timeout(Duration(seconds: 30))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_asks.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
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
import '../../agentd/support/fakes.dart';
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

  testWidgets('an ask that arrived while another tab was active is shown on '
      'switching to its tab', (tester) async {
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
    final connector = FakeConnector();
    final built = <AgentdClient>[];
    addTearDown(() async {
      for (final c in built) {
        await c.close().timeout(const Duration(seconds: 5));
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tabsProvider.overrideWith(() => _Tabs(tabs, 0)),
          agentdClientProvider.overrideWith((ref, id) async {
            final client = AgentdClient(
              endpoint: const AgentdEndpoint(host: '127.0.0.1', port: 1),
              token: 'FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfakeFAK',
              connect: connector.call,
            );
            built.add(client);
            ref.onDispose(client.close);
            return client;
          }),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    // Every tab keeps its profile connected (as the tab strip does).
    final keep = [
      container.listen(agentdClientStatesProvider('pa'), (_, _) {}),
      container.listen(agentdClientStatesProvider('pb'), (_, _) {}),
    ];
    addTearDown(() {
      for (final k in keep) {
        k.close();
      }
    });
    await tester.pump();
    await tester.pump();
    expect(connector.channels, hasLength(2));
    // connector order: pa first, pb second.
    for (final ch in connector.channels) {
      ch.serveReady();
    }
    connector.channels[1].serve(
      proto.AskMessage(
        requestId: 'x1',
        method: 'confirm',
        title: 'Question for B',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Question for B'), findsNothing); // tab A is active

    container.read(tabsProvider.notifier).setActiveTab(1);
    await tester.pumpAndSettle();
    expect(find.byType(AgentAskBanner), findsOneWidget);
    expect(find.text('Question for B'), findsOneWidget);
  });
}
