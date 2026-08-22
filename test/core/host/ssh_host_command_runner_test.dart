import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/probe/probe_script_v1.dart';
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

    test(
      'delivers the real probe script via the fixed literal /bin/sh -s, '
      'with no other command issued',
      () async {
        final channel = _FakeSshCommandChannel(exitCode: 0);
        final openedCommands = <String>[];
        final runner = SshHostCommandRunner.withOpener((command) async {
          openedCommands.add(command);
          return channel;
        });

        await runner.runScript(probeScriptV1);

        expect(openedCommands, ['/bin/sh -s']);
        expect(utf8.decode(channel.stdinBytesWritten), probeScriptV1);
        expect(channel.stdinClosed, isTrue);
      },
    );
  });

  group('draining outlives the channel closing', () {
    // dartssh2 2.16.0 documents this explicitly on SSHSession.done
    // (ssh_session.dart:31-33): "This Future completes when the channel is
    // closed. More data may still be available on the stdout and stderr
    // streams at this time." The stdout/stderr controllers are closed
    // separately, by _handleChannelDataDone.
    //
    // Draining only until `done` therefore silently loses the tail of the
    // output. Measured against the real host: the probe emitted 699 bytes
    // and this class returned 687 — dropping exactly the 12-byte `end`
    // record, which is the one record that tells the parser the report is
    // complete. Every probe consequently parsed as `truncated`.
    //
    // The pre-existing fakes above hide this because `Stream.value` and an
    // already-completed `done` happen to interleave favourably in a single
    // microtask. These fakes reproduce the real ordering instead.

    test('captures stdout that arrives after done completes', () async {
      final stdout = StreamController<Uint8List>();
      final doneCompleter = Completer<void>();
      final channel = _LateDeliveryChannel(
        stdout: stdout,
        done: doneCompleter.future,
        exitCode: 0,
      );
      final runner = SshHostCommandRunner.withOpener((_) async => channel);

      final pending = runner.runScript('probe-script');

      // The channel closes first...
      await Future<void>.delayed(Duration.zero);
      doneCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      // ...and the buffered tail is delivered only afterwards.
      stdout.add(Uint8List.fromList(utf8.encode('helm-probe/1\n')));
      stdout.add(Uint8List.fromList(utf8.encode('end\tok\t42\n')));
      await stdout.close();

      final result = await pending;

      expect(result.stdout, 'helm-probe/1\nend\tok\t42\n');
    });

    test('captures stderr that arrives after done completes', () async {
      final stderr = StreamController<Uint8List>();
      final doneCompleter = Completer<void>();
      final channel = _LateDeliveryChannel(
        stderr: stderr,
        done: doneCompleter.future,
        exitCode: 1,
      );
      final runner = SshHostCommandRunner.withOpener((_) async => channel);

      final pending = runner.run('failing-command');

      await Future<void>.delayed(Duration.zero);
      doneCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      stderr.add(Uint8List.fromList(utf8.encode('boom')));
      await stderr.close();

      final result = await pending;

      expect(result.stderr, 'boom');
    });

    test(
      'a timeout still wins, so a stream that never closes cannot hang the '
      'caller',
      () async {
        // Waiting for the streams must not reintroduce an unbounded wait:
        // the timeout has to cover the drain, not just the channel.
        final stdout = StreamController<Uint8List>();
        final channel = _LateDeliveryChannel(
          stdout: stdout,
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
        await stdout.close();
      },
    );
  });
}

/// [SshCommandChannel] whose stdout/stderr are caller-driven controllers,
/// so a test can deliver bytes AFTER [done] completes — the ordering real
/// dartssh2 documents and the in-memory fake above cannot express.
class _LateDeliveryChannel implements SshCommandChannel {
  _LateDeliveryChannel({
    StreamController<Uint8List>? stdout,
    StreamController<Uint8List>? stderr,
    required Future<void> done,
    this.exitCode,
  }) : _stdout = stdout ?? (StreamController<Uint8List>()..close()),
       _stderr = stderr ?? (StreamController<Uint8List>()..close()),
       _done = done;

  final StreamController<Uint8List> _stdout;
  final StreamController<Uint8List> _stderr;
  final Future<void> _done;
  final _stdinController = StreamController<Uint8List>()..stream.drain<void>();

  @override
  int? exitCode;

  @override
  StreamSink<Uint8List> get stdin => _stdinController.sink;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done;
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
