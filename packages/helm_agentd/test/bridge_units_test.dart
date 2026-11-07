@Timeout(Duration(seconds: 30))
library;

import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('deriveState', () {
    AgentState d(
      SupervisorState s, {
      int asks = 0,
      bool busy = false,
      int tools = 0,
    }) => deriveState(
      supervisor: s,
      openAsks: asks,
      busy: busy,
      runningTools: tools,
    );

    test('supervisor lifecycle wins over everything', () {
      for (final (s, want) in [
        (SupervisorState.starting, AgentState.starting),
        (SupervisorState.restarting, AgentState.restarting),
        (SupervisorState.failed, AgentState.error),
        (SupervisorState.stopped, AgentState.stopped),
      ]) {
        expect(d(s, asks: 2, busy: true, tools: 1), want);
      }
    });

    test('running: asks > tools-or-busy > idle, working beats thinking', () {
      const r = SupervisorState.running;
      expect(d(r), AgentState.idle);
      expect(d(r, tools: 1), AgentState.idle, reason: 'not busy');
      expect(d(r, busy: true), AgentState.thinking);
      expect(d(r, busy: true, tools: 1), AgentState.working);
      expect(d(r, busy: true, tools: 1, asks: 1), AgentState.needsYou);
      expect(d(r, asks: 1), AgentState.needsYou);
    });
  });

  group('DeltaCoalescer', () {
    late FakeTimers timers;
    late List<(String, String)> out;
    late DeltaCoalescer c;
    setUp(() {
      timers = FakeTimers();
      out = [];
      c = DeltaCoalescer(
        timerFactory: timers.create,
        interval: const Duration(milliseconds: 50),
        onFlush: (id, text) => out.add((id, text)),
      );
    });

    test('joins deltas of one message into a single flush, in order', () {
      c.add('m1', 'a');
      c.add('m1', 'b\u2028');
      c.add('m1', 'c');
      expect(out, isEmpty);
      expect(timers.created, hasLength(1));
      expect(timers.created.single.duration, const Duration(milliseconds: 50));
      timers.created.single.fire();
      expect(out, [('m1', 'ab\u2028c')]);
    });

    test('flush() emits now and cancels the timer', () {
      c.add('m1', 'a');
      c.flush();
      expect(out, [('m1', 'a')]);
      expect(timers.created.single.cancelled, isTrue);
      c.flush();
      expect(out, hasLength(1), reason: 'nothing left');
    });

    test('a new batch after a flush starts a new timer', () {
      c.add('m1', 'a');
      timers.created.last.fire();
      c.add('m1', 'b');
      expect(timers.created, hasLength(2));
      timers.created.last.fire();
      expect(out, [('m1', 'a'), ('m1', 'b')]);
    });

    test('two messages flush in first-seen order, text kept apart', () {
      c.add('m1', 'a');
      c.add('m2', 'x');
      c.add('m1', 'b');
      c.flush();
      expect(out, [('m1', 'ab'), ('m2', 'x')]);
    });

    test('dispose cancels the timer and drops nothing already flushed', () {
      c.add('m1', 'a');
      c.dispose();
      expect(timers.created.single.cancelled, isTrue);
      c.add('m1', 'late');
      expect(out, isEmpty, reason: 'disposed: nothing is scheduled again');
    });
  });

  group('RequestIdCache', () {
    test('first sight is new, second is a duplicate', () {
      final c = RequestIdCache();
      expect(c.add('a'), isTrue);
      expect(c.add('a'), isFalse);
      expect(c.add('b'), isTrue);
    });

    test('forget lets an id be used again', () {
      final c = RequestIdCache()..add('a');
      c.forget('a');
      expect(c.add('a'), isTrue);
    });

    test('bounded at 256: the oldest id is evicted', () {
      final c = RequestIdCache();
      for (var i = 0; i < 256; i++) {
        c.add('id$i');
      }
      expect(c.length, 256);
      expect(c.add('extra'), isTrue);
      expect(c.length, 256);
      expect(c.add('id0'), isTrue, reason: 'oldest was evicted');
      expect(c.add('id255'), isFalse, reason: 'recent one is still there');
    });

    test('seeing a duplicate refreshes its recency', () {
      final c = RequestIdCache(capacity: 3);
      c
        ..add('a')
        ..add('b')
        ..add('c');
      expect(c.add('a'), isFalse); // refresh a
      c.add('d'); // evicts b, not a
      expect(c.add('a'), isFalse);
      expect(c.add('b'), isTrue);
    });

    test('an in-flight id is never evicted, however many others pass', () {
      final c = RequestIdCache(capacity: 3);
      expect(c.begin('slow'), isTrue);
      for (var i = 0; i < 10; i++) {
        expect(c.begin('id$i'), isTrue);
        c.complete('id$i');
      }
      expect(c.begin('slow'), isFalse, reason: 'still in flight');
    });

    test('a completed id is a duplicate; a failed one can be retried', () {
      final c = RequestIdCache();
      expect(c.begin('ok'), isTrue);
      c.complete('ok');
      expect(c.begin('ok'), isFalse);
      expect(c.begin('bad'), isTrue);
      c.fail('bad');
      expect(c.begin('bad'), isTrue);
    });
  });
}
