/// Supervises one `pi --mode rpc` child process: correlates command
/// responses, republishes session events, restarts with backoff, and shuts
/// down in escalating steps.
///
/// Policies (all configurable through the constructor):
/// * Restart after an unexpected exit: backoff `initialBackoff * 2^n`,
///   capped at `maxBackoff`; `n` resets when the process had been up at
///   least `stableUptime`. A process that keeps crashing is retried forever
///   at the capped rate, never in a tight loop.
/// * Spawn failure (the starter throws, e.g. ENOENT): up to
///   `maxSpawnAttempts` consecutive attempts, separated by the same
///   backoff; then the state becomes `failed` (terminal) and [failure]
///   holds the error. No further attempt is made.
/// * After a respawn the supervisor sends `get_state`, then `switch_session`
///   back to the last known session file, BEFORE publishing `running`, so no
///   caller command can land in the wrong session.
/// * Shutdown: close stdin, wait `stdinGrace`, SIGTERM, wait `termGrace`,
///   SIGKILL. No restart afterwards.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:helm_protocol/helm_protocol.dart';

enum SupervisorState { starting, running, restarting, stopped, failed }

/// Base of every error [PiSupervisor] completes a command with.
sealed class PiSupervisorException implements Exception {
  const PiSupervisorException();
}

/// The process is not (or no longer) accepting commands.
class PiNotRunning extends PiSupervisorException {
  const PiNotRunning(this.state);
  final SupervisorState state;
  @override
  String toString() => 'PiNotRunning(${state.name})';
}

/// The process exited while the command was in flight.
class PiProcessExited extends PiSupervisorException {
  const PiProcessExited(this.exitCode);
  final int? exitCode;
  @override
  String toString() => 'PiProcessExited(exitCode: $exitCode)';
}

class PiCommandTimeout extends PiSupervisorException {
  const PiCommandTimeout(this.command, this.timeout);
  final String command;
  final Duration timeout;
  @override
  String toString() => 'PiCommandTimeout($command after $timeout)';
}

sealed class SupervisorEvent {
  const SupervisorEvent();
}

/// A non-response record: session event or extension UI request.
class PiRecordEvent extends SupervisorEvent {
  const PiRecordEvent(this.record);
  final PiRecord record;
}

/// The process died while an agent run was in flight.
class InterruptedEvent extends SupervisorEvent {
  const InterruptedEvent();
}

enum DiagnosticSource { stderr, malformedStdout, supervisor }

class SupervisorDiagnostic {
  const SupervisorDiagnostic(this.source, this.text);
  final DiagnosticSource source;
  final String text;
  @override
  String toString() => '${source.name}: $text';
}

typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> args);
typedef TimerFactory = Timer Function(Duration d, void Function() callback);

class _Pending {
  _Pending(this.completer, this.timer, {this.learnSession = false, this.path});
  final Completer<PiResponse> completer;
  final Timer timer;
  final bool learnSession;

  /// For `switch_session`: the file that becomes current on success.
  final String? path;
}

/// A timer that can be awaited and cancelled (cancelling also completes it).
class _Sleep {
  _Sleep(TimerFactory factory, Duration d) {
    _timer = factory(d, _finish);
  }
  late final Timer _timer;
  final _done = Completer<void>();
  Future<void> get done => _done.future;
  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  void cancel() {
    _timer.cancel();
    _finish();
  }
}

class PiSupervisor {
  PiSupervisor({
    this.executable = 'pi',
    List<String>? args,
    String? sessionDir,
    ProcessStarter? starter,
    TimerFactory? timerFactory,
    DateTime Function()? now,
    this.commandTimeout = const Duration(seconds: 30),
    this.stdinGrace = const Duration(seconds: 5),
    this.termGrace = const Duration(seconds: 5),
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.stableUptime = const Duration(seconds: 30),
    this.drainGrace = const Duration(seconds: 2),
    this.maxSpawnAttempts = 3,
    this.probeOnStart = true,
  }) : args =
           args ??
           [
             '--mode',
             'rpc',
             if (sessionDir != null) ...['--session-dir', sessionDir],
           ],
       _starter = starter ?? ((exe, a) => Process.start(exe, a)),
       _timer = timerFactory ?? Timer.new,
       _now = now ?? DateTime.now;

  final String executable;
  final List<String> args;
  final Duration commandTimeout;
  final Duration stdinGrace;
  final Duration termGrace;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final Duration stableUptime;
  final Duration drainGrace;
  final int maxSpawnAttempts;

  /// Send `get_state` after the first start to learn the session file, so a
  /// later respawn can switch back to it.
  final bool probeOnStart;

  final ProcessStarter _starter;
  final TimerFactory _timer;
  final DateTime Function() _now;

  final _states = StreamController<SupervisorState>.broadcast();
  final _events = StreamController<SupervisorEvent>.broadcast();
  final _diagnostics = StreamController<SupervisorDiagnostic>.broadcast();
  final _pending = <String, _Pending>{};
  final _settled = Completer<void>();

