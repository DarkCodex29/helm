/// The single derived agent state the daemon reports. Mirrors the daemon's
/// `AgentState`; [unknown] covers a value this app does not know yet.
enum AgentState {
  idle,
  thinking,
  working,
  needsYou,
  starting,
  restarting,
  stopped,
  error,
  unknown;

  /// Maps the daemon's wire string (`needs_you`, ...) to a state.
  static AgentState fromWire(String? wire) => switch (wire) {
    'idle' => idle,
    'thinking' => thinking,
    'working' => working,
    'needs_you' => needsYou,
    'starting' => starting,
    'restarting' => restarting,
    'stopped' => stopped,
    'error' => error,
    _ => unknown,
  };
}
