import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart';

/// A bridge with no Pi behind it: records what the server hands over.
class StubBridge implements Bridge {
  final attached = <ClientSink>[];
  final detached = <ClientSink>[];
  final received = <ClientMessage>[];

  @override
  void attach(ClientSink client) {
    attached.add(client);
    client.send(
      const ReadyMessage(
        protocol: phoneProtocolVersion,
        agentState: AgentState.idle,
      ),
    );
  }

  @override
  void detach(ClientSink client) => detached.add(client);

  @override
  void onMessage(ClientSink client, ClientMessage message) {
    received.add(message);
    // Echo so a test can observe per-connection seq.
    client.send(AckMessage(requestId: '${received.length}', duplicate: false));
  }
}
