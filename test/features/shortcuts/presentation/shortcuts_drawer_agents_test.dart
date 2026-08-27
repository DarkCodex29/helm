// Widget tests for the AGENTS section of the shortcuts drawer.
//
// The section has a FOUR-WAY branch, and the reason it is four ways
// instead of "a list, possibly empty" is the entire point: three of the
// four mean "helm does not know", and only one of them may say "no agents
// running right now". A naive implementation renders all four identically
// and quietly tells the user everything is fine while an agent waits.
//
// These are driven through the real ShortcutsDrawer rather than a promoted
// copy of the private section, so the wiring from the active tab's session
// into the branch is covered too.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/session_vitality.dart';
import 'package:helm/core/testing/semantic_ids.dart';
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

/// A [TabsNotifier] pinned to one state, so the drawer can be rendered
/// against a chosen active tab without any SSH machinery.
class _FixedTabsNotifier extends TabsNotifier {
  _FixedTabsNotifier(this._fixed);

  final TabsState _fixed;

  @override
  TabsState build() => _fixed;
}

/// An UNCONNECTED [TerminalSession] whose agent snapshot is set directly.
///
/// Deliberately never connected: `refreshAgents` returns immediately for a
/// disconnected session, so the drawer's open-time refresh is inert, and
/// agent polling is never enabled — so this harness cannot leave a timer
/// pending behind a widget test.
TerminalSession _sessionShowing(
  AgentSnapshot snapshot, {
  SessionVitality vitality = const SessionVitalityNotProbed(),
}) {
  final session = TerminalSession(
    profile: _profile,
    sshService: FakeSSHService(),
  );
  session.agentsNotifier.value = snapshot;
  session.sessionVitalityNotifier.value = vitality;
  return session;
}

AgentStatus _agent(AgentState state, String target) =>
    (target: target, label: target, state: state);

/// Every line of text rendered inside the AGENTS section, joined.
///
/// Scoped by the section's own semantics identifier so the drawer's other
/// sections cannot contribute wording this assertion would misread.
String _agentsSectionText(WidgetTester tester) {
  final section = find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.identifier == ShortcutsSemantics.agentsSection,
  );
  expect(section, findsOneWidget);
  return tester
      .widgetList<Text>(find.descendant(of: section, matching: find.byType(Text)))
      .map((t) => t.data ?? '')
      .join('|');
}

