// Tests for PushToTalkButton, the footer control that wires the gesture
// (press-and-hold, release) onto PushToTalkRecorder and, on a clean
// release, a caller-supplied transcribe function.
//
// Each test asserts an OBSERVABLE EFFECT — what got typed where, what
// status text appeared — never internal state, per
// `odd/tasks/voice-input-cross-platform.md`'s test-first instructions.
//
// A fake VoiceRecorder stands in for the platform plugin (no device, no
// channel); a fake transcribe function stands in for VoiceTranscriber (no
// SSH session, no upload) — VoiceTranscriber itself is already covered by
// `voice_transcriber_test.dart`. This file only proves the WIRING.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/voice/application/voice_recorder_provider.dart';
import 'package:helm/features/voice/domain/voice_recorder.dart';
import 'package:helm/features/voice/domain/voice_transcription.dart';
import 'package:helm/features/voice/presentation/widgets/push_to_talk_button.dart';

class _FakeVoiceRecorder implements VoiceRecorder {
  VoiceRecordingStart startResult = const VoiceRecordingStarted();
  VoiceRecording stopResult = const VoiceRecording('/tmp/ptt_fake.wav');

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

Future<void> _pumpButton(
  WidgetTester tester, {
  required _FakeVoiceRecorder recorder,
  required VoiceTranscribe? Function() resolveTranscribe,
  required void Function(String text) typeAtPrompt,
  required void Function(String? message) onStatus,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [voiceRecorderProvider.overrideWithValue(recorder)],
      child: MaterialApp(
        home: Scaffold(
          body: PushToTalkButton(
            resolveTranscribe: resolveTranscribe,
            typeAtPrompt: typeAtPrompt,
            onStatus: onStatus,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '1. press and release types the transcript at the prompt, un-sent',
    (tester) async {
      final recorder = _FakeVoiceRecorder();
      final typed = <String>[];
      final statuses = <String?>[];

      await _pumpButton(
        tester,
        recorder: recorder,
        resolveTranscribe: () =>
            (recording) async =>
                const VoiceTranscriptionSucceeded('onTaskRemoved en repo helm'),
        typeAtPrompt: typed.add,
        onStatus: statuses.add,
      );

      final button = find.bySemanticsIdentifier(KeyboardLayoutSemantics.voice);
      expect(button, findsOneWidget);

      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      expect(recorder.startCalls, 1);

      await gesture.up();
      await tester.pumpAndSettle();

      expect(recorder.stopCalls, 1);
      expect(recorder.cancelCalls, 0);
      expect(typed, ['onTaskRemoved en repo helm']);
    },
  );

  testWidgets(
    '2. releasing after a DENIED permission types nothing and surfaces the '
    'denial',
    (tester) async {
      final recorder = _FakeVoiceRecorder()
        ..startResult = const VoiceRecordingDenied();
      final typed = <String>[];
      final statuses = <String?>[];
      var transcribeCalls = 0;

      await _pumpButton(
        tester,
        recorder: recorder,
        resolveTranscribe: () => (recording) async {
          transcribeCalls++;
          return const VoiceTranscriptionSucceeded('should never type');
        },
        typeAtPrompt: typed.add,
        onStatus: statuses.add,
      );

      final button = find.bySemanticsIdentifier(KeyboardLayoutSemantics.voice);
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(typed, isEmpty);
      expect(transcribeCalls, 0);
      expect(recorder.stopCalls, 0);
      expect(
        statuses.whereType<String>().any(
          (message) => message.toLowerCase().contains('permission'),
        ),
        isTrue,
        reason: 'statuses were: $statuses',
      );
    },
  );

  testWidgets(
    '3. a failed transcription types nothing and surfaces the failure',
    (tester) async {
      final recorder = _FakeVoiceRecorder();
      final typed = <String>[];
      final statuses = <String?>[];

      await _pumpButton(
        tester,
        recorder: recorder,
        resolveTranscribe: () =>
            (recording) async =>
                const VoiceTranscriptionFailed('whisper-cli exited 1'),
        typeAtPrompt: typed.add,
        onStatus: statuses.add,
      );

      final button = find.bySemanticsIdentifier(KeyboardLayoutSemantics.voice);
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(typed, isEmpty);
      expect(
        statuses.whereType<String>().any(
          (message) => message.toLowerCase().contains('fail'),
        ),
        isTrue,
        reason: 'statuses were: $statuses',
      );
    },
  );

  testWidgets('4. disposing mid-press cancels the recording, not stops it', (
    tester,
  ) async {
    final recorder = _FakeVoiceRecorder();
    final typed = <String>[];
    final statuses = <String?>[];

    await _pumpButton(
      tester,
      recorder: recorder,
      resolveTranscribe: () => null,
      typeAtPrompt: typed.add,
      onStatus: statuses.add,
    );

    final button = find.bySemanticsIdentifier(KeyboardLayoutSemantics.voice);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    expect(recorder.startCalls, 1);

    // Tear the widget down WITHOUT ever releasing the press.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(recorder.cancelCalls, 1);
    expect(recorder.stopCalls, 0);
    expect(typed, isEmpty);

    // Release the test's own pointer bookkeeping. The widget is already
    // gone, so this routes nowhere and must not re-trigger any handler.
    await gesture.up();
  });

  testWidgets('not connected: types nothing and surfaces it, deletes nothing '
      'remote (resolveTranscribe is never reached)', (tester) async {
    final recorder = _FakeVoiceRecorder();
    final typed = <String>[];
    final statuses = <String?>[];

    await _pumpButton(
      tester,
      recorder: recorder,
      resolveTranscribe: () => null,
      typeAtPrompt: typed.add,
      onStatus: statuses.add,
    );

    final button = find.bySemanticsIdentifier(KeyboardLayoutSemantics.voice);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    // The real event loop, not the fake one testWidgets normally runs on:
    // releasing without a resolved transcribe calls VoiceRecording.delete(),
    // genuine dart:io, which pumpAndSettle's frame scheduling cannot wait
    // for.
    await tester.runAsync(() async {
      await gesture.up();
      // Let the detached _onPressEnd future — which does real file IO via
      // VoiceRecording.delete() — actually finish; it is deliberately not
      // awaited by the pointer callback itself (pointer callbacks are
      // synchronous), so nothing shorter than letting real time pass
      // proves it ran.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(typed, isEmpty);
    expect(
      statuses.whereType<String>().any(
        (message) => message.toLowerCase().contains('connect'),
      ),
      isTrue,
      reason: 'statuses were: $statuses',
    );
  });
}
