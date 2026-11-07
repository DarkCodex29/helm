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
  bool _disposed = false;

  /// The in-flight [onPressStart], so a release or dispose that lands
  /// before the platform finished starting can wait for it instead of
  /// leaving the microphone open and the temp wav undeleted.
  Future<PushToTalkStartResult>? _starting;

  /// Call when the press begins. Requests microphone permission on first
  /// use, through [VoiceRecorder.start].
  Future<PushToTalkStartResult> onPressStart() {
    final flow = _start();
    _starting = flow;
    return flow.whenComplete(() {
      if (identical(_starting, flow)) _starting = null;
    });
  }

  Future<PushToTalkStartResult> _start() async {
    final result = await _recorder.start();
    switch (result) {
      case VoiceRecordingStarted():
        if (_disposed) {
          // Disposed while start was in flight: nothing asked for this
          // recording any more. Discard it rather than leak the mic.
          unawaited(_recorder.cancel());
          return PushToTalkStartResult.failed;
        }
        _recording = true;
        return PushToTalkStartResult.started;
      case VoiceRecordingDenied():
        return PushToTalkStartResult.denied;
      case VoiceRecordingStartFailed():
        return PushToTalkStartResult.failed;
    }
  }

  /// Call when the press ends normally. Returns the finished recording, or
  /// null if nothing was recording (a denied or failed [onPressStart]) or
  /// the platform could not produce a file. A release that arrives while
  /// start is still in flight waits for it, then stops normally.
  Future<VoiceRecording?> onPressEnd() async {
    final starting = _starting;
    if (starting != null) await starting;
    if (!_recording) return null;
    _recording = false;
    return _recorder.stop();
  }

  /// Call when the widget holding the press is disposed. If a recording
  /// is still open — the press never released cleanly — it is cancelled
  /// and its temp file discarded, not left running or silently kept. If
  /// start is still in flight, the cancel happens as soon as it resolves.
  ///
  /// Fire-and-forget on purpose: `dispose()` methods in this codebase (see
  /// [PlatformSharedTextReceiver.dispose]) are synchronous, and a widget's
  /// `State.dispose()` cannot await one that is not. The cancellation
  /// still happens; it is simply not awaited by the caller.
  void dispose() {
    _disposed = true;
    if (!_recording) return;
    _recording = false;
    unawaited(_recorder.cancel());
  }
}
