import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/ssh_host_command_runner.dart';

void main() {
  group('run', () {
    test(
      'returns stdout, stderr, exitCode and timedOut=false on success',
      () async {
        final channel = _FakeSshCommandChannel(
          stdoutBytes: utf8.encode('hello'),
          stderrBytes: utf8.encode('warn'),
          exitCode: 0,
        );
        String? openedCommand;
        final runner = SshHostCommandRunner.withOpener((command) async {
          openedCommand = command;
          return channel;
        });

        final result = await runner.run('echo hello');

        expect(openedCommand, 'echo hello');
        expect(result.stdout, 'hello');
        expect(result.stderr, 'warn');
        expect(result.exitCode, 0);
        expect(result.timedOut, isFalse);
      },
    );

    test('reports timedOut=true when the command exceeds the timeout', () async {
      final channel = _FakeSshCommandChannel(
        done: Completer<void>().future,
        exitCode: 0,
      );
      final runner = SshHostCommandRunner.withOpener((_) async => channel);

      final result = await runner.run(
        'sleep 100',
        timeout: const Duration(milliseconds: 20),
      );

      expect(result.timedOut, isTrue);
      expect(result.exitCode, isNull);
    });
  });

  group('runScript', () {
    test(
      'opens exactly /bin/sh -s, writes the script to stdin, closes it, '
      'and issues no other command',
      () async {
        final channel = _FakeSshCommandChannel(exitCode: 0);
        final openedCommands = <String>[];
        final runner = SshHostCommandRunner.withOpener((command) async {
          openedCommands.add(command);
          return channel;
        });

        final result = await runner.runScript('echo probe');

        expect(openedCommands, ['/bin/sh -s']);
        expect(utf8.decode(channel.stdinBytesWritten), 'echo probe');
        expect(channel.stdinClosed, isTrue);
        expect(result.exitCode, 0);
      },
    );

    test('returns the drained stdout of the executed script', () async {
      final channel = _FakeSshCommandChannel(
        stdoutBytes: utf8.encode('helm-probe/1'),
        exitCode: 0,
      );
      final runner = SshHostCommandRunner.withOpener((_) async => channel);

      final result = await runner.runScript('probe-script');

      expect(result.stdout, 'helm-probe/1');
    });
  });
}

/// In-memory [SshCommandChannel] stand-in. Records everything written to
/// [stdin] and whether it was closed; [stdout]/[stderr] replay fixed bytes;
/// [done] completes with the given future (defaults to already-completed).
class _FakeSshCommandChannel implements SshCommandChannel {
  _FakeSshCommandChannel({
    List<int> stdoutBytes = const [],
    List<int> stderrBytes = const [],
    this.exitCode,
    Future<void>? done,
  }) : _stdoutBytes = stdoutBytes,
       _stderrBytes = stderrBytes,
       _done = done ?? Future.value() {
    _stdinController.stream.listen(
      stdinBytesWritten.addAll,
      onDone: () => stdinClosed = true,
    );
  }

  final List<int> _stdoutBytes;
  final List<int> _stderrBytes;
  final Future<void> _done;
  final _stdinController = StreamController<Uint8List>();

  /// Bytes written to [stdin] before it was closed.
  final List<int> stdinBytesWritten = [];

  /// True once [stdin] has been closed.
  bool stdinClosed = false;

  @override
  int? exitCode;

  @override
  StreamSink<Uint8List> get stdin => _stdinController.sink;

  @override
  Stream<Uint8List> get stdout =>
      Stream.value(Uint8List.fromList(_stdoutBytes));

  @override
  Stream<Uint8List> get stderr =>
      Stream.value(Uint8List.fromList(_stderrBytes));

  @override
  Future<void> get done => _done;
}
