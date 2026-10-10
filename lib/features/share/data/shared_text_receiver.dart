import 'dart:async';

import 'package:flutter/services.dart';
import 'package:helm/core/utils/logger.dart';

/// The channel `SharedTextPlugin.kt` answers on.
///
/// Duplicated in that file as `CHANNEL`, and the two MUST stay equal.
const String kSharedTextMethodChannel = 'helm/shared_text';

/// Everything helm asks of the platform's `ACTION_SEND` share machinery.
///
/// A seam for the same reason `ForegroundServiceHost` is one: nothing
/// outside [PlatformSharedTextReceiver] touches a [MethodChannel], so
/// consumers are testable without a platform, and a platform with no
/// share sheet at all (iOS, for now) is one implementation away rather
/// than a rewrite.
///
/// ## Two delivery paths, because they are genuinely different
///
/// A share that COLD-STARTS helm puts the intent on the Activity at
/// creation time, before any Dart code is listening — so the native side
/// has to HOLD it until something asks. [takeInitialSharedText] is that
/// ask: a pull, answered once per hold.
///
/// A share arriving while helm is already running has a live Dart
/// listener waiting, so the native side PUSHES it straight onto
/// [sharedText] instead of stashing anything.
abstract interface class SharedTextReceiver {
  /// Asks the platform for the text a cold start was launched with, if
  /// any.
  ///
  /// Returns null when helm was not opened via a share, or the hold was
  /// already consumed. Call once, early in startup — a second call
  /// answering null is the correct way to learn the hold is empty, not a
  /// sign anything went wrong.
  Future<String?> takeInitialSharedText();

  /// Shared text pushed from the platform while helm is already running.
  Stream<String> get sharedText;
}

/// The real receiver, over a [MethodChannel] to `SharedTextPlugin.kt`.
class PlatformSharedTextReceiver implements SharedTextReceiver {
  PlatformSharedTextReceiver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kSharedTextMethodChannel) {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  static final _log = HelmLogger('SharedTextReceiver');

  final MethodChannel _channel;
  final _controller = StreamController<String>.broadcast();

  @override
  Future<String?> takeInitialSharedText() async {
    try {
      final text = await _channel.invokeMethod<String>('takeInitialSharedText');
      return _normalise(text);
    } on PlatformException catch (e) {
      _log.w('Could not read the cold-start share: ${e.code} ${e.message}');
      return null;
    } on MissingPluginException {
      // Every platform except Android, or a test with no handler wired.
      return null;
    }
  }

  @override
  Stream<String> get sharedText => _controller.stream;

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method != 'onSharedText') return null;
    final text = _normalise(
      call.arguments is String ? call.arguments as String : null,
    );
    if (text != null) _controller.add(text);
    return null;
  }

  /// Null for anything that is not a non-blank string, so every caller
  /// gets the same answer for "nothing worth delivering" instead of each
  /// reimplementing the blank check.
  String? _normalise(String? text) {
    if (text == null) return null;
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Detaches the method call handler so a disposed receiver stops
  /// answering for a channel another instance (a hot-restarted app, a
  /// later test) may install its own handler on.
  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
