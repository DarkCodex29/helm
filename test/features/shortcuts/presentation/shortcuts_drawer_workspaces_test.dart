// Widget tests for the workspace tree in the drawer.
//
// helm's drawer knew one thing about the host: the SSH profile name, one
// row that never changes. herdr on that host already knew the structure
// the owner actually thinks in — workspaces are his clients, tabs are
// their projects — and reaching one meant driving herdr's TUI with a phone
// keyboard, the exact chore helm exists to remove.
//
// Two properties are defended here.
//
// FIRST, the tree must never compose a lie out of a partial truth. A
// workspace header with no tabs under it reads as "this client has no
// projects", so a tree helm could not fully read must not be drawn as a
// tree at all — the discipline the sealed AgentSnapshot variants enforce
// for the agent list, applied to a structure with two levels instead of
// one.
//
// SECOND, the closing gesture is the success report, exactly as it is for
// agent focus (commit a2a3db7): the drawer closing says "you are looking
// at that project now". A focus that did not happen must leave the drawer
// open and say why.
// THIRD, added for this slice: a workspace HEADER must be reachable too.
// Only the tabs under each header were tappable; a user who wanted a
// client had to already know which project inside it to aim for. Tapping
// the header now focuses the tab the host says that client was last
// looking at, falling back honestly when that cannot be resolved -- never
// a silent no-op, and never a guess dressed up as a known fact.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/shortcuts/presentation/shortcuts_drawer.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
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

/// An UNCONNECTED [TerminalSession] that answers the tree and the focus
/// from a script, and REPORTS ITSELF CONNECTED.
///
/// [isConnected] is overridden rather than the session actually being
/// connected because the drawer gates the tree on it — a real connection
/// would drag an SSH transport, a probe and an agent tracker into a widget
/// test whose subject is none of those. Everything else is the real
/// session, including the disposal each test performs.
class _TreeScriptedSession extends TerminalSession {
  _TreeScriptedSession({
    required this.tree,
    this.focusResult = const MuxTabFocused(),
    this.connected = true,
  }) : super(profile: _profile, sshService: FakeSSHService());

  final MuxWorkspaceTreeResult tree;
  final MuxTabFocusResult focusResult;
  final bool connected;

  final List<String> focusedTabs = [];
  int treeCalls = 0;

  @override
  bool get isConnected => connected;

  @override
  Future<MuxWorkspaceTreeResult> refreshWorkspaceTree() async {
    treeCalls++;
    return tree;
  }

  @override
  Future<MuxTabFocusResult> focusTab(String tabId) async {
    focusedTabs.add(tabId);
    return focusResult;
  }
}

MuxWorkspace _ws(
  String id,
  String label, [
  AgentState state = AgentState.idle,
  String? activeTabId,
]) => (
  workspaceId: id,
  label: label,
  agentState: state,
  activeTabId: activeTabId,
);

MuxTab _tab(
  String id,
  String workspaceId,
  String label, {
  int number = 1,
  bool focused = false,
  AgentState state = AgentState.unknown,
}) => (
  tabId: id,
  workspaceId: workspaceId,
  label: label,
  number: number,
  focused: focused,
  agentState: state,
);

/// The owner's real tree, trimmed. w2's tabs are supplied in the order
/// herdr ACTUALLY returns them — the focused tab hoisted to the front, 6
/// before 1 — which is what the ordering test below exists for.
///
/// The owner's real w2 also holds a tab labelled "Helm", and it is left out
/// on purpose: the drawer's own header renders the app name "Helm" too, so
/// a fixture tab by that name makes every text assertion here ambiguous
/// between the header and the row. "Email" is an equally real tab in the
/// same workspace and collides with nothing.
final _realTree = MuxWorkspaceTreeAvailable(
  workspaces: [
    _ws('w1', 'EBIM', AgentState.working, 'w1:t1'),
    _ws('w2', 'Go Nexa', AgentState.idle, 'w2:t6'),
  ],
  tabs: [
    _tab('w1:t1', 'w1', 'Calera', state: AgentState.working),
    _tab('w2:t6', 'w2', 'Email', number: 6, focused: true),
    _tab('w2:t1', 'w2', 'Portal de Proveedores'),
  ],
);

