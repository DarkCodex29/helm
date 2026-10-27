import 'dart:io';

/// What happened when a push-to-talk press asked a [VoiceRecorder] to
/// [VoiceRecorder.start].
///
/// A SEALED outcome rather than a bool, because "no" has two different
/// causes a caller must tell apart: the user said no (ask again later, no
/// different than any other denial in this app) and the platform could not
/// record at all (a bug to surface, not a permission prompt to retry).
sealed class VoiceRecordingStart {
  const VoiceRecordingStart();
}

/// Recording began. Pair this with exactly one later call to
/// [VoiceRecorder.stop] or [VoiceRecorder.cancel].
final class VoiceRecordingStarted extends VoiceRecordingStart {
  const VoiceRecordingStarted();
}

/// The user (or a prior permanent denial) refused microphone access.
///
/// THIS IS NOT A CRASH AND NOT A SILENT NO-OP — it is the handled failure
/// S3 and the task's acceptance criteria both require. A caller answers
/// this by telling the user why nothing was recorded, the same way a
/// declined folder pick or a declined file pick is answered elsewhere in
/// this app.
final class VoiceRecordingDenied extends VoiceRecordingStart {
  const VoiceRecordingDenied();
}

/// The platform refused to start recording for a reason that is not a
/// permission denial — a device already in use, a plugin exception, or
/// anything else [AudioRecorder.start] threw.
final class VoiceRecordingStartFailed extends VoiceRecordingStart {
  const VoiceRecordingStartFailed(this.detail);

  /// Free text for logs, never shown to the user as-is and never a
  /// transcript — see this feature's security boundary on never logging
  /// dictation content. This is a plugin error string, not audio content.
  final String detail;
}

/// A finished recording: 16 kHz mono WAV, written to a temporary file the
/// CALLER now owns.
///
/// [delete] exists because the caller decides when the file is no longer
/// needed — after a successful upload, or immediately, if the caller
/// changes its mind. [VoiceRecorder] deletes the file ITSELF only when a
/// recording never reaches this class at all (a start or stop failure);
/// once a [VoiceRecording] is handed back, ownership has passed.
final class VoiceRecording {
  const VoiceRecording(this.path);

  /// Absolute path to the temporary WAV file.
  final String path;

  /// Deletes the temporary file. Safe to call on a file that is already
  /// gone.
  Future<void> delete() async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

/// Everything helm asks of the platform's microphone, to record one
/// push-to-talk utterance.
///
/// An interface for the same reason [DocumentTreeGateway] is one: the real
/// implementation reaches the platform through a plugin that does not
/// exist in a unit test, so this is the seam that lets push-to-talk's
/// start/stop/dispose semantics — including the pocket-microphone case —
/// be tested without a device.
///
/// UNLIKE [DocumentTreeGateway] / [SafDocumentTreeGateway], this seam has
/// exactly ONE implementation, not one per platform. The `record` package
/// is itself a federated plugin (`record_android` + `record_ios` behind
/// one Dart API), so there is no iOS/Android fork to make here — the thing
/// [UploadSourcePicker]'s provider does for SAF-vs-not has nothing to
/// decide in this feature. See [RecordPluginVoiceRecorder] for the one
/// real implementation and why it is the only one.
abstract interface class VoiceRecorder {
  /// Starts a new recording, requesting microphone permission on FIRST USE
  /// if it has not already been granted or denied — never at app launch.
  ///
  /// Must be paired with exactly one later call to [stop] or [cancel].
  /// Calling [start] again while already recording is a caller bug; the
  /// implementation is not required to detect it.
  Future<VoiceRecordingStart> start();

  /// Stops the current recording and returns the finished file.
  ///
  /// Returns null if the platform could not produce a file — e.g. the
  /// native stop call failed — in which case the implementation has
  /// already deleted whatever temp file existed. Only call this after a
  /// [start] that returned [VoiceRecordingStarted].
  Future<VoiceRecording?> stop();

  /// Stops and DISCARDS whatever is currently recording, deleting its
  /// temp file.
  ///
  /// This is the pocket-microphone case: a press that never released
  /// cleanly because the widget holding it was disposed mid-recording.
  /// Safe to call when nothing is recording.
  Future<void> cancel();
}
