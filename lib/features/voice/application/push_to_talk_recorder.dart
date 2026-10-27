import 'dart:async';

import 'package:helm/features/voice/domain/voice_recorder.dart';

/// What a push-to-talk press-and-hold told the caller when it started.
enum PushToTalkStartResult {
  /// Recording is underway. The caller must eventually call [onPressEnd]
  /// (press released) or [PushToTalkRecorder.dispose] (widget torn down
  /// first).
  started,

  /// The user, or an earlier permanent denial, refused microphone access.
  /// Nothing is recording; [onPressEnd] is a safe no-op if called anyway.
  denied,

  /// The platform could not start recording for a non-permission reason.
  /// Nothing is recording; [onPressEnd] is a safe no-op if called anyway.
  failed,
}

/// Wires push-to-talk GESTURE lifecycle onto a [VoiceRecorder].
///
/// "a toggle left recording in a pocket is a microphone nobody asked
/// for." That sentence has one consequence for this class: there is no
/// method that starts a recording without an obvious, immediate way to
/// stop it again, and tearing down the owning widget counts as one of
/// those ways. [onPressStart] begins recording; [onPressEnd] stops it
/// cleanly on release; [dispose] cancels it if the widget holding the
/// press goes away before release ever happens — the only path that does
/// not end with a finished recording, by design, because nothing asked
/// for one.
///
/// This class owns no plugin and no platform channel; it owns exactly one
/// state bit (is a recording currently open) so that [dispose] knows
/// whether there is anything to cancel. Everything else is delegated to
/// [VoiceRecorder], which is why it is trivially testable with a fake.
class PushToTalkRecorder {
  PushToTalkRecorder(this._recorder);

  final VoiceRecorder _recorder;
  bool _recording = false;

  /// Call when the press begins. Requests microphone permission on first
  /// use, through [VoiceRecorder.start].
  Future<PushToTalkStartResult> onPressStart() async {
    final result = await _recorder.start();
    return switch (result) {
      VoiceRecordingStarted() => () {
        _recording = true;
        return PushToTalkStartResult.started;
      }(),
      VoiceRecordingDenied() => PushToTalkStartResult.denied,
      VoiceRecordingStartFailed() => PushToTalkStartResult.failed,
    };
  }

  /// Call when the press ends normally. Returns the finished recording, or
  /// null if nothing was recording (a denied or failed [onPressStart]) or
  /// the platform could not produce a file.
  Future<VoiceRecording?> onPressEnd() async {
    if (!_recording) return null;
    _recording = false;
    return _recorder.stop();
  }

  /// Call when the widget holding the press is disposed. If a recording
  /// is still open — the press never released cleanly — it is cancelled
  /// and its temp file discarded, not left running or silently kept.
  ///
  /// Fire-and-forget on purpose: `dispose()` methods in this codebase (see
  /// [PlatformSharedTextReceiver.dispose]) are synchronous, and a widget's
  /// `State.dispose()` cannot await one that is not. The cancellation
  /// still happens; it is simply not awaited by the caller.
  void dispose() {
    if (!_recording) return;
    _recording = false;
    unawaited(_recorder.cancel());
  }
}