Future<TerminalSession?> _pumpDrawer(
  WidgetTester tester, {
  required AgentSnapshot? snapshot,
  SessionVitality vitality = const SessionVitalityNotProbed(),
}) async {
  // Tear the previous tree down first. Pumping a second drawer into a live
  // tree reuses the Scaffold element and keeps the ORIGINAL notifier, so a
  // loop over several snapshots would silently re-read the first one.
  await tester.pumpWidget(const SizedBox.shrink());

  final session = snapshot == null
      ? null
      : _sessionShowing(snapshot, vitality: vitality);
  final tabs = session == null
      ? const TabsState()
      : TabsState(
          tabs: [
            TerminalTab(
              id: 'tab-1',
              title: 'helm-0',
              session: session,
              profile: _profile,
            ),
          ],
        );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [tabsProvider.overrideWith(() => _FixedTabsNotifier(tabs))],
      child: const MaterialApp(home: Scaffold(drawer: ShortcutsDrawer())),
    ),
  );
  // Open the drawer: Scaffold's DrawerController does not build its child
  // while closed, so nothing under test exists until this runs.
  tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
  await tester.pumpAndSettle();
  return session;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AGENTS section — four outcomes, only one of them says "none"', () {
    testWidgets('no active session says so, rather than showing an empty list',
        (tester) async {
      await _pumpDrawer(tester, snapshot: null);

      expect(find.text('No active session'), findsOneWidget);
      expect(find.byType(AgentRow), findsNothing);
    });

    testWidgets(
      'nothing probed yet says agent state is unknown, never "no agents"',
      (tester) async {
        final session = await _pumpDrawer(
          tester,
          snapshot: const AgentsNotProbed(),
        );

        expect(find.text('Not connected — agent state unknown'), findsOneWidget);
        expect(find.textContaining('No agents'), findsNothing);
        expect(find.byType(AgentRow), findsNothing);

        await session?.dispose();
      },
    );

    testWidgets(
      'an agent-blind multiplexer NAMES itself — the actionable fact is '
      'that this one cannot answer, not that helm failed',
      (tester) async {
        final session = await _pumpDrawer(
          tester,
          snapshot: const AgentsUnsupported(MultiplexerId.tmux),
        );

        expect(find.text('tmux does not track agent state'), findsOneWidget);
        expect(find.textContaining('No agents'), findsNothing);
        expect(find.byType(AgentRow), findsNothing);

        await session?.dispose();
      },
    );

    testWidgets('an unreachable server says "could not reach", never "none"', (
      tester,
    ) async {
      final session = await _pumpDrawer(
        tester,
        snapshot: const AgentsUnreachable(),
      );

      expect(find.textContaining('Could not reach'), findsOneWidget);
      expect(find.textContaining('No agents'), findsNothing);
      expect(find.byType(AgentRow), findsNothing);

      await session?.dispose();
    });

    testWidgets(
      'ONLY an authoritative empty reading is allowed to say no agents are '
      'running',
      (tester) async {
        final session = await _pumpDrawer(
          tester,
          snapshot: const AgentsKnown([]),
        );

        expect(find.text('No agents running right now'), findsOneWidget);
        expect(find.byType(AgentRow), findsNothing);

        await session?.dispose();
      },
    );

    testWidgets(
      'a VIRGIN verdict on an empty agent list says the session came back '
      'empty — the whole point of the second fact',
      (tester) async {
        final session = await _pumpDrawer(
          tester,
          snapshot: const AgentsKnown([]),
          vitality: const SessionVitalityKnown(SessionShape.virgin),
        );

        expect(find.textContaining('restored empty'), findsOneWidget);
        // It must REPLACE the neutral wording, not sit beside it: two
        // hints would read as two separate facts about the same thing.
        expect(find.text('No agents running right now'), findsNothing);
        expect(find.byType(AgentRow), findsNothing);

        await session?.dispose();
      },
    );

    testWidgets(
      'a LIVED-IN verdict on an empty agent list keeps the neutral wording: '
      'the user simply has not started anything yet',
      (tester) async {
        final session = await _pumpDrawer(
          tester,
          snapshot: const AgentsKnown([]),
          vitality: const SessionVitalityKnown(SessionShape.livedIn),
        );

        expect(find.text('No agents running right now'), findsOneWidget);
        expect(find.textContaining('restored empty'), findsNothing);

        await session?.dispose();
      },
    );

    // A claim about the host that nobody measured is exactly what
    // `mostUrgentAgentState` refuses to draw a badge for. The same rule
    // applies here: these three variants MUST NOT produce the alarm.
    for (final vitality in const <SessionVitality>[
      SessionVitalityNotProbed(),
      SessionVitalityUnreachable(),
      SessionVitalityIndeterminate(),
      SessionVitalityUnsupported(MultiplexerId.tmux),
    ]) {
      testWidgets(
        'an unmeasured verdict (${vitality.runtimeType}) draws no claim at '
        'all — silence is the only honest output',
        (tester) async {
          final session = await _pumpDrawer(
            tester,
            snapshot: const AgentsKnown([]),
            vitality: vitality,
          );

          expect(find.textContaining('restored empty'), findsNothing);
          expect(find.text('No agents running right now'), findsOneWidget);

          await session?.dispose();
        },
      );
    }

    testWidgets(
      'a VIRGIN verdict never overrides live agents — a session with an '
      'agent in it is being worked in, whatever else was measured',
      (tester) async {
        final session = await _pumpDrawer(
          tester,
          snapshot: AgentsKnown([_agent(AgentState.working, 'a')]),
          vitality: const SessionVitalityKnown(SessionShape.virgin),
        );

        expect(find.byType(AgentRow), findsOneWidget);
        expect(find.textContaining('restored empty'), findsNothing);

        await session?.dispose();
      },
    );

    testWidgets('a non-empty reading renders one row per agent', (
      tester,
    ) async {
      final session = await _pumpDrawer(
        tester,
        snapshot: AgentsKnown([
          _agent(AgentState.working, 'a'),
          _agent(AgentState.idle, 'b'),
        ]),
      );

      expect(find.byType(AgentRow), findsNWidgets(2));
      expect(find.textContaining('No agents'), findsNothing);

      await session?.dispose();
    });

    testWidgets(
      'the four not-running outcomes never share wording, so a user can '
      'tell "we do not know" from "nothing is happening"',
      (tester) async {
        final wordings = <String>{};
        const snapshots = <AgentSnapshot>[
          AgentsNotProbed(),
          AgentsUnsupported(MultiplexerId.tmux),
          AgentsUnreachable(),
          AgentsKnown([]),
        ];

        for (final snapshot in snapshots) {
          final session = await _pumpDrawer(tester, snapshot: snapshot);
          wordings.add(_agentsSectionText(tester));
          await session?.dispose();
        }

        expect(
          wordings,
          hasLength(snapshots.length),
          reason: 'each outcome must read differently: $wordings',
        );
        expect(wordings, everyElement(isNotEmpty));
      },
    );
  });

  group('AGENTS section — the one waiting on a human comes first', () {
    testWidgets('sorts most urgent first regardless of host order', (
      tester,
    ) async {
      final session = await _pumpDrawer(
        tester,
        snapshot: AgentsKnown([
          _agent(AgentState.idle, 'idle-one'),
          _agent(AgentState.working, 'working-one'),
          _agent(AgentState.blocked, 'blocked-one'),
        ]),
      );

      final rows = tester
          .widgetList<AgentRow>(find.byType(AgentRow))
          .map((r) => r.agent.state)
          .toList();

      expect(rows, [AgentState.blocked, AgentState.working, AgentState.idle]);

      await session?.dispose();
    });

    testWidgets(
      'ties keep the host order, which is stable across polls — a list '
      'that reshuffles itself every ten seconds is unreadable',
      (tester) async {
        final session = await _pumpDrawer(
          tester,
          snapshot: AgentsKnown([
            _agent(AgentState.idle, 'first'),
            _agent(AgentState.idle, 'second'),
            _agent(AgentState.idle, 'third'),
          ]),
        );

        final order = tester
            .widgetList<AgentRow>(find.byType(AgentRow))
            .map((r) => r.agent.target)
            .toList();

        expect(order, ['first', 'second', 'third']);

        await session?.dispose();
      },
    );

    testWidgets('re-sorting does not mutate the snapshot it was handed', (
      tester,
    ) async {
      final agents = [
        _agent(AgentState.idle, 'idle-one'),
        _agent(AgentState.blocked, 'blocked-one'),
      ];
      final session = await _pumpDrawer(tester, snapshot: AgentsKnown(agents));

      expect(agents.first.state, AgentState.idle);

      await session?.dispose();
    });
  });
}
