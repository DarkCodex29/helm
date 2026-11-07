import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart';

/// Lets queued event-loop turns run (no real waiting) until [cond] holds.
Future<void> until(bool Function() cond, {String what = 'condition'}) async {
  for (var i = 0; i < 2000; i++) {
    if (cond()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('never reached: $what');
}

/// In-memory [Process]: the test drives stdout/stderr/exit and reads what the
/// supervisor wrote to stdin.
class FakeProc implements Process {
  FakeProc() {
    stdin = IOSink(_stdinC);
    _stdinC.stream
        .transform(const JsonlDecoder())
        .listen(
          (item) {
            if (item is JsonlObject) {
              written.add(item.value);
              final auto = autoData[item.value['type']];
              final id = item.value['id'];
              if (auto != null && id != null) {
                emit({
                  'type': 'response',
                  'id': id,
                  'command': item.value['type'],
                  'success': true,
                  'data': auto,
                });
              }
            }
          },
          onDone: () {
            stdinClosed = true;
            if (exitsOnStdinClose) exit(0);
          },
        );
  }

  final _stdinC = StreamController<List<int>>();
  final _stdoutC = StreamController<List<int>>();
  final _stderrC = StreamController<List<int>>();
  final _exit = Completer<int>();

  /// Commands the supervisor wrote, decoded.
  final List<Map<String, Object?>> written = [];
  final List<ProcessSignal> signals = [];
  var stdinClosed = false;

  /// Like a well-behaved Pi; escalation tests turn this off.
  var exitsOnStdinClose = true;

  /// Signals that actually kill this fake process.
  final Set<ProcessSignal> diesOn = {ProcessSignal.sigkill};

  /// command type -> `data` of an automatic successful response.
  final Map<String, Object?> autoData = {};

  bool get exited => _exit.isCompleted;

  @override
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdout => _stdoutC.stream;

  @override
  Stream<List<int>> get stderr => _stderrC.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  void emit(Map<String, Object?> record) =>
      _stdoutC.add(utf8.encode('${jsonEncode(record)}\n'));
  void emitRaw(String text) => _stdoutC.add(utf8.encode(text));
  void emitStderr(String text) => _stderrC.add(utf8.encode(text));

  void exit(int code) {
    if (_exit.isCompleted) return;
    unawaited(_stdoutC.close());
    unawaited(_stderrC.close());
    _exit.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (diesOn.contains(signal)) exit(-signal.signalNumber);
    return true;
  }

  List<String> get writtenTypes => [
    for (final w in written) w['type']! as String,
  ];
}

class FakeTimer implements Timer {
  FakeTimer(this.duration, this._callback);
  final Duration duration;
  final void Function() _callback;
  var cancelled = false;
  var fired = false;

  void fire() {
    if (cancelled || fired) return;
    fired = true;
    _callback();
  }

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled && !fired;
  @override
  int get tick => 0;
}

class FakeTimers {
  final List<FakeTimer> created = [];

  /// Timers whose duration matches fire on their own (next microtask).
  bool Function(Duration) autoFire = (_) => false;

  Timer create(Duration d, void Function() cb) {
    final t = FakeTimer(d, cb);
    created.add(t);
    if (autoFire(d)) scheduleMicrotask(t.fire);
    return t;
  }

  Iterable<FakeTimer> pending(Duration d) =>
      created.where((t) => t.isActive && t.duration == d);

  Future<void> fireNext(Duration d) async {
    await until(() => pending(d).isNotEmpty, what: 'timer $d');
    pending(d).first.fire();
  }
}

/// A supervisor wired to fakes. Durations are distinctive so a test can tell
/// which timer is which.
class Harness {
  Harness({
    bool probeOnStart = false,
    int maxSpawnAttempts = 3,
    List<Object>? script,
  }) : script = script ?? [] {
    sup = PiSupervisor(
      executable: 'pi-fake',
      args: const ['--mode', 'rpc'],
      starter: _start,
      timerFactory: timers.create,
      now: () => clock,
      commandTimeout: const Duration(minutes: 10),
      stdinGrace: const Duration(seconds: 5),
      termGrace: const Duration(seconds: 6),
      drainGrace: const Duration(milliseconds: 50),
      probeOnStart: probeOnStart,
      maxSpawnAttempts: maxSpawnAttempts,
    );
    sup.states.listen(states.add);
    sup.events.listen(events.add);
    sup.diagnostics.listen(diagnostics.add);
  }

  /// Items are consumed per spawn: a [FakeProc] to hand out, or any other
  /// object to throw. When empty a fresh [FakeProc] is created.
  final List<Object> script;
  late final PiSupervisor sup;
  final timers = FakeTimers();
  final procs = <FakeProc>[];
  final states = <SupervisorState>[];
  final events = <SupervisorEvent>[];
  final diagnostics = <SupervisorDiagnostic>[];
  var spawnAttempts = 0;
  var clock = DateTime.utc(2030);

  Future<Process> _start(String exe, List<String> args) async {
    spawnAttempts++;
    // Respawned processes answer the supervisor's get_state by default.
    final Object next;
    if (script.isNotEmpty) {
      next = script.removeAt(0);
    } else {
      final fresh = FakeProc();
      if (spawnAttempts > 1) fresh.autoData['get_state'] = <String, Object?>{};
      next = fresh;
    }
    if (next is FakeProc) {
      procs.add(next);
      return next;
    }
    // ignore: only_throw_errors
    throw next;
  }

  /// Backoff timers only (everything else has a distinct duration).
  List<Duration> get backoffs => [
    for (final t in timers.created)
      if (t.duration >= const Duration(seconds: 1) &&
          t.duration != const Duration(seconds: 5) &&
          t.duration != const Duration(seconds: 6) &&
          t.duration < const Duration(minutes: 10))
        t.duration,
  ];

  /// Event labels, including interrupted.
  List<String> get eventLabels => [
    for (final e in events)
      switch (e) {
        PiRecordEvent(:final record) => switch (record) {
          PiAgentStart() => 'agent_start',
          PiAgentSettled() => 'agent_settled',
          PiMessageUpdate(:final textDelta) => 'delta:$textDelta',
          PiExtensionUiRequest(:final method) => 'ui:$method',
          _ => record.runtimeType.toString(),
        },
        InterruptedEvent() => 'interrupted',
      },
  ];
}
