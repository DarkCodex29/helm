// Tests for the pure decision layer between an agent reading and what a
// user sees: which snapshots may carry a badge, which state wins when
// several agents compete, and what each state is called in words.
//
// A badge is a POSITIVE CLAIM about the host. Drawing one for a snapshot
// nobody measured would assert a state helm does not have — the same lie
// as an empty list, in a smaller pixel budget — so most of this file is
// about the cases that must produce NO badge at all.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/agent_snapshot.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';

AgentStatus _agent(AgentState state, {String target = 't'}) =>
    (target: target, label: target, state: state);

void main() {
  group('mostUrgentAgentState — no badge unless somebody measured one', () {
    test('nothing asked yet draws no badge', () {
      expect(mostUrgentAgentState(const AgentsNotProbed()), isNull);
    });

    test('a multiplexer that cannot track agents draws no badge', () {
      expect(
        mostUrgentAgentState(const AgentsUnsupported(MultiplexerId.tmux)),
        isNull,
      );
    });

    test('an unreachable agent server draws no badge', () {
      expect(mostUrgentAgentState(const AgentsUnreachable()), isNull);
    });

    test(
      'a known but empty reading draws no badge either — "nothing is '
      'happening" is not worth a pixel in the tab strip',
      () {
        expect(mostUrgentAgentState(const AgentsKnown([])), isNull);
      },
    );

    test('only a known, non-empty reading produces a badge', () {
      expect(
        mostUrgentAgentState(AgentsKnown([_agent(AgentState.idle)])),
        AgentState.idle,
      );
    });
  });

  group('mostUrgentAgentState — the loudest state wins', () {
    test('a single agent badges its own state, whatever it is', () {
      for (final state in AgentState.values) {
        expect(
          mostUrgentAgentState(AgentsKnown([_agent(state)])),
          state,
          reason: 'a lone $state agent must badge as $state',
        );
      }
    });

    test('blocked outranks every other state, in either order', () {
      for (final other in AgentState.values) {
        if (other == AgentState.blocked) continue;
        final blockedFirst = AgentsKnown([
          _agent(AgentState.blocked, target: 'a'),
          _agent(other, target: 'b'),
        ]);
        final blockedLast = AgentsKnown([
          _agent(other, target: 'a'),
          _agent(AgentState.blocked, target: 'b'),
        ]);

        expect(mostUrgentAgentState(blockedFirst), AgentState.blocked);
        expect(
          mostUrgentAgentState(blockedLast),
          AgentState.blocked,
          reason: 'position in the host list must not decide urgency',
        );
      }
    });

    test('picks the most urgent out of a full crowd', () {
      final all = AgentsKnown([
        for (final (i, state) in AgentState.values.indexed)
          _agent(state, target: 't$i'),
      ]);

      expect(mostUrgentAgentState(all), AgentState.blocked);
    });

    test('falls to the next state down when nothing is blocked', () {
      expect(
        mostUrgentAgentState(
          AgentsKnown([
            _agent(AgentState.idle, target: 'a'),
            _agent(AgentState.working, target: 'b'),
            _agent(AgentState.done, target: 'c'),
          ]),
        ),
        AgentState.working,
      );
    });
  });

  group('agentStateUrgency — one ordering, so the badge and the drawer '
      'can never disagree', () {
    test('ranks blocked > working > done > idle > unknown', () {
      const descending = [
        AgentState.blocked,
        AgentState.working,
        AgentState.done,
        AgentState.idle,
        AgentState.unknown,
      ];

      for (var i = 0; i < descending.length - 1; i++) {
        expect(
          agentStateUrgency(descending[i]),
          greaterThan(agentStateUrgency(descending[i + 1])),
          reason: '${descending[i].name} must outrank '
              '${descending[i + 1].name}',
        );
      }
    });

    test('gives every state a distinct rank, so ties are never invented', () {
      final ranks = AgentState.values.map(agentStateUrgency).toList();

      expect(ranks.toSet(), hasLength(AgentState.values.length));
    });
  });

  group('agentStateLabel — what a person actually reads', () {
    test(
      'blocked reads as a prompt to answer, not as a failure to '
      'investigate — it is the state this whole feature exists for',
      () {
        expect(agentStateLabel(AgentState.blocked), 'Needs you');
        expect(agentStateLabel(AgentState.blocked), isNot('Blocked'));
      },
    );

    test('every other state has its own plain-language wording', () {
      expect(agentStateLabel(AgentState.working), 'Working');
      expect(agentStateLabel(AgentState.done), 'Done');
      expect(agentStateLabel(AgentState.idle), 'Idle');
      expect(agentStateLabel(AgentState.unknown), 'Unknown');
    });

    test('no state falls through to an enum name or an empty string', () {
      for (final state in AgentState.values) {
        final label = agentStateLabel(state);
        expect(label, isNotEmpty);
        expect(label, isNot(state.name));
      }
    });
  });
}
