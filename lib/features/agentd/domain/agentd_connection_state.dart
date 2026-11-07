import 'agent_state.dart';

/// Why a connection ended for good (never retried).
enum AgentdFailure {
  /// The daemon refused the token (close code 4401).
  unauthorized,

  /// The daemon does not speak this protocol version (close code 4400, or a
  /// `ready` announcing another version).
  protocolMismatch,

  /// No token is stored for this profile.
  noToken,
}

/// Connection to `helm-agentd`, as the UI sees it.
sealed class AgentdConnectionState {
  const AgentdConnectionState();
}

class AgentdDisconnected extends AgentdConnectionState {
  const AgentdDisconnected();
  @override
  String toString() => 'disconnected';
}

class AgentdConnecting extends AgentdConnectionState {
  const AgentdConnecting();
  @override
  String toString() => 'connecting';
}

class AgentdConnected extends AgentdConnectionState {
  const AgentdConnected(this.agentState);
  final AgentState agentState;

  @override
  bool operator ==(Object other) =>
      other is AgentdConnected && other.agentState == agentState;
  @override
  int get hashCode => Object.hash('connected', agentState);
  @override
  String toString() => 'connected(${agentState.name})';
}

class AgentdReconnecting extends AgentdConnectionState {
  const AgentdReconnecting({required this.attempt, required this.delay});

  /// 1-based count of consecutive failures.
  final int attempt;
  final Duration delay;

  @override
  bool operator ==(Object other) =>
      other is AgentdReconnecting &&
      other.attempt == attempt &&
      other.delay == delay;
  @override
  int get hashCode => Object.hash('reconnecting', attempt, delay);
  @override
  String toString() => 'reconnecting(#$attempt in ${delay.inMilliseconds}ms)';
}

/// Fatal: not retried.
class AgentdFailed extends AgentdConnectionState {
  const AgentdFailed(this.reason);
  final AgentdFailure reason;

  @override
  bool operator ==(Object other) =>
      other is AgentdFailed && other.reason == reason;
  @override
  int get hashCode => Object.hash('failed', reason);
  @override
  String toString() => 'failed(${reason.name})';
}
