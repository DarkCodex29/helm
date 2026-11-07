@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

import 'support/ws_client.dart';

/// Real server + real PiSupervisor + the fake Pi subprocess + real clients.
/// Every wait is bounded; everything is closed in tearDown.
final _fakePi = File('../helm_protocol/tool/fake_pi.dart').absolute.path;

class Rig {
  late Directory tmp;
  late String token;
  late File piLog;
  late PiSupervisor sup;
  late AgentBridge bridge;
  late AgentServer server;
  final spawned = <Process>[];
  final clients = <TestClient>[];

  Future<void> up() async {
    tmp = await Directory.systemTemp.createTemp('helm_agentd_daemon_');
    piLog = File('${tmp.path}/pi.log');
    final store = TokenStore('${tmp.path}/token');
    await store.ensure();
    token = (await File('${tmp.path}/token').readAsString()).trim();
    sup = PiSupervisor(
      executable: Platform.resolvedExecutable,
      args: [_fakePi],
      starter: (exe, args) async {
        final p = await Process.start(
          exe,
          args,
          environment: {'HELM_FAKE_PI_LOG': piLog.path},
        );
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
    server = AgentServer(bridge: bridge, tokens: store, port: 0);
    await sup.start().timeout(const Duration(seconds: 15));
    bridge.start();
    await server.start().timeout(bound);
  }

  Future<Client> client() async {
    final c = await TestClient.connect(server.port);
    clients.add(c);
    await c.hello(token);
    final ready = await c.next();
    expect(ready.message, isA<ReadyMessage>());
    return Client(c);
  }

  Future<void> down() async {
    for (final c in clients) {
      await c.dispose();
    }
    await server.close().timeout(bound, onTimeout: () {});
    bridge.dispose();
    await sup.shutdown().timeout(const Duration(seconds: 15), onTimeout: () {});
    for (final p in spawned) {
      p.kill(ProcessSignal.sigkill);
    }
    await tmp.delete(recursive: true);
  }

  List<Map<String, Object?>> piReceived() => piLog.existsSync()
      ? [
          for (final l in piLog.readAsLinesSync())
            if (l.trim().isNotEmpty)
              Map<String, Object?>.from(jsonDecode(l) as Map),
        ]
      : [];
}

/// Collects every decoded frame and waits for conditions on them.
class Client {
  Client(this.ws);
  final TestClient ws;
  var _cursor = 0;
  final all = <ServerFrame>[];

  void _pull() {
    while (_cursor < ws.frames.length) {
      all.add(decodeServerFrame(ws.frames[_cursor++]));
    }
  }

  List<ServerMessage> get messages {
    _pull();
    return [for (final f in all) f.message];
  }

  Future<void> waitFor(
    bool Function(List<ServerMessage>) cond,
    String what,
  ) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (!cond(messages)) {
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('no $what; got ${messages.map((m) => m.type)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void send(ClientMessage m) => ws.sendMessage(m);

  String get text =>
      messages.whereType<MessageDeltaMessage>().map((m) => m.delta).join();
  List<AgentState> get states =>
      messages.whereType<AgentStateMessage>().map((m) => m.state).toList();
}

void main() {
  late Rig rig;
  setUp(() async {
    rig = Rig();
    await rig.up();
  });
  tearDown(() => rig.down());

  bool done(List<ServerMessage> m) => m.any((x) => x is MessageDoneMessage);

  test('send hello: ack, coalesced deltas, done, state transitions', () async {
    final c = await rig.client();
    c.send(const ClientSend(text: 'hello', requestId: 'r1'));
    await c.waitFor(
      (m) => done(m) && m.whereType<AgentStateMessage>().length >= 2,
      'done + idle',
    );
    const full = 'Hello from fake\u2028pi.';
    expect(c.text, full);
    expect(c.messages.whereType<MessageDoneMessage>().single.text, full);
    final ack = c.messages.whereType<AckMessage>().single;
    expect((ack.requestId, ack.duplicate), ('r1', false));
    expect(c.states.first, AgentState.thinking);
    expect(c.states.last, AgentState.idle);
    // delta text always precedes message_done
    final types = c.messages.map((m) => m.type).toList();
    expect(
      types.lastIndexOf('message_delta'),
      lessThan(types.indexOf('message_done')),
    );
    // seq is strictly increasing from 1
    final seqs = c.all.map((f) => f.seq).toList();
    expect(seqs.first, 1);
    for (var i = 1; i < seqs.length; i++) {
      expect(seqs[i], seqs[i - 1] + 1);
    }
  });

  test('tool run shows working and an activity pair', () async {
    final c = await rig.client();
    c.send(const ClientSend(text: 'tool:read', requestId: 'r1'));
    await c.waitFor(done, 'done');
    await c.waitFor((m) => c.states.contains(AgentState.idle), 'idle');
    final acts = c.messages.whereType<ActivityMessage>().toList();
    expect([for (final a in acts) a.phase], ['start', 'end']);
    expect(acts.first.tool, 'read');
    expect(c.states, contains(AgentState.working));
    expect(c.text, 'Ran read.');
  });

  test('a duplicate requestId is acked and never reaches Pi', () async {
    final c = await rig.client();
    c.send(const ClientSend(text: 'hello', requestId: 'same'));
    await c.waitFor(
      (m) => done(m) && c.states.contains(AgentState.idle),
      'first run',
    );
    c.send(const ClientSend(text: 'hello', requestId: 'same'));
    await c.waitFor((m) => m.whereType<AckMessage>().length == 2, 'second ack');
    expect(c.messages.whereType<AckMessage>().last.duplicate, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final prompts = rig.piReceived().where((r) => r['type'] == 'prompt');
    expect(prompts, hasLength(1));
  });

  test(
    'ask answered by client B while A is connected: one ask_resolved each',
    () async {
      final a = await rig.client();
      final b = await rig.client();
      a.send(const ClientSend(text: 'ask:confirm', requestId: 'r1'));
      await a.waitFor((m) => m.any((x) => x is AskMessage), 'ask on A');
      await b.waitFor((m) => m.any((x) => x is AskMessage), 'ask on B');
      expect(a.states.last, AgentState.needsYou);
      final ask = b.messages.whereType<AskMessage>().single;
      b.send(ClientUiResponse.confirmed(ask.requestId, true));
      await a.waitFor(done, 'done on A');
      await b.waitFor(done, 'done on B');
      expect(a.messages.whereType<AskResolvedMessage>(), hasLength(1));
      expect(b.messages.whereType<AskResolvedMessage>(), hasLength(1));
      expect(a.text, 'Confirmed.');
      // A answers late: told it is resolved, nothing forwarded again.
      a.send(ClientUiResponse.confirmed(ask.requestId, false));
      await a.waitFor(
        (m) => m.whereType<ErrorMessage>().any((e) => e.code == 'ask_resolved'),
        'late answer error',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        rig.piReceived().where((r) => r['type'] == 'extension_ui_response'),
        hasLength(1),
      );
    },
  );

  test('a client that connects mid-ask receives it again', () async {
    final a = await rig.client();
    a.send(const ClientSend(text: 'ask:select', requestId: 'r1'));
    await a.waitFor((m) => m.any((x) => x is AskMessage), 'ask');
    final late = await rig.client();
    await late.waitFor((m) => m.any((x) => x is AskMessage), 'replayed ask');
    expect(
      (late.messages.first as ReadyMessage).agentState,
      AgentState.needsYou,
    );
  });

  test('burst:500 arrives in far fewer frames with identical text', () async {
    final c = await rig.client();
    c.send(const ClientSend(text: 'burst:500', requestId: 'r1'));
    await c.waitFor(done, 'done');
    final expected = [for (var i = 0; i < 500; i++) 'd$i '].join();
    expect(c.text, expected);
    final deltas = c.messages.whereType<MessageDeltaMessage>().length;
    expect(deltas, lessThan(250), reason: '$deltas delta frames for 500');
    expect(c.messages.whereType<MessageDoneMessage>().single.text, expected);
  });

  test('crash: interrupted, restarting, then usable again', () async {
    final c = await rig.client();
    c.send(const ClientSend(text: 'crash', requestId: 'r1'));
    await c.waitFor(
      (m) => m.any((x) => x is InterruptedMessage),
      'interrupted',
    );
    await c.waitFor(
      (m) => c.states.contains(AgentState.restarting),
      'restarting',
    );
    // wait until the supervisor is back, then a fresh prompt works
    await c.waitFor(
      (m) => c.states.isNotEmpty && c.states.last == AgentState.idle,
      'idle after restart',
    );
    final before = c.messages.whereType<MessageDoneMessage>().length;
    c.send(const ClientSend(text: 'hello', requestId: 'r2'));
    await c.waitFor(
      (m) => m.whereType<MessageDoneMessage>().length > before,
      'reply after restart',
    );
    expect(
      c.messages.whereType<MessageDoneMessage>().last.text,
      'Hello from fake\u2028pi.',
    );
  });

  test('send while Pi is down is an error carrying the requestId', () async {
    final c = await rig.client();
    await rig.sup.shutdown();
    await c.waitFor((m) => c.states.contains(AgentState.stopped), 'stopped');
    c.send(const ClientSend(text: 'hello', requestId: 'lost'));
    await c.waitFor((m) => m.any((x) => x is ErrorMessage), 'error');
    final e = c.messages.whereType<ErrorMessage>().single;
    expect(e.code, 'not_running');
    expect(e.message, contains('lost'));
  });

  test(
    'an unauthenticated client gets no agent data while another works',
    () async {
      final good = await rig.client();
      final bad = await TestClient.connect(rig.server.port);
      rig.clients.add(bad);
      await bad.hello('wrong');
      good.send(const ClientSend(text: 'hello', requestId: 'r1'));
      await good.waitFor(done, 'done');
      expect(await bad.closeCode(), 4401);
      expect(bad.frames, isEmpty);
    },
  );
}