  var _state = SupervisorState.stopped;
  var _stopping = false;
  var _busy = false;
  var _seq = 0;
  var _backoffIndex = 0;
  String? _sessionFile;
  Object? _failure;
  Process? _proc;
  Future<void>? _loop;
  Future<void>? _terminating;
  Future<void>? _shutdownFuture;
  _Sleep? _backoffSleep;

  SupervisorState get state => _state;
  Stream<SupervisorState> get states => _states.stream;

  /// Session events and extension UI requests in arrival order, plus
  /// [InterruptedEvent]. Responses are never published here.
  Stream<SupervisorEvent> get events => _events.stream;

  /// stderr lines, malformed stdout lines and supervisor notes.
  Stream<SupervisorDiagnostic> get diagnostics => _diagnostics.stream;
  bool get isBusy => _busy;

  /// Last session file known to the supervisor (from `get_state`).
  String? get sessionFile => _sessionFile;

  /// Why the state is `failed`.
  Object? get failure => _failure;

  /// Starts the process. Completes once the supervisor is `running`,
  /// `failed` or `stopped`.
  Future<void> start() async {
    if (_stopping) return;
    _loop ??= _run().catchError((Object e) {
      _failure = e;
      _diag(DiagnosticSource.supervisor, 'supervisor loop crashed: $e');
      _setState(SupervisorState.failed);
    });
    await _settled.future;
  }

  Future<PiResponse> send(PiCommand command, {Duration? timeout}) {
    if (command is PiExtensionUiResponse) {
      throw ArgumentError('use sendUiResponse for extension_ui_response');
    }
    return _dispatch(
      command.toJson(),
      timeout,
      requireRunning: true,
      learnSession: command is PiGetState,
    );
  }

  /// Answers a dialog request. Pi sends no response to it.
  void sendUiResponse(PiExtensionUiResponse response) {
    final p = _proc;
    if (p == null || _state != SupervisorState.running || _stopping) {
      throw PiNotRunning(_state);
    }
    _write(p, response.toJson());
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  // ------------------------------------------------------------------ loop

  Future<void> _run() async {
    var respawn = false; // a process already ran: resume its session
    var retrying = false; // any attempt but the very first
    var spawnFailures = 0;
    while (!_stopping) {
      _setState(
        retrying ? SupervisorState.restarting : SupervisorState.starting,
      );
      final knownSession = _sessionFile;
      final Process p;
      try {
        p = await _starter(executable, args);
      } on Object catch (e) {
        _failure = e;
        _diag(DiagnosticSource.supervisor, 'could not start $executable: $e');
        if (++spawnFailures >= maxSpawnAttempts) {
          _setState(SupervisorState.failed);
          return;
        }
        retrying = true;
        await _backoff();
        continue;
      }
      spawnFailures = 0;
      _failure = null;
      _proc = p;
      _terminating = null;
      final startedAt = _now();
      final outputDone = _attach(p);
      if (_stopping) {
        await _terminateOnce(p);
      }
      final exitFuture = p.exitCode.then((code) async {
        final s = _Sleep(_timer, drainGrace);
        await Future.any([outputDone, s.done]);
        s.cancel();
        _proc = null;
        _failAll(PiProcessExited(code));
        return code;
      });
      if (!_stopping) {
        if (respawn) {
          await _resume(knownSession);
          if (!_stopping && _proc != null) _setState(SupervisorState.running);
        } else {
          _setState(SupervisorState.running);
          if (probeOnStart) _probe();
        }
      }
      final code = await exitFuture;
      if (_stopping) break;
      _diag(DiagnosticSource.supervisor, 'pi exited with code $code');
      if (_busy) {
        _busy = false;
        _events.add(const InterruptedEvent());
      }
      if (_now().difference(startedAt) >= stableUptime) _backoffIndex = 0;
      respawn = retrying = true;
      _setState(SupervisorState.restarting);
      await _backoff();
    }
    _busy = false;
    if (_state != SupervisorState.failed) _setState(SupervisorState.stopped);
  }

  Future<void> _backoff() async {
    if (_stopping) return;
    final factor = 1 << (_backoffIndex < 20 ? _backoffIndex : 20);
    _backoffIndex++;
    var delay = initialBackoff * factor;
    if (delay > maxBackoff) delay = maxBackoff;
    final sleep = _backoffSleep = _Sleep(_timer, delay);
    await sleep.done;
    _backoffSleep = null;
  }

  /// `get_state`, then `switch_session` back to [session]. Failures are
  /// diagnostics: a respawned Pi on a fresh session is still usable.
  Future<void> _resume(String? session) async {
    try {
      await _dispatch(const PiGetState().toJson(), null, requireRunning: false);
      if (session == null) return;
      final r = await _dispatch(
        {'type': 'switch_session', 'sessionPath': session},
        null,
        requireRunning: false,
        switchPath: session,
      );
      final data = r.data;
      if (!r.success || (data is Map && data['cancelled'] == true)) {
        _diag(DiagnosticSource.supervisor, 'switch_session not applied');
      }
    } on PiSupervisorException catch (e) {
      _diag(DiagnosticSource.supervisor, 'resume failed: $e');
    }
  }

  void _probe() {
    _dispatch(
      const PiGetState().toJson(),
      null,
      requireRunning: false,
      learnSession: true,
    ).then<void>((_) {}, onError: (Object _) {});
  }

  // ------------------------------------------------------------------- I/O

  /// Wires stdout/stderr; completes when both ended.
  Future<void> _attach(Process p) {
    final out = Completer<void>();
    final err = Completer<void>();
    p.stdout
        .transform(const JsonlDecoder())
        .listen(
          _onItem,
          onDone: out.complete,
          onError: (Object e) =>
              _diag(DiagnosticSource.supervisor, 'stdout: $e'),
        );
    p.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (l) => _diag(DiagnosticSource.stderr, l),
          onDone: err.complete,
          onError: (Object _) {},
        );
    unawaited(p.stdin.done.then<void>((_) {}, onError: (Object _) {}));
    return Future.wait([out.future, err.future]);
  }

