import 'dart:async';
import 'dart:io';

import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

/// Runs the REAL fake agent (and a stubborn one) as subprocesses. Every wait
/// is bounded so a regression fails the test instead of hanging CI.
const _bound = Duration(seconds: 20);

final _fakePi = File('../helm_protocol/tool/fake_pi.dart').absolute.path;
final _stubborn = File('test/support/stubborn_agent.dart').absolute.path;

class Rig {
  Rig(
    String script, {
    Duration grace = const Duration(seconds: 5),
    bool probe = true,
  }) {
    sup = PiSupervisor(
      executable: Platform.resolvedExecutable,
      args: [script],
      starter: (exe, args) async {
        final p = await Process.start(exe, args);
        spawned.add(p);
        return p;
      },
      initialBackoff: const Duration(milliseconds: 50),
      maxBackoff: const Duration(milliseconds: 200),
      stdinGrace: grace,
      termGrace: grace,
      commandTimeout: _bound,
      probeOnStart: probe,
    );
    sup.events.listen(events.add);
    sup.states.listen(states.add);
    sup.diagnostics.listen(diagnostics.add);
  }

  late final PiSupervisor sup;
  final spawned = <Process>[];
  final events = <SupervisorEvent>[];
  final states = <SupervisorState>[];
  final diagnostics = <SupervisorDiagnostic>[];

  Future<void> waitEvent(
    bool Function(SupervisorEvent) test,
    String what,
  ) async {
    final end = DateTime.now().add(_bound);
    while (!events.any(test)) {
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('no $what; events: $events');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> waitState(SupervisorState s) async {
    final end = DateTime.now().add(_bound);
    while (sup.state != s) {
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('state ${sup.state}, wanted $s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> dispose() async {
    await sup.shutdown().timeout(_bound, onTimeout: () {});
    for (final p in spawned) {
      p.kill(ProcessSignal.sigkill);
    }
  }
}

bool _is<T>(SupervisorEvent e) => e is PiRecordEvent && e.record is T;

void main() {
  late Rig rig;
  tearDown(() => rig.dispose());

  test('hello round trip delivers events in order', () async {
    rig = Rig(_fakePi);
    await rig.sup.start();
    final r = await rig.sup.send(const PiPrompt('hello'));
    expect(r.success, isTrue);
    await rig.waitEvent(_is<PiAgentSettled>, 'agent_settled');
    final types = [
      for (final e in rig.events)
        if (e is PiRecordEvent) e.record.runtimeType,
    ];
    expect(types.first, PiAgentStart);
    expect(types.last, PiAgentSettled);
    expect(
      types,
      containsAllInOrder([PiMessageStart, PiMessageUpdate, PiMessageEnd]),
    );
    final text = rig.events
        .whereType<PiRecordEvent>()
        .map((e) => e.record)
        .whereType<PiMessageUpdate>()
        .map((u) => u.textDelta ?? '')
        .join();
    expect(text, isNotEmpty);
    expect(rig.sup.isBusy, isFalse);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('crash: interrupted, restart, and usable again', () async {
    rig = Rig(_fakePi);
    await rig.sup.start();
    await rig.sup.send(const PiPrompt('crash'));
    await rig.waitEvent((e) => e is InterruptedEvent, 'interrupted');
    await rig.waitState(SupervisorState.running);
    expect(rig.spawned, hasLength(2));
    final r = await rig.sup.send(const PiPrompt('hello'));
    expect(r.success, isTrue);
    await rig.waitEvent(_is<PiAgentSettled>, 'agent_settled after restart');
    expect(
      rig.diagnostics.map((d) => d.text),
      contains(contains('crashing on purpose')),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('hang then shutdown: the agent ends and is not restarted', () async {
    rig = Rig(_fakePi, grace: const Duration(seconds: 2));
    await rig.sup.start();
    await rig.sup.send(const PiPrompt('hang'));
    await rig.waitEvent(_is<PiAgentStart>, 'agent_start');
    await rig.sup.shutdown().timeout(_bound);
    expect(rig.sup.state, SupervisorState.stopped);
    expect(rig.spawned, hasLength(1));
    await rig.spawned.single.exitCode.timeout(_bound);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test(
    'shutdown escalates to SIGKILL for an agent that ignores EOF and SIGTERM',
    () async {
      rig = Rig(
        _stubborn,
        grace: const Duration(milliseconds: 300),
        probe: false,
      );
      await rig.sup.start();
      final sw = Stopwatch()..start();
      await rig.sup.shutdown().timeout(_bound);
      final code = await rig.spawned.single.exitCode.timeout(_bound);
      expect(code, -9);
      expect(
        sw.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 500)),
      );
      expect(rig.spawned, hasLength(1));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test('stdin close exits 0 cleanly and is not restarted', () async {
    rig = Rig(_fakePi);
    await rig.sup.start();
    await rig.sup.send(const PiGetState());
    await rig.sup.shutdown().timeout(_bound);
    expect(await rig.spawned.single.exitCode.timeout(_bound), 0);
    expect(rig.sup.state, SupervisorState.stopped);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(rig.spawned, hasLength(1));
    expect(rig.events.whereType<InterruptedEvent>(), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 45)));
}
