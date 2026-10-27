/// What came back from asking the Mac to transcribe one [VoiceRecording].
///
/// SEALED for the same reason [VoiceRecordingStart] is one: this caller
/// must tell apart "nothing to type" from "here is text to type at the
/// prompt", and a bool loses the detail a log line needs — see
/// [VoiceTranscriptionFailed.detail]'s own comment for why that detail is
/// never the transcript itself.
sealed class VoiceTranscription {
  const VoiceTranscription();
}

/// Transcription succeeded. [text] is what goes at the remote prompt,
/// un-sent — see task 1's `typeAtPrompt`, which this feeds.
final class VoiceTranscriptionSucceeded extends VoiceTranscription {
  const VoiceTranscriptionSucceeded(this.text);

  /// NEVER LOG THIS. Dictation can carry secrets; see
  /// `VoiceTranscriber`'s class comment for the logging rule this type
  /// exists to make easy to follow — a caller that logs `result` instead
  /// of reaching for `.text` cannot leak it by accident.
  final String text;
}

/// The upload, the remote command, or the result parsing failed. Cleanup
/// (remote and local audio) has already run by the time this is returned
/// — see `VoiceTranscriber.transcribe`'s `finally`.
final class VoiceTranscriptionFailed extends VoiceTranscription {
  const VoiceTranscriptionFailed(this.detail);

  /// Free text for logs. A plugin/transport error string, never a
  /// transcript and never audio content.
  final String detail;
}
