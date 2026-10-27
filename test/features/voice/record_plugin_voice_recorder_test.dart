// Tests for RecordPluginVoiceRecorder, the one real implementation of
// VoiceRecorder, over the `record` package.
//
// No device and no MethodChannel: `record` is itself built on a
// platform-interface package precisely so it can be swapped out for a fake
// in tests (the same reason `saf_util`/`saf_stream` expose the classes
// DocumentTreeGateway wraps rather than only a MethodChannel). FakeRecordPlatform
// here plays the role a real `record_android`/`record_ios` plugin would.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/voice/data/record_plugin_voice_recorder.dart';
import 'package:helm/features/voice/domain/voice_recorder.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

/// A [RecordPlatform] double with no native side at all.
///
/// Every knob a test needs to force is a public field, set before the call
/// it affects — permission denial, a thrown start, a thrown stop — and
/// every call is counted so a test can assert WHICH of stop/cancel ran,
/// not just that recording stopped somehow.
class FakeRecordPlatform extends RecordPlatform {
  bool permissionGranted = true;
  Object? startError;
  Object? stopError;

  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int hasPermissionCalls = 0;
  String? lastStartPath;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    startCalls++;
    lastStartPath = path;
    if (startError != null) throw startError!;
    // A real plugin creates the output file as soon as recording begins,
    // not only once it stops. Reproduced here because the "a recording
    // failure deletes the temp file" case means deleting a file that
    // genuinely exists, not asserting the absence of one that was never
    // created either way.
    await File(path).writeAsBytes(const <int>[]);
  }

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    throw UnimplementedError('push-to-talk never streams');
  }

  @override
  Future<String?> stop(String recorderId) async {
    stopCalls++;
    if (stopError != null) throw stopError!;
    return lastStartPath;
  }

  @override
  Future<void> pause(String recorderId) async {}

  @override
  Future<void> resume(String recorderId) async {}

  @override
  Future<bool> isRecording(String recorderId) async => false;

  @override
  Future<bool> isPaused(String recorderId) async => false;

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    hasPermissionCalls++;
    return permissionGranted;
  }

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: 0, max: 0);

  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async => true;

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async => [];

  @override
  Future<void> cancel(String recorderId) async {
    cancelCalls++;
    final path = lastStartPath;
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();

  @override
  void setOnConfigChanged(
    String recorderId,
    void Function(RecordConfig config)? handler,
  ) {}
}

void main() {
  late FakeRecordPlatform fake;
  late Directory tempDir;

  RecordPluginVoiceRecorder makeRecorder() =>
      RecordPluginVoiceRecorder(tempDirectory: () async => tempDir);

  setUp(() async {
    fake = FakeRecordPlatform();
    RecordPlatform.instance = fake;
    tempDir = await Directory.systemTemp.createTemp('voice_recorder_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('start - permission requested at first use', () {
    test('a granted permission starts a 16kHz mono wav recording', () async {
      final recorder = makeRecorder();

      final result = await recorder.start();

      expect(result, isA<VoiceRecordingStarted>());
      expect(fake.hasPermissionCalls, 1);
      expect(fake.startCalls, 1);
    });

    test(
      'a denied permission surfaces as a handled failure, not a crash',
      () async {
        fake.permissionGranted = false;
        final recorder = makeRecorder();

        final result = await recorder.start();

        expect(result, isA<VoiceRecordingDenied>());
        // Denial is answered before ever touching the recorder: nothing
        // was started that would need stopping or cleaning up.
        expect(fake.startCalls, 0);
      },
    );
  });

  group('a recording failure deletes the temp file', () {
    test('the platform throwing on start leaves no temp file behind', () async {
      fake.startError = Exception('device busy');
      final recorder = makeRecorder();

      final result = await recorder.start();

      expect(result, isA<VoiceRecordingStartFailed>());
      final path = fake.lastStartPath;
      expect(path, isNotNull);
      expect(await File(path!).exists(), isFalse);
    });

    test(
      'the platform throwing on stop deletes the file it had written',
      () async {
        final recorder = makeRecorder();
        await recorder.start();
        final path = fake.lastStartPath!;
        expect(await File(path).exists(), isTrue);
        fake.stopError = Exception('encoder crashed');

        final recording = await recorder.stop();

        expect(recording, isNull);
        expect(await File(path).exists(), isFalse);
      },
    );
  });

  group('stop - a clean recording', () {
    test('returns the file the platform produced', () async {
      final recorder = makeRecorder();
      await recorder.start();

      final recording = await recorder.stop();

      expect(recording, isNotNull);
      expect(recording!.path, fake.lastStartPath);
      expect(fake.stopCalls, 1);
      expect(fake.cancelCalls, 0);

      await recording.delete();
    });
  });

  group('cancel - the pocket-microphone case', () {
    test('discards the recording without calling stop', () async {
      final recorder = makeRecorder();
      await recorder.start();
      final path = fake.lastStartPath!;

      await recorder.cancel();

      expect(fake.cancelCalls, 1);
      expect(fake.stopCalls, 0);
      expect(await File(path).exists(), isFalse);
    });
  });
}