/// A tree built to exercise the workspace HEADER's own focus target, kept
/// separate from [_realTree] because every one of its workspaces is
/// deliberately a DIFFERENT shape:
///
///  * `w1` (EBIM): two tabs, and `active_tab_id` names the SECOND one by
///    number — proving a header tap honours the host's "last looked at",
///    not "first in the tab bar".
///  * `w2` (Go Nexa): `active_tab_id` names a tab this tree does NOT
///    carry — the atomicity race [MuxWorkspaceTreeAvailable] documents —
///    so a tap must degrade to the first tab by number rather than fail.
///  * `w3` (Empty Co): no tabs at all. A tap has nothing to resolve to and
///    must say so rather than silently doing nothing or crashing.
final _headerTree = MuxWorkspaceTreeAvailable(
  workspaces: [
    _ws('w1', 'EBIM', AgentState.idle, 'w1:t2'),
    _ws('w2', 'Go Nexa', AgentState.idle, 'w2:ghost'),
    _ws('w3', 'Empty Co', AgentState.idle, 'w3:ghost'),
  ],
  tabs: [
    _tab('w1:t1', 'w1', 'Calera'),
    _tab('w1:t2', 'w1', 'Documentos', number: 2),
    _tab('w2:t1', 'w2', 'Portal de Proveedores'),
  ],
);

