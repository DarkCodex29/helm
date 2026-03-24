import 'package:flutter/foundation.dart';

class HelmLogger {
  const HelmLogger(this._tag);

  final String _tag;

  void d(String message) {
    if (kDebugMode) {
      debugPrint('[$_tag] DEBUG: $message');
    }
  }

  void i(String message) {
    if (kDebugMode) {
      debugPrint('[$_tag] INFO:  $message');
    }
  }

  void w(String message) {
    if (kDebugMode) {
      debugPrint('[$_tag] WARN:  $message');
    }
  }

  void e(String message, [Object? error, StackTrace? stackTrace]) {
    if (kDebugMode) {
      debugPrint('[$_tag] ERROR: $message');
      if (error != null) debugPrint('  ↳ $error');
      if (stackTrace != null) debugPrint('  ↳ $stackTrace');
    }
  }
}
