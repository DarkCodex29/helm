# ux-pendings-2026-10

Three carried-over UX slices from the 2026-09-27 session, delegated one bounded
writer per slice. Baseline: `main` at `45ef435`, clean, `origin/main` in sync,
`flutter analyze` clean, 1320/1320 tests.

## Why these run sequentially, not in parallel

Slice 1 and slice 2 both edit
`lib/features/terminal/presentation/widgets/terminal_view_widget.dart`
(`:230` scrim, `:149` fontSize). Two concurrent writers on one file is a
guaranteed conflict. Independently, three concurrent `flutter test` runs in a
single checkout contend over `.dart_tool`. Slice order puts the cheap colliding
one first so the large slice starts from a settled file.

## Architectural invariant no slice may break

`terminal_view_widget.dart:110-148` records a paid-for failure: the column/row
count must come from xterm's real font metrics, never from a hand-computed cell
estimate. `TerminalSession` listens to that layout resize from its constructor
and pushes the result at the remote PTY (`terminal_session.dart:521-538`,
`:928-931`, `:1066`). A font-size change therefore propagates columns for free.
Re-adding a second, estimating source of truth is the regression `62565f3`
exists to prevent.

## Tasks

- [x] 1. Make the disconnection overlay scrim actually opaque
  - Surfaces: `lib/core/theme/app_theme.dart`,
    `lib/features/terminal/presentation/widgets/terminal_view_widget.dart`
  - `AppTheme.scrim` is `Color(0xCC0D1117)` (80%), so the terminal shows through
    the three-line overlay and the text collides with the icon.
  - `AppTheme.scrim` had exactly one consumer, so the shared token went fully
    opaque rather than forking a second one. No layout change was needed: the
    text/icon collision WAS the terminal bleeding through.
  - Commit: `389c69b`

- [x] 2. Terminal font-size control, persisted per profile
  - Surfaces: `lib/features/connection/domain/connection_profile.dart`,
    `lib/features/connection/data/connection_profile_repository.dart`,
    `lib/features/settings/presentation/`,
    `lib/features/terminal/presentation/widgets/terminal_view_widget.dart`
  - `fontSize: 13` is hardcoded at `terminal_view_widget.dart:149` and yields
    ~50 columns at 391.9dp, while gentle-shell TUIs paint for 80. Measured:
    13 -> 50 col, 11 -> 59, 10 -> 65, 9 -> 72, 8 -> 81.
  - Agreed design: a Settings control showing the LIVE column count for each
    value, persisted per `ConnectionProfile`.
  - `ConnectionProfile` is `@freezed` with generated `fromJson`/`toJson`, so a
    new field requires `build_runner`.
  - Landed in the profile editor, not global settings: `settings_screen.dart`
    edits no profile fields at all, and `holdInBackground`'s own doc argues why
    a per-machine judgement is deliberately not global.
  - The live column preview measures the same way xterm's own
    `TerminalPainter._measureCharSize` does (a real `ui.Paragraph` over the real
    font stack) in `terminal_font_size_preview.dart`. It is preview-only;
    `TerminalView`'s layout stays the sole source of the size pushed at the PTY.
  - `HelmTerminalView` gained no constructor parameter — it reads the profile
    the session already carries, so its ten call sites were untouched.
  - NOT verified without a device: the exact on-device column count per size.
    The harness lacks real device font metrics, so only monotonicity and
    direction are proven there.
  - Commit: `e6d6a18`

- [x] 3. Make workspace headers tappable in the shortcuts drawer
  - Surfaces: `lib/features/shortcuts/presentation/shortcuts_drawer.dart`,
    multiplexer workspace-tree layer
  - `_WorkspaceTreeSection` (`:613`) draws `EBIM`, `Go Nexa` as inert text.
    herdr exposes `active_tab_id` per workspace, so a header can focus it.
  - Existing coverage to extend:
    `test/features/shortcuts/presentation/shortcuts_drawer_workspaces_test.dart`
  - `MuxWorkspace` now reads `active_tab_id`; its doc comment records that a
    reader arrived rather than contradicting the old "nobody reads this"
    reasoning. A stale id falls back to the workspace's first tab by number,
    treated as the same non-atomic race the tree's own doc already names.
  - Focus reuses the existing `_focusTab` path, so there is one error wording
    and one close-on-success order.
  - NOT verified without the live host: `active_tab_id` behavior across a host
    mutation between the two commands. The fallback exists for that gap.
  - Commit: `9e08068`

## Final verification

`flutter analyze` clean. Full suite `1348/1348` passing, up from the `1320`
baseline. Branch `feat/ux-pendings-2026-10`, three commits, not pushed and not
merged — both remain the owner's decision.

No slice has been exercised on the S22 or against the live herdr host. Every
claim above is from `flutter test` and `flutter analyze` only.

## Deliberately out of scope

- Moving the files (`folder`) or hold (`pin`) actions into the drawer:
  `_buildBrowseAction` already argues why — the drawer CHANGES the active
  session, so a session-scoped control becomes ambiguous inside it.
- Reaching 48x48dp keys: impossible with 11 columns in 403dp (33.2dp ceiling).
