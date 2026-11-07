import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('commands', () {
    test('prompt', () {
      expect(const PiPrompt('hi').toJson(), {
        'type': 'prompt',
        'message': 'hi',
      });
      expect(
        const PiPrompt('hi', id: 'r1', streamingBehavior: 'steer').toJson(),
        {
          'type': 'prompt',
          'id': 'r1',
          'message': 'hi',
          'streamingBehavior': 'steer',
        },
      );
    });

    test('steer, abort, get_state', () {
      expect(const PiSteer('now').toJson(), {
        'type': 'steer',
        'message': 'now',
      });
      expect(const PiAbort(id: 'a').toJson(), {'type': 'abort', 'id': 'a'});
      expect(const PiGetState().toJson(), {'type': 'get_state'});
    });

    test('extension_ui_response variants', () {
      expect(const PiExtensionUiResponse.value('u1', 'Allow').toJson(), {
        'type': 'extension_ui_response',
        'id': 'u1',
        'value': 'Allow',
      });
      expect(const PiExtensionUiResponse.confirmed('u2', true).toJson(), {
        'type': 'extension_ui_response',
        'id': 'u2',
        'confirmed': true,
      });
      expect(const PiExtensionUiResponse.cancelled('u3').toJson(), {
        'type': 'extension_ui_response',
        'id': 'u3',
        'cancelled': true,
      });
    });
  });

  group('records', () {
    test('response ok', () {
      final r =
          parsePiRecord({
                'id': 'p',
                'type': 'response',
                'command': 'get_state',
                'success': true,
                'data': {'isStreaming': false},
              })
              as PiResponse;
      expect(r.id, 'p');
      expect(r.command, 'get_state');
      expect(r.success, isTrue);
      expect(r.data, {'isStreaming': false});
      expect(r.error, isNull);
    });

    test('response failure without id', () {
      final r =
          parsePiRecord({
                'type': 'response',
                'command': 'prompt',
                'success': false,
                'error': 'busy',
              })
              as PiResponse;
      expect(r.id, isNull);
      expect(r.success, isFalse);
      expect(r.error, 'busy');
    });

    test('agent lifecycle', () {
      expect(parsePiRecord({'type': 'agent_start'}), isA<PiAgentStart>());
      final end =
          parsePiRecord({
                'type': 'agent_end',
                'messages': [],
                'willRetry': true,
              })
              as PiAgentEnd;
      expect(end.willRetry, isTrue);
      expect(
        (parsePiRecord({'type': 'agent_end'}) as PiAgentEnd).willRetry,
        isFalse,
      );
      final settled =
          parsePiRecord({'type': 'agent_settled', 'aborted': true})
              as PiAgentSettled;
      expect(settled.aborted, isTrue);
    });

    test('message start / update / end', () {
      final s =
          parsePiRecord({
                'type': 'message_start',
                'message': {'role': 'assistant'},
              })
              as PiMessageStart;
      expect(s.message['role'], 'assistant');

      final u =
          parsePiRecord({
                'type': 'message_update',
                'usage': {},
                'assistantMessageEvent': {
                  'type': 'text_delta',
                  'contentIndex': 0,
                  'delta': 'Hel\u2028lo',
                },
              })
              as PiMessageUpdate;
      expect(u.eventType, 'text_delta');
      expect(u.textDelta, 'Hel\u2028lo');
      expect(u.contentIndex, 0);

      final t =
          parsePiRecord({
                'type': 'message_update',
                'assistantMessageEvent': {
                  'type': 'thinking_delta',
                  'delta': 'hm',
                },
              })
              as PiMessageUpdate;
      expect(t.eventType, 'thinking_delta');
      expect(t.textDelta, isNull, reason: 'only text_delta is reply text');

      final e =
          parsePiRecord({
                'type': 'message_end',
                'message': {'role': 'assistant'},
              })
              as PiMessageEnd;
      expect(e.message['role'], 'assistant');
    });

    test('tool execution', () {
      final s =
          parsePiRecord({
                'type': 'tool_execution_start',
                'toolCallId': 'c1',
                'toolName': 'bash',
                'args': {'command': 'ls'},
              })
              as PiToolExecutionStart;
      expect(s.toolCallId, 'c1');
      expect(s.toolName, 'bash');
      expect(s.args, {'command': 'ls'});

      final e =
          parsePiRecord({
                'type': 'tool_execution_end',
                'toolCallId': 'c1',
                'toolName': 'bash',
                'result': {'content': <Object?>[]},
                'isError': true,
              })
              as PiToolExecutionEnd;
      expect(e.isError, isTrue);
      expect(e.toolCallId, 'c1');
    });

    test('queue_update', () {
      final q =
          parsePiRecord({
                'type': 'queue_update',
                'steering': ['a'],
                'followUp': ['b', 'c'],
              })
              as PiQueueUpdate;
      expect(q.steering, ['a']);
      expect(q.followUp, ['b', 'c']);
    });

    test('extension_ui_request dialogs', () {
      final sel =
          parsePiRecord({
                'type': 'extension_ui_request',
                'id': 'u1',
                'method': 'select',
                'title': 'Allow?',
                'options': ['Allow', 'Block'],
                'timeout': 10000,
              })
              as PiExtensionUiRequest;
      expect(sel.isDialog, isTrue);
      expect(sel.options, ['Allow', 'Block']);
      expect(sel.timeoutMs, 10000);

      final c =
          parsePiRecord({
                'type': 'extension_ui_request',
                'id': 'u2',
                'method': 'confirm',
                'title': 'Sure?',
                'message': 'm',
              })
              as PiExtensionUiRequest;
      expect(c.isDialog, isTrue);
      expect(c.message, 'm');

      for (final m in ['input', 'editor']) {
        final r =
            parsePiRecord({
                  'type': 'extension_ui_request',
                  'id': 'x',
                  'method': m,
                  'title': 't',
                  'placeholder': 'p',
                  'prefill': 'f',
                })
                as PiExtensionUiRequest;
        expect(r.isDialog, isTrue);
        expect(r.placeholder, 'p');
        expect(r.prefill, 'f');
      }
    });

    test('extension_ui_request fire-and-forget', () {
      final n =
          parsePiRecord({
                'type': 'extension_ui_request',
                'id': 'u5',
                'method': 'notify',
                'message': 'blocked',
                'notifyType': 'warning',
              })
              as PiExtensionUiRequest;
      expect(n.isDialog, isFalse);
      expect(n.notifyType, 'warning');

      final defaults =
          parsePiRecord({
                'type': 'extension_ui_request',
                'id': 'u6',
                'method': 'notify',
                'message': 'x',
              })
              as PiExtensionUiRequest;
      expect(defaults.notifyType, 'info');

      final status =
          parsePiRecord({
                'type': 'extension_ui_request',
                'id': 'u7',
                'method': 'setStatus',
                'statusKey': 'k',
              })
              as PiExtensionUiRequest;
      expect(status.isDialog, isFalse);
      expect(status.method, 'setStatus');
    });

    test('unknown type is preserved, never thrown', () {
      final raw = <String, Object?>{'type': 'turn_start', 'extra': 1};
      final r = parsePiRecord(raw);
      expect(r, isA<UnknownRecord>());
      expect(r.raw, raw);
    });

    test('record without a type is preserved as unknown', () {
      final r = parsePiRecord({'hello': 'world'});
      expect(r, isA<UnknownRecord>());
      expect(r.raw, {'hello': 'world'});
    });

    test('known type with wrong field shapes degrades to unknown', () {
      final raw = <String, Object?>{
        'type': 'tool_execution_start',
        'toolName': 5,
      };
      final r = parsePiRecord(raw);
      expect(r, isA<UnknownRecord>());
      expect(r.raw, raw);
    });

    test('every parsed record keeps its raw map', () {
      final raw = <String, Object?>{'type': 'agent_start', 'future': 'field'};
      expect(parsePiRecord(raw).raw, raw);
    });
  });
}
