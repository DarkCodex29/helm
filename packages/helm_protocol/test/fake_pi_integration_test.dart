@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

import 'support/fake_pi_process.dart';

void main() {
  late FakePiProcess pi;

  setUp(() async => pi = await FakePiProcess.start());
  tearDown(() => pi.dispose());

  test('hello: exact event order, U+2028 survives the real pipe', () async {
    final id = pi.send(const PiPrompt('hello'));
    await pi.waitSettled();

    expect(pi.labels(), [
      'response:prompt',
      'agent_start',
      'message_start',
      'message_update:text_delta',
      'message_end',
      'agent_end',
      'agent_settled',
    ]);
    final response = await pi.waitResponse(id);
    expect(response.success, isTrue);
    expect((response.data as Map)['disposition'], 'started');
    expect(pi.records.whereType<PiMessageUpdate>().length, greaterThan(2));
    expect(pi.replyText(), contains('\u2028'));
    expect(pi.records.whereType<PiAgentSettled>().single.aborted, isFalse);
    expect(pi.malformed, isEmpty);
  });

  test('tool:<name>: tool events with the requested name', () async {
    pi.send(const PiPrompt('tool:bash'));
    await pi.waitSettled();

    expect(pi.labels(), [
      'response:prompt',
      'agent_start',
      'tool_execution_start',
      'tool_execution_end',
      'message_start',
      'message_update:text_delta',
      'message_end',
      'agent_end',
      'agent_settled',
    ]);
    final start = pi.records.whereType<PiToolExecutionStart>().single;
    final end = pi.records.whereType<PiToolExecutionEnd>().single;
    expect(start.toolName, 'bash');
    expect(end.toolName, 'bash');
    expect(end.toolCallId, start.toolCallId);
    expect(end.isError, isFalse);
  });

  group('ask:confirm', () {
    test('confirmed', () async {
      pi.send(const PiPrompt('ask:confirm'));
      final req =
          await pi.waitFor((r) => r is PiExtensionUiRequest, what: 'ui request')
              as PiExtensionUiRequest;
      expect(req.method, 'confirm');
      expect(req.isDialog, isTrue);
      // Nothing may finish before the answer.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(pi.records.whereType<PiAgentEnd>(), isEmpty);

      pi.send(PiExtensionUiResponse.confirmed(req.id, true));
      await pi.waitSettled();

      expect(pi.labels(), [
        'response:prompt',
        'agent_start',
        'ui:confirm',
        'message_start',
        'message_update:text_delta',
        'message_end',
        'agent_end',
        'agent_settled',
      ]);
      expect(pi.replyText(), contains('Confirmed'));
    });

    test('cancelled finishes with a stopped reply', () async {
      pi.send(const PiPrompt('ask:confirm'));
      final req =
          await pi.waitFor((r) => r is PiExtensionUiRequest)
              as PiExtensionUiRequest;
      pi.send(PiExtensionUiResponse.cancelled(req.id));
      await pi.waitSettled();

      expect(pi.labels().last, 'agent_settled');
      expect(pi.replyText(), contains('Stopped'));
      expect(pi.replyText(), isNot(contains('Confirmed')));
    });

    test('declined', () async {
      pi.send(const PiPrompt('ask:confirm'));
      final req =
          await pi.waitFor((r) => r is PiExtensionUiRequest)
              as PiExtensionUiRequest;
      pi.send(PiExtensionUiResponse.confirmed(req.id, false));
      await pi.waitSettled();
      expect(pi.replyText(), contains('Declined'));
    });
  });

  group('ask:select', () {
    test('value answer', () async {
      pi.send(const PiPrompt('ask:select'));
      final req =
          await pi.waitFor((r) => r is PiExtensionUiRequest)
              as PiExtensionUiRequest;
      expect(req.method, 'select');
      expect(req.options, isNotEmpty);
      pi.send(PiExtensionUiResponse.value(req.id, req.options.first));
      await pi.waitSettled();
      expect(pi.replyText(), contains('Selected: ${req.options.first}'));
    });

    test('cancelled', () async {
      pi.send(const PiPrompt('ask:select'));
      final req =
          await pi.waitFor((r) => r is PiExtensionUiRequest)
              as PiExtensionUiRequest;
      pi.send(PiExtensionUiResponse.cancelled(req.id));
      await pi.waitSettled();
      expect(pi.replyText(), contains('Stopped'));
    });

    test('a response with a wrong id is ignored', () async {
      pi.send(const PiPrompt('ask:select'));
      final req =
          await pi.waitFor((r) => r is PiExtensionUiRequest)
              as PiExtensionUiRequest;
      pi.send(const PiExtensionUiResponse.value('nope', 'x'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(pi.records.whereType<PiAgentEnd>(), isEmpty);
      pi.send(PiExtensionUiResponse.value(req.id, 'ok'));
      await pi.waitSettled();
    });
  });

  test('slow + abort: run is interrupted, still settles aborted', () async {
    pi.send(const PiPrompt('slow'));
    await pi.waitFor((r) => r is PiMessageUpdate, what: 'first delta');
    final abortId = pi.send(const PiAbort());
    await pi.waitSettled();

    final settled = pi.records.whereType<PiAgentSettled>().single;
    expect(settled.aborted, isTrue);
    expect(pi.records.whereType<PiAgentEnd>(), hasLength(1));
    final deltas = pi.records.whereType<PiMessageUpdate>().length;
    expect(deltas, lessThan(30), reason: 'abort must cut the script short');

    final r = await pi.waitResponse(abortId);
    expect(r.success, isTrue);
    // The abort response comes after the run went idle.
    expect(pi.records.indexOf(r), greaterThan(pi.records.indexOf(settled)));
  });

  test(
    'prompt while streaming without streamingBehavior is rejected',
    () async {
      pi.send(const PiPrompt('slow'));
      await pi.waitFor((r) => r is PiMessageUpdate);
      final id = pi.send(const PiPrompt('hello'));
      final r = await pi.waitResponse(id);
      expect(r.success, isFalse);
      expect(r.error, isNotEmpty);
      pi.send(const PiAbort());
      await pi.waitSettled();
    },
  );

  test('steer while streaming is queued and reported', () async {
    pi.send(const PiPrompt('slow'));
    await pi.waitFor((r) => r is PiMessageUpdate);
    final id = pi.send(const PiSteer('turn left'));
    final r = await pi.waitResponse(id);
    expect(r.success, isTrue);
    final q = await pi.waitFor((r) => r is PiQueueUpdate) as PiQueueUpdate;
    expect(q.steering, ['turn left']);
    pi.send(const PiAbort());
    await pi.waitSettled();
  });

  test('crash: exits non-zero mid-run, after the prompt response', () async {
    pi.send(const PiPrompt('crash'));
    final code = await pi.exitCode;
    expect(code, isNot(0));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(pi.labels(), contains('agent_start'));
    expect(pi.labels(), isNot(contains('agent_settled')));
  });

  test(
    'hang: stops emitting, ignores commands, exits 0 on stdin close',
    () async {
      pi.send(const PiPrompt('hang'));
      await pi.waitFor((r) => r is PiAgentStart);
      final before = pi.records.length;
      pi.send(const PiGetState());
      pi.send(const PiAbort());
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(pi.records.length, before, reason: 'a hung agent answers nothing');

      await pi.closeStdin();
      expect(await pi.exitCode, 0);
    },
  );

  test('burst:n emits n deltas back to back', () async {
    pi.send(const PiPrompt('burst:200'));
    await pi.waitSettled();
    final deltas = pi.records.whereType<PiMessageUpdate>().toList();
    expect(deltas, hasLength(200));
    expect(pi.replyText().length, greaterThanOrEqualTo(200));
  });

  test('get_state reflects idle and streaming', () async {
    final idle = pi.send(const PiGetState());
    final r1 = await pi.waitResponse(idle);
    expect(r1.success, isTrue);
    expect((r1.data as Map)['isStreaming'], isFalse);

    pi.send(const PiPrompt('slow'));
    await pi.waitFor((r) => r is PiMessageUpdate);
    final busy = pi.send(const PiGetState());
    final r2 = await pi.waitResponse(busy);
    expect((r2.data as Map)['isStreaming'], isTrue);
    pi.send(const PiAbort());
    await pi.waitSettled();
  });

  test('every command is answered and echoes its id', () async {
    final a = pi.send(const PiGetState());
    expect((await pi.waitResponse(a)).command, 'get_state');
    final b = pi.send(const PiAbort());
    final rb = await pi.waitResponse(b);
    expect(rb.command, 'abort');
    pi.sendRaw({'id': 'weird', 'type': 'no_such_command'});
    final rc = await pi.waitResponse('weird');
    expect(rc.success, isFalse);
  });

  test(
    'invalid input line yields an error response, process survives',
    () async {
      pi.sendRawLine('this is not json');
      await pi.waitFor(
        (r) => r is PiResponse && !r.success && r.command == 'parse',
        what: 'parse error response',
      );
      final id = pi.send(const PiGetState());
      expect((await pi.waitResponse(id)).success, isTrue);
    },
  );

  test('stdin close: orderly exit 0, even mid-run', () async {
    await pi.closeStdin();
    expect(await pi.exitCode, 0);
  });

  test('stdin close during a slow run still exits 0', () async {
    pi.send(const PiPrompt('slow'));
    await pi.waitFor((r) => r is PiMessageUpdate);
    await pi.closeStdin();
    expect(await pi.exitCode, 0);
  });

  test('diagnostics never go to stdout', () async {
    pi.send(const PiPrompt('hello'));
    await pi.waitSettled();
    expect(pi.malformed, isEmpty);
  });

  test('HELM_FAKE_PI_LOG appends every received command', () async {
    final dir = Directory.systemTemp.createTempSync('fake_pi_log');
    addTearDown(() => dir.deleteSync(recursive: true));
    final log = File('${dir.path}/commands.jsonl');
    final p = await FakePiProcess.start(env: {'HELM_FAKE_PI_LOG': log.path});
    addTearDown(p.dispose);
    p.send(const PiGetState());
    final id = p.send(const PiPrompt('hello'));
    await p.waitResponse(id);
    await p.closeStdin();
    await p.exitCode;
    final lines = log.readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines.first, contains('"get_state"'));
    expect(lines.last, contains('"prompt"'));
  });
}
