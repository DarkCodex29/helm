// Tests for PushToTalkRecorder, the gesture-lifecycle wrapper around
// VoiceRecorder. No plugin, no platform channel: VoiceRecorder is a plain
// interface, so these drive it with an in-memory fake and assert what the
// FAKE observed — which call happened, not what field changed — exactly
// as the task's instructions ask.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/voice/application/push_to_talk_recorder.dart';
import 'package:helm/features/voice/domain/voice_recorder.dart';

class FakeVoiceRecorder implements VoiceRecorder {
  VoiceRecordingStart startResult = const VoiceRecordingStarted();
  VoiceRecording? stopResult = const VoiceRecording('/tmp/fake.wav');

  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

  @override
  Future<VoiceRecordingStart> start() async {
    startCalls++;
    return startResult;
  }

  @override
  Future<VoiceRecording?> stop() async {
    stopCalls++;
    return stopResult;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

void main() {
  group('onPressEnd - releasing the press', () {
    test('stops the recording, not cancels it', () async {
      final fake = FakeVoiceRecorder();
      final pushToTalk = PushToTalkRecorder(fake);

      final started = await pushToTalk.onPressStart();
      final recording = await pushToTalk.onPressEnd();

      expect(started, PushToTalkStartResult.started);
      expect(fake.stopCalls, 1);
      expect(fake.cancelCalls, 0);
      expect(recording?.path, '/tmp/fake.wav');
    });

    test(
      'with nothing started (denied earlier) is a no-op, not a stray stop',
      () async {
        final fake = FakeVoiceRecorder()
          ..startResult = const VoiceRecordingDenied();
        final pushToTalk = PushToTalkRecorder(fake);

        await pushToTalk.onPressStart();
        final recording = await pushToTalk.onPressEnd();

        expect(fake.stopCalls, 0);
        expect(recording, isNull);
      },
    );
  });

  group('dispose - the pocket-microphone case', () {
    test('disposing while recording cancels it, not stops it', () async {
      final fake = FakeVoiceRecorder();
      final pushToTalk = PushToTalkRecorder(fake);

      await pushToTalk.onPressStart();
      pushToTalk.dispose();
      await pumpEventQueue();

      expect(fake.cancelCalls, 1);
      expect(fake.stopCalls, 0);
    });

    test('disposing when nothing is recording touches neither', () async {
      final fake = FakeVoiceRecorder();
      final pushToTalk = PushToTalkRecorder(fake);

      pushToTalk.dispose();
      await pumpEventQueue();

      expect(fake.cancelCalls, 0);
      expect(fake.stopCalls, 0);
    });

    test('disposing after a clean release does not cancel twice', () async {
      final fake = FakeVoiceRecorder();
      final pushToTalk = PushToTalkRecorder(fake);

      await pushToTalk.onPressStart();
      await pushToTalk.onPressEnd();
      pushToTalk.dispose();
      await pumpEventQueue();

      expect(fake.cancelCalls, 0);
    });
  });

  group('onPressStart - a denied permission', () {
    test('surfaces as a handled result, not a thrown error', () async {
      final fake = FakeVoiceRecorder()
        ..startResult = const VoiceRecordingDenied();
      final pushToTalk = PushToTalkRecorder(fake);

      final result = await pushToTalk.onPressStart();

      expect(result, PushToTalkStartResult.denied);
    });

    test('a non-permission start failure is distinguished from denial', () async {
      final fake = FakeVoiceRecorder()
        ..startResult = const VoiceRecordingStartFailed('device busy');
      final pushToTalk = PushToTalkRecorder(fake);

      final result = await pushToTalk.onPressStart();

      expect(result, PushToTalkStartResult.failed);
    });
  });
}
