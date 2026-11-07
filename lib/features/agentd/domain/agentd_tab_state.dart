import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_state.dart';
import 'agentd_connection_state.dart';

/// The agent states the tab badge can show from the daemon.
enum AgentdUiState { needsYou, working, thinking, idle }

/// What the daemon says about one tab's agent, as the tab strip needs it.
///
/// Never claims a state that was not measured: everything short of a
/// connected, understood reading is [AgentdTabAbsent], and the herdr lane
/// keeps rendering as before.
sealed class AgentdTabState {
  const AgentdTabState();
}

class AgentdTabAbsent extends AgentdTabState {
  const AgentdTabAbsent();
}

class AgentdTabKnown extends AgentdTabState {
  const AgentdTabKnown(this.state);
  final AgentdUiState state;
}

/// The daemon is reachable in principle but cannot tell; [hint] is short,
/// user-facing and never carries a token or host.
class AgentdTabUnavailable extends AgentdTabState {
  const AgentdTabUnavailable(this.hint);
  final String hint;
}

/// Pure mapping from the connection state to the tab state.
AgentdTabState agentdTabStateFor(AsyncValue<AgentdConnectionState> async) {
  final s = async.valueOrNull;
  if (s == null) return const AgentdTabAbsent();
  return switch (s) {
    AgentdDisconnected() ||
    AgentdConnecting() ||
    AgentdReconnecting() => const AgentdTabAbsent(),
    AgentdConnected(:final agentState) => switch (agentState) {
      AgentState.needsYou => const AgentdTabKnown(AgentdUiState.needsYou),
      AgentState.working ||
      AgentState.starting ||
      AgentState.restarting => const AgentdTabKnown(AgentdUiState.working),
      AgentState.thinking => const AgentdTabKnown(AgentdUiState.thinking),
      AgentState.idle => const AgentdTabKnown(AgentdUiState.idle),
      AgentState.stopped ||
      AgentState.error => const AgentdTabUnavailable('Agent stopped'),
      AgentState.unknown => const AgentdTabAbsent(),
    },
    AgentdFailed(:final reason) => switch (reason) {
      AgentdFailure.unauthorized => const AgentdTabUnavailable(
        'Agent daemon refused this phone',
      ),
      AgentdFailure.protocolMismatch => const AgentdTabUnavailable(
        'Update helm or the agent daemon',
      ),
      AgentdFailure.noToken => const AgentdTabAbsent(),
    },
  };
}
