// A fake `pi --mode rpc` for tests: same JSONL on stdin/stdout, scripted
// scenarios chosen by the prompt text, diagnostics only on stderr.
//
//   dart run tool/fake_pi.dart
//
// Scenarios (prompt `message`):
//   hello          agent_start, message with text deltas (one holds U+2028)
//   tool:<name>    tool_execution_start/end, then the reply
//   ask:confirm    extension_ui_request(confirm), waits for the response
//   ask:select     extension_ui_request(select), waits for the response
//   slow           40 deltas, 100 ms apart; `abort` cuts it short
//   crash          exits 3 mid-run
//   hang           stops emitting, ignores everything but stdin close
//   burst:<n>      n back-to-back deltas
//   anything else  echoes the text back
//
// Env: HELM_FAKE_PI_LOG=<path> appends every received line to that file.
//
// Deliberately depends on dart:* only, so it works from any cwd and does not
// share code with the codec it is used to test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void main() => _FakePi().serve();

class _Run {
  final done = Completer<void>();
  final abortSignal = Completer<void>();
  bool get aborted => abortSignal.isCompleted;
  void abort() {
    if (!abortSignal.isCompleted) abortSignal.complete();
  }
}

class _FakePi {
  final String? _logPath = Platform.environment['HELM_FAKE_PI_LOG'];
  final _pendingUi = <String, Completer<Map<String, Object?>>>{};
  final _steering = <String>[];
  final _followUp = <String>[];
  _Run? _run;
  bool _hung = false;
  int _uiCounter = 0;
  int _messageCount = 0;

  void serve() {
    var buffer = '';
    stdin
        .transform(utf8.decoder)
        .listen(
          (chunk) {
            buffer += chunk;
            int lf;
            while ((lf = buffer.indexOf('\n')) >= 0) {
              var line = buffer.substring(0, lf);
              buffer = buffer.substring(lf + 1);
              if (line.endsWith('\r')) {
                line = line.substring(0, line.length - 1);
              }
              _onLine(line);
            }
          },
          onDone: () async {
            if (buffer.isNotEmpty) _onLine(buffer);
            await _shutdown();
          },
        );
  }

  Future<void> _shutdown() async {
    final run = _run;
    if (run != null && !_hung) {
      run.abort();
      await run.done.future;
    }
    await stdout.flush();
    exit(0);
  }

  void _emit(Map<String, Object?> record) =>
      stdout.write('${jsonEncode(record)}\n');

  void _respond(
    Object? id,
    String command, {
    bool success = true,
    Object? data,
    String? error,
  }) => _emit({
    'id': ?id,
    'type': 'response',
    'command': command,
    'success': success,
    'data': ?data,
    'error': ?error,
  });

