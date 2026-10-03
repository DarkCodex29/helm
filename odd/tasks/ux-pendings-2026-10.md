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

- [ ] 1. Make the disconnection overlay scrim actually opaque
  - Surfaces: `lib/core/theme/app_theme.dart`,
    `lib/features/terminal/presentation/widgets/terminal_view_widget.dart`
  - `AppTheme.scrim` is `Color(0xCC0D1117)` (80%), so the terminal shows through
    the three-line overlay and the text collides with the icon.
  - Commit: pending

- [ ] 2. Terminal font-size control, persisted per profile
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
  - Commit: pending

- [ ] 3. Make workspace headers tappable in the shortcuts drawer
  - Surfaces: `lib/features/shortcuts/presentation/shortcuts_drawer.dart`,
    multiplexer workspace-tree layer
  - `_WorkspaceTreeSection` (`:613`) draws `EBIM`, `Go Nexa` as inert text.
    herdr exposes `active_tab_id` per workspace, so a header can focus it.
  - Existing coverage to extend:
    `test/features/shortcuts/presentation/shortcuts_drawer_workspaces_test.dart`
  - Commit: pending

## Deliberately out of scope

- Moving the files (`folder`) or hold (`pin`) actions into the drawer:
  `_buildBrowseAction` already argues why — the drawer CHANGES the active
  session, so a session-scoped control becomes ambiguous inside it.
- Reaching 48x48dp keys: impossible with 11 columns in 403dp (33.2dp ceiling).