Future<_TreeScriptedSession> _pumpOpenDrawer(
  WidgetTester tester, {
  required MuxWorkspaceTreeResult tree,
  MuxTabFocusResult focusResult = const MuxTabFocused(),
  bool connected = true,
  bool withSession = true,
}) async {
  final session = _TreeScriptedSession(
    tree: tree,
    focusResult: focusResult,
    connected: connected,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tabsProvider.overrideWith(
          () => _FixedTabsNotifier(
            TabsState(
              tabs: withSession
                  ? [
                      TerminalTab(
                        id: 'tab-1',
                        title: 'helm-0',
                        session: session,
                        profile: _profile,
                      ),
                    ]
                  : [],
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

  group('the tree the host reported', () {
    testWidgets('shows each workspace and the tabs beneath it', (tester) async {
      final session = await _pumpOpenDrawer(tester, tree: _realTree);

      expect(find.text('EBIM'), findsOneWidget);
      expect(find.text('Go Nexa'), findsOneWidget);
      expect(find.text('Calera'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Portal de Proveedores'), findsOneWidget);

      await session.dispose();
    });

    testWidgets(
      'orders tabs by their tab-bar number, NOT by the order herdr sent '
      'them — MEASURED live, herdr hoists the focused tab to the front, so '
      'arrival order would reshuffle the list under the user\'s thumb every '
      'time they tapped a row',
      (tester) async {
        final session = await _pumpOpenDrawer(tester, tree: _realTree);

        final labels = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .toList();
        expect(
          labels.indexOf('Portal de Proveedores'),
          lessThan(labels.indexOf('Email')),
          reason: 'tab 1 must precede tab 6 however herdr ordered them',
        );

        await session.dispose();
      },
    );

    testWidgets('keeps each workspace\'s tabs under that workspace', (
      tester,
    ) async {
      final session = await _pumpOpenDrawer(tester, tree: _realTree);

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();

      // Calera belongs to EBIM, so it must fall between EBIM and the next
      // workspace header rather than drifting into Go Nexa's group.
      expect(labels.indexOf('EBIM'), lessThan(labels.indexOf('Calera')));
      expect(labels.indexOf('Calera'), lessThan(labels.indexOf('Go Nexa')));

      await session.dispose();
    });

    testWidgets(
      'marks the tab the host is actually looking at IN WORDS, so the tree '
      'says where you already are — a colour-only marker would be no '
      'marker at all to a screen reader, and this is the one row in the '
      'tree that does not need tapping',
      (tester) async {
        final session = await _pumpOpenDrawer(tester, tree: _realTree);

        expect(find.text('current'), findsOneWidget);

        // On the FOCUSED row and no other. `_realTree` marks w2:t6
        // (Email), so the marker must sit beside that label rather than
        // the first row that happened to render.
        final labels = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .toList();
        expect(labels.indexOf('Email'), lessThan(labels.indexOf('current')));
        expect(
          labels.indexOf('current') - labels.indexOf('Email'),
          lessThanOrEqualTo(2),
          reason: 'the marker must belong to the Email row, not a later one',
        );

        await session.dispose();
      },
    );

    testWidgets('every tab row is at least 48dp tall', (tester) async {
      final session = await _pumpOpenDrawer(tester, tree: _realTree);

      for (final label in ['Calera', 'Email', 'Portal de Proveedores']) {
        final row = find.ancestor(
          of: find.text(label),
          matching: find.byType(InkWell),
        );
        expect(tester.getSize(row.first).height, greaterThanOrEqualTo(48.0));
      }

      await session.dispose();
    });
  });

  group('tapping a workspace header', () {
    testWidgets(
      'focuses the tab the host says this client was last looking at, by '
      'the active_tab_id it reported — not the first tab in the tab bar',
      (tester) async {
        final session = await _pumpOpenDrawer(tester, tree: _realTree);

        await tester.tap(find.text('EBIM'));
        await tester.pumpAndSettle();

        expect(session.focusedTabs, ['w1:t1']);

        await session.dispose();
      },
    );

    testWidgets(
      'honours active_tab_id over the first tab when the last-looked-at tab '
      'is NOT the first one by number',
      (tester) async {
        final session = await _pumpOpenDrawer(tester, tree: _headerTree);

        await tester.tap(find.text('EBIM'));
        await tester.pumpAndSettle();

        expect(
          session.focusedTabs,
          ['w1:t2'],
          reason:
              'EBIM\'s active_tab_id names Documentos (w1:t2), not Calera '
              '(w1:t1), which is first by number',
        );

        await session.dispose();
      },
    );

    testWidgets(
      'falls back to the first tab by number when active_tab_id names a tab '
      'this tree does not carry — the atomicity race '
      "MuxWorkspaceTreeAvailable's own doc names, degraded honestly rather "
      'than refused',
      (tester) async {
        final session = await _pumpOpenDrawer(tester, tree: _headerTree);

        await tester.tap(find.text('Go Nexa'));
        await tester.pumpAndSettle();

        expect(
          session.focusedTabs,
          ['w2:t1'],
          reason:
              "Go Nexa's active_tab_id (w2:ghost) is not in the tree, so "
              'the fallback is the first tab by number',
        );

        await session.dispose();
      },
    );

    testWidgets(
      'a workspace with no tabs at all says so, rather than a silent no-op '
      'or a crash on a target that cannot exist',
      (tester) async {
        final session = await _pumpOpenDrawer(tester, tree: _headerTree);

        await tester.tap(find.text('Empty Co'));
        await tester.pumpAndSettle();

        expect(session.focusedTabs, isEmpty);
        expect(find.textContaining('no tabs'), findsOneWidget);
        expect(
          find.byType(ShortcutsDrawer),
          findsOneWidget,
          reason: 'nothing was focused, so the drawer must stay open',
        );

        await session.dispose();
      },
    );

    testWidgets(
      'closes the drawer once the resolved tab is actually up — the same '
      'success-report order a tab row\'s own tap follows',
      (tester) async {
        final session = await _pumpOpenDrawer(tester, tree: _realTree);

        await tester.tap(find.text('EBIM'));
        await tester.pumpAndSettle();

        expect(find.byType(ShortcutsDrawer), findsNothing);

        await session.dispose();
      },
    );

    testWidgets(
      'a focus that did not happen on the host reuses the SAME failure '
      'wording _focusTab already reports for a tab row — one error path, '
      'not a second one that could drift from it',
      (tester) async {
        final session = await _pumpOpenDrawer(
          tester,
          tree: _realTree,
          focusResult: const MuxTabFocusFailed(null),
        );

        await tester.tap(find.text('EBIM'));
        await tester.pumpAndSettle();

        expect(find.textContaining('Could not'), findsOneWidget);
        expect(find.byType(ShortcutsDrawer), findsOneWidget);

        await session.dispose();
      },
    );
  });

  group('tapping a tab', () {
    testWidgets(
      'asks the host to focus THAT tab, by the id the host itself reported '
      '— not by label, not by list position',
      (tester) async {
        final session = await _pumpOpenDrawer(tester, tree: _realTree);

        await tester.tap(find.text('Portal de Proveedores'));
        await tester.pumpAndSettle();

        expect(session.focusedTabs, ['w2:t1']);

        await session.dispose();
      },
    );

    testWidgets(
      'closes the drawer once the tab is actually up — closing IS the '
      'success report, so it is the last thing that happens',
      (tester) async {
        final session = await _pumpOpenDrawer(tester, tree: _realTree);

        await tester.tap(find.text('Calera'));
        await tester.pumpAndSettle();

        expect(find.byType(ShortcutsDrawer), findsNothing);

        await session.dispose();
      },
    );
  });

  group('a focus that did not happen', () {
    testWidgets(
      'leaves the drawer OPEN — closing it would claim the user is now '
      'looking at a project that never came up',
      (tester) async {
        final session = await _pumpOpenDrawer(
          tester,
          tree: _realTree,
          focusResult: const MuxTabFocusFailed('server_not_running'),
        );

        await tester.tap(find.text('Calera'));
        await tester.pumpAndSettle();

        expect(find.byType(ShortcutsDrawer), findsOneWidget);
        expect(find.text('Calera'), findsOneWidget);

        await session.dispose();
      },
    );

    testWidgets('says so, rather than failing in silence', (tester) async {
      final session = await _pumpOpenDrawer(
        tester,
        tree: _realTree,
        focusResult: const MuxTabFocusFailed(null),
      );

      await tester.tap(find.text('Calera'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not'), findsOneWidget);

      await session.dispose();
    });

    testWidgets(
      'a vanished tab reads DIFFERENTLY from a host we could not reach — '
      'one says this tree is stale, the other says helm could not ask',
      (tester) async {
        final texts = <String, String>{};

        for (final result in const <MuxTabFocusResult>[
          MuxTabFocusTargetNotFound(),
          MuxTabFocusFailed('server_not_running'),
        ]) {
          await tester.pumpWidget(const SizedBox.shrink());
          final session = await _pumpOpenDrawer(
            tester,
            tree: _realTree,
            focusResult: result,
          );

          await tester.tap(find.text('Calera'));
          await tester.pumpAndSettle();

          // Every line that names the tab EXCEPT the row's own label.
          texts['$result'] = tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data ?? '')
              .where((t) => t.contains('Calera') && t != 'Calera')
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
  });

  group('the states that are NOT a tree', () {
    testWidgets('no session at all says so', (tester) async {
      final session = await _pumpOpenDrawer(
        tester,
        tree: _realTree,
        withSession: false,
      );

      expect(find.text('EBIM'), findsNothing);

      await session.dispose();
    });

    testWidgets(
      'a multiplexer that has no workspaces NAMES itself, rather than '
      'letting the user read an empty drawer as an empty host',
      (tester) async {
        final session = await _pumpOpenDrawer(
          tester,
          tree: const MuxWorkspaceTreeUnsupported(MultiplexerId.tmux),
        );

        expect(find.textContaining('tmux'), findsOneWidget);

        await session.dispose();
      },
    );

    testWidgets(
      'an EMPTY tree and an UNREACHABLE host must not look the same — one '
      'is a measurement, the other is an admission',
      (tester) async {
        final wordings = <String, String>{};

        for (final entry in <String, MuxWorkspaceTreeResult>{
          'empty': const MuxWorkspaceTreeAvailable(workspaces: [], tabs: []),
          'unreachable': const MuxWorkspaceTreeUnreachable(),
        }.entries) {
          await tester.pumpWidget(const SizedBox.shrink());
          final session = await _pumpOpenDrawer(tester, tree: entry.value);

          wordings[entry.key] = tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data ?? '')
              .join('|');

          await session.dispose();
        }

        expect(
          wordings['empty'],
          isNot(equals(wordings['unreachable'])),
          reason: 'an empty host and an unreachable one read alike: $wordings',
        );
      },
    );

    testWidgets('a disconnected session says THAT, not that herdr could not be '
        'reached — helm never opened a connection to reach it over', (
      tester,
    ) async {
      final session = await _pumpOpenDrawer(
        tester,
        tree: _realTree,
        connected: false,
      );

      expect(find.text('EBIM'), findsNothing);
      expect(find.textContaining('Not connected'), findsWidgets);
      expect(
        session.treeCalls,
        0,
        reason: 'a disconnected session must not be asked at all',
      );

      await session.dispose();
    });
  });
}
