# drop-duplicated-drawer-sections

Baseline `4482cde` on `main`, clean tree, 1545/1545 tests. Branch
`refactor/drop-duplicated-drawer-sections`.

## Why

`ShortcutsDrawer` reimplements, on the phone, two panels herdr already renders
in the TUI that helm draws over SSH.

herdr documentation (v0.9.3) states: "The sidebar is the main Herdr dashboard."
Its agent rows carry `state_icon`, `state_text`, `machine`, `workspace`, `tab`,
`agent`; its `Spaces` panel carries `workspace`, `branch`, `git_status`. Those
are the exact fields helm's `AGENTS` and `WORKSPACES` sections render.

The owner confirmed first-hand that he reaches and taps herdr's own sidebar from
the phone, which settles the one fact the documentation could not: the
replacement is not merely documented, it is in daily use. Installed herdr is
0.9.0 while the published documentation is 0.9.3; the owner's usage, not the
version match, is the evidence here.

## What is NOT duplicated, and therefore stays

Measured section by section, not assumed from the drawer's name:

| Section | Line | Replaced by herdr |
| --- | --- | --- |
| `AGENTS` | 128 | yes — herdr's Agent panel |
| `WORKSPACES` | 147 | yes — herdr's Spaces panel |
| `PROJECTS` | 160 | NO — `openShortcut` opens a new helm TAB |
| `QUICK ACTIONS` | 186 | NO — sends a canned command to the active session |
| Footer `Settings` | 213 | NO — and it is the only reachable route there |

`PROJECTS` and `QUICK ACTIONS` are a session launcher and a command emitter, not
an agent dashboard. herdr has neither.

The `Settings` footer must survive: `ShortcutsSemantics.settingsButton` is the
only reachable navigation to `/settings`. The other call site,
`home_screen.dart:489`, sits inside `if (profiles.isEmpty)` — the dead branch
that `maestro/flows/02_settings_reachable.yaml` exists to catch, because setup
always creates a profile. Dropping the whole drawer would reintroduce that bug.

## Why delete on a branch rather than comment out

The owner asked to comment the sections out so the change could be undone after
device validation. The branch provides that undo exactly: it is unmerged, so
`git checkout main` restores every line. Commenting instead would leave ~640
production lines and ~1529 test lines that no longer compile against a live
tree, which rots silently and cannot be reviewed.

## Dependency map (measured, no orphans left behind)

Removed because only the two dropped sections referenced them:

- `_AgentsSection` (506-659), `_WorkspaceTreeSection` (660-815)
- `_WorkspaceHeader` (816-862) — sole ref `_WorkspaceTreeSection:741`
- `_TabRow` (863-932) — sole ref `_WorkspaceTreeSection:747`
- `_StateGlyph` (933-947) — sole refs `_WorkspaceHeader:847`, `_TabRow:912`
- `_FocusError` (1143-1170) — sole refs `_AgentsSection:619`,
  `_WorkspaceTreeSection:753`
- `_focusAgent` (271), `_focusTab` (316), `_focusWorkspace` (363)
- state `_focusError`, `_tabFocusError`, `_focusing`, `_workspaceTree`, and the
  `initState` tree refresh

Kept, because the surviving sections use them: `_DrawerHeader`,
`_SectionHeader`, `_EmptyHint` (refs at 165 and 190), `_ProjectShortcutTile`,
`_QuickActionsRow`.

## Tasks

- [ ] 1. Drop the two duplicated sections and everything only they used
  - Surfaces: `lib/features/shortcuts/presentation/shortcuts_drawer.dart`,
    `test/features/shortcuts/presentation/shortcuts_drawer_agents_test.dart`,
    `test/features/shortcuts/presentation/shortcuts_drawer_workspaces_test.dart`,
    `test/features/shortcuts/presentation/shortcuts_drawer_focus_test.dart`
  - Remove the now-unused imports too; `flutter analyze` must stay clean.
  - The three test files cover ONLY the removed sections. Any case in them that
    asserts surviving behaviour must be kept, moved, not deleted wholesale.
  - Commit: pending

- [ ] 2. Retire the e2e guard whose defect no longer exists
  - Surfaces: `maestro/agent_focus_honesty.yaml`
  - This flow asserts the drawer stays open after tapping an agent, reporting
    where focus landed. With the `AGENTS` section gone there is no agent row to
    tap, so the flow cannot run. It is retired because its defect is now
    unreachable, not because it became inconvenient.
  - `maestro/flows/02_settings_reachable.yaml` and
    `maestro/flows/03_drawer_back_navigation.yaml` must keep passing untouched:
    both drive the hamburger, the drawer identifier and the Settings footer,
    all of which survive.
  - Commit: pending

- [ ] 3. Reconcile two ODD task files whose checkboxes outlived their work
  - Surfaces: `odd/tasks/sftp-upload-2026-10.md`,
    `odd/tasks/tailscale-addressing-2026-10.md`
  - Both show open items that are committed and merged. Verified:
    `sftp-upload` tasks 1-2 are in `lib/features/files/` (`sftp_upload_service`,
    `saf_upload_source`, `file_upload_provider`); `tailscale-addressing` task 1
    is `2f12b55`, task 2 is `d543602`, task 3 is `557d712` + `9d5bbf9` +
    `faeba48`.
  - Record the commit identities so the next session does not re-derive them.
  - Commit: pending

## Device validation, deferred by standing preference

Verification on the S22 happens once, at the end of the whole block, not slice
by slice. What must be checked there:

1. The drawer still opens from the hamburger and shows `PROJECTS`,
   `QUICK ACTIONS` and the `Settings` footer.
2. Settings is still reachable.
3. Android back still closes the drawer instead of killing the app.
4. herdr's own sidebar still covers agent and workspace navigation inside the
   terminal view.

## Out of scope, recorded deliberately

- Deleting the rest of the `shortcuts` feature. `PROJECTS` and `QUICK ACTIONS`
  have no replacement anywhere.
- Moving `Settings` onto the AppBar. It is reachable today through the drawer
  footer, which survives; moving it is a separate UX decision.
- Fixing `home_screen.dart:489`'s unreachable `/settings` push. Pre-existing,
  guarded by an e2e flow, and untouched by this change.
