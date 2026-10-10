# retire-shortcuts-drawer

Baseline `e03a952` on `refactor/drop-duplicated-drawer-sections`, clean tree.
Suite at baseline: 1469 passing, 28 failing — all 28 pre-existing on `main` in
`file_browser_sheet_test.dart`, measured directly.

## Why

`ada44bb` removed the two sections herdr already renders. What remained was
`PROJECTS`, `QUICK ACTIONS` and the `Settings` footer. The owner reports that in
his actual use the drawer now holds only `Settings` worth reaching: his
`PROJECTS` and `QUICK ACTIONS` lists are empty, so the drawer is a full-screen
surface whose only live control is one row at the bottom.

The concern that `PROJECTS` and `QUICK ACTIONS` have no replacement was raised
before this decision and the owner reaffirmed it. That is his call and this
change follows it in full.

## What survives the deletion

Saved shortcut data is NOT destroyed. `ShortcutsRepository` persists to
SharedPreferences under `shortcuts_projects` and `shortcuts_quick_actions`
(`shortcuts_repository.dart:11-12`). Removing the UI leaves those keys on the
device, unreachable but intact. Nothing in this change clears them.

## Ordering constraint, not a preference

`ShortcutsSemantics.settingsButton` in the drawer footer is today the only
reachable route to `/settings`. The other call site, `home_screen.dart:489`,
sits inside `if (profiles.isEmpty)` — the dead branch
`maestro/flows/02_settings_reachable.yaml` exists to catch.

Therefore Settings lands in the overflow menu FIRST, in its own commit, and the
drawer is removed only after. No commit in this branch may leave Settings
unreachable, including intermediate ones.

Settings must be an ALWAYS-PRESENT overflow entry, following
`Reset keyboard layout` rather than `_overflowSessionItems`: the latter returns
an empty list when no session is connected, and Settings must not depend on a
connection.

## Identifier convention, taken from the codebase

`semantic_ids.dart` documents its own rule for this exact move: "the id MOVED
WITH THE WIDGET rather than being kept stable for the flows' convenience: an
identifier naming a surface its widget no longer sits on costs nothing to leave
behind and a whole debugging session to discover."

So `ShortcutsSemantics.settingsButton` becomes `HomeSemantics.settingsButton`
(`helm.home.settings_button`), which is what it was called before it moved into
the drawer.

## Dead identifiers to collect on the way

`ShortcutsSemantics.agentsSection` and `ShortcutsSemantics.workspaceHeaderButton`
were orphaned by `ada44bb`; the writer could not reach `semantic_ids.dart`
because it was outside its allowed surfaces. They go with the rest.

## Cascade, measured

`openShortcut` (`tabs_provider.dart:400`) has exactly ONE caller:
`shortcuts_drawer.dart:55`. It dies with the drawer.

The `shortcuts` feature is 2374 lines across 11 files, of which
`shortcut_form_sheet.dart` (784) and `shortcuts_drawer.dart` (445) are reached
only from the drawer.

## Tasks

- [ ] 1. Put Settings in the overflow menu, before anything is removed
  - Surfaces: `lib/features/terminal/presentation/home_screen.dart`,
    `lib/core/testing/semantic_ids.dart`, `test/features/terminal/**`
  - Always present, beside `Reset keyboard layout`, never inside
    `_overflowSessionItems`.
  - Test first: a widget test that opens the overflow and reaches `/settings`
    must fail before the entry exists.
  - Commit: pending

- [ ] 2. Remove the drawer and everything only it reached
  - Surfaces: `lib/features/terminal/presentation/home_screen.dart`,
    `lib/features/shortcuts/**`, `lib/core/testing/semantic_ids.dart`,
    `lib/features/terminal/presentation/providers/tabs_provider.dart`,
    `test/features/shortcuts/**`, `test/features/terminal/**`
  - Includes the hamburger, `drawer:`, `onDrawerChanged`, `_isDrawerOpen`,
    `_scaffoldKey` and the `canPop`/`closeDrawer` back handling that existed
    only to dismiss the drawer.
  - `canPop` becomes unconditional: Home is the only route on the stack, so
    back closes the app again, which is the behaviour from before the drawer.
  - Commit: pending

- [ ] 3. Realign the e2e flows to the surface that now exists
  - Surfaces: `maestro/flows/02_settings_reachable.yaml`,
    `maestro/flows/03_drawer_back_navigation.yaml`, `maestro/config.yaml`
  - `02` keeps its purpose — Settings must be reachable from Home — and is
    rewritten to go through the overflow button instead of the hamburger. It is
    NOT deleted: its defect (`/settings` reachable only from a dead branch) is
    still reachable and is exactly what this change risks.
  - `03` is deleted with its entry in `executionOrder`: it guards back-closes-
    the-drawer, and there is no drawer.
  - Commit: pending

## Device validation, deferred by standing preference

1. The three-dot menu shows Settings with no session connected.
2. Settings opens and back returns to Home.
3. No hamburger remains on the app bar.
4. Android back from Home closes the app, with nothing left to dismiss first.

## Out of scope, recorded deliberately

- Clearing the `shortcuts_projects` / `shortcuts_quick_actions` preference keys.
  Destructive to user data, reversible only by retyping it, and not asked for.
- Fixing `home_screen.dart:489`'s unreachable `/settings` push inside
  `if (profiles.isEmpty)`. Pre-existing, and task 1 makes it redundant rather
  than wrong.
- The 28 pre-existing failures in `file_browser_sheet_test.dart`. Different
  cause, own branch.
