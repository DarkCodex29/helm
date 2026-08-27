// Widget tests for the two surfaces that render one agent's state: the
// tab-strip badge and the drawer row.
//
// Both are driven by the same AgentStateStyle table, which exists so the
// two can never disagree about what a state looks like. These pin the
// wording a user reads and the emphasis given to `blocked` — the one state
// the whole feature exists to surface, and the only one allowed to shout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/features/terminal/presentation/widgets/agent_state_chip.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

AgentStatus _agent(AgentState state, {String label = 'claude'}) =>
    (target: 't1', label: label, state: state, tabId: null, workspaceId: null);

void main() {
  group('AgentBadge', () {
    testWidgets('carries the state wording in its tooltip, since an '
        'icon-only badge cannot say it out loud', (tester) async {
      for (final state in AgentState.values) {
        await tester.pumpWidget(_host(AgentBadge(state: state)));

        final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
        expect(tooltip.message, agentStateLabel(state));
      }
    });

    testWidgets('renders the icon its shared style table assigns', (
      tester,
    ) async {
      for (final state in AgentState.values) {
        await tester.pumpWidget(_host(AgentBadge(state: state)));

        final icon = tester.widget<Icon>(find.byType(Icon));
        expect(icon.icon, AgentStateStyle.of(state).icon);
      }
    });

    testWidgets(
      'fills only the blocked badge — every other state stays quiet so the '
      'one needing a human is the one that draws the eye',
      (tester) async {
        await tester.pumpWidget(
          _host(const AgentBadge(state: AgentState.blocked)),
        );
        final blockedFill = _badgeFillAlpha(tester);

        for (final state in AgentState.values) {
          if (state == AgentState.blocked) continue;
          await tester.pumpWidget(_host(AgentBadge(state: state)));

          expect(
            _badgeFillAlpha(tester),
            lessThan(blockedFill),
            reason: '$state must not compete with blocked',
          );
        }
      },
    );

    testWidgets('inverts the glyph on the filled badge so it stays legible', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const AgentBadge(state: AgentState.blocked)),
      );
      final blockedIcon = tester.widget<Icon>(find.byType(Icon));

      await tester.pumpWidget(
        _host(const AgentBadge(state: AgentState.working)),
      );
      final workingIcon = tester.widget<Icon>(find.byType(Icon));

      expect(
        blockedIcon.color,
        isNot(AgentStateStyle.of(AgentState.blocked).color),
      );
      expect(workingIcon.color, AgentStateStyle.of(AgentState.working).color);
    });
  });

  group('AgentRow', () {
    testWidgets('shows the agent label and its state in words — there is '
        'room here, so nothing hides in a tooltip', (tester) async {
      await tester.pumpWidget(
        _host(AgentRow(agent: _agent(AgentState.blocked, label: 'opencode'))),
      );

      expect(find.text('opencode'), findsOneWidget);
      expect(find.text('Needs you'), findsOneWidget);
    });

    testWidgets('renders every state with its own wording', (tester) async {
      for (final state in AgentState.values) {
        await tester.pumpWidget(_host(AgentRow(agent: _agent(state))));

        expect(find.text(agentStateLabel(state)), findsOneWidget);
        expect(
          tester.widget<Icon>(find.byType(Icon)).icon,
          AgentStateStyle.of(state).icon,
        );
      }
    });

    testWidgets(
      'outlines only the blocked row, so the drawer opens onto the agent '
      'that is waiting',
      (tester) async {
        await tester.pumpWidget(
          _host(AgentRow(agent: _agent(AgentState.blocked))),
        );
        final blocked = _rowBorder(tester);

        for (final state in AgentState.values) {
          if (state == AgentState.blocked) continue;
          await tester.pumpWidget(_host(AgentRow(agent: _agent(state))));

          final other = _rowBorder(tester);
          expect(other.top.width, lessThan(blocked.top.width));
          expect(other.top.color, isNot(blocked.top.color));
        }
      },
    );

    testWidgets('truncates a long label instead of overflowing the drawer', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 200,
            child: AgentRow(agent: _agent(AgentState.idle, label: 'x' * 300)),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('x' * 300));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });
  });

  group('AgentRow — the context that tells two identical agents apart', () {
    testWidgets('renders the context it was given', (tester) async {
      await tester.pumpWidget(
        _host(
          AgentRow(
            agent: _agent(AgentState.blocked),
            contextLabel: 'Helm · Go Nexa',
          ),
        ),
      );

      expect(find.text('Helm · Go Nexa'), findsOneWidget);
    });

    testWidgets(
      'adds nothing at all without a context — an agent helm cannot place '
      'is still a real agent, and the row falls back to what it showed',
      (tester) async {
        await tester.pumpWidget(
          _host(AgentRow(agent: _agent(AgentState.idle, label: 'opencode'))),
        );
        final bare = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .toList();

        expect(bare, ['opencode', 'Idle']);
      },
    );

    testWidgets(
      'keeps the agent name primary and the context subordinate, so the '
      'row still reads name-first',
      (tester) async {
        await tester.pumpWidget(
          _host(
            AgentRow(
              agent: _agent(AgentState.idle, label: 'opencode'),
              contextLabel: 'Helm · Go Nexa',
            ),
          ),
        );

        final name = tester.widget<Text>(find.text('opencode')).style!;
        final ctx = tester.widget<Text>(find.text('Helm · Go Nexa')).style!;

        expect(ctx.fontSize!, lessThan(name.fontSize!));
        expect(ctx.color, isNot(name.color));
        expect(
          tester.getTopLeft(find.text('Helm · Go Nexa')).dy,
          greaterThan(tester.getTopLeft(find.text('opencode')).dy),
        );
      },
    );

    testWidgets(
      'truncates a real long context instead of overflowing a 280dp drawer '
      '— "Facturación Electrónica" is one of the owner\'s actual tabs',
      (tester) async {
        const long = 'Facturación Electrónica · Go Nexa';
        await tester.pumpWidget(
          _host(
            SizedBox(
              width: 280,
              child: AgentRow(
                agent: _agent(AgentState.working, label: 'opencode'),
                contextLabel: long,
              ),
            ),
          ),
        );

        final text = tester.widget<Text>(find.text(long));
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('still gives the tap 48dp with a context line present', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AgentRow(
            agent: _agent(AgentState.blocked),
            contextLabel: 'Helm · Go Nexa',
            onTap: () {},
          ),
        ),
      );

      expect(
        tester.getSize(find.byType(InkWell)).height,
        greaterThanOrEqualTo(48.0),
      );
    });

    testWidgets('leaves the blocked outline exactly as it was', (tester) async {
      await tester.pumpWidget(
        _host(AgentRow(agent: _agent(AgentState.blocked))),
      );
      final without = _rowBorder(tester);

      await tester.pumpWidget(
        _host(
          AgentRow(
            agent: _agent(AgentState.blocked),
            contextLabel: 'Helm · Go Nexa',
          ),
        ),
      );

      expect(_rowBorder(tester).top, without.top);
    });
  });

  group('AgentRow — tapping it is how the user reaches that agent', () {
    testWidgets('reports the tap to its owner', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(AgentRow(agent: _agent(AgentState.blocked), onTap: () => taps++)),
      );

      await tester.tap(find.byType(AgentRow));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets(
      'is inert without a handler — a row nobody can act on must not look '
      'or behave as though it were pressable',
      (tester) async {
        await tester.pumpWidget(
          _host(AgentRow(agent: _agent(AgentState.idle))),
        );

        await tester.tap(find.byType(AgentRow));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
      },
    );

    testWidgets(
      'gives the tap at least 48dp of height, because this is a phone held '
      'one-handed and the row beneath it belongs to a different agent',
      (tester) async {
        for (final state in AgentState.values) {
          await tester.pumpWidget(
            _host(AgentRow(agent: _agent(state), onTap: () {})),
          );

          expect(
            tester.getSize(find.byType(InkWell)).height,
            greaterThanOrEqualTo(48.0),
            reason: '$state row is too small to hit reliably',
          );
        }
      },
    );
  });
}

/// Alpha of the badge container's fill — how loudly it claims attention.
double _badgeFillAlpha(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .ancestor(of: find.byType(Icon), matching: find.byType(Container))
        .first,
  );
  final decoration = container.decoration! as BoxDecoration;
  return decoration.color!.a;
}

/// The [AgentRow] container's border.
Border _rowBorder(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .ancestor(of: find.byType(Icon), matching: find.byType(Container))
        .first,
  );
  return (container.decoration! as BoxDecoration).border! as Border;
}
