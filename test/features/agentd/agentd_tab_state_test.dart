import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm/features/agentd/domain/agent_state.dart';
import 'package:helm/features/agentd/domain/agentd_connection_state.dart';
import 'package:helm/features/agentd/domain/agentd_tab_state.dart';

AgentdTabState _map(AgentdConnectionState s) => agentdTabStateFor(AsyncData(s));

void _known(AgentdTabState s, AgentdUiState expected) {
  expect(s, isA<AgentdTabKnown>());
  expect((s as AgentdTabKnown).state, expected);
}

void main() {
  group('connection states that were not measured are Absent', () {
    test('loading', () {
      expect(agentdTabStateFor(const AsyncLoading()), isA<AgentdTabAbsent>());
    });
    test('error while resolving', () {
      expect(
        agentdTabStateFor(AsyncError('x', StackTrace.empty)),
        isA<AgentdTabAbsent>(),
      );
    });
    test('disconnected', () {
      expect(_map(const AgentdDisconnected()), isA<AgentdTabAbsent>());
    });
    test('connecting', () {
      expect(_map(const AgentdConnecting()), isA<AgentdTabAbsent>());
    });
    test('reconnecting', () {
      expect(
        _map(const AgentdReconnecting(attempt: 1, delay: Duration(seconds: 1))),
        isA<AgentdTabAbsent>(),
      );
    });
    test('failed with no token', () {
      expect(
        _map(const AgentdFailed(AgentdFailure.noToken)),
        isA<AgentdTabAbsent>(),
      );
    });
  });

  group('connected agent states', () {
    test('needsYou', () {
      _known(
        _map(const AgentdConnected(AgentState.needsYou)),
        AgentdUiState.needsYou,
      );
    });
    test('working', () {
      _known(
        _map(const AgentdConnected(AgentState.working)),
        AgentdUiState.working,
      );
    });
    test('thinking', () {
      _known(
        _map(const AgentdConnected(AgentState.thinking)),
        AgentdUiState.thinking,
      );
    });
    test('idle', () {
      _known(_map(const AgentdConnected(AgentState.idle)), AgentdUiState.idle);
    });
    test('starting is working', () {
      _known(
        _map(const AgentdConnected(AgentState.starting)),
        AgentdUiState.working,
      );
    });
    test('restarting is working', () {
      _known(
        _map(const AgentdConnected(AgentState.restarting)),
        AgentdUiState.working,
      );
    });
    test('stopped is unavailable', () {
      final s = _map(const AgentdConnected(AgentState.stopped));
      expect(s, isA<AgentdTabUnavailable>());
      expect((s as AgentdTabUnavailable).hint, 'Agent stopped');
    });
    test('error is unavailable', () {
      final s = _map(const AgentdConnected(AgentState.error));
      expect((s as AgentdTabUnavailable).hint, 'Agent stopped');
    });
    test('unknown is Absent', () {
      expect(
        _map(const AgentdConnected(AgentState.unknown)),
        isA<AgentdTabAbsent>(),
      );
    });
  });

  group('fatal failures carry a short hint', () {
    test('unauthorized', () {
      final s = _map(const AgentdFailed(AgentdFailure.unauthorized));
      expect(
        (s as AgentdTabUnavailable).hint,
        'Agent daemon refused this phone',
      );
    });
    test('protocol mismatch', () {
      final s = _map(const AgentdFailed(AgentdFailure.protocolMismatch));
      expect(
        (s as AgentdTabUnavailable).hint,
        'Update helm or the agent daemon',
      );
    });
  });

  test('agentdTabStateProvider maps the live connection state', () async {
    final c = ProviderContainer(
      overrides: [
        agentdClientStatesProvider.overrideWith(
          (ref, id) => Stream.value(const AgentdConnected(AgentState.working)),
        ),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(agentdTabStateProvider('p'), (_, _) {});
    // Loading first: never claims a state that was not measured.
    expect(sub.read(), isA<AgentdTabAbsent>());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    _known(sub.read(), AgentdUiState.working);
  });
}
