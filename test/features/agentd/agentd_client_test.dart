@Timeout(Duration(seconds: 30))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/domain/agent_state.dart';
import 'package:helm/features/agentd/domain/agentd_connection_state.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;

import 'support/fakes.dart';

const _token = 'FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfakeFAK';
const _cmdTimeout = Duration(seconds: 15);
const _bound = Duration(seconds: 5);

void main() {
  late FakeConnector connector;
  late ManualTimers timers;
  late AgentdClient client;
  late List<AgentdConnectionState> states;
  late List<proto.ServerMessage> messages;
  late List<AgentdDiagnostic> diagnostics;
  var idCounter = 0;

  setUp(() {
    idCounter = 0;
    connector = FakeConnector();
    timers = ManualTimers();
    client = AgentdClient(
      endpoint: const AgentdEndpoint(host: '127.0.0.1', port: 7480),
      token: _token,
      connect: connector.call,
      timers: timers.call,
      commandTimeout: _cmdTimeout,
      newRequestId: () => 'req-${++idCounter}',
    );
    states = [];
    messages = [];
    diagnostics = [];
    client.states.listen(states.add);
    client.messages.listen(messages.add);
    client.diagnostics.listen(diagnostics.add);
    addTearDown(client.close);
  });

  Future<FakeChannel> connectAndReady() async {
    client.connect();
    await pump();
    connector.last.serveReady();
    await pump();
    return connector.last;
  }

  /// Drops the live connection and fires the reconnect timer.
  Future<void> dropAndReconnect(FakeChannel c, {int? code}) async {
    c.serverClose(code);
    await pump();
    final t = timers.all.lastWhere(
      (t) =>
          t.isActive && t.duration.inSeconds <= 30 && t.duration != _cmdTimeout,
    );
    t.fire();
    await pump();
  }

  group('handshake', () {
    test('hello is the first frame and carries token + protocol', () async {
      client.connect();
      await pump();

      expect(connector.uris.single.toString(), 'ws://127.0.0.1:7480');
      final first = connector.last.clientFrames.first;
      expect(first, isA<proto.ClientHello>());
      first as proto.ClientHello;
      expect(first.token, _token);
      expect(first.protocol, proto.phoneProtocolVersion);
      expect(connector.last.sent, hasLength(1));
      expect(client.state, isA<AgentdConnecting>());
    });

    test('ready makes it connected with the agent state', () async {
      await connectAndReady();
      expect(client.state, const AgentdConnected(AgentState.idle));
      expect(states, [
        const AgentdConnecting(),
        const AgentdConnected(AgentState.idle),
      ]);
    });

    test('agent_state updates the connected state', () async {
      final c = await connectAndReady();
      c.serve(const proto.AgentStateMessage(proto.AgentState.needsYou));
      await pump();
      expect(client.state, const AgentdConnected(AgentState.needsYou));
    });

    test('ready with another protocol version is fatal', () async {
      client.connect();
      await pump();
      connector.last.serve(
        const proto.ReadyMessage(
          protocol: 2,
          agentState: proto.AgentState.idle,
        ),
      );
      await pump();
      expect(client.state, const AgentdFailed(AgentdFailure.protocolMismatch));
      expect(connector.last.closedByClient, isTrue);
    });

    test('toString never shows the token', () {
      expect(client.toString(), isNot(contains(_token)));
    });
  });

  group('reconnect', () {
    test('default backoff is 1,2,4,8,16,30,30 seconds', () {
      expect(
        [for (var a = 1; a <= 7; a++) AgentdClient.defaultBackoff(a).inSeconds],
        [1, 2, 4, 8, 16, 30, 30],
      );
      expect(AgentdClient.defaultBackoff(500).inSeconds, 30);
    });

    test('drops without a typed message keep growing the delay', () async {
      client.connect();
      await pump();
      for (var i = 0; i < 3; i++) {
        connector.last.serverClose(1006);
        await pump();
        final delay = Duration(seconds: 1 << i);
        expect(client.state, AgentdReconnecting(attempt: i + 1, delay: delay));
        timers.one(delay).fire();
        await pump();
      }
      expect(connector.channels, hasLength(4));
    });

    test('a connect error is retried with backoff', () async {
      connector.failWith = const FormatException('refused');
      client.connect();
      await pump();
      expect(
        client.state,
        const AgentdReconnecting(attempt: 1, delay: Duration(seconds: 1)),
      );
      connector.failWith = null;
      timers.one(const Duration(seconds: 1)).fire();
      await pump();
      connector.last.serveReady();
      await pump();
      expect(client.state, isA<AgentdConnected>());
    });

    test('backoff resets only after a typed server message', () async {
      client.connect();
      await pump();
      // Two bare drops: 1s then 2s.
      connector.last.serverClose(1006);
      await pump();
      timers.one(const Duration(seconds: 1)).fire();
      await pump();
      connector.last.serverClose(1006);
      await pump();
      expect(
        client.state,
        const AgentdReconnecting(attempt: 2, delay: Duration(seconds: 2)),
      );
      timers.one(const Duration(seconds: 2)).fire();
      await pump();

      // Garbage and unknown types do NOT reset.
      connector.last.serveRaw('not json');
      connector.last.serveRaw('{"type":"from_the_future","seq":1}');
      await pump();
      connector.last.serverClose(1006);
      await pump();
      expect(
        client.state,
        const AgentdReconnecting(attempt: 3, delay: Duration(seconds: 4)),
      );
      timers.one(const Duration(seconds: 4)).fire();
      await pump();

      // A typed message does.
      connector.last.serveReady();
      await pump();
      connector.last.serverClose(1006);
      await pump();
      expect(
        client.state,
        const AgentdReconnecting(attempt: 1, delay: Duration(seconds: 1)),
      );
    });

    test('4401 is fatal: unauthorized, no retry', () async {
      client.connect();
      await pump();
      connector.last.serverClose(4401);
      await pump();

      expect(client.state, const AgentdFailed(AgentdFailure.unauthorized));
      expect(timers.all.where((t) => t.isActive), isEmpty);
      expect(connector.channels, hasLength(1));
      await expectLater(
        client.send('x'),
        throwsA(isA<AgentdCommandException>()),
      );
    });

    test('4400 is fatal: protocolMismatch, no retry', () async {
      client.connect();
      await pump();
      connector.last.serverClose(4400);
      await pump();

      expect(client.state, const AgentdFailed(AgentdFailure.protocolMismatch));
      expect(timers.all.where((t) => t.isActive), isEmpty);
      expect(connector.channels, hasLength(1));
    });

    test('close() stops reconnecting and is idempotent', () async {
      client.connect();
      await pump();
      connector.last.serverClose(1006);
      await pump();
      final pending = timers.one(const Duration(seconds: 1));

      await client.close();
      await client.close();
      pending.fire(); // already cancelled: must do nothing
      await pump();

      expect(pending.cancelled, isTrue);
      expect(connector.channels, hasLength(1));
      expect(client.state, isA<AgentdDisconnected>());
      client.connect(); // final: ignored
      await pump();
      expect(connector.channels, hasLength(1));
    });

    test('close() closes the live socket', () async {
      final c = await connectAndReady();
      await client.close();
      expect(c.closedByClient, isTrue);
    });

    test('connect() twice does not open two sockets', () async {
      client.connect();
      client.connect();
      await pump();
      expect(connector.channels, hasLength(1));
    });
  });

  group('commands', () {
    test('send resolves on the matching ack', () async {
      final c = await connectAndReady();
      var done = false;
      final f = client.send('hi').then((_) => done = true);
      await pump();

      final frame = c.clientFrames.last as proto.ClientSend;
      expect(frame.text, 'hi');
      expect(frame.requestId, 'req-1');
      expect(done, isFalse);

      c.serve(const proto.AckMessage(requestId: 'other', duplicate: false));
      await pump();
      expect(done, isFalse, reason: 'a foreign ack must not resolve it');

      c.serve(const proto.AckMessage(requestId: 'req-1', duplicate: false));
      await f.timeout(_bound);
      expect(done, isTrue);
    });

    test('duplicate:true counts as success', () async {
      final c = await connectAndReady();
      final f = client.send('hi');
      await pump();
      c.serve(const proto.AckMessage(requestId: 'req-1', duplicate: true));
      await f.timeout(_bound);
    });

    test('an error naming the request fails it with the code', () async {
      final c = await connectAndReady();
      final f = client.send('hi');
      final expectation = expectLater(
        f,
        throwsA(
          isA<AgentdCommandException>()
              .having((e) => e.kind, 'kind', AgentdCommandError.rejected)
              .having((e) => e.code, 'code', 'not_running')
              .having((e) => e.requestId, 'requestId', 'req-1'),
        ),
      );
      await pump();
      c.serve(
        const proto.ErrorMessage(
          code: 'not_running',
          message: 'request req-1: Pi is not running',
        ),
      );
      await expectation.timeout(_bound);
    });

    test('an error for another request leaves it pending', () async {
      final c = await connectAndReady();
      var done = false;
      unawaited(client.send('hi').then((_) => done = true, onError: (_) {}));
      await pump();
      c.serve(const proto.ErrorMessage(code: 'x', message: 'request zzz: no'));
      await pump();
      expect(done, isFalse);
      expect(timers.active(_cmdTimeout), hasLength(1));
    });

    test('an error whose text mentions another id does not fail it', () async {
      final c = await connectAndReady();
      var done = false;
      unawaited(client.send('hi').then((_) => done = true, onError: (_) {}));
      final other = client.send('there');
      final otherResult = expectLater(
        other,
        throwsA(
          isA<AgentdCommandException>().having(
            (e) => e.requestId,
            'requestId',
            'req-2',
          ),
        ),
      );
      await pump();
      // About req-2, but the body names req-1 first.
      c.serve(
        const proto.ErrorMessage(
          code: 'rejected',
          message: 'request req-2: Pi said "request req-1 is odd"',
          requestId: 'req-2',
        ),
      );
      await otherResult.timeout(_bound);
      expect(done, isFalse);
      expect(timers.active(_cmdTimeout), hasLength(1));
    });

    test('text of another command in the body is never scanned', () async {
      final c = await connectAndReady();
      var done = false;
      unawaited(client.send('hi').then((_) => done = true, onError: (_) {}));
      await pump();
      c.serve(
        const proto.ErrorMessage(
          code: 'x',
          message: 'failure while handling request req-1 elsewhere',
        ),
      );
      await pump();
      expect(done, isFalse);
      expect(timers.active(_cmdTimeout), hasLength(1));
    });

    test('an error with requestId fails exactly that command', () async {
      final c = await connectAndReady();
      final a = client.send('a');
      final b = client.send('b');
      var bDone = false;
      unawaited(b.then((_) => bDone = true, onError: (_) {}));
      final expectation = expectLater(
        a,
        throwsA(
          isA<AgentdCommandException>()
              .having((e) => e.kind, 'kind', AgentdCommandError.rejected)
              .having((e) => e.requestId, 'requestId', 'req-1'),
        ),
      );
      await pump();
      c.serve(
        const proto.ErrorMessage(
          code: 'rejected',
          message: 'unrelated wording',
          requestId: 'req-1',
        ),
      );
      await expectation.timeout(_bound);
      expect(bDone, isFalse);
    });

    test('an error with an unknown requestId fails nothing', () async {
      final c = await connectAndReady();
      var done = false;
      unawaited(client.send('hi').then((_) => done = true, onError: (_) {}));
      await pump();
      c.serve(
        const proto.ErrorMessage(
          code: 'x',
          message: 'request req-1: looks like yours',
          requestId: 'zzz',
        ),
      );
      await pump();
      expect(done, isFalse);
    });

    test(
      'an answer failure carrying the ask id fails the answer now',
      () async {
        final c = await connectAndReady();
        final bad = client.answer('ask-9', confirmed: true);
        final expectation = expectLater(
          bad,
          throwsA(
            isA<AgentdCommandException>()
                .having((e) => e.code, 'code', 'not_running')
                .having((e) => e.requestId, 'requestId', 'ask-9'),
          ),
        );
        await pump();
        c.serve(
          const proto.ErrorMessage(
            code: 'not_running',
            message: 'Pi is not running',
            requestId: 'ask-9',
          ),
        );
        await expectation.timeout(_bound);
        expect(timers.active(_cmdTimeout), isEmpty);
      },
    );

    test('times out when no ack arrives', () async {
      await connectAndReady();
      final f = client.send('hi');
      final expectation = expectLater(
        f,
        throwsA(
          isA<AgentdCommandException>().having(
            (e) => e.kind,
            'kind',
            AgentdCommandError.timeout,
          ),
        ),
      );
      await pump();
      timers.one(_cmdTimeout).fire();
      await expectation.timeout(_bound);
    });

    test(
      'a command is not left behind after its ack (timer cancelled)',
      () async {
        final c = await connectAndReady();
        final f = client.send('hi');
        await pump();
        c.serve(const proto.AckMessage(requestId: 'req-1', duplicate: false));
        await f.timeout(_bound);
        expect(timers.active(_cmdTimeout), isEmpty);
      },
    );

    test('steer, abort and answer use the right frames', () async {
      final c = await connectAndReady();
      unawaited(client.steer('left').catchError((_) {}));
      unawaited(client.abort().catchError((_) {}));
      unawaited(client.answer('ask-1', value: 'yes').catchError((_) {}));
      await pump();

      final frames = c.clientFrames.skip(1).toList();
      expect(frames[0], isA<proto.ClientSteer>());
      expect((frames[0] as proto.ClientSteer).text, 'left');
      expect(frames[1], isA<proto.ClientAbort>());
      expect((frames[1] as proto.ClientAbort).requestId, isNotNull);
      expect(frames[2], isA<proto.ClientUiResponse>());
      final r = frames[2] as proto.ClientUiResponse;
      expect(r.requestId, 'ask-1');
      expect(r.value, 'yes');
    });

    test('answer resolves on ask_resolved and fails on an error', () async {
      final c = await connectAndReady();
      final ok = client.answer('ask-1', confirmed: true);
      await pump();
      c.serve(const proto.AskResolvedMessage('ask-1'));
      await ok.timeout(_bound);

      final bad = client.answer('ask-2', cancelled: true);
      final expectation = expectLater(
        bad,
        throwsA(
          isA<AgentdCommandException>().having(
            (e) => e.code,
            'code',
            'ask_resolved',
          ),
        ),
      );
      await pump();
      c.serve(
        const proto.ErrorMessage(
          code: 'ask_resolved',
          message: 'ask ask-2 was already answered',
        ),
      );
      await expectation.timeout(_bound);
    });

    test('answer needs exactly one of value/confirmed/cancelled', () {
      expect(() => client.answer('a'), throwsArgumentError);
      expect(
        () => client.answer('a', value: 'x', confirmed: true),
        throwsArgumentError,
      );
    });

    test('a command issued before ready is sent after ready', () async {
      client.connect();
      await pump();
      final f = client.send('early');
      await pump();
      expect(
        connector.last.clientFrames.whereType<proto.ClientSend>(),
        isEmpty,
      );

      connector.last.serveReady();
      await pump();
      expect(
        connector.last.clientFrames.whereType<proto.ClientSend>().single.text,
        'early',
      );
      connector.last.serve(
        const proto.AckMessage(requestId: 'req-1', duplicate: false),
      );
      await f.timeout(_bound);
    });

    test('send before connect() fails fast', () async {
      await expectLater(
        client.send('x'),
        throwsA(
          isA<AgentdCommandException>().having(
            (e) => e.kind,
            'kind',
            AgentdCommandError.notConnected,
          ),
        ),
      );
    });

    test('close() fails what is in flight', () async {
      await connectAndReady();
      final f = client.send('hi');
      final expectation = expectLater(
        f,
        throwsA(
          isA<AgentdCommandException>().having(
            (e) => e.kind,
            'kind',
            AgentdCommandError.closed,
          ),
        ),
      );
      await pump();
      await client.close();
      await expectation.timeout(_bound);
      expect(timers.active(_cmdTimeout), isEmpty);
    });
  });

  group('in-flight commands across a reconnect', () {
    test(
      'is retried ONCE with the SAME requestId after the next ready',
      () async {
        final c1 = await connectAndReady();
        var acked = false;
        final f = client.send('hi').then((_) => acked = true);
        await pump();
        expect(c1.clientFrames.whereType<proto.ClientSend>(), hasLength(1));

        await dropAndReconnect(c1, code: 1006);
        final c2 = connector.last;
        expect(
          c2.clientFrames.whereType<proto.ClientSend>(),
          isEmpty,
          reason: 'not before ready',
        );
        c2.serveReady();
        await pump();

        final retry = c2.clientFrames.whereType<proto.ClientSend>().single;
        expect(retry.requestId, 'req-1');
        expect(retry.text, 'hi');
        expect(acked, isFalse);

        c2.serve(const proto.AckMessage(requestId: 'req-1', duplicate: true));
        await f.timeout(_bound);
        expect(acked, isTrue);
      },
    );

    test('gives up with a typed error on the second disconnect', () async {
      final c1 = await connectAndReady();
      final f = client.send('hi');
      final expectation = expectLater(
        f,
        throwsA(
          isA<AgentdCommandException>()
              .having((e) => e.kind, 'kind', AgentdCommandError.disconnected)
              .having((e) => e.requestId, 'requestId', 'req-1'),
        ),
      );
      await pump();

      await dropAndReconnect(c1, code: 1006);
      connector.last.serveReady();
      await pump();
      expect(
        connector.last.clientFrames.whereType<proto.ClientSend>(),
        hasLength(1),
      );

      connector.last.serverClose(1006); // second drop, never acked
      await pump();
      await expectation.timeout(_bound);

      // And it is not sent a third time.
      timers.all
          .lastWhere((t) => t.isActive && t.duration != _cmdTimeout)
          .fire();
      await pump();
      connector.last.serveReady();
      await pump();
      expect(
        connector.last.clientFrames.whereType<proto.ClientSend>(),
        isEmpty,
      );
    });

    test('an acked command is not resent after a reconnect', () async {
      final c1 = await connectAndReady();
      final f = client.send('hi');
      await pump();
      c1.serve(const proto.AckMessage(requestId: 'req-1', duplicate: false));
      await f.timeout(_bound);

      await dropAndReconnect(c1, code: 1006);
      connector.last.serveReady();
      await pump();
      expect(
        connector.last.clientFrames.whereType<proto.ClientSend>(),
        isEmpty,
      );
    });

    test('a fatal close fails in-flight commands', () async {
      final c1 = await connectAndReady();
      final f = client.send('hi');
      final expectation = expectLater(
        f,
        throwsA(isA<AgentdCommandException>()),
      );
      await pump();
      c1.serverClose(4401);
      await expectation.timeout(_bound);
    });
  });

  group('adversarial', () {
    test('frames and a close from a stale channel are ignored', () async {
      final old = await connectAndReady();
      await dropAndReconnect(old);
      final fresh = connector.last;
      expect(fresh, isNot(same(old)));
      fresh.serveReady();
      await pump();
      final before = List.of(messages);
      final stateBefore = client.state;
      final send = client.send('x');
      unawaited(send.then((_) {}, onError: (_) {}));
      await pump();

      old.serve(const proto.AckMessage(requestId: 'req-1', duplicate: false));
      old.serve(const proto.AgentStateMessage(proto.AgentState.needsYou));
      old.serve(
        const proto.ErrorMessage(code: 'x', message: 'm', requestId: 'req-1'),
      );
      await pump();
      expect(messages, before);
      expect(client.state, stateBefore);
      expect(timers.active(_cmdTimeout), hasLength(1)); // still pending

      // A late close from the old channel does not drop the new one.
      old.closeCode = closeUnauthorized;
      await pump();
      expect(client.state, isA<AgentdConnected>());
      expect(fresh.closedByClient, isFalse);
    });

    test('close() during an in-flight connect leaves nothing open', () async {
      final gate = Completer<AgentdChannel>();
      final c = AgentdClient(
        endpoint: const AgentdEndpoint(host: '127.0.0.1', port: 7480),
        token: _token,
        connect: (_) => gate.future,
        timers: timers.call,
      );
      c.connect();
      await pump();
      await c.close();
      final late = FakeChannel();
      gate.complete(late);
      await pump();
      expect(late.closedByClient, isTrue);
      expect(late.sent, isEmpty);
      expect(timers.all.where((t) => t.isActive), isEmpty);
      expect(c.state, isA<AgentdDisconnected>());
    });

    test('a connect that finishes after the timeout is closed', () async {
      final gate = Completer<AgentdChannel>();
      final c = AgentdClient(
        endpoint: const AgentdEndpoint(host: '127.0.0.1', port: 7480),
        token: _token,
        connect: (_) => gate.future,
        timers: timers.call,
        connectTimeout: const Duration(seconds: 10),
      );
      addTearDown(c.close);
      c.connect();
      await pump();
      timers.one(const Duration(seconds: 10)).fire();
      await pump();
      expect(c.state, isA<AgentdReconnecting>());
      final late = FakeChannel();
      gate.complete(late);
      await pump();
      expect(late.closedByClient, isTrue);
      expect(late.sent, isEmpty);
      expect(c.state, isA<AgentdReconnecting>());
    });

    test('a duplicate ready does not re-send sent commands', () async {
      final c = await connectAndReady();
      unawaited(client.send('hi').then((_) {}, onError: (_) {}));
      await pump();
      final sentBefore = c.sent.length;
      c.serveReady();
      await pump();
      expect(c.sent, hasLength(sentBefore));
      expect(c.clientFrames.whereType<proto.ClientSend>(), hasLength(1));
    });
  });

  group('stream and seq', () {
    test('agent messages are broadcast; acks are internal', () async {
      final c = await connectAndReady();
      c.serve(const proto.MessageDeltaMessage(messageId: 'm1', delta: 'He'));
      c.serve(const proto.AckMessage(requestId: 'x', duplicate: false));
      c.serve(const proto.MessageDoneMessage(messageId: 'm1', text: 'He'));
      await pump();

      expect(messages.map((m) => m.type), [
        'ready',
        'message_delta',
        'message_done',
      ]);
    });

    test('a seq gap is reported with expected and got', () async {
      final c = await connectAndReady(); // seq 1
      c.serve(const proto.AgentStateMessage(proto.AgentState.working)); // 2
      c.serve(const proto.AgentStateMessage(proto.AgentState.idle), seq: 5);
      await pump();

      expect(diagnostics, hasLength(1));
      final gap = diagnostics.single as SeqGap;
      expect(gap.expected, 3);
      expect(gap.got, 5);

      // It resynchronises on what it saw: 6 is fine, 8 is a new gap.
      c.serve(const proto.AgentStateMessage(proto.AgentState.idle), seq: 6);
      c.serve(const proto.AgentStateMessage(proto.AgentState.idle), seq: 8);
      await pump();
      expect(diagnostics, hasLength(2));
      expect((diagnostics.last as SeqGap).expected, 7);
    });

    test('seq restarts on a new connection without a false gap', () async {
      final c1 = await connectAndReady();
      c1.serve(const proto.AgentStateMessage(proto.AgentState.idle));
      await dropAndReconnect(c1, code: 1006);
      connector.last.serveReady(); // seq 1 again
      await pump();
      expect(diagnostics, isEmpty);
    });

    test('a frame without a usable seq is not a gap', () async {
      final c = await connectAndReady();
      c.serveRaw('{"type":"agent_state","state":"idle"}');
      await pump();
      expect(diagnostics, isEmpty);
    });
  });
}
