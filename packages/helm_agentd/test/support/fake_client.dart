import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart';

/// A [ClientSink] that records what the bridge sent it.
class FakeClient implements ClientSink {
  final messages = <ServerMessage>[];
  var open = true;

  @override
  bool get isOpen => open;

  @override
  void send(ServerMessage message) {
    if (open) messages.add(message);
  }

  @override
  void close([int code = 1000, String reason = '']) => open = false;

  Iterable<T> of<T extends ServerMessage>() => messages.whereType<T>();

  /// Compact labels, for order assertions.
  List<String> get labels => [
    for (final m in messages)
      switch (m) {
        MessageDeltaMessage(:final delta) => 'delta:$delta',
        MessageDoneMessage(:final text) => 'done:$text',
        AgentStateMessage(:final state) => 'state:${state.wire}',
        ActivityMessage(:final tool, :final phase) => 'activity:$tool:$phase',
        AskMessage(:final requestId) => 'ask:$requestId',
        AskResolvedMessage(:final requestId) => 'resolved:$requestId',
        ErrorMessage(:final code) => 'error:$code',
        AckMessage(:final duplicate) => 'ack:$duplicate',
        _ => m.type,
      },
  ];
}
