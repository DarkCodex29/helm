import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/auto_connect_decision.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:helm/features/terminal/presentation/home_screen.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_host_command_runner.dart';
import '../../../helpers/fake_ssh_service.dart';

const _profile = ConnectionProfile(
  id: 'settings-overflow-test',
  name: 'Test',
  host: 'example.test',
  username: 'tester',
);

/// Mirrors the no-tap, no-connection harness in
/// `home_screen_floating_keyboard_test.dart`: one tab, one session that is
/// never connected. This test's whole point is that Settings must not
/// depend on a connected session, so the session here is deliberately
/// left disconnected.
class _Tabs extends TabsNotifier {
  _Tabs(this.session);
  final TerminalSession session;

  @override
  TabsState build() => TabsState(
    tabs: [
      TerminalTab(
        id: 'test',
        title: 'Test',
        session: session,
        profile: _profile,
      ),
    ],
  );

  @override
  Future<AutoConnectDecision> autoConnectDefault({
    required bool recoveryPending,
  }) async => const AutoConnectSkip(AutoConnectSkipReason.alreadyOpen);
}

void main() {
  testWidgets(
    'the overflow menu always offers Settings and routes to it, with no '
    'connected session',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = TerminalSession(
        profile: _profile,
        sshService: FakeSSHService(),
        hostRunnerFactory: (_) => FakeHostCommandRunner(),
      );
      addTearDown(session.dispose);

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          GoRoute(
            path: '/settings',
            builder: (context, state) =>
                const Scaffold(body: Text('settings-placeholder')),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [tabsProvider.overrideWith(() => _Tabs(session))],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Opening the overflow menu with no connected session - the whole
      // claim under test is that Settings is NOT scoped to a connection.
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      final settingsItem = find.text('Settings');
      expect(settingsItem, findsOneWidget);

      await tester.tap(settingsItem);
      await tester.pumpAndSettle();

      expect(find.text('settings-placeholder'), findsOneWidget);
    },
  );
}