  void _onItem(JsonlItem item) {
    switch (item) {
      case JsonlMalformed():
        _diag(DiagnosticSource.malformedStdout, item.toString());
      case JsonlObject(:final value):
        final record = parsePiRecord(value);
        if (record is PiResponse) return _onResponse(record);
        if (record is PiAgentStart) _busy = true;
        if (record is PiAgentSettled) _busy = false;
        _events.add(PiRecordEvent(record));
    }
  }

  void _onResponse(PiResponse r) {
    final pending = r.id == null ? null : _pending.remove(r.id);
    if (pending == null) {
      _diag(
        DiagnosticSource.supervisor,
        'unmatched response ${r.command} (id ${r.id}, success ${r.success})',
      );
      return;
    }
    pending.timer.cancel();
    final data = r.data;
    if (r.success && pending.learnSession && data is Map) {
      final file = data['sessionFile'];
      if (file is String) _sessionFile = file;
    }
    if (r.success && pending.path != null) {
      if (!(data is Map && data['cancelled'] == true)) {
        _sessionFile = pending.path;
      }
    }
    pending.completer.complete(r);
  }

  Future<PiResponse> _dispatch(
    Map<String, Object?> command,
    Duration? timeout, {
    required bool requireRunning,
    bool learnSession = false,
    String? switchPath,
  }) {
    final p = _proc;
    if (p == null ||
        _stopping ||
        (requireRunning && _state != SupervisorState.running)) {
      return Future.error(PiNotRunning(_state));
    }
    final id = 'h${++_seq}';
    final limit = timeout ?? commandTimeout;
    final completer = Completer<PiResponse>();
    final timer = _timer(limit, () {
      if (_pending.remove(id) != null) {
        completer.completeError(PiCommandTimeout('${command['type']}', limit));
      }
    });
    _pending[id] = _Pending(
      completer,
      timer,
      learnSession: learnSession,
      path: switchPath,
    );
    try {
      _write(p, {...command, 'id': id});
    } on Object {
      _pending.remove(id);
      timer.cancel();
      return Future.error(const PiProcessExited(null));
    }
    return completer.future;
  }

  void _write(Process p, Map<String, Object?> json) =>
      p.stdin.add(encodeJsonl(json));

  void _failAll(PiSupervisorException error) {
    final all = List.of(_pending.values);
    _pending.clear();
    for (final p in all) {
      p.timer.cancel();
      p.completer.completeError(error);
    }
  }

  // -------------------------------------------------------------- shutdown

  Future<void> _shutdown() async {
    _stopping = true;
    _backoffSleep?.cancel();
    final p = _proc;
    if (p != null) await _terminateOnce(p);
    final loop = _loop;
    if (loop != null) {
      await loop;
    } else {
      _setState(SupervisorState.stopped);
    }
  }

  Future<void> _terminateOnce(Process p) => _terminating ??= _terminate(p);

  Future<void> _terminate(Process p) async {
    unawaited(p.stdin.close().then<void>((_) {}, onError: (Object _) {}));
    if (await _exitedWithin(p, stdinGrace)) return;
    p.kill(ProcessSignal.sigterm);
    if (await _exitedWithin(p, termGrace)) return;
    p.kill(ProcessSignal.sigkill);
    if (!await _exitedWithin(p, termGrace)) {
      _diag(DiagnosticSource.supervisor, 'process survived SIGKILL');
    }
  }

  Future<bool> _exitedWithin(Process p, Duration grace) async {
    final s = _Sleep(_timer, grace);
    final exited = await Future.any([
      p.exitCode.then((_) => true),
      s.done.then((_) => false),
    ]);
    s.cancel();
    return exited;
  }

  // ----------------------------------------------------------------- misc

  void _setState(SupervisorState s) {
    if (_state != s) {
      _state = s;
      _states.add(s);
    }
    if (s != SupervisorState.starting &&
        s != SupervisorState.restarting &&
        !_settled.isCompleted) {
      _settled.complete();
    }
  }

  void _diag(DiagnosticSource source, String text) =>
      _diagnostics.add(SupervisorDiagnostic(source, text));
}
