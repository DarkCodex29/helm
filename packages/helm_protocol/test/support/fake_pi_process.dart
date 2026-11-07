import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:helm_protocol/helm_protocol.dart';

/// Spawns `tool/fake_pi.dart` as a real subprocess and exposes its stdout as
/// parsed [PiRecord]s. Every wait is bounded so a broken fake fails the test
/// instead of hanging CI.
class FakePiProcess {
  FakePiProcess._(this._process, this._stdoutDone);

  final Process _process;
  final Future<void> _stdoutDone;
  final List<PiRecord> records = [];
  final List<JsonlMalformed> malformed = [];
  final StringBuffer stderrText = StringBuffer();
  final List<_Waiter> _waiters = [];
  var _nextId = 0;

  static const defaultTimeout = Duration(seconds: 15);

  static Future<FakePiProcess> start({Map<String, String>? env}) async {
    final script = File('tool/fake_pi.dart').absolute.path;
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      script,
    ], environment: env);
    final done = Completer<void>();
    final self = FakePiProcess._(process, done.future);
    process.stdout
        .transform(const JsonlDecoder())
        .listen(
          (item) {
            switch (item) {
              case JsonlObject(:final value):
                self.records.add(parsePiRecord(value));
              case JsonlMalformed():
                self.malformed.add(item);
            }
            self._wake();
          },
          onDone: () {
            done.complete();
            self._wake();
          },
        );
    process.stderr
        .transform(utf8.decoder)
        .listen((s) => self.stderrText.write(s));
    return self;
  }

  void _wake() {
    for (final w in List.of(_waiters)) {
      w.check();
    }
  }

  /// Sends a command; returns the id it carries.
  String send(PiCommand command, {bool withId = true}) {
    final json = Map<String, Object?>.from(command.toJson());
    final id = 'c${_nextId++}';
    if (withId && command is! PiExtensionUiResponse) json['id'] ??= id;
    sendRaw(json);
    return (json['id'] as String?) ?? id;
  }

  void sendRaw(Map<String, Object?> json) =>
      _process.stdin.add(encodeJsonl(json));

  void sendRawLine(String line) => _process.stdin.add(utf8.encode('$line\n'));

  Future<void> closeStdin() => _process.stdin.close();

  /// Completes with the first record at/after [from] matching [test].
  Future<PiRecord> waitFor(
    bool Function(PiRecord) test, {
    int from = 0,
    Duration timeout = defaultTimeout,
    String? what,
  }) {
    final waiter = _Waiter(this, test, from);
    _waiters.add(waiter);
    waiter.check();
    return waiter.completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw TimeoutException(
          'timed out waiting for ${what ?? 'record'}; got types: '
          '${records.map(describe).toList()}; stderr: $stderrText',
        );
      },
    );
  }

  /// Waits until the run settled (agent_settled seen after [from]).
  Future<void> waitSettled({int from = 0}) =>
      waitFor((r) => r is PiAgentSettled, from: from, what: 'agent_settled');

  Future<PiResponse> waitResponse(String id) async =>
      await waitFor((r) => r is PiResponse && r.id == id, what: 'response $id')
          as PiResponse;

  Future<int> get exitCode => _process.exitCode.timeout(
    defaultTimeout,
    onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
      throw TimeoutException('process did not exit; stderr: $stderrText');
    },
  );

  Future<void> dispose() async {
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode;
    await _stdoutDone.timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  /// Short label per record, for exact-order assertions.
  static String describe(PiRecord r) => switch (r) {
    PiResponse(:final command) => 'response:$command',
    PiAgentStart() => 'agent_start',
    PiAgentEnd() => 'agent_end',
    PiAgentSettled() => 'agent_settled',
    PiMessageStart() => 'message_start',
    PiMessageUpdate(:final eventType) => 'message_update:$eventType',
    PiMessageEnd() => 'message_end',
    PiToolExecutionStart() => 'tool_execution_start',
    PiToolExecutionEnd() => 'tool_execution_end',
    PiQueueUpdate() => 'queue_update',
    PiExtensionUiRequest(:final method) => 'ui:$method',
    UnknownRecord(:final type) => 'unknown:$type',
  };

  /// Labels with consecutive message_update:text_delta collapsed to one.
  List<String> labels({int from = 0}) {
    final out = <String>[];
    for (final r in records.skip(from)) {
      final l = describe(r);
      if (l == 'message_update:text_delta' && out.isNotEmpty && out.last == l) {
        continue;
      }
      out.add(l);
    }
    return out;
  }

  /// All text deltas concatenated.
  String replyText({int from = 0}) => records
      .skip(from)
      .whereType<PiMessageUpdate>()
      .map((u) => u.textDelta ?? '')
      .join();
}

class _Waiter {
  _Waiter(this.owner, this.test, this.from);
  final FakePiProcess owner;
  final bool Function(PiRecord) test;
  final int from;
  final completer = Completer<PiRecord>();

  void check() {
    if (completer.isCompleted) return;
    for (var i = from; i < owner.records.length; i++) {
      if (test(owner.records[i])) {
        completer.complete(owner.records[i]);
        owner._waiters.remove(this);
        return;
      }
    }
  }
}
