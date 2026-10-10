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

  /// Null builds a Home with NO tabs at all.
  final TerminalSession? session;

  @override
  TabsState build() {
    final live = session;
    if (live == null) return const TabsState(tabs: []);
    return TabsState(
      tabs: [
        TerminalTab(
          id: 'test',
          title: 'Test',
          session: live,
          profile: _profile,
        ),
      ],
    );
  }

  @override
  Future<AutoConnectDecision> autoConnectDefault({
    required bool recoveryPending,
  }) async => const AutoConnectSkip(AutoConnectSkipReason.alreadyOpen);
}

GoRouter _router() => GoRouter(
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

Widget _app(GoRouter router, TerminalSession? session) => ProviderScope(
  overrides: [tabsProvider.overrideWith(() => _Tabs(session))],
  child: MaterialApp.router(routerConfig: router),
);

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

      await tester.pumpWidget(_app(_router(), session));
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

  // The case the first version of this test MISSED, and the one that
  // matters most. `maestro/flows/02_settings_reachable.yaml` reaches Home
  // straight out of setup, where there is no tab at all, and the overflow
  // button used to be built behind `if (tabsState.hasTabs)`. Settings was
  // therefore unreachable from exactly the screen a user lands on when
  // their only profile will not connect — which is where they go looking
  // for Settings.
  testWidgets('the overflow menu offers Settings with no tabs open at all', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(_app(_router(), null));
    await tester.pumpAndSettle();

    // Precondition, asserted rather than assumed: this really is the empty
    // Home, not a Home that happens to have a tab.
    expect(find.text('No active sessions'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    final settingsItem = find.text('Settings');
    expect(settingsItem, findsOneWidget);

    await tester.tap(settingsItem);
    await tester.pumpAndSettle();

    expect(find.text('settings-placeholder'), findsOneWidget);
  });
}
