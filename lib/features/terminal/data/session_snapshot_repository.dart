import 'dart:convert';

import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Modelo simple que representa una tab abierta al momento del crash.
class TabSnapshot {
  const TabSnapshot({
    required this.profileId,
    required this.profileName,
    required this.tmuxSessionName,
  });

  final String profileId;
  final String profileName;
  final String tmuxSessionName;

  Map<String, dynamic> toJson() => {
    'profileId': profileId,
    'profileName': profileName,
    'tmuxSessionName': tmuxSessionName,
  };

  factory TabSnapshot.fromJson(Map<String, dynamic> json) => TabSnapshot(
    profileId: json['profileId'] as String,
    profileName: json['profileName'] as String,
    tmuxSessionName: json['tmuxSessionName'] as String,
  );
}

/// Persiste y recupera el snapshot de tabs abiertas para detección de crash.
///
/// Flujo (lifecycle-based):
/// - En `paused` (app va a background): se guarda snapshot + timestamp.
/// - En `resumed` (app vuelve sin crash): se limpia el snapshot.
/// - Al iniciar: si hay snapshot con timestamp > 5s de antigüedad → crash real.
///   Si tiene menos de 5s, fue un resume rápido (Flutter llama paused+resumed
///   en ciertos dispositivos), se ignora.
class SessionSnapshotRepository {
  static final _log = HelmLogger('SessionSnapshotRepository');

  /// Key privada para el timestamp del snapshot (ms desde epoch).
  static const _timestampKey = 'helm_session_snapshot_ts';

  /// Umbral mínimo en ms para considerar un snapshot como crash real.
  static const _crashThresholdMs = 5000;

  /// Marca la sesión como "sucia" y persiste el snapshot de tabs actuales
  /// junto con el timestamp actual.
  Future<void> markDirty(List<TabSnapshot> tabs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(tabs.map((t) => t.toJson()).toList());
      await prefs.setBool(AppConstants.sessionDirtyKey, true);
      await prefs.setString(AppConstants.sessionSnapshotKey, encoded);
      await prefs.setInt(_timestampKey, DateTime.now().millisecondsSinceEpoch);
      _log.i('Session marked dirty — ${tabs.length} tab(s) snapshotted');
    } catch (e) {
      _log.e('Failed to mark session dirty', e);
    }
  }

  /// Limpia el flag dirty, el snapshot y el timestamp.
  Future<void> markClean() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConstants.sessionDirtyKey);
      await prefs.remove(AppConstants.sessionSnapshotKey);
      await prefs.remove(_timestampKey);
      _log.i('Session marked clean');
    } catch (e) {
      _log.e('Failed to mark session clean', e);
    }
  }

  /// Retorna `null` si no hay sesión sucia pendiente de recuperar.
  /// Retorna la lista de [TabSnapshot] si hay un crash real pendiente.
  ///
  /// Un crash es "real" si el snapshot tiene más de [_crashThresholdMs] ms
  /// de antigüedad. Snapshots más recientes se ignoran para evitar falsos
  /// positivos cuando Flutter emite `paused` + `resumed` rápidamente.
  Future<List<TabSnapshot>?> getPendingRecovery() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDirty = prefs.getBool(AppConstants.sessionDirtyKey) ?? false;
      if (!isDirty) return null;

      // Verificar antigüedad del snapshot para descartar resumes rápidos.
      final ts = prefs.getInt(_timestampKey) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age < _crashThresholdMs) {
        _log.i(
          'Snapshot too recent (${age}ms) — likely a fast resume, ignoring',
        );
        return null;
      }

      final raw = prefs.getString(AppConstants.sessionSnapshotKey);
      if (raw == null || raw.isEmpty) return null;

      final decoded = jsonDecode(raw) as List<dynamic>;
      final snapshots = decoded
          .map((e) {
            try {
              return TabSnapshot.fromJson(e as Map<String, dynamic>);
            } catch (err) {
              _log.e('Failed to deserialize TabSnapshot', err);
              return null;
            }
          })
          .whereType<TabSnapshot>()
          .toList();

      if (snapshots.isEmpty) return null;

      _log.i(
        'Found pending recovery — ${snapshots.length} tab(s), age: ${age}ms',
      );
      return snapshots;
    } catch (e) {
      _log.e('Failed to get pending recovery', e);
      return null;
    }
  }
}
