import 'dart:convert';

import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

ClientMessage rt(ClientMessage m) =>
    decodeClientMessage(encodeClientMessage(m));

ServerMessage srt(ServerMessage m) {
  final frame = decodeServerFrame(encodeServerFrame(7, m));
  expect(frame.seq, 7);
  return frame.message;
}

void main() {
  group('client messages', () {
    test('hello round trips and its toString hides the token', () {
      final m = rt(const ClientHello(token: 'sekret', protocol: 1));
      expect(m, isA<ClientHello>());
      expect((m as ClientHello).token, 'sekret');
      expect(m.protocol, 1);
      expect(m.toString(), isNot(contains('sekret')));
    });

    test('send, steer, get_state round trip', () {
      final s = rt(const ClientSend(text: 'hi\u2028x', requestId: 'r1'));
      expect((s as ClientSend).text, 'hi\u2028x');
      expect(s.requestId, 'r1');
      final st = rt(const ClientSteer(text: 'go', requestId: 'r2'));
      expect((st as ClientSteer).requestId, 'r2');
      expect(rt(const ClientGetState()), isA<ClientGetState>());
    });

    test('abort with and without requestId', () {
      expect((rt(const ClientAbort()) as ClientAbort).requestId, isNull);
      expect(
        (rt(const ClientAbort(requestId: 'a')) as ClientAbort).requestId,
        'a',
      );
    });

    test('ui_response: value, confirmed, cancelled', () {
      final v =
          rt(const ClientUiResponse.value('q', 'Allow')) as ClientUiResponse;
      expect(
        [v.requestId, v.value, v.confirmed, v.cancelled],
        ['q', 'Allow', null, false],
      );
      final c =
          rt(const ClientUiResponse.confirmed('q', false)) as ClientUiResponse;
      expect([c.value, c.confirmed, c.cancelled], [null, false, false]);
      final x = rt(const ClientUiResponse.cancelled('q')) as ClientUiResponse;
      expect([x.value, x.confirmed, x.cancelled], [null, null, true]);
    });

    test('unknown type, bad shapes and non-objects become Unknown', () {
      for (final text in [
        '{"type":"teleport"}',
        '{"type":"send","text":5,"requestId":"r"}',
        '{"type":"send","text":"x"}',
        '{"type":"hello","token":"t"}',
        '{"type":"ui_response","requestId":"q"}',
        '{"type":7}',
        '[]',
        'not json',
        '',
      ]) {
        expect(
          decodeClientMessage(text),
          isA<UnknownClientMessage>(),
          reason: text,
        );
      }
      expect(
        (decodeClientMessage('{"type":"teleport"}') as UnknownClientMessage)
            .type,
        'teleport',
      );
    });
  });

  group('server frames', () {
    test('every message type round trips', () {
      expect(
        (srt(const ReadyMessage(protocol: 1, agentState: AgentState.idle))
                as ReadyMessage)
            .agentState,
        AgentState.idle,
      );
      final ack =
          srt(const AckMessage(requestId: 'r', duplicate: true)) as AckMessage;
      expect([ack.requestId, ack.duplicate], ['r', true]);
      expect(
        (srt(const AgentStateMessage(AgentState.needsYou)) as AgentStateMessage)
            .state,
        AgentState.needsYou,
      );
      final d =
          srt(const MessageDeltaMessage(messageId: 'm1', delta: 'a\u2029'))
              as MessageDeltaMessage;
      expect([d.messageId, d.delta], ['m1', 'a\u2029']);
      final done =
          srt(
                const MessageDoneMessage(
                  messageId: 'm1',
                  text: 'full',
                  stopped: true,
                  error: 'boom',
                ),
              )
              as MessageDoneMessage;
      expect([done.text, done.stopped, done.error], ['full', true, 'boom']);
      final plain =
          srt(const MessageDoneMessage(messageId: 'm', text: 't'))
              as MessageDoneMessage;
      expect([plain.stopped, plain.error], [null, null]);
      final act =
          srt(
                const ActivityMessage(
                  messageId: 'm1',
                  tool: 'bash',
                  phase: 'end',
                  isError: true,
                ),
              )
              as ActivityMessage;
      expect(
        [act.messageId, act.tool, act.phase, act.isError],
        ['m1', 'bash', 'end', true],
      );
      final ask =
          srt(
                const AskMessage(
                  requestId: 'u',
                  method: 'select',
                  title: 'T',
                  message: 'M',
                  options: ['a', 'b'],
                  placeholder: 'p',
                  timeoutMs: 500,
                ),
              )
              as AskMessage;
      expect(
        [
          ask.method,
          ask.title,
          ask.message,
          ask.options,
          ask.placeholder,
          ask.timeoutMs,
        ],
        [
          'select',
          'T',
          'M',
          ['a', 'b'],
          'p',
          500,
        ],
      );
      expect(
        (srt(const AskResolvedMessage('u')) as AskResolvedMessage).requestId,
        'u',
      );
      final q =
          srt(const QueueMessage(steering: ['s'], followUp: ['f']))
              as QueueMessage;
      expect(
        [q.steering, q.followUp],
        [
          ['s'],
          ['f'],
        ],
      );
      expect(srt(const InterruptedMessage()), isA<InterruptedMessage>());
      final e =
          srt(const ErrorMessage(code: 'c', message: 'm')) as ErrorMessage;
      expect([e.code, e.message], ['c', 'm']);
    });

    test('error requestId round trips, and is omitted when null', () {
      final withId =
          srt(const ErrorMessage(code: 'c', message: 'm', requestId: 'r1'))
              as ErrorMessage;
      expect(withId.requestId, 'r1');
      final without =
          srt(const ErrorMessage(code: 'c', message: 'm')) as ErrorMessage;
      expect(without.requestId, isNull);
      final json =
          jsonDecode(
                encodeServerFrame(
                  1,
                  const ErrorMessage(code: 'c', message: 'm'),
                ),
              )
              as Map;
      expect(json.keys, unorderedEquals(['type', 'seq', 'code', 'message']));
      final wire =
          jsonDecode(
                encodeServerFrame(
                  1,
                  const ErrorMessage(code: 'c', message: 'm', requestId: 'r1'),
                ),
              )
              as Map;
      expect(wire['requestId'], 'r1');
    });

    test('error decoding tolerates a missing or mistyped requestId', () {
      final old = decodeServerFrame('{"type":"error","code":"c","message":"m"}')
          .message as ErrorMessage;
      expect(old.requestId, isNull);
      final odd = decodeServerFrame(
        '{"type":"error","code":"c","message":"m","requestId":7}',
      ).message;
      expect(odd, isA<ErrorMessage>());
      expect((odd as ErrorMessage).requestId, isNull);
    });

    test('optional fields are omitted from the wire', () {
      final json =
          jsonDecode(
                encodeServerFrame(
                  1,
                  const MessageDoneMessage(messageId: 'm', text: 't'),
                ),
              )
              as Map;
      expect(json.keys, unorderedEquals(['type', 'seq', 'messageId', 'text']));
    });

    test('unknown type keeps raw map and seq; garbage degrades safely', () {
      final f = decodeServerFrame('{"type":"future","seq":4,"x":1}');
      expect(f.seq, 4);
      final u = f.message as UnknownServerMessage;
      expect(u.type, 'future');
      expect(u.raw['x'], 1);
      expect(decodeServerFrame('nope').message, isA<UnknownServerMessage>());
      expect(
        decodeServerFrame('{"type":"ack","seq":1}').message,
        isA<UnknownServerMessage>(),
      );
      expect(
        decodeServerFrame(
          '{"type":"agent_state","seq":1,"state":"zzz"}',
        ).message,
        isA<UnknownServerMessage>(),
      );
    });

    test('agent states use the documented wire names', () {
      expect(AgentState.needsYou.wire, 'needs_you');
      expect(
        {for (final s in AgentState.values) s.wire},
        {
          'starting',
          'restarting',
          'error',
          'stopped',
          'needs_you',
          'idle',
          'working',
          'thinking',
        },
      );
    });
  });
}
