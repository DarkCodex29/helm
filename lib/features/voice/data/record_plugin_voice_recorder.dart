import 'dart:io';

import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/voice/domain/voice_recorder.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

/// Where [RecordPluginVoiceRecorder] writes its temp WAV files.
///
/// A seam for the same reason `DownloadDirectoryResolver` is one on
/// `SftpDownloadService`: `path_provider`'s answer comes over a platform
/// channel that does not exist in a unit test, and nothing in this
/// class's own contract depends on which directory it is -- only that it
/// exists and this process may write there.
typedef TempDirectoryResolver = Future<Directory> Function();

/// The only real [VoiceRecorder], over the `record` package.
///
/// UNLIKE [DocumentTreeGateway] / [SafDocumentTreeGateway], there is no
/// second implementation and no provider choosing between them. `record`
/// is itself a federated plugin -- `record_android` and `record_ios` are
/// both declared dependencies of the `record` package, verified before
/// adding it -- so the iOS/Android fork this feature would otherwise need
/// is already made, inside the dependency, rather than in this app.
class RecordPluginVoiceRecorder implements VoiceRecorder {
  RecordPluginVoiceRecorder({
    AudioRecorder? recorder,
    Uuid? uuid,
    TempDirectoryResolver? tempDirectory,
  }) : _recorder = recorder ?? AudioRecorder(),
       _uuid = uuid ?? const Uuid(),
       _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  static final _log = HelmLogger('RecordPluginVoiceRecorder');

  final AudioRecorder _recorder;
  final Uuid _uuid;
  final TempDirectoryResolver _tempDirectory;

  /// Set the moment a recording successfully starts, cleared the moment it
  /// stops or is cancelled. This is the one piece of state this class
  /// keeps, and it exists for exactly one reason: so a failed [stop] or a
  /// called [cancel] knows which temp file to delete.
  String? _activePath;

  /// 16 kHz mono WAV, matching S5's measured constraint and this task's
  /// explicit requirement. `AudioEncoder.wav` is PCM-16 with a WAV header
  /// (record_platform_interface's own doc comment on the enum value), so
  /// no separate conversion step is needed before upload.
  static const _config = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
  );

  @override
  Future<VoiceRecordingStart> start() async {
    // Requested on FIRST USE: `request: true` (the default) only shows a
    // system prompt the very first time, or after the app's grant was
    // reset; a held grant or a permanent denial both return immediately
    // with no prompt. Nothing calls this at app launch -- it only runs when
    // a press-to-talk gesture actually asks to record.
    final granted = await _recorder.hasPermission();
    if (!granted) {
      _log.w('Microphone permission denied; recording not started');
      return const VoiceRecordingDenied();
    }

    final path = await _newTempPath();
    try {
      await _recorder.start(_config, path: path);
    } catch (error, stack) {
      _log.e('Failed to start recording', error, stack);
      await _deleteIfExists(path);
      return VoiceRecordingStartFailed('$error');
    }
    _activePath = path;
    return const VoiceRecordingStarted();
  }

  @override
  Future<VoiceRecording?> stop() async {
    final path = _activePath;
    _activePath = null;
    if (path == null) return null;

    String? producedPath;
    try {
      producedPath = await _recorder.stop();
    } catch (error, stack) {
      _log.e('Failed to stop recording', error, stack);
      await _deleteIfExists(path);
      return null;
    }

    if (producedPath == null) {
      // The platform stopped cleanly but reports no file -- same outcome as
      // a thrown stop from this class's caller's point of view: nothing to
      // hand back, and nothing left on disk.
      await _deleteIfExists(path);
      return null;
    }
    return VoiceRecording(producedPath);
  }

  @override
  Future<void> cancel() async {
    final path = _activePath;
    _activePath = null;
    if (path == null) return;
    try {
      await _recorder.cancel();
    } catch (error, stack) {
      // cancel() already means "discard"; a plugin exception on the way
      // out does not change that intent. Logged, not rethrown -- there is
      // no caller decision left to make, only cleanup.
      _log.w('cancel() reached the platform with an error: $error\n$stack');
    }
    await _deleteIfExists(path);
  }

  Future<String> _newTempPath() async {
    final dir = await _tempDirectory();
    return '${dir.path}/voice_${_uuid.v4()}.wav';
  }

  Future<void> _deleteIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
