import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/voice/data/record_plugin_voice_recorder.dart';
import 'package:helm/features/voice/domain/voice_recorder.dart';

/// Chooses the real [VoiceRecorder] in ONE place, following the same
/// discipline `uploadSourcePickerProvider` documents for the iOS/Android
/// gateway choice.
///
/// There is no `Platform.isIOS` here, and that absence is deliberate, not
/// an oversight: [RecordPluginVoiceRecorder] is already the single
/// implementation for both platforms (see its own doc comment for why —
/// the `record` package is itself federated into `record_android` and
/// `record_ios`). A provider still exists, in the same place the per-
/// platform decision would otherwise live, so that nothing above it ever
/// constructs [RecordPluginVoiceRecorder] directly and a future seam
/// change (a platform-specific override, a test double) has exactly one
/// place to happen.
final voiceRecorderProvider = Provider<VoiceRecorder>(
  (_) => RecordPluginVoiceRecorder(),
);
