// Widget tests for tapping an agent row in the drawer.
//
// The drawer's agent list was read-only, which meant the owner could learn
// that an agent needed him and then had to go FIND that pane himself by
// driving herdr's TUI with a phone keyboard — the exact chore helm exists
// to remove. Tapping a row is the shortcut.
//
// What these tests defend is the honesty of the closing gesture. The
// drawer closing IS the success report: it says "you are looking at that
// agent now". So a focus that did not happen must never close it, and must
// never be silent about why — the same discipline the sealed AgentSnapshot
// variants enforce for what the drawer READS, applied to what it DOES.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/shortcuts/presentation/shortcuts_drawer.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:helm/features/terminal/presentation/widgets/agent_state_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_ssh_service.dart';

const _profile = ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  username: 'tester',
);

class _FixedTabsNotifier extends TabsNotifier {
  _FixedTabsNotifier(this._fixed);

  final TabsState _fixed;

  @override
  TabsState build() => _fixed;
}

/// An UNCONNECTED [TerminalSession] whose [focusAgent] answers with a
/// scripted result and records what it was asked to raise.
///
/// Subclassed rather than mocked so the rest of the session — the
/// notifiers the drawer reads, the disposal the test performs — is the
/// real thing. Deliberately never connected, so nothing here can leave a
/// poll or a timer pending behind a widget test.
class _FocusScriptedSession extends TerminalSession {
  _FocusScriptedSession(this.result)
    : super(profile: _profile, sshService: FakeSSHService());

  final MuxAgentFocusResult result;
  final List<String> focused = [];

  @override
  Future<MuxAgentFocusResult> focusAgent(String target) async {
    focused.add(target);
    return result;
  }
}

AgentStatus _agent(AgentState state, String target, {String? label}) => (
  target: target,
  label: label ?? target,
  state: state,
  tabId: null,
  workspaceId: null,
);

Future<_FocusScriptedSession> _pumpOpenDrawer(
  WidgetTester tester, {
  required List<AgentStatus> agents,
  required MuxAgentFocusResult focusResult,
}) async {
  final session = _FocusScriptedSession(focusResult)
    ..agentsNotifier.value = AgentsKnown(agents);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tabsProvider.overrideWith(
          () => _FixedTabsNotifier(
            TabsState(
              tabs: [
                TerminalTab(
                  id: 'tab-1',
                  title: 'helm-0',
                  session: session,
                  profile: _profile,
                ),
              ],
            ),
          ),
        ),
      ],
      child: const MaterialApp(home: Scaffold(drawer: ShortcutsDrawer())),
    ),
  );
  tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
  await tester.pumpAndSettle();
  return session;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('tapping an agent row', () {
    testWidgets(
      'asks the host to focus THAT agent, by the target the host itself '
      'reported — not by label, not by list position',
      (tester) async {
        final session = await _pumpOpenDrawer(
          tester,
          agents: [
            _agent(AgentState.working, 'w1:p1', label: 'claude'),
            _agent(AgentState.idle, 'w5:p2', label: 'opencode'),
          ],
          focusResult: const MuxAgentFocused(),
        );

        await tester.tap(find.text('opencode'));
        await tester.pumpAndSettle();

        expect(session.focused, ['w5:p2']);

        await session.dispose();
      },
    );

    testWidgets(
      'reports WHERE the focus landed instead of closing as if this screen '
      'had followed it',
      (tester) async {
        // MEASURED on a real S22 against a live herdr 0.9.0: `agent focus`
        // returns success and moves the pane on the DESKTOP, while the
        // phone's view stays exactly where it was. One herdr session, two
        // clients, independent views, and no way to aim the CLI at one.
        //
        // So a success here is a fact about the Mac, not about this
        // screen. Closing the drawer used to BE the success report — the
        // old name for this test said so — which made the app assert the
        // one thing it had not done. Being told nothing happened is
        // better than being shown a screen that implies it did.
        final session = await _pumpOpenDrawer(
          tester,
          agents: [_agent(AgentState.blocked, 'w1:p1')],
          focusResult: const MuxAgentFocused(),
        );

        await tester.tap(find.byType(AgentRow));
        await tester.pumpAndSettle();

        expect(find.byType(ShortcutsDrawer), findsOneWidget);
        expect(find.textContaining('on the Mac'), findsOneWidget);
        expect(
          find.textContaining('this screen'),
          findsOneWidget,
          reason: 'it must name what did NOT move, not only what did',
        );

        await session.dispose();
      },
    );
  });

  group('a focus that did not happen', () {
    testWidgets(
      'leaves the drawer OPEN — closing it would claim the user is now '
      'looking at a pane that never came up',
      (tester) async {
        final session = await _pumpOpenDrawer(
          tester,
          agents: [_agent(AgentState.blocked, 'w1:p1')],
          focusResult: const MuxAgentFocusFailed('server_not_running'),
        );

        await tester.tap(find.byType(AgentRow));
        await tester.pumpAndSettle();

        expect(find.byType(ShortcutsDrawer), findsOneWidget);
        expect(find.byType(AgentRow), findsOneWidget);

        await session.dispose();
      },
    );

    testWidgets('says so, rather than failing in silence', (tester) async {
      final session = await _pumpOpenDrawer(
        tester,
        agents: [_agent(AgentState.blocked, 'w1:p1', label: 'claude')],
        focusResult: const MuxAgentFocusFailed(null),
      );

      await tester.tap(find.byType(AgentRow));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not focus'), findsOneWidget);

      await session.dispose();
    });

    testWidgets(
      'a vanished agent reads DIFFERENTLY from a host we could not reach — '
      'one says this list is stale, the other says helm could not ask',
      (tester) async {
        final texts = <MuxAgentFocusResult, String>{};

        for (final result in const <MuxAgentFocusResult>[
          MuxAgentFocusTargetNotFound(),
          MuxAgentFocusFailed('server_not_running'),
        ]) {
          await tester.pumpWidget(const SizedBox.shrink());
          final session = await _pumpOpenDrawer(
            tester,
            agents: [_agent(AgentState.blocked, 'w1:p1', label: 'claude')],
            focusResult: result,
          );

          await tester.tap(find.byType(AgentRow));
          await tester.pumpAndSettle();

          // Every line that names the agent EXCEPT the row's own label,
          // which is the bare string on its own.
          texts[result] = tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data ?? '')
              .where((t) => t.contains('claude') && t != 'claude')
              .join('|');

          await session.dispose();
        }

        expect(texts.values, everyElement(isNotEmpty));
        expect(
          texts.values.toSet(),
          hasLength(2),
          reason: 'the two failures must not share wording: $texts',
        );
      },
    );

    testWidgets(
      'the message clears on the next attempt, so a stale complaint does '
      'not outlive the thing it was about',
      (tester) async {
        final session = await _pumpOpenDrawer(
          tester,
          agents: [_agent(AgentState.blocked, 'w1:p1', label: 'claude')],
          focusResult: const MuxAgentFocusFailed(null),
        );

        await tester.tap(find.byType(AgentRow));
        await tester.pumpAndSettle();
        expect(find.textContaining('Could not focus'), findsOneWidget);

        // The second tap is scripted to fail too, but the message must be
        // rebuilt from THIS attempt rather than left over from the last.
        await tester.tap(find.byType(AgentRow));
        await tester.pumpAndSettle();

        expect(find.textContaining('Could not focus'), findsOneWidget);
        expect(session.focused, ['w1:p1', 'w1:p1']);

        await session.dispose();
      },
    );
  });
}
