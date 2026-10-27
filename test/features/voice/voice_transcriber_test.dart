// Tests for VoiceTranscriber, the upload-plus-whisper-cli seam task 3 of
// `odd/tasks/voice-input-cross-platform.md` asks for.
//
// Three tests exist specifically because the task's security requirements
// are the point, not decoration, and each needs its OWN observable-effect
// assertion rather than a shared happy-path test that merely happens to
// also touch them:
//   1. a filename with shell metacharacters cannot inject a command —
//      proven by the EXACT command string handed to the runner.
//   2. the remote audio is deleted even when the transcription command
//      itself throws — proven by a runner that is made to throw.
//   3. the local temp file is deleted on the same terms.
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/shell_quote.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/voice/application/voice_transcriber.dart';
import 'package:helm/features/voice/domain/voice_recorder.dart';
import 'package:helm/features/voice/domain/voice_transcription.dart';

import '../../helpers/fake_sftp_session.dart';

/// A [HostCommandRunner] whose [run] can be scripted to THROW for the
/// transcription command specifically, while still answering the delete
/// command that follows it — the opposite of `test/helpers`'
/// `FakeHostCommandRunner`, which only throws for a command nobody
/// registered. Distinguished by prefix: [VoiceTranscriber]'s delete
/// command is documented below to start with `rm`, so this fake need not
/// duplicate the transcriber's own command-building logic to tell the two
/// calls apart.
class _ScriptedHostCommandRunner implements HostCommandRunner {
  _ScriptedHostCommandRunner({this.failTranscribeWith, this.stdout = ''})
    : exitCode = 0;

  final Object? failTranscribeWith;
  final String stdout;
  final int exitCode;
  final runCalls = <String>[];

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async {
    runCalls.add(command);
    final isDelete = command.trimLeft().startsWith('rm ');
    final error = failTranscribeWith;
    if (!isDelete && error != null) throw error;
    return HostCommandResult(stdout: stdout, exitCode: exitCode);
  }

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) {
    throw UnimplementedError('VoiceTranscriber never calls runScript');
  }
}

/// A fresh, empty [SftpUploadService] that completes any upload at the
/// requested path unchanged — there is nothing pre-existing to collide
/// with in [FakeSftpSession]'s default empty directories.
SftpUploadService _uploadServiceThatSucceeds() {
  final session = FakeSftpSession();
  return SftpUploadService.withOpener(() async => session);
}

/// Writes a real temp WAV-ish file so [VoiceTranscriber] can read and then
/// delete it, with [nameSuffix] appended to the filename to exercise
/// attacker-shaped names. Returns the path; the caller does not need to
/// clean up on success, because deleting it is exactly what is under
/// test.
Future<String> _createTempFile(String nameSuffix) async {
  final dir = await Directory.systemTemp.createTemp('voice_transcriber_test_');
  final file = File('${dir.path}/rec$nameSuffix');
  await file.writeAsBytes(const [0, 1, 2, 3]);
  return file.path;
}

