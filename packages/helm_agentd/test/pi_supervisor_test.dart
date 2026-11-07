import 'dart:async';
import 'dart:io';

import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

const _s = Duration(seconds: 1);

Future<Harness> started({
  bool probe = false,
  int attempts = 3,
  List<Object>? script,
}) async {
  final h = Harness(
    probeOnStart: probe,
    maxSpawnAttempts: attempts,
    script: script,
  );
  await h.sup.start();
  return h;
}

void main() {
  group('commands', () {
    test(
      'send assigns unique ids and completes with the matching response',
      () async {
        final h = await started();
        final p = h.procs.single;
        final a = h.sup.send(const PiGetState());
        final b = h.sup.send(const PiPrompt('x'));
        await until(() => p.written.length == 2, what: 'two writes');
        final ids = p.written.map((w) => w['id']).toSet();
        expect(ids, hasLength(2));
        expect(ids, everyElement(isA<String>()));
        p.emit({
          'type': 'response',
          'id': p.written[0]['id'],
          'command': 'get_state',
          'success': true,
        });
        expect((await a).command, 'get_state');
        p.emit({
          'type': 'response',
          'id': p.written[1]['id'],
          'command': 'prompt',
          'success': true,
        });
        expect((await b).command, 'prompt');
        await h.sup.shutdown();
      },
    );

    test('out-of-order responses reach the right caller', () async {
      final h = await started();
      final p = h.procs.single;
      final a = h.sup.send(const PiGetState());
      final b = h.sup.send(const PiPrompt('x'));
      await until(() => p.written.length == 2);
      p.emit({
        'type': 'response',
        'id': p.written[1]['id'],
        'command': 'prompt',
        'success': true,
      });
      p.emit({
        'type': 'response',
        'id': p.written[0]['id'],
        'command': 'get_state',
        'success': true,
      });
      expect((await a).command, 'get_state');
      expect((await b).command, 'prompt');
      await h.sup.shutdown();
    });

    test('send overrides a caller-supplied id so ids stay unique', () async {
      final h = await started();
      final p = h.procs.single;
      unawaited(
        h.sup
            .send(const PiPrompt('x', id: 'mine'))
            .catchError(
              (Object _) =>
                  const PiResponse({}, id: null, command: '', success: false),
            ),
      );
      await until(() => p.written.isNotEmpty);
      expect(p.written.single['id'], isNot('mine'));
      await h.sup.shutdown();
    });

    test(
      'send fails fast with PiNotRunning before start and after stop',
      () async {
        final h = Harness();
        await expectLater(
          h.sup.send(const PiGetState()),
          throwsA(isA<PiNotRunning>()),
        );
        await h.sup.start();
        await h.sup.shutdown();
        await expectLater(
          h.sup.send(const PiGetState()),
          throwsA(
            isA<PiNotRunning>().having(
              (e) => e.state,
              'state',
              SupervisorState.stopped,
            ),
          ),
        );
      },
    );

    test(
      'times out per command; a late response is a diagnostic, not an event',
      () async {
        final h = await started();
        final p = h.procs.single;
        final f = h.sup.send(
          const PiGetState(),
          timeout: const Duration(seconds: 7),
        );
        final failed = expectLater(f, throwsA(isA<PiCommandTimeout>()));
        await until(() => p.written.isNotEmpty);
        await h.timers.fireNext(const Duration(seconds: 7));
        await failed;
        p.emit({
          'type': 'response',
          'id': p.written.single['id'],
          'command': 'get_state',
          'success': true,
        });
        await until(() => h.diagnostics.isNotEmpty, what: 'diagnostic');
        expect(h.diagnostics.single.source, DiagnosticSource.supervisor);
        expect(h.events, isEmpty);
        await h.sup.shutdown();
      },
    );

    test(
      'a response completes its command and cancels the timeout timer',
      () async {
        final h = await started();
        final p = h.procs.single;
        final f = h.sup.send(const PiGetState());
        await until(() => p.written.isNotEmpty);
        p.emit({
          'type': 'response',
          'id': p.written.single['id'],
          'command': 'get_state',
          'success': false,
          'error': 'nope',
        });
        final r = await f;
        expect(r.success, isFalse);
        expect(r.error, 'nope');
        expect(h.timers.pending(const Duration(minutes: 10)), isEmpty);
        await h.sup.shutdown();
      },
    );

    test(
      'in-flight commands fail with PiProcessExited when the process dies',
      () async {
        final h = await started();
        final p = h.procs.single;
        h.timers.autoFire = (d) => d >= _s && d <= const Duration(seconds: 30);
        final a = h.sup.send(const PiPrompt('a'));
        final b = h.sup.send(const PiPrompt('b'));
        final ea = expectLater(
          a,
          throwsA(isA<PiProcessExited>().having((e) => e.exitCode, 'code', 3)),
        );
        final eb = expectLater(b, throwsA(isA<PiProcessExited>()));
        await until(() => p.written.length == 2);
        p.exit(3);
        await ea;
        await eb;
        await h.sup.shutdown();
      },
    );

    test('sendUiResponse writes the response with the request id', () async {
      final h = await started();
      final p = h.procs.single;
      h.sup.sendUiResponse(
        const PiExtensionUiResponse.confirmed('req-1', true),
      );
      await until(() => p.written.isNotEmpty);
      expect(p.written.single, {
        'type': 'extension_ui_response',
        'id': 'req-1',
        'confirmed': true,
      });
      await h.sup.shutdown();
    });
  });

  group('events and diagnostics', () {
    test(
      'non-response records arrive in order; responses are not events',
      () async {
        final h = await started();
        final p = h.procs.single;
        p
          ..emit({'type': 'agent_start'})
          ..emit({
            'type': 'extension_ui_request',
            'id': 'u1',
            'method': 'setStatus',
          })
          ..emit({'type': 'response', 'command': 'x', 'success': true})
          ..emit({
            'type': 'message_update',
            'assistantMessageEvent': {'type': 'text_delta', 'delta': 'hi'},
          })
          ..emit({'type': 'agent_settled'});
        await until(() => h.events.length >= 4);
        expect(h.eventLabels, [
          'agent_start',
          'ui:setStatus',
          'delta:hi',
          'agent_settled',
        ]);
        await h.sup.shutdown();
      },
    );

    test(
      'malformed stdout lines are diagnostics and the stream continues',
      () async {
        final h = await started();
        final p = h.procs.single;
        p
          ..emitRaw('this is not json\n')
          ..emit({'type': 'agent_start'});
        await until(() => h.events.isNotEmpty);
        expect(h.diagnostics.single.source, DiagnosticSource.malformedStdout);
        expect(h.eventLabels, ['agent_start']);
        await h.sup.shutdown();
      },
    );

    test('stderr is drained as diagnostic lines and never parsed', () async {
      final h = await started();
      final p = h.procs.single;
      p.emitStderr('{"type":"agent_start"}\nsecond ');
      p.emitStderr('line\n');
      await until(() => h.diagnostics.length >= 2);
      expect(
        h.diagnostics.map((d) => d.source),
        everyElement(DiagnosticSource.stderr),
      );
      expect(h.diagnostics.map((d) => d.text), [
        '{"type":"agent_start"}',
        'second line',
      ]);
      expect(h.events, isEmpty);
      await h.sup.shutdown();
    });

    test('isBusy follows agent_start and agent_settled', () async {
      final h = await started();
      final p = h.procs.single;
      expect(h.sup.isBusy, isFalse);
      p.emit({'type': 'agent_start'});
      await until(() => h.sup.isBusy);
      p.emit({'type': 'agent_end'});
      p.emit({'type': 'agent_settled'});
      await until(() => !h.sup.isBusy);
      await h.sup.shutdown();
    });
  });

  group('restart', () {
    test('backoff doubles 1s,2s,4s,8s,16s then caps at 30s', () async {
      final h = Harness();
      h.timers.autoFire = (d) => d >= _s && d <= const Duration(seconds: 30);
      await h.sup.start();
      for (var i = 0; i < 7; i++) {
        await until(() => h.procs.length == i + 1, what: 'spawn ${i + 1}');
        await until(() => h.sup.state == SupervisorState.running);
        h.procs[i].exit(1);
      }
      await until(() => h.procs.length == 8);
      expect(h.backoffs.take(7).map((d) => d.inSeconds), [
        1,
        2,
        4,
        8,
        16,
        30,
        30,
      ]);
      await h.sup.shutdown();
    });

    test('backoff resets after stable uptime', () async {
      final h = Harness();
      h.timers.autoFire = (d) => d >= _s && d <= const Duration(seconds: 30);
      await h.sup.start();
      for (var i = 0; i < 2; i++) {
        await until(() => h.procs.length == i + 1);
        await until(() => h.sup.state == SupervisorState.running);
        h.procs[i].exit(1);
      }
      await until(() => h.procs.length == 3);
      await until(() => h.sup.state == SupervisorState.running);
      // The third process stays up for 30s before dying: backoff resets.
      h.clock = h.clock.add(const Duration(seconds: 30));
      h.procs[2].exit(1);
      await until(() => h.procs.length == 4);
      await until(() => h.sup.state == SupervisorState.running);
      // 4th dies quickly: continues from the start of the sequence again.
      h.procs[3].exit(1);
      await until(() => h.procs.length == 5);
      expect(h.backoffs.map((d) => d.inSeconds), [1, 2, 1, 2]);
      await h.sup.shutdown();
    });

    test('state goes starting, running, restarting, running', () async {
      final h = Harness();
      h.timers.autoFire = (d) => d == _s;
      await h.sup.start();
      h.procs[0].exit(1);
      await until(() => h.procs.length == 2);
      await until(() => h.sup.state == SupervisorState.running);
      expect(h.states, [
        SupervisorState.starting,
        SupervisorState.running,
        SupervisorState.restarting,
        SupervisorState.running,
      ]);
      await h.sup.shutdown();
    });

    test('interrupted is emitted after earlier events when busy', () async {
      final h = await started();
      h.timers.autoFire = (d) => d == _s;
      h.procs.single
        ..emit({'type': 'agent_start'})
        ..emit({
          'type': 'message_update',
          'assistantMessageEvent': {'type': 'text_delta', 'delta': 'abou'},
        });
      await until(() => h.events.length == 2);
      h.procs.single.exit(3);
      await until(() => h.eventLabels.contains('interrupted'));
      expect(h.eventLabels, ['agent_start', 'delta:abou', 'interrupted']);
      expect(h.sup.isBusy, isFalse);
      await h.sup.shutdown();
    });

    test('no interrupted event when idle', () async {
      final h = await started();
      h.timers.autoFire = (d) => d == _s;
      h.procs.single
        ..emit({'type': 'agent_start'})
        ..emit({'type': 'agent_settled'});
      await until(() => h.events.length == 2);
      h.procs.single.exit(1);
      await until(() => h.procs.length == 2);
      expect(h.eventLabels, ['agent_start', 'agent_settled']);
      await h.sup.shutdown();
    });

    test(
      'respawn sends get_state, then switch_session to the known file',
      () async {
        final h = Harness(probeOnStart: true);
        h.timers.autoFire = (d) => d == _s;
        final first = FakeProc()
          ..autoData['get_state'] = {'sessionFile': '/sessions/a.jsonl'};
        final second = FakeProc()
          ..autoData['get_state'] = {'sessionFile': '/sessions/NEW.jsonl'}
          ..autoData['switch_session'] = {'cancelled': false};
        h.script.addAll([first, second]);
        await h.sup.start();
        await until(() => h.sup.sessionFile == '/sessions/a.jsonl');
        first.exit(1);
        await until(() => second.written.length == 2);
        expect(second.writtenTypes, ['get_state', 'switch_session']);
        expect(second.written[1]['sessionPath'], '/sessions/a.jsonl');
        await until(() => h.sup.state == SupervisorState.running);
        expect(h.sup.sessionFile, '/sessions/a.jsonl');
        await h.sup.shutdown();
      },
    );

    test('commands are refused until the respawn sequence finished', () async {
      final h = Harness(probeOnStart: true);
      h.timers.autoFire = (d) => d == _s;
      final first = FakeProc()
        ..autoData['get_state'] = {'sessionFile': '/sessions/a.jsonl'};
      final second = FakeProc()..autoData['get_state'] = {};
      h.script.addAll([first, second]);
      await h.sup.start();
      await until(() => h.sup.sessionFile != null);
      first.exit(1);
      await until(() => second.written.length == 2);
      // switch_session is unanswered: still not running.
      expect(h.sup.state, SupervisorState.restarting);
      await expectLater(
        h.sup.send(const PiGetState()),
        throwsA(isA<PiNotRunning>()),
      );
      second.emit({
        'type': 'response',
        'id': second.written[1]['id'],
        'command': 'switch_session',
        'success': true,
        'data': {'cancelled': false},
      });
      await until(() => h.sup.state == SupervisorState.running);
      await h.sup.shutdown();
    });

    test('respawn with no known session only sends get_state', () async {
      final h = Harness();
      h.timers.autoFire = (d) => d == _s;
      await h.sup.start();
      h.procs[0].exit(1);
      await until(() => h.procs.length == 2);
      await until(() => h.sup.state == SupervisorState.running);
      expect(h.procs[1].writtenTypes, ['get_state']);
      await h.sup.shutdown();
    });
  });

  group('spawn failure policy', () {
    test('bounded retries with backoff, then failed; no tight loop', () async {
      final h = Harness(
        script: [
          const ProcessException('pi-fake', [], 'No such file', 2),
          const ProcessException('pi-fake', [], 'No such file', 2),
          const ProcessException('pi-fake', [], 'No such file', 2),
          FakeProc(), // must never be reached
        ],
      );
      h.timers.autoFire = (d) => d >= _s && d <= const Duration(seconds: 30);
      await h.sup.start();
      expect(h.sup.state, SupervisorState.failed);
      expect(h.sup.failure, isA<ProcessException>());
      expect(h.spawnAttempts, 3);
      expect(h.backoffs.map((d) => d.inSeconds), [1, 2]);
      expect(h.states, [
        SupervisorState.starting,
        SupervisorState.restarting,
        SupervisorState.failed,
      ]);
      await expectLater(
        h.sup.send(const PiGetState()),
        throwsA(
          isA<PiNotRunning>().having(
            (e) => e.state,
            's',
            SupervisorState.failed,
          ),
        ),
      );
      await h.sup.shutdown();
      expect(h.spawnAttempts, 3);
    });

    test('a spawn failure followed by success recovers', () async {
      final h = Harness(
        script: [const ProcessException('pi-fake', [], 'busy', 26), FakeProc()],
      );
      h.timers.autoFire = (d) => d == _s;
      await h.sup.start();
      expect(h.sup.state, SupervisorState.running);
      expect(h.spawnAttempts, 2);
      await h.sup.shutdown();
    });
  });

  group('shutdown', () {
    test(
      'escalates stdin close, SIGTERM, SIGKILL with the configured graces',
      () async {
        final h = await started();
        final p = h.procs.single..exitsOnStdinClose = false;
        final done = h.sup.shutdown();
        await until(() => p.stdinClosed, what: 'stdin closed');
        expect(p.signals, isEmpty);
        await h.timers.fireNext(const Duration(seconds: 5));
        await until(() => p.signals.isNotEmpty);
        expect(p.signals, [ProcessSignal.sigterm]);
        await h.timers.fireNext(const Duration(seconds: 6));
        await done;
        expect(p.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
        expect(h.sup.state, SupervisorState.stopped);
        expect(h.procs, hasLength(1), reason: 'no restart after shutdown');
      },
    );

    test('SIGTERM is enough when the process honours it', () async {
      final h = await started();
      final p = h.procs.single
        ..exitsOnStdinClose = false
        ..diesOn.add(ProcessSignal.sigterm);
      final done = h.sup.shutdown();
      await h.timers.fireNext(const Duration(seconds: 5));
      await done;
      expect(p.signals, [ProcessSignal.sigterm]);
    });

    test('a process that exits on stdin close is never signalled', () async {
      final h = await started();
      final p = h.procs.single;
      await h.sup.shutdown();
      expect(p.signals, isEmpty);
      expect(h.sup.state, SupervisorState.stopped);
      expect(h.procs, hasLength(1));
    });

    test('is idempotent', () async {
      final h = await started();
      final p = h.procs.single;
      await Future.wait([h.sup.shutdown(), h.sup.shutdown()]);
      await h.sup.shutdown();
      expect(p.signals, isEmpty);
      expect(h.states.where((s) => s == SupervisorState.stopped), hasLength(1));
    });

    test('during backoff prevents the restart', () async {
      final h = await started();
      h.procs.single.exit(1);
      await until(() => h.sup.state == SupervisorState.restarting);
      await h.sup.shutdown();
      expect(h.sup.state, SupervisorState.stopped);
      expect(h.timers.pending(_s), isEmpty, reason: 'backoff timer cancelled');
      expect(h.spawnAttempts, 1);
    });

    test('fails commands still in flight', () async {
      final h = await started();
      final p = h.procs.single;
      final f = h.sup.send(const PiPrompt('x'));
      final failed = expectLater(f, throwsA(isA<PiProcessExited>()));
      await until(() => p.written.isNotEmpty);
      await h.sup.shutdown();
      await failed;
    });

    test(
      'before start leaves the supervisor stopped and unable to start',
      () async {
        final h = Harness();
        await h.sup.shutdown();
        expect(h.sup.state, SupervisorState.stopped);
        await h.sup.start();
        expect(h.spawnAttempts, 0);
      },
    );
  });
}
