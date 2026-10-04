import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Normalized travel (0..1) survives rotation; dimensions are logical pixels.
@immutable
class KeyboardGeometry {
  const KeyboardGeometry(this.x, this.y, this.width, this.height);
  final double x, y, width, height;
}

/// Device ergonomics, not host configuration: font density depends on remote
/// content, but panel placement depends on this screen and the user's hand.
/// Switching servers must not move it, nor should profile exports carry it.
/// Like DownloadDestinationStore, this ordinary, changeable preference is
/// not a credential and belongs in shared_preferences, not secure storage.
/// Invalid data means no preference. Platform/storage failures never escape.
class KeyboardGeometryStore {
  Future<KeyboardGeometry?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConstants.keyboardGeometryKey);
      if (raw == null) return null;
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return null;
      final values = [
        'x',
        'y',
        'width',
        'height',
      ].map((key) => map[key]).toList();
      if (values.any((v) => v is! num || !v.isFinite)) return null;
      final numbers = values.cast<num>().map((v) => v.toDouble()).toList();
      if (numbers[0] < 0 ||
          numbers[0] > 1 ||
          numbers[1] < 0 ||
          numbers[1] > 1 ||
          numbers[2] <= 0 ||
          numbers[3] <= 0) {
        return null;
      }
      return KeyboardGeometry(numbers[0], numbers[1], numbers[2], numbers[3]);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(KeyboardGeometry geometry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AppConstants.keyboardGeometryKey,
        jsonEncode({
          'x': geometry.x,
          'y': geometry.y,
          'width': geometry.width,
          'height': geometry.height,
        }),
      );
    } catch (_) {
      /* A failed preference write must not interrupt typing. */
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConstants.keyboardGeometryKey);
    } catch (_) {
      /* Reset still applies in memory when storage is unavailable. */
    }
  }
}

final keyboardGeometryStoreProvider = Provider<KeyboardGeometryStore>(
  (ref) => KeyboardGeometryStore(),
);
