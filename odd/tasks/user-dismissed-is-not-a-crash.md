# user-dismissed-is-not-a-crash

Baseline `ebe0301` on `refactor/drop-duplicated-drawer-sections`, clean tree.
Suite: 1455 passing, 28 failing — all 28 pre-existing on `main` in
`file_browser_sheet_test.dart`, verified by attribution.

## The defect, measured end to end on an S22 (SM-S908E, SDK 33)

1. The user swipes helm out of Recents.
2. `SessionHoldService.onTaskRemoved` stops the hold. Android destroys
   `MainActivity`, its `FlutterEngine` and the isolate that owns the SSH
   socket. Measured: `socket=0`, `fgservice=0`, then the pid disappears.
3. The earlier `paused` had already called `saveSnapshot()`, so a
   crash-recovery snapshot is sitting in SharedPreferences.
4. On relaunch `decideAutoConnect` sees `recoveryPending == true`, returns
   `AutoConnectSkip`, and the user is offered recovery instead of being
   reconnected. That is the reported "me dice que tengo que reconectar".

**A deliberate swipe is not a crash.** `saveSnapshot()` cannot tell "I went to
background and will be back" from "the user dismissed me", so both produce the
same snapshot and the same prompt. `onTaskRemoved` is exactly the signal that
knows the difference.

## What is NOT the fix, and why

Removing `stopSelfAndDismiss()` from `onTaskRemoved` was proposed and
**retracted after reading the code**. `MainActivity` is a
`FlutterFragmentActivity` with no `FlutterEngineCache` and no `cachedEngine`,
and `cleanUpFlutterEngine` disposes the engine with the Activity. The socket
dies with the isolate no matter what that method does, so keeping the service
alive would only leave a notification claiming a hold that no longer exists —
precisely what its author avoided. The original code is right.

Moving the socket into a service-owned isolate is not an option either: a live
`dart:io` `Socket` is unsendable across isolates, so it would mean re-dialling
and re-authenticating. That is a transport rewrite, not this change.

## What the swipe actually costs, measured

Nothing on the Mac. Immediately after the swipe, herdr still held all five
panes at their pre-swipe revisions, three of them still `working`:

| pane | revision | status |
| --- | --- | --- |
| `w2:p2` | 6 | idle |
| `w2:p5` | 11 | working |
| `w3:p1` | 15 | working |
| `w4:p1` | 11 | working |
| `wC:p1` | 13 | done |

So the cost is one reconnect, not data. This change removes the prompt, not a
risk of loss.

## The mechanism being changed

`SessionSnapshotRepository` owns three keys: `helm_session_dirty`,
`helm_session_snapshot` and `helm_session_snapshot_ts`. `markDirty` sets all
three on `paused`, `markClean` clears them on `resumed`, and
`getPendingRecovery` returns the snapshot when dirty and older than 5s.

The snapshot must be KEPT — it is what restores more than one tab. Auto-connect
alone would open only the default profile and lose the tab layout. So recovery
is auto-APPLIED, not discarded.

## Tasks

- [ ] 1. Record that the exit was user-initiated, from the dying process
  - Surfaces: `android/app/src/main/kotlin/com/darkcodex/helm/SessionHoldService.kt`
  - In `onTaskRemoved`, before stopping, write a flag into the same
    SharedPreferences file Flutter uses.
  - MUST use `commit()`, not `apply()`: the process is being torn down and an
    async write may never flush. This is the whole reason the flag is written
    from Kotlin rather than Dart — the isolate is already going.
  - Verify the file name and key prefix Flutter actually uses on this version
    rather than trusting the brief; read it off the device or the plugin source.
  - Commit: pending

- [ ] 2. Teach the repository that a dismissal is not a crash
  - Surfaces: `lib/features/terminal/data/session_snapshot_repository.dart`,
    `lib/core/constants/app_constants.dart`, `test/features/terminal/data/**`
  - Expose whether the pending snapshot came from a user dismissal, and clear
    that flag wherever the other three are cleared, so it cannot leak into a
    later launch.
  - Test first.
  - Commit: pending

- [ ] 3. Apply the recovery instead of offering it, when the user dismissed
  - Surfaces: `lib/features/terminal/presentation/home_screen.dart`,
    `test/features/terminal/presentation/**`
  - A real crash keeps its prompt. Only a user dismissal auto-applies.
  - Commit: pending

## Device validation, still owed

The USB cable disconnected mid-investigation, so task 1 has no device evidence
yet. What must be measured once reconnected:

1. Swipe helm from Recents, relaunch, and confirm it reattaches without a
   prompt and with every tab back.
2. Force-stop or kill the process instead, relaunch, and confirm the recovery
   prompt STILL appears — the crash path must not be swallowed.
3. Confirm the flag does not survive into a third launch.

## Out of scope, recorded deliberately

- Keeping the SSH socket alive across task removal. Architecturally closed
  above.
- The 4h `kSessionHoldIdleTimeout`. Deliberate, with a standing decision not to
  shorten it.
- The 28 pre-existing failures in `file_browser_sheet_test.dart`. Different
  cause, own branch.
