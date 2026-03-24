import 'dart:convert';

import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Persists and retrieves [ConnectionProfile] instances using SharedPreferences.
class ConnectionProfileRepository {
  static final _log = HelmLogger('ConnectionProfileRepository');
  static const _uuid = Uuid();

  // ── Read ────────────────────────────────────────────────────────────────

  Future<List<ConnectionProfile>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(AppConstants.profilesStorageKey) ?? [];
    return raw
        .map((json) {
          try {
            return ConnectionProfile.fromJson(
              jsonDecode(json) as Map<String, dynamic>,
            );
          } catch (e) {
            _log.e('Failed to deserialize profile', e);
            return null;
          }
        })
        .whereType<ConnectionProfile>()
        .toList();
  }

  Future<ConnectionProfile?> getById(String id) async {
    final all = await getAll();
    try {
      return all.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<ConnectionProfile?> getDefault() async {
    final all = await getAll();
    try {
      return all.firstWhere((p) => p.isDefault);
    } catch (_) {
      return all.isEmpty ? null : all.first;
    }
  }

  // ── Write ────────────────────────────────────────────────────────────────

  /// Saves a new [profile]. Generates a UUID id if [profile.id] is empty.
  Future<ConnectionProfile> create(ConnectionProfile profile) async {
    final withId = profile.id.isNotEmpty
        ? profile
        : profile.copyWith(id: _uuid.v4());

    final all = await getAll();
    final updated = [...all, withId];
    await _persist(updated);
    _log.i('Created profile: ${withId.id}');
    return withId;
  }

  /// Replaces the profile with the same [id]. Throws if not found.
  Future<void> update(ConnectionProfile profile) async {
    final all = await getAll();
    final index = all.indexWhere((p) => p.id == profile.id);
    if (index == -1) throw StateError('Profile ${profile.id} not found');
    all[index] = profile;
    await _persist(all);
    _log.i('Updated profile: ${profile.id}');
  }

  Future<void> delete(String id) async {
    final all = await getAll();
    final updated = all.where((p) => p.id != id).toList();
    await _persist(updated);
    _log.i('Deleted profile: $id');
  }

  /// Marks [id] as the default and clears isDefault on all others.
  Future<void> setDefault(String id) async {
    final all = await getAll();
    final updated = all.map((p) => p.copyWith(isDefault: p.id == id)).toList();
    await _persist(updated);
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  Future<void> _persist(List<ConnectionProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = profiles.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(AppConstants.profilesStorageKey, raw);
  }
}
