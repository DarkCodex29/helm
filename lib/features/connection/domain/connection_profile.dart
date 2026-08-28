// ignore_for_file: invalid_annotation_target — see the doc comment on
// ConnectionProfile.sessionRef for why this is a known false positive.
import 'package:freezed_annotation/freezed_annotation.dart';

part 'connection_profile.freezed.dart';
part 'connection_profile.g.dart';

/// Resolves [ConnectionProfile.sessionRef] from a persisted JSON map,
/// falling back to the legacy `tmuxSession` key when the neutral key is
/// absent or null (spec.md: session-reference-storage).
///
/// - Only `tmuxSession` present → its value is returned (Requirement:
///   Legacy Field Still Readable).
/// - Only `sessionRef` present → its value is returned.
/// - Both present → `sessionRef`'s own value wins, unconditionally
///   (Requirement: Neutral Field Takes Precedence When Both Are Present).
/// - Neither present → `null`; never invented.
///
/// ### Why this is a `readValue` callback, not a hand-written `fromJson`
///
/// The natural first attempt is a hand-written `factory
/// ConnectionProfile.fromJson(...)` body that pre-normalizes the raw map
/// before delegating to the generated `_$ConnectionProfileFromJson`.
/// That does NOT work with this project's freezed 2.5.7 /
/// json_serializable 6.9.2: freezed's JSON-support detection requires the
/// `fromJson` factory to be the **exact** one-line
/// `=> _$ConnectionProfileFromJson(json);` delegate. Verified empirically
/// — giving that factory any other body, even one that still calls the
/// generated function, makes freezed treat the class as not
/// JSON-enabled at all: `connection_profile.g.dart` stopped being
/// generated entirely (confirmed by running `build_runner build` against
/// that version of this file — the file was deleted, and with it the
/// generated `toJson()` on `_$ConnectionProfileImpl`, so `.toJson()`
/// calls throughout the app would have stopped compiling). Since
/// `_$ConnectionProfileImpl implements _ConnectionProfile` (an interface
/// relationship, not `extends`), a body written on the abstract class
/// here can never substitute for that generated implementation either.
///
/// `@JsonKey(readValue: _readSessionRef)` keeps the canonical `fromJson`
/// delegate intact, so both `fromJson` and `toJson` stay fully generated,
/// and the fallback logic runs inside the generated field parser instead.
Object? _readSessionRef(Map<dynamic, dynamic> json, String key) {
  final neutral = json['sessionRef'] as String?;
  if (neutral != null) return neutral;
  return json['tmuxSession'] as String?;
}

/// Represents a saved SSH connection configuration.
///
/// [tmuxSession] is the legacy, multiplexer-specific session name.
/// [sessionRef] is its neutral replacement, paired with [multiplexer] to
/// say which multiplexer that name applies to (`null` ⇒ host default).
/// The legacy key is never deleted from persisted JSON — see
/// [_readSessionRef] for the read-time precedence rule; `toJson()` (the
/// plain generated field mapper, unmodified) always includes both keys
/// because both remain real fields on this class.
///
/// [tmuxSession] is kept as a real, readable/writable field — not
/// converted into a computed getter — specifically so call sites that
/// still construct a [ConnectionProfile] with a `tmuxSession:` named
/// argument (`profile_edit_screen.dart`, out of scope for this migration
/// unit — see task 6.15) keep compiling unchanged. It is read verbatim
/// from its own JSON key and never silently overwritten to match
/// [sessionRef], so a legacy value already on disk is always preserved
/// exactly as persisted.
@freezed
class ConnectionProfile with _$ConnectionProfile {
  const factory ConnectionProfile({
    /// Unique identifier (UUID v4).
    required String id,

    /// Human-readable name for this profile (e.g. "Mac Studio").
    required String name,

    /// Hostname or IP address of the remote machine.
    required String host,

    /// SSH port — defaults to 22.
    @Default(22) int port,

    /// SSH username on the remote machine.
    required String username,

    /// Optional custom tmux session name. Falls back to AppConstants.defaultSessionRef.
    /// Superseded by [sessionRef] — see the class doc.
    String? tmuxSession,

    /// Neutral session reference, meaningful for whichever [multiplexer]
    /// is selected. See [_readSessionRef] for the read-time precedence
    /// rule. Never defaulted here — a null value is not an invented
    /// fallback; callers apply AppConstants.defaultSessionRef themselves,
    /// exactly as they already did for [tmuxSession] before this
    /// migration. `invalid_annotation_target` (see the file-level ignore
    /// above) is a known freezed+json_serializable false positive for
    /// this exact pattern; the annotation is correctly applied to the
    /// generated field (confirmed: `connection_profile.g.dart` calls
    /// `_readSessionRef(json, 'sessionRef')`).
    @JsonKey(readValue: _readSessionRef) String? sessionRef,

    /// Which multiplexer [sessionRef] applies to. `null` means the host's
    /// default multiplexer (see [MultiplexerId] in
    /// `lib/core/host/multiplexer_adapter.dart`).
    String? multiplexer,

    /// Whether this is the default profile to connect to on launch.
    @Default(false) bool isDefault,

    /// Whether a successful connect on this profile should hold the
    /// session open in the background.
    ///
    /// A hold runs an Android foreground service with an ongoing
    /// notification (see `SessionHoldService.kt`), which is why this
    /// carries `@Default(false)` and why that default is load-bearing
    /// rather than incidental:
    ///
    ///  * Every profile already on a device predates this key. freezed's
    ///    `@Default` makes json_serializable emit
    ///    `json['holdInBackground'] as bool? ?? false`, so those records
    ///    deserialize with the hold OFF. Installing an update can
    ///    therefore never start a service the user was never asked about
    ///    — see `connection_profile_test.dart`'s
    ///    "Background hold is chosen, never inherited" group, which asserts
    ///    this against JSON captured verbatim from the pre-field app.
    ///  * Turning it ON is the user-initiated action Play's foreground
    ///    service rules require. That only holds while the switch is
    ///    honest about what it starts, which is why the editor's copy
    ///    names the service, the notification and the battery cost rather
    ///    than promising something vague like "stay connected".
    ///
    /// It is deliberately NOT a global setting. Which sessions are worth
    /// a notification is a per-machine judgement: a long-lived agent host
    /// is, a box the user opens for one command is not.
    @Default(false) bool holdInBackground,
  }) = _ConnectionProfile;

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) =>
      _$ConnectionProfileFromJson(json);
}
