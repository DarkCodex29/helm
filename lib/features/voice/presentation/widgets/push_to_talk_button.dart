import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/voice/application/push_to_talk_recorder.dart';
import 'package:helm/features/voice/application/voice_recorder_provider.dart';
import 'package:helm/features/voice/domain/voice_recorder.dart';
import 'package:helm/features/voice/domain/voice_transcription.dart';

/// Exactly [VoiceTranscriber.transcribe]'s shape, so the real
/// implementation can be handed to [PushToTalkButton] directly while a
/// test substitutes a fake without constructing a live SSH session.
typedef VoiceTranscribe =
    Future<VoiceTranscription> Function(VoiceRecording recording);

/// The footer's push-to-talk control: press and HOLD to record, release
/// to transcribe and type the result at the prompt un-sent.
///
/// This widget owns exactly two things a caller cannot supply: the
/// [PushToTalkRecorder] gesture wrapper (so disposal mid-press cancels
/// cleanly, per that class's own doc comment) and the pressed/recording
/// visual. Everything that depends on a live connection — whether there
/// is a session to transcribe through, and where the transcript goes — is
/// handed in, so this widget is testable with plain fakes and carries no
/// knowledge of `TerminalSession`, `SftpUploadService` or
/// `HostCommandRunner`.
///
/// NEVER LOGS THE TRANSCRIPT. The only things this widget hands to
/// [onStatus] are short, fixed, human-facing strings — "Recording…",
/// "Microphone permission denied", "Transcription failed", "Not
/// connected" — never [VoiceTranscriptionSucceeded.text] and never
/// [VoiceTranscriptionFailed.detail] (which can itself carry no
/// dictation, but is still infrastructure detail this UI has no reason to
/// surface to a friend using a public app).
class PushToTalkButton extends ConsumerStatefulWidget {
  const PushToTalkButton({
    super.key,
    required this.resolveTranscribe,
    required this.typeAtPrompt,
    required this.onStatus,
  });

  /// Called once per release, AFTER the recording has finished, so it
  /// reflects the connection state at that moment rather than one
  /// captured when the press began. Returning null means "nothing to
  /// transcribe through right now" — the recording is discarded and
  /// [onStatus] is told "Not connected", never typed anywhere.
  final VoiceTranscribe? Function() resolveTranscribe;

  /// Types a successful transcript at the prompt, un-sent. Exactly
  /// `TerminalSession.typeAtPrompt`, handed in rather than reached for.
  final void Function(String text) typeAtPrompt;

  /// Reports transient status text for the footer to show (or null to
  /// clear it). Never the transcript itself — see this class's own
  /// comment above.
  final void Function(String? message) onStatus;

  @override
  ConsumerState<PushToTalkButton> createState() => _PushToTalkButtonState();
}

class _PushToTalkButtonState extends ConsumerState<PushToTalkButton> {
  PushToTalkRecorder? _recorder;
  bool _recording = false;

  PushToTalkRecorder _recorderFor(VoiceRecorder voiceRecorder) =>
      _recorder ??= PushToTalkRecorder(voiceRecorder);

  @override
  void dispose() {
    // The pocket-microphone case: a press that never released cleanly
    // because this widget was torn down first. PushToTalkRecorder.dispose
    // cancels (not stops) whatever is still open — see its own doc
    // comment for why that distinction matters.
    _recorder?.dispose();
    super.dispose();
  }

  Future<void> _onPressStart() async {
    final recorder = _recorderFor(ref.read(voiceRecorderProvider));
    final result = await recorder.onPressStart();
    if (!mounted) return;
    switch (result) {
      case PushToTalkStartResult.started:
        setState(() => _recording = true);
        widget.onStatus('Recording…');
      case PushToTalkStartResult.denied:
        widget.onStatus('Microphone permission denied');
      case PushToTalkStartResult.failed:
        widget.onStatus('Could not start recording');
    }
  }

  Future<void> _onPressEnd() async {
    final recorder = _recorder;
    if (recorder == null) return;
    final recording = await recorder.onPressEnd();
    if (mounted) {
      setState(() => _recording = false);
    }
    // Nothing was recording — onPressStart already reported denial or
    // failure above; there is no recording to transcribe or discard.
    if (recording == null) return;

    final transcribe = widget.resolveTranscribe();
    if (transcribe == null) {
      await recording.delete();
      if (mounted) widget.onStatus('Not connected');
      return;
    }

    if (mounted) widget.onStatus('Transcribing…');
    final result = await transcribe(recording);
    if (!mounted) return;
    switch (result) {
      case VoiceTranscriptionSucceeded(:final text):
        widget.onStatus(null);
        widget.typeAtPrompt(text);
      case VoiceTranscriptionFailed():
        widget.onStatus('Transcription failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: KeyboardLayoutSemantics.voice,
      label: _recording ? 'Recording, release to finish' : 'Hold to dictate',
      child: Tooltip(
        message: 'Hold to dictate',
        child: Listener(
          behavior: HitTestBehavior.opaque,
          // Pointer events, not GestureDetector's tap recognizer: a tap can
          // be disqualified (and lose its press) by ordinary finger
          // tremor while holding, which would silently discard a
          // recording nobody meant to cancel. Only PushToTalkRecorder's
          // own dispose() — this widget being torn down mid-press — ever
          // discards instead of finishing.
          onPointerDown: (_) => unawaited(_onPressStart()),
          onPointerUp: (_) => unawaited(_onPressEnd()),
          onPointerCancel: (_) => unawaited(_onPressEnd()),
          child: SizedBox(
            height: 48,
            width: 48,
            child: Icon(
              _recording ? Icons.mic : Icons.mic_none,
              color: _recording ? AppTheme.error : AppTheme.onSurfaceMuted,
            ),
          ),
        ),
      ),
    );
  }
}
