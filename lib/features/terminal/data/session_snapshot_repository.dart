import 'dart:convert';

import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resolves [TabSnapshot.sessionRef] from a persisted JSON map, falling
/// back to the legacy `tmuxSessionName` key when the neutral key is
/// absent or null (spec.md: session-reference-storage). Same precedence
/// rule as `ConnectionProfile._readSessionRef` and
/// `ProjectShortcut._readSessionRef`, but written as a plain hand-written
/// function rather than a `@JsonKey(readValue:)` callback — [TabSnapshot]
/// has no freezed/json_serializable codegen at all, so none of the
/// codegen constraints those two models work around apply here.
///
/// - Only `tmuxSessionName` present → its value is returned (Requirement:
///   Legacy Field Still Readable).
/// - Only `sessionRef` present → its value is returned.
/// - Both present → `sessionRef`'s own value wins, unconditionally
///   (Requirement: Neutral Field Takes Precedence When Both Are Present).
/// - Neither present → `null`; never invented. Note: since
///   [TabSnapshot.tmuxSessionName] is a required, non-nullable field
///   (matching [ProjectShortcut.tmuxSession]'s nullability, not
///   [ConnectionProfile.tmuxSession]'s), a record missing the
///   `tmuxSessionName` key entirely already fails to load before this
///   function ever runs — that is pre-existing behavior, unchanged by
///   this migration.
String? _readSessionRef(Map<String, dynamic> json) {
  final neutral = json['sessionRef'] as String?;
  if (neutral != null) return neutral;
  return json['tmuxSessionName'] as String?;
}

/// Modelo simple que representa una tab abierta al momento del crash.
///
/// [tmuxSessionName] is the legacy, multiplexer-specific session name and
/// stays a required, real field — every [TabSnapshot] has always carried
/// one, so this migration does not relax that requiredness. [sessionRef]
/// is its neutral replacement, paired with [multiplexer] to say which
/// multiplexer that name applies to (`null` ⇒ host default). The legacy
/// key is never deleted from persisted JSON — see [_readSessionRef] for
/// the read-time precedence rule; [toJson] always includes both keys
/// because both remain real fields on this class.
class TabSnapshot {
  const TabSnapshot({
    required this.profileId,
    required this.profileName,
    required this.tmuxSessionName,
    this.sessionRef,
    this.multiplexer,
  });

  final String profileId;
  final String profileName;

  /// Superseded by [sessionRef] — see the class doc.
  final String tmuxSessionName;

  /// Neutral session reference, meaningful for whichever [multiplexer]
  /// is selected. See [_readSessionRef] for the read-time precedence
  /// rule. Never defaulted here — a null value is not an invented
  /// fallback.
  final String? sessionRef;

  /// Which multiplexer [sessionRef] applies to. `null` means the host's
  /// default multiplexer (see `MultiplexerId` in
  /// `lib/core/host/multiplexer_adapter.dart`).
  final String? multiplexer;

  Map<String, dynamic> toJson() => {
    'profileId': profileId,
    'profileName': profileName,
    'tmuxSessionName': tmuxSessionName,
    'sessionRef': sessionRef,
    'multiplexer': multiplexer,
  };

  factory TabSnapshot.fromJson(Map<String, dynamic> json) => TabSnapshot(
    profileId: json['profileId'] as String,
    profileName: json['profileName'] as String,
    tmuxSessionName: json['tmuxSessionName'] as String,
    sessionRef: _readSessionRef(json),
    multiplexer: json['multiplexer'] as String?,
  );
}

/// Persists and recovers the snapshot of open tabs, for crash detection.
///
/// Lifecycle-driven flow:
/// - On `paused` (app backgrounded): snapshot + timestamp are stored.
/// - On `resumed` (app came back without crashing): the snapshot is cleared.
/// - On launch: a snapshot older than 5s means a real crash. Anything more
///   recent was a fast resume — some devices make Flutter emit `paused`
///   immediately followed by `resumed` — and is ignored.
class SessionSnapshotRepository {
  static final _log = HelmLogger('SessionSnapshotRepository');

  /// Private key for the snapshot timestamp (ms since epoch).
  static const _timestampKey = 'helm_session_snapshot_ts';

  /// Minimum age in ms before a snapshot counts as a real crash.
  static const _crashThresholdMs = 5000;

  /// Marks the session dirty and stores the current tabs alongside the
  /// current timestamp.
  Future<void> markDirty(List<TabSnapshot> tabs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(tabs.map((t) => t.toJson()).toList());
      await prefs.setBool(AppConstants.sessionDirtyKey, true);
      await prefs.setString(AppConstants.sessionSnapshotKey, encoded);
      await prefs.setInt(_timestampKey, DateTime.now().millisecondsSinceEpoch);
      _log.i('Session marked dirty - ${tabs.length} tab(s) snapshotted');
    } catch (e) {
      _log.e('Failed to mark session dirty', e);
    }
  }

  /// Clears the dirty flag, the snapshot and the timestamp.
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

  /// Returns `null` when no dirty session is waiting to be recovered, or
  /// the list of [TabSnapshot] when a real crash is pending.
  ///
  /// A crash counts as real once the snapshot is older than
  /// [_crashThresholdMs]. More recent ones are ignored to avoid false
  /// positives when Flutter emits `paused` + `resumed` in quick succession.
  Future<List<TabSnapshot>?> getPendingRecovery() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDirty = prefs.getBool(AppConstants.sessionDirtyKey) ?? false;
      if (!isDirty) return null;

      // Check the snapshot's age to rule out fast resumes.
      final ts = prefs.getInt(_timestampKey) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age < _crashThresholdMs) {
        _log.i(
          'Snapshot too recent (${age}ms) - likely a fast resume, ignoring',
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
        'Found pending recovery - ${snapshots.length} tab(s), age: ${age}ms',
      );
      return snapshots;
    } catch (e) {
      _log.e('Failed to get pending recovery', e);
      return null;
    }
  }
}