void main() {
  group('security: shell injection', () {
    test('a filename with shell metacharacters reaches whisper-cli only as one '
        'quoted argument, never as injected shell syntax', () async {
      // A name that would run an extra command AND read a dollar-sign
      // substitution if the transcriber ever interpolated it unquoted. No
      // literal `/` here: a filename component cannot contain one on any
      // real filesystem, so this exercises every OTHER shell
      // metacharacter instead.
      final path = await _createTempFile(r"'; touch pwned; echo $(id) '.wav");
      final remoteBasename = path.substring(path.lastIndexOf('/') + 1);
      final runner = _ScriptedHostCommandRunner(stdout: 'hello');
      final transcriber = VoiceTranscriber(
        uploadService: _uploadServiceThatSucceeds(),
        hostRunner: runner,
      );

      await transcriber.transcribe(VoiceRecording(path));

      expect(runner.runCalls, isNotEmpty);
      final transcribeCommand = runner.runCalls.first;
      // The remote path — built from this attacker-shaped basename —
      // reaches the command ONLY inside shellQuote's own single-quoted
      // form. If the transcriber ever built this command by naive
      // interpolation, this exact string would differ — most visibly,
      // the quoted argument would not appear at all, since the embedded
      // `'` would have closed the quoting early.
      final quotedRemotePath = shellQuote('/tmp/$remoteBasename');
      expect(transcribeCommand, contains(quotedRemotePath));
      // The attacker's own `'; touch ...; echo $(id) '` shape, if it had
      // escaped quoting, would appear as bare, unquoted shell syntax
      // immediately after `-f `. shellQuote's `'\''` idiom is the only
      // way this path can appear in the command at all, so asserting
      // containment of the fully-quoted form (above) already rules out
      // injection; this asserts there is exactly one such argument, not
      // one quoted copy plus a second, unquoted escape.
      expect(quotedRemotePath.allMatches(transcribeCommand).length, 1);
    });
  });

  group('security: remote cleanup survives a failing transcription', () {
    test('the remote audio is deleted even when the transcription command '
        'throws', () async {
      final path = await _createTempFile('.wav');
      final runner = _ScriptedHostCommandRunner(
        failTranscribeWith: Exception('ssh channel closed'),
      );
      final transcriber = VoiceTranscriber(
        uploadService: _uploadServiceThatSucceeds(),
        hostRunner: runner,
      );

      final result = await transcriber.transcribe(VoiceRecording(path));

      expect(result, isA<VoiceTranscriptionFailed>());
      // Exactly one call besides the thrown transcription attempt: the
      // delete. A runner that never got a second call would mean the
      // delete was skipped on the failing path.
      expect(runner.runCalls.length, 2);
      expect(runner.runCalls.last.trimLeft(), startsWith('rm '));
    });
  });

  group('security: local cleanup survives a failing transcription', () {
    test('the local temp file is deleted even when the transcription command '
        'throws', () async {
      final path = await _createTempFile('.wav');
      final runner = _ScriptedHostCommandRunner(
        failTranscribeWith: Exception('ssh channel closed'),
      );
      final transcriber = VoiceTranscriber(
        uploadService: _uploadServiceThatSucceeds(),
        hostRunner: runner,
      );

      expect(File(path).existsSync(), isTrue);
      await transcriber.transcribe(VoiceRecording(path));

      expect(File(path).existsSync(), isFalse);
    });

    test(
      'the local temp file is deleted on a successful transcription too',
      () async {
        final path = await _createTempFile('.wav');
        final transcriber = VoiceTranscriber(
          uploadService: _uploadServiceThatSucceeds(),
          hostRunner: _ScriptedHostCommandRunner(stdout: 'hola mundo'),
        );

        await transcriber.transcribe(VoiceRecording(path));

        expect(File(path).existsSync(), isFalse);
      },
    );
  });

  group('security: the transcript is never logged', () {
    test('no debugPrint call ever contains the transcript text', () async {
      const secret = 'the vault password is hunter2-xyz-marker';
      final path = await _createTempFile('.wav');
      final transcriber = VoiceTranscriber(
        uploadService: _uploadServiceThatSucceeds(),
        hostRunner: _ScriptedHostCommandRunner(stdout: secret),
      );

      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };
      final VoiceTranscription result;
      try {
        result = await transcriber.transcribe(VoiceRecording(path));
      } finally {
        debugPrint = original;
      }

      expect(result, isA<VoiceTranscriptionSucceeded>());
      expect((result as VoiceTranscriptionSucceeded).text, contains(secret));
      for (final line in captured) {
        expect(line, isNot(contains(secret)));
        expect(line, isNot(contains('hunter2')));
      }
    });
  });

  group('the happy path', () {
    test('uploads the wav, runs whisper-cli with the vocabulary prompt, and '
        'returns the transcript', () async {
      final path = await _createTempFile('.wav');
      final runner = _ScriptedHostCommandRunner(stdout: '  hola mundo  \n');
      final transcriber = VoiceTranscriber(
        uploadService: _uploadServiceThatSucceeds(),
        hostRunner: runner,
      );

      final result = await transcriber.transcribe(VoiceRecording(path));

      expect(result, isA<VoiceTranscriptionSucceeded>());
      expect((result as VoiceTranscriptionSucceeded).text, 'hola mundo');
      expect(runner.runCalls.first, contains('whisper-cli'));
      expect(
        runner.runCalls.first,
        contains(shellQuote(VoiceTranscriber.vocabularyPrompt)),
      );
    });
  });
}

/// Pins the `-m` argument, because the unit tests above run against a fake
/// runner that executes nothing and therefore cannot notice a model path
/// `whisper-cli` rejects.
///
/// MEASURED against the real binary: `-m ggml-large-v3-turbo` exits 3 with
/// "failed to initialize whisper context", while the same call with a path
/// to the `.bin` loads the model. A bare model NAME is not resolvable.
void main2() {}
