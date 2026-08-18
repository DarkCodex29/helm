// ignore_for_file: invalid_annotation_target — see the doc comment on
// ProjectShortcut.sessionRef for why this is a known false positive.
import 'package:freezed_annotation/freezed_annotation.dart';

part 'project_shortcut.freezed.dart';
part 'project_shortcut.g.dart';

/// Resolves [ProjectShortcut.sessionRef] from a persisted JSON map,
/// falling back to the legacy `tmuxSession` key when the neutral key is
/// absent or null (spec.md: session-reference-storage). Same precedence
/// rule and the same `readValue`-callback technique as
/// `ConnectionProfile._readSessionRef` in
/// `lib/features/connection/domain/connection_profile.dart` — see that
/// doc comment for the full rationale and the empirically verified
/// freezed/json_serializable constraints (a hand-written `fromJson` body
/// disables JSON codegen for the whole class; `toJson` cannot be
/// overridden by inheritance) that require this to be a `readValue`
/// callback rather than a hand-written `fromJson` wrapper.
///
/// - Only `tmuxSession` present → its value is returned (Requirement:
///   Legacy Field Still Readable).
/// - Only `sessionRef` present → its value is returned.
/// - Both present → `sessionRef`'s own value wins, unconditionally
///   (Requirement: Neutral Field Takes Precedence When Both Are Present).
/// - Neither present → `null`; never invented. Note: since
///   [ProjectShortcut.tmuxSession] is a required, non-nullable field
///   (unlike `ConnectionProfile.tmuxSession`), a record missing the
///   `tmuxSession` key entirely already fails to load before this
///   callback ever runs — that is pre-existing behavior, unchanged by
///   this migration.
Object? _readSessionRef(Map<dynamic, dynamic> json, String key) {
  final neutral = json['sessionRef'] as String?;
  if (neutral != null) return neutral;
  return json['tmuxSession'] as String?;
}

/// A project shortcut that opens a terminal in a specific directory
/// with a named tmux session and optional command.
///
/// [tmuxSession] is the legacy, multiplexer-specific session name and
/// stays a required, real field — every [ProjectShortcut] has always
/// carried one, so this migration does not relax that requiredness.
/// [sessionRef] is its neutral replacement, paired with [multiplexer] to
/// say which multiplexer that name applies to (`null` ⇒ host default).
/// The legacy key is never deleted from persisted JSON — see
/// [_readSessionRef] for the read-time precedence rule; `toJson()` (the
/// plain generated field mapper, unmodified) always includes both keys
/// because both remain real fields on this class.
@freezed
class ProjectShortcut with _$ProjectShortcut {
  const factory ProjectShortcut({
    /// Unique identifier (UUID v4).
    required String id,

    /// Human-readable name (e.g. "Metalpren").
    required String name,

    /// Absolute path on the remote machine (e.g. "/home/gian/proyectos/metalpren").
    required String projectPath,

    /// tmux session name to attach to or create (e.g. "metalpren").
    /// Superseded by [sessionRef] — see the class doc.
    required String tmuxSession,

    /// Command to run after navigating to [projectPath] (e.g. "opencode").
    /// Empty string means no command is run.
    @Default('') String command,

    /// ID of the [ConnectionProfile] to use.
    required String profileId,

    /// Sort order for display in the sidebar.
    @Default(0) int sortOrder,

    /// Neutral session reference, meaningful for whichever [multiplexer]
    /// is selected. See [_readSessionRef] for the read-time precedence
    /// rule. Never defaulted here — a null value is not an invented
    /// fallback; callers apply AppConstants.defaultSessionRef themselves,
    /// exactly as they already did for [tmuxSession] before this
    /// migration. `invalid_annotation_target` (see the file-level ignore
    /// above) is a known freezed+json_serializable false positive for
    /// this exact pattern.
    @JsonKey(readValue: _readSessionRef) String? sessionRef,

    /// Which multiplexer [sessionRef] applies to. `null` means the host's
    /// default multiplexer (see `MultiplexerId` in
    /// `lib/core/host/multiplexer_adapter.dart`).
    String? multiplexer,
  }) = _ProjectShortcut;

  factory ProjectShortcut.fromJson(Map<String, dynamic> json) =>
      _$ProjectShortcutFromJson(json);
}