  void _onLine(String line) {
    if (line.isEmpty) return;
    final logPath = _logPath;
    if (logPath != null) {
      File(logPath).writeAsStringSync('$line\n', mode: FileMode.append);
    }
    if (_hung) return;

    final Map<String, Object?> cmd;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) throw const FormatException('not an object');
      cmd = Map<String, Object?>.from(decoded);
    } on FormatException catch (e) {
      stderr.writeln('fake_pi: unparseable input: ${e.message}');
      _respond(
        null,
        'parse',
        success: false,
        error: 'Failed to parse command: ${e.message}',
      );
      return;
    }

    final id = cmd['id'];
    final type = cmd['type'];
    switch (type) {
      case 'prompt':
        _onPrompt(id, cmd);
      case 'steer':
        _onQueue(id, 'steer', cmd, _steering);
      case 'follow_up':
        _onQueue(id, 'follow_up', cmd, _followUp);
      case 'abort':
        _onAbort(id);
      case 'get_state':
        _respond(id, 'get_state', data: _state());
      case 'extension_ui_response':
        final pending = _pendingUi.remove(cmd['id']);
        if (pending == null) {
          stderr.writeln('fake_pi: no pending dialog for id ${cmd['id']}');
        } else {
          pending.complete(cmd);
        }
      default:
        _respond(id, '$type', success: false, error: 'Unknown command: $type');
    }
  }

  Map<String, Object?> _state() => {
    'model': {'id': 'fake-model', 'name': 'Fake Model', 'provider': 'fake'},
    'thinkingLevel': 'off',
    'isStreaming': _run != null,
    'isCompacting': false,
    'steeringMode': 'one-at-a-time',
    'followUpMode': 'one-at-a-time',
    'sessionId': 'fake-session',
    'autoCompactionEnabled': true,
    'messageCount': _messageCount,
    'pendingMessageCount': _steering.length + _followUp.length,
  };

  void _emitQueue() => _emit({
    'type': 'queue_update',
    'steering': List<String>.of(_steering),
    'followUp': List<String>.of(_followUp),
  });

  void _onQueue(
    Object? id,
    String command,
    Map<String, Object?> cmd,
    List<String> queue,
  ) {
    if (_run == null) {
      _respond(id, command, success: false, error: 'Agent is not streaming');
      return;
    }
    queue.add('${cmd['message']}');
    _respond(id, command, data: {'disposition': 'queued'});
    _emitQueue();
  }

  void _onPrompt(Object? id, Map<String, Object?> cmd) {
    final message = '${cmd['message'] ?? ''}';
    if (_run != null) {
      final behavior = cmd['streamingBehavior'];
      if (behavior == 'steer') {
        _onQueue(id, 'prompt', cmd, _steering);
      } else if (behavior == 'followUp') {
        _onQueue(id, 'prompt', cmd, _followUp);
      } else {
        _respond(
          id,
          'prompt',
          success: false,
          error:
              'Agent is already processing. Specify streamingBehavior '
              "('steer' or 'followUp') to queue the message.",
        );
      }
      return;
    }
    final run = _run = _Run();
    _respond(id, 'prompt', data: {'disposition': 'started'});
    unawaited(_execute(run, message));
  }

  void _onAbort(Object? id) {
    final run = _run;
    if (run == null) {
      _respond(id, 'abort');
      return;
    }
    run.abort();
    // Like Pi: respond only once the session is idle again.
    run.done.future.then((_) => _respond(id, 'abort'));
  }

  // ------------------------------------------------------------ scenarios

  Future<void> _execute(_Run run, String message) async {
    try {
      _emit({'type': 'agent_start'});
      if (message == 'hang') {
        _hung = true;
        await Completer<void>().future; // never completes; stdin close exits
      } else if (message == 'crash') {
        _emitMessageStart();
        _emitDelta('about to ');
        await stdout.flush();
        stderr.writeln('fake_pi: crashing on purpose');
        exit(3);
      } else if (message == 'slow') {
        await _reply(run, [
          for (var i = 0; i < 40; i++) 'tick$i ',
        ], pauseMs: 100);
      } else if (message.startsWith('burst:')) {
        final n = int.tryParse(message.substring(6)) ?? 10;
        await _reply(run, [for (var i = 0; i < n; i++) 'd$i ']);
      } else if (message.startsWith('tool:')) {
        final tool = message.substring(5);
        _emit({
          'type': 'tool_execution_start',
          'toolCallId': 'call_1',
          'toolName': tool,
          'args': <String, Object?>{},
        });
        _emit({
          'type': 'tool_execution_end',
          'toolCallId': 'call_1',
          'toolName': tool,
          'result': {
            'content': [
              {'type': 'text', 'text': 'fake $tool output'},
            ],
          },
          'isError': false,
          'durationMs': 1,
        });
        await _reply(run, ['Ran ', tool, '.']);
      } else if (message == 'ask:confirm') {
        final answer = await _ask(run, {
          'method': 'confirm',
          'title': 'Proceed?',
          'message': 'The fake agent wants to continue.',
        });
        await _reply(run, [
          if (answer == null || answer['cancelled'] == true)
            'Stopped: request cancelled.'
          else if (answer['confirmed'] == true)
            'Confirmed.'
          else
            'Declined.',
        ]);
      } else if (message == 'ask:select') {
        final answer = await _ask(run, {
          'method': 'select',
          'title': 'Allow dangerous command?',
          'options': ['Allow', 'Block'],
        });
        await _reply(run, [
          if (answer == null || answer['cancelled'] == true)
            'Stopped: request cancelled.'
          else
            'Selected: ${answer['value']}',
        ]);
      } else if (message == 'hello') {
        await _reply(run, ['Hello', ' from', ' fake\u2028pi', '.']);
      } else {
        await _reply(run, ['Echo: ', message]);
      }
    } finally {
      if (!_hung) {
        _emit({
          'type': 'agent_end',
          'messages': <Object?>[],
          'willRetry': false,
        });
        _emit({'type': 'agent_settled', 'aborted': run.aborted});
        _steering.clear();
        _followUp.clear();
        _run = null;
      }
      if (!run.done.isCompleted) run.done.complete();
    }
  }

  /// Emits a dialog request and waits for its response (null if aborted).
  Future<Map<String, Object?>?> _ask(
    _Run run,
    Map<String, Object?> request,
  ) async {
    final id = 'ui-${_uiCounter++}';
    final waiter = _pendingUi[id] = Completer<Map<String, Object?>>();
    _emit({'type': 'extension_ui_request', 'id': id, ...request});
    final result = await Future.any<Map<String, Object?>?>([
      waiter.future,
      run.abortSignal.future.then((_) => null),
    ]);
    _pendingUi.remove(id);
    return result;
  }

  void _emitMessageStart() => _emit({
    'type': 'message_start',
    'message': {'role': 'assistant', 'content': <Object?>[]},
  });

  void _emitDelta(String text) => _emit({
    'type': 'message_update',
    'usage': {'input': 0, 'output': 0, 'totalTokens': 0},
    'assistantMessageEvent': {
      'type': 'text_delta',
      'contentIndex': 0,
      'delta': text,
    },
  });

  Future<void> _reply(_Run run, List<String> deltas, {int pauseMs = 0}) async {
    _emitMessageStart();
    final text = StringBuffer();
    for (final d in deltas) {
      if (run.aborted) break;
      _emitDelta(d);
      text.write(d);
      if (pauseMs > 0) {
        await Future.any<void>([
          Future<void>.delayed(Duration(milliseconds: pauseMs)),
          run.abortSignal.future,
        ]);
      } else {
        await Future<void>.delayed(Duration.zero); // let stdin be read
      }
    }
    _messageCount += 1;
    _emit({
      'type': 'message_end',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text.toString()},
        ],
        'stopReason': run.aborted ? 'aborted' : 'stop',
      },
    });
  }
}
