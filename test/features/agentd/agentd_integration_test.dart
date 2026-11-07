@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/domain/agentd_connection_state.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;

/// The real [AgentdClient] against a real in-process [AgentServer] +
/// [AgentBridge] + [PiSupervisor] driving the fake Pi over loopback.
///
/// Every wait is bounded and everything is closed in tearDown.
const _bound = Duration(seconds: 10);

/// The `dart` binary used to run the fake Pi.
///
/// NOT `Platform.resolvedExecutable`: under `flutter test` that is the
/// Flutter tester, which cannot run a script. `flutter test` exports
/// FLUTTER_ROOT, whose bundled SDK holds the dart binary; failing that, the
/// `dart` found on PATH (CI: subosito/flutter-action puts it there).
String _dartBinary() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final candidate = File(
      [
        root,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'dart',
      ].join(Platform.pathSeparator),
    );
    if (candidate.existsSync()) return candidate.path;
  }
  return 'dart';
}

final _fakePi = File('packages/helm_protocol/tool/fake_pi.dart').absolute.path;

class _Rig {
  late Directory tmp;
  late String token;
  late PiSupervisor sup;
  late AgentBridge bridge;
  late TokenStore store;
  AgentServer? server;
  final spawned = <Process>[];
  final clients = <AgentdClient>[];

  Future<void> up() async {
    tmp = await Directory.systemTemp.createTemp('helm_agentd_client_');
    // Temp dirs are 0755 on Linux CI; the daemon's token store refuses a
    // directory others can enter, so make it owner-only first.
    final chmod = await Process.run('chmod', ['700', tmp.path]);
    expect(chmod.exitCode, 0);
    store = TokenStore('${tmp.path}/token');
    await store.ensure();
    token = (await File('${tmp.path}/token').readAsString()).trim();
    sup = PiSupervisor(
      executable: _dartBinary(),
      args: [_fakePi],
      starter: (exe, args) async {
        final p = await Process.start(exe, args);
        spawned.add(p);
        return p;
      },
      initialBackoff: const Duration(milliseconds: 50),
      maxBackoff: const Duration(milliseconds: 200),
      stdinGrace: const Duration(seconds: 3),
      termGrace: const Duration(seconds: 3),
      commandTimeout: const Duration(seconds: 10),
    );
    bridge = AgentBridge(supervisor: sup);
    await sup.start().timeout(const Duration(seconds: 20));
    bridge.start();
    await startServer(0);
  }

  Future<void> startServer(int port) async {
    final s = AgentServer(bridge: bridge, tokens: store, port: port);
    await s.start().timeout(_bound);
    server = s;
  }

  Future<void> stopServer() async {
    final s = server;
    server = null;
    await s?.close().timeout(_bound, onTimeout: () {});
  }

  int get port => server!.port;

  AgentdClient client({String? withToken}) {
    final c = AgentdClient(
      endpoint: AgentdEndpoint(host: '127.0.0.1', port: port),
      token: withToken ?? token,
      backoff: (_) => const Duration(milliseconds: 100),
    );
    clients.add(c);
    return c;
  }

  Future<void> down() async {
    for (final c in clients) {
      await c.close().timeout(_bound, onTimeout: () {});
    }
    await stopServer();
    bridge.dispose();
    await sup.shutdown().timeout(const Duration(seconds: 15), onTimeout: () {});
    for (final p in spawned) {
      p.kill(ProcessSignal.sigkill);
    }
    await tmp.delete(recursive: true);
  }
}

Future<void> _until(
  AgentdClient c,
  bool Function(AgentdConnectionState) test,
) async {
  if (test(c.state)) return;
  await c.states.firstWhere(test).timeout(_bound);
}

void main() {
  late _Rig rig;

  setUp(() async {
    rig = _Rig();
    await rig.up();
    addTearDown(rig.down);
  });

  test('connects, sends a prompt and streams the reply', () async {
    final client = rig.client();
    final messages = <proto.ServerMessage>[];
    client.messages.listen(messages.add);
    final done = client.messages
        .firstWhere((m) => m is proto.MessageDoneMessage)
        .timeout(_bound);

    client.connect();
    await _until(client, (s) => s is AgentdConnected);

    await client.send('hello').timeout(_bound);
    final end = await done as proto.MessageDoneMessage;

    final deltas = messages
        .whereType<proto.MessageDeltaMessage>()
        .map((d) => d.delta)
        .join();
    expect(end.text, isNotEmpty);
    expect(deltas, end.text);
  });

  test('a wrong token fails as unauthorized and is not retried', () async {
    final client = rig.client(withToken: 'W' * 43);
    final states = <AgentdConnectionState>[];
    client.states.listen(states.add);

    client.connect();
    await _until(client, (s) => s is AgentdFailed);
    expect(client.state, const AgentdFailed(AgentdFailure.unauthorized));

    // Long enough for several 100 ms backoffs, had any been scheduled.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(states.whereType<AgentdReconnecting>(), isEmpty);
    expect(client.state, const AgentdFailed(AgentdFailure.unauthorized));
  });

  test('reconnects and is ready again after a server restart', () async {
    final client = rig.client();
    client.connect();
    await _until(client, (s) => s is AgentdConnected);
    final port = rig.port;

    await rig.stopServer();
    await _until(client, (s) => s is AgentdReconnecting);

    await rig.startServer(port);
    await _until(client, (s) => s is AgentdConnected);

    await client.send('hello').timeout(_bound);
  });
}
