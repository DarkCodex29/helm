import 'multiplexer_adapter.dart';

/// Mirrors [value] into both fields a persisted model's write path must
/// set identically: the neutral session reference and the model's legacy
/// session-name field ([ConnectionProfile.tmuxSession],
/// [ProjectShortcut.tmuxSession], [TabSnapshot.tmuxSessionName]).
///
/// This is the single implementation of host-session-contract slice 6's
/// mirroring decision: whenever a write sets a session reference, the
/// SAME value MUST also land in that model's legacy field. Three widgets
/// call this (directly or through [resolveOptionalSessionReference] /
/// [resolveRequiredSessionReference]) so the policy lives in exactly one
/// place — a widget that instead re-derived the rule independently is
/// exactly how the three models would silently drift.
///
/// The purpose is rollback: a build from before this migration reads
/// only the legacy field. Mirroring is what lets that build see the
/// user's CURRENT choice instead of a stale one — even when the user
/// picked herdr or zellij, whose session identifiers are not tmux
/// session names. That imprecision is an accepted, known cost; this
/// function does not attempt to avoid it.
({String? sessionRef, String legacyValue}) mirrorSessionReference(
  String value,
) => (sessionRef: value, legacyValue: value);

/// Resolves raw text input (not yet trimmed) into the mirrored pair for
/// a model whose legacy field is nullable
/// ([ConnectionProfile.tmuxSession]).
///
/// Empty or whitespace-only input resolves to `null` for BOTH fields —
/// "no session override", exactly as before this migration. A non-empty
/// value is trimmed once and mirrored via [mirrorSessionReference].
({String? sessionRef, String? legacyValue}) resolveOptionalSessionReference(
  String? rawInput,
) {
  final trimmed = rawInput?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return (sessionRef: null, legacyValue: null);
  }
  final mirrored = mirrorSessionReference(trimmed);
  return (sessionRef: mirrored.sessionRef, legacyValue: mirrored.legacyValue);
}

/// Resolves raw text input into the mirrored pair for a model whose
/// legacy field is required and non-nullable
/// ([ProjectShortcut.tmuxSession], [TabSnapshot.tmuxSessionName]).
///
/// Empty or whitespace-only input falls back to [fallback] for BOTH
/// fields. Leaving `sessionRef` null while only the legacy field
/// silently received [fallback] would itself be a divergence — the exact
/// thing mirroring exists to prevent — so [fallback] is mirrored the
/// same way a real value would be.
({String? sessionRef, String legacyValue}) resolveRequiredSessionReference(
  String? rawInput, {
  required String fallback,
}) {
  final trimmed = rawInput?.trim();
  final value = (trimmed == null || trimmed.isEmpty) ? fallback : trimmed;
  return mirrorSessionReference(value);
}

/// Encodes [multiplexer] for storage in [ConnectionProfile.multiplexer] /
/// [ProjectShortcut.multiplexer] / [TabSnapshot.multiplexer].
///
/// Uses [MultiplexerId.name] (`'herdr'` / `'tmux'` / `'zellij'`),
/// deliberately chosen over `toString()` — which would persist the
/// `'MultiplexerId.herdr'`-shaped default and break silently on any
/// refactor of the enum's declaration — and over the enum's index, an
/// unstable integer that reorders if the enum's declaration order ever
/// changes. `.name` is stable across reorders and human-readable in
/// persisted JSON. `null` means "host default" and stays `null`.
String? encodeMultiplexer(MultiplexerId? multiplexer) => multiplexer?.name;

/// Decodes a persisted multiplexer string back into a [MultiplexerId].
///
/// Returns `null` for an absent, empty, or unrecognized value — an
/// unrecognized string (e.g. from a future app version storing a
/// multiplexer this build does not know about) MUST resolve to "host
/// default", never throw and never silently guess a specific
/// multiplexer.
MultiplexerId? decodeMultiplexer(String? stored) {
  if (stored == null) return null;
  for (final id in MultiplexerId.values) {
    if (id.name == stored) return id;
  }
  return null;
}
