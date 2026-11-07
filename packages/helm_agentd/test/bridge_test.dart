@Timeout(Duration(seconds: 30))
library;

import 'dart:async';

import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

import 'support/fake_client.dart';
import 'support/fakes.dart';

const _flush = Duration(milliseconds: 50);

Map<String, Object?> _delta(String t) => {
  'type': 'message_update',
  'assistantMessageEvent': {
    'type': 'text_delta',
    'contentIndex': 0,
    'delta': t,
  },
};

Map<String, Object?> _msgStart([String role = 'assistant']) => {
  'type': 'message_start',
  'message': {'role': role, 'content': <Object?>[]},
};

Map<String, Object?> _msgEnd(String text, {String stop = 'stop'}) => {
  'type': 'message_end',
  'message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'stopReason': stop,
  },
};

Map<String, Object?> _ask(String id, {String method = 'confirm'}) => {
  'type': 'extension_ui_request',
  'id': id,
  'method': method,
  'title': 'Run it?',
  'message': 'rm -rf build',
  if (method == 'select') 'options': ['a', 'b'],
};

void main() {
  late Harness h;
  late FakeTimers coalesceTimers;
  late AgentBridge bridge;
  late FakeClient a;
  late FakeClient b;
  late FakeProc proc;

  Future<void> boot({bool respond = true}) async {
    h = Harness();
    coalesceTimers = FakeTimers();
    proc = FakeProc();
    if (respond) {
      proc.autoData['prompt'] = <String, Object?>{};
      proc.autoData['steer'] = <String, Object?>{};
      proc.autoData['abort'] = <String, Object?>{};
    }
    h.script.add(proc);
    bridge = AgentBridge(
      supervisor: h.sup,
      timerFactory: coalesceTimers.create,
    );
    await h.sup.start();
    bridge.start();
    a = FakeClient();
    b = FakeClient();
    bridge.attach(a);
  }

  tearDown(() async {
    bridge.dispose();
    await h.sup.shutdown().timeout(const Duration(seconds: 10));
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> emit(Map<String, Object?> r) async {
    proc.emit(r);
    await settle();
    await settle();
  }

  void fireFlush() {
    final t = coalesceTimers.pending(_flush).firstOrNull;
    if (t != null) t.fire();
  }

  group('ready and state', () {
    test('attach sends ready with the current state', () async {
      await boot();
      final ready = a.messages.single as ReadyMessage;
      expect(ready.protocol, phoneProtocolVersion);
      expect(ready.agentState, AgentState.idle);
    });

    test('agent_state is broadcast on change only', () async {
      await boot();
      bridge.attach(b);
      await emit({'type': 'agent_start'});
      await emit({'type': 'agent_start'}); // no change
      expect(a.labels.where((l) => l.startsWith('state:')), ['state:thinking']);
      await emit({
        'type': 'tool_execution_start',
        'toolCallId': 't1',
        'toolName': 'bash',
      });
      await emit({
        'type': 'tool_execution_end',
        'toolCallId': 't1',
        'toolName': 'bash',
        'isError': false,
      });
      await emit({'type': 'agent_settled'});
      expect(a.labels.where((l) => l.startsWith('state:')), [
        'state:thinking',
        'state:working',
        'state:thinking',
        'state:idle',
      ]);
      expect(b.labels.where((l) => l.startsWith('state:')), hasLength(4));
    });

    test('get_state answers the asking client only', () async {
      await boot();
      bridge.attach(b);
      final before = b.messages.length;
      bridge.onMessage(a, const ClientGetState());
      expect(a.of<AgentStateMessage>().single.state, AgentState.idle);
      expect(b.messages, hasLength(before));
    });

    test('a client that detached receives nothing more', () async {
      await boot();
      bridge.detach(a);
      await emit({'type': 'agent_start'});
      expect(a.messages, hasLength(1)); // only ready
    });

    test('unknown client messages get an error that echoes nothing', () async {
      await boot();
      bridge.onMessage(a, const UnknownClientMessage({'type': 'dance'}));
      final e = a.of<ErrorMessage>().single;
      expect(e.code, 'unknown_message');
      expect(e.message, isNot(contains('dance')));
    });
  });

  group('deltas and activity', () {
    test(
      'coalesces deltas, flushes before message_done, never reorders',
      () async {
        await boot();
        await emit(_msgStart());
        await emit(_delta('Hel'));
        await emit(_delta('lo\u2028'));
        await emit(_delta('world'));
        expect(a.of<MessageDeltaMessage>(), isEmpty, reason: 'held back');
        await emit(_msgEnd('Hello\u2028world'));
        expect(a.labels.skip(1), [
          'delta:Hello\u2028world',
          'done:Hello\u2028world',
        ]);
        final d = a.of<MessageDeltaMessage>().single;
        final done = a.of<MessageDoneMessage>().single;
        expect(done.messageId, d.messageId);
      },
    );

    test('the timer flushes after 50 ms', () async {
      await boot();
      await emit(_msgStart());
      await emit(_delta('a'));
      expect(coalesceTimers.pending(_flush), hasLength(1));
      fireFlush();
      expect(a.labels.last, 'delta:a');
      await emit(_delta('b'));
      fireFlush();
      expect(a.of<MessageDeltaMessage>().map((m) => m.delta), ['a', 'b']);
    });

    test('activity flushes pending text first', () async {
      await boot();
      await emit(_msgStart());
      await emit(_delta('before'));
      await emit({
        'type': 'tool_execution_start',
        'toolCallId': 't1',
        'toolName': 'read',
      });
      final l = a.labels;
      expect(
        l.indexOf('delta:before'),
        lessThan(l.indexOf('activity:read:start')),
      );
      await emit({
        'type': 'tool_execution_end',
        'toolCallId': 't1',
        'toolName': 'read',
        'isError': true,
      });
      final end = a.of<ActivityMessage>().last;
      expect(end.phase, 'end');
      expect(end.isError, isTrue);
    });

    test('two messages get different ids', () async {
      await boot();
      for (final t in ['one', 'two']) {
        await emit(_msgStart());
        await emit(_delta(t));
        await emit(_msgEnd(t));
      }
      final ids = a.of<MessageDoneMessage>().map((m) => m.messageId).toSet();
      expect(ids, hasLength(2));
    });

    test('thinking deltas and user messages are not forwarded', () async {
      await boot();
      await emit(_msgStart('user'));
      await emit({
        'type': 'message_end',
        'message': {'role': 'user', 'content': 'hi'},
      });
      await emit(_msgStart());
      await emit({
        'type': 'message_update',
        'assistantMessageEvent': {'type': 'thinking_delta', 'delta': 'hmm'},
      });
      await emit(_msgEnd('ok'));
      expect(a.of<MessageDeltaMessage>(), isEmpty);
      expect(a.of<MessageDoneMessage>().single.text, 'ok');
    });

    test('an aborted message is reported as stopped', () async {
      await boot();
      await emit(_msgStart());
      await emit(_msgEnd('par', stop: 'aborted'));
      expect(a.of<MessageDoneMessage>().single.stopped, isTrue);
    });

    test('an errored message carries its error text', () async {
      await boot();
      await emit(_msgStart());
      await emit({
        'type': 'message_end',
        'message': {
          'role': 'assistant',
          'content': <Object?>[],
          'stopReason': 'error',
          'errorMessage': 'overloaded',
        },
      });
      final m = a.of<MessageDoneMessage>().single;
      expect(m.error, 'overloaded');
      expect(m.text, '');
    });

    test('queue_update is broadcast and re-sent to new clients', () async {
      await boot();
      await emit({
        'type': 'queue_update',
        'steering': ['s1'],
        'followUp': ['f1'],
      });
      expect(a.of<QueueMessage>().single.steering, ['s1']);
      bridge.attach(b);
      expect(b.of<QueueMessage>().single.followUp, ['f1']);
    });
  });

  group('asks', () {
    test('a dialog request becomes an ask, state needs_you', () async {
      await boot();
      await emit(_ask('q1', method: 'select'));
      final ask = a.of<AskMessage>().single;
      expect(ask.requestId, 'q1');
      expect(ask.method, 'select');
      expect(ask.title, 'Run it?');
      expect(ask.options, ['a', 'b']);
      expect(a.labels, contains('state:needs_you'));
    });

    test('notify and other fire-and-forget requests produce nothing', () async {
      await boot();
      await emit({
        'type': 'extension_ui_request',
        'id': 'n1',
        'method': 'notify',
        'message': 'hi',
      });
      await emit({
        'type': 'extension_ui_request',
        'id': 'n2',
        'method': 'setStatus',
      });
      expect(a.messages, hasLength(1));
    });

    test(
      'first answer wins and is forwarded once; second gets ask_resolved',
      () async {
        await boot();
        bridge.attach(b);
        await emit(_ask('q1'));
        bridge.onMessage(b, const ClientUiResponse.confirmed('q1', true));
        bridge.onMessage(a, const ClientUiResponse.confirmed('q1', false));
        await settle();
        await settle();
        final forwarded = proc.written
            .where((w) => w['type'] == 'extension_ui_response')
            .toList();
        expect(forwarded, hasLength(1));
        expect(forwarded.single['id'], 'q1');
        expect(forwarded.single['confirmed'], true);
        expect(a.of<AskResolvedMessage>().single.requestId, 'q1');
        expect(b.of<AskResolvedMessage>().single.requestId, 'q1');
        final late = a.of<ErrorMessage>().single;
        expect(late.code, 'ask_resolved');
        expect(late.requestId, 'q1');
        expect(b.of<ErrorMessage>(), isEmpty);
        expect(a.of<AgentStateMessage>().last.state, AgentState.idle);
      },
    );

    test('value and cancelled answers map onto Pi responses', () async {
      await boot();
      await emit(_ask('q1', method: 'select'));
      bridge.onMessage(a, const ClientUiResponse.value('q1', 'b'));
      await emit(_ask('q2'));
      bridge.onMessage(a, const ClientUiResponse.cancelled('q2'));
      await settle();
      await settle();
      final w = proc.written
          .where((w) => w['type'] == 'extension_ui_response')
          .toList();
      expect(w[0]['value'], 'b');
      expect(w[1]['cancelled'], true);
    });

    test(
      'answering an ask nobody asked is unknown_ask, nothing forwarded',
      () async {
        await boot();
        bridge.onMessage(a, const ClientUiResponse.confirmed('ghost', true));
        expect(a.of<ErrorMessage>().single.code, 'unknown_ask');
        expect(a.of<ErrorMessage>().single.requestId, 'ghost');
        expect(
          proc.written.where((w) => w['type'] == 'extension_ui_response'),
          isEmpty,
        );
      },
    );

    test('a client attaching later gets pending asks re-sent', () async {
      await boot();
      await emit(_ask('q1'));
      bridge.attach(b);
      expect(b.labels.take(2), ['ready', 'ask:q1']);
      expect(
        (b.messages.first as ReadyMessage).agentState,
        AgentState.needsYou,
      );
    });

    test('a resolved ask is not re-sent', () async {
      await boot();
      await emit(_ask('q1'));
      bridge.onMessage(a, const ClientUiResponse.confirmed('q1', true));
      bridge.attach(b);
      expect(b.of<AskMessage>(), isEmpty);
    });

    test('supervisor restart resolves pending asks', () async {
      await boot();
      await emit(_ask('q1'));
      proc.exit(1);
      await until(
        () => a.labels.contains('resolved:q1'),
        what: 'ask resolved on restart',
      );
      expect(a.labels, contains('state:restarting'));
      bridge.onMessage(a, const ClientUiResponse.confirmed('q1', true));
      expect(a.of<ErrorMessage>().last.code, 'ask_resolved');
    });
  });

  group('interrupted', () {
    test(
      'a crash mid-run flushes text, then interrupted, then restarting',
      () async {
        await boot();
        await emit({'type': 'agent_start'});
        await emit(_msgStart());
        await emit(_delta('partial'));
        proc.exit(1);
        await until(
          () => a.labels.contains('state:restarting'),
          what: 'restarting',
        );
        final l = a.labels;
        expect(l.indexOf('delta:partial'), lessThan(l.indexOf('interrupted')));
        expect(l, contains('interrupted'));
      },
    );
  });

  group('send', () {
    String ids() => proc.written.map((w) => w['type']).join(',');

    test('send becomes a prompt and is acked after Pi accepts', () async {
      await boot(respond: false);
      bridge.onMessage(a, const ClientSend(text: 'hi', requestId: 'r1'));
      await settle();
      final cmd = proc.written.singleWhere((w) => w['type'] == 'prompt');
      expect(cmd['message'], 'hi');
      expect(cmd.containsKey('streamingBehavior'), isFalse);
      expect(a.of<AckMessage>(), isEmpty, reason: 'not accepted yet');
      proc.emit({
        'type': 'response',
        'id': cmd['id'],
        'command': 'prompt',
        'success': true,
      });
      await until(() => a.of<AckMessage>().isNotEmpty, what: 'ack');
      expect(a.of<AckMessage>().single.requestId, 'r1');
      expect(a.of<AckMessage>().single.duplicate, isFalse);
    });

    test('send while busy steers', () async {
      await boot();
      await emit({'type': 'agent_start'});
      bridge.onMessage(a, const ClientSend(text: 'also', requestId: 'r1'));
      await until(() => a.of<AckMessage>().isNotEmpty, what: 'ack');
      final cmd = proc.written.singleWhere((w) => w['type'] == 'prompt');
      expect(cmd['streamingBehavior'], 'steer');
    });

    test(
      'a duplicate requestId is acked as duplicate and not forwarded',
      () async {
        await boot();
        bridge.onMessage(a, const ClientSend(text: 'hi', requestId: 'r1'));
        await until(() => a.of<AckMessage>().isNotEmpty, what: 'ack');
        bridge.onMessage(b, const ClientSend(text: 'hi', requestId: 'r1'));
        expect(b.of<AckMessage>().single.duplicate, isTrue);
        expect(proc.written.where((w) => w['type'] == 'prompt'), hasLength(1));
      },
    );

    test(
      'a duplicate while the first is still in flight is not forwarded',
      () async {
        await boot(respond: false);
        bridge.onMessage(a, const ClientSend(text: 'hi', requestId: 'r1'));
        bridge.onMessage(a, const ClientSend(text: 'hi', requestId: 'r1'));
        await settle();
        expect(proc.written.where((w) => w['type'] == 'prompt'), hasLength(1));
        expect(a.of<AckMessage>().single.duplicate, isTrue);
      },
    );

    test('steer and abort map onto Pi commands', () async {
      await boot();
      bridge.onMessage(a, const ClientSteer(text: 'left', requestId: 's1'));
      bridge.onMessage(a, const ClientAbort(requestId: 'x1'));
      await until(() => a.of<AckMessage>().length == 2, what: 'acks');
      expect(ids(), contains('steer'));
      expect(ids(), contains('abort'));
      expect(
        proc.written.firstWhere((w) => w['type'] == 'steer')['message'],
        'left',
      );
    });

    test(
      'Pi rejecting the command is an error with the requestId, and retryable',
      () async {
        await boot(respond: false);
        bridge.onMessage(a, const ClientSend(text: 'hi', requestId: 'r1'));
        await settle();
        final cmd = proc.written.singleWhere((w) => w['type'] == 'prompt');
        proc.emit({
          'type': 'response',
          'id': cmd['id'],
          'command': 'prompt',
          'success': false,
          'error': 'no model',
        });
        await until(() => a.of<ErrorMessage>().isNotEmpty, what: 'error');
        final e = a.of<ErrorMessage>().single;
        expect(e.code, 'rejected');
        expect(e.requestId, 'r1');
        expect(e.message, contains('r1'));
        expect(e.message, contains('no model'));
        expect(a.of<AckMessage>(), isEmpty);
        // The id was released: the same send can be retried.
        bridge.onMessage(a, const ClientSend(text: 'hi', requestId: 'r1'));
        await settle();
        expect(proc.written.where((w) => w['type'] == 'prompt'), hasLength(2));
      },
    );

    test(
      'supervisor not running: error with the requestId, nothing written',
      () async {
        await boot();
        proc.exit(1);
        await until(
          () => a.labels.contains('state:restarting'),
          what: 'restarting',
        );
        final before = proc.written.length;
        bridge.onMessage(a, const ClientSend(text: 'hi', requestId: 'r9'));
        await until(() => a.of<ErrorMessage>().isNotEmpty, what: 'error');
        final e = a.of<ErrorMessage>().single;
        expect(e.code, 'not_running');
        expect(e.requestId, 'r9');
        expect(e.message, contains('r9'));
        expect(proc.written, hasLength(before));
      },
    );

    test('an answer the supervisor cannot take carries the ask id', () async {
      await boot();
      await emit(_ask('q1'));
      await h.sup.shutdown();
      bridge.onMessage(a, const ClientUiResponse.confirmed('q1', true));
      final e = a.of<ErrorMessage>().last;
      expect(e.requestId, 'q1');
    });

    test('a command without a requestId has an error without one', () async {
      await boot();
      proc.exit(1);
      await until(
        () => a.labels.contains('state:restarting'),
        what: 'restarting',
      );
      bridge.onMessage(a, const ClientAbort(requestId: null));
      await until(() => a.of<ErrorMessage>().isNotEmpty, what: 'error');
      expect(a.of<ErrorMessage>().single.requestId, isNull);
    });

    test('ui_response while the supervisor is down is an error', () async {
      await boot();
      await emit(_ask('q1'));
      // Simulate the agent going away without the restart clearing yet.
      await h.sup.shutdown();
      bridge.onMessage(a, const ClientUiResponse.confirmed('q1', true));
      expect(
        a.of<ErrorMessage>().last.code,
        anyOf('not_running', 'ask_resolved'),
      );
    });
  });
}
