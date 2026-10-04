# Upload queue, gallery source, and the floating keyboard (2026-10)

Branch `feat/upload-queue-2026-10`, off `main` = `12515e9`. Pushed.
**1540/1540 tests** (block started at 1469), `flutter analyze` clean.

`main` is untouched. Merging it there is a separate decision.

## Why

Attaching a photo from the phone was effectively impossible. The upload
button worked, but `UploadSourcePicker.pick()` called `saf_util.pickFile()`
with NO mime filter, which is Android's *document* picker: reaching a
camera photo meant navigating to `DCIM/Camera` by hand and recognising a
filename.

The user's first framing was a modal on the files icon offering "Mac files"
or "phone files". That does not hold: the files icon opens the REMOTE
browser, and a local-only browser has no destination and no purpose. The
real fork is the SOURCE of an upload — document or photo — so the modal
belongs on the upload button. Agreed and built that way.

A second request followed: the keyboard toggle should be a FAB, and the
keyboard floating, movable and adjustable.

## Shipped

| Commit | What |
| --- | --- |
| `1976be0` | Split `file_browser_sheet.dart` (1604 lines) into a library plus 8 `part` files |
| `93a26c0` | Media seam: `pickMedia` over `MediaStore.ACTION_PICK_IMAGES`, plus sub-API-33 fallback |
| `3f10071` | Free-name resolution, `foto.jpg` → `foto(1).jpg`, bounded at 100 |
| `ce817d2` | Honour cancellation in the final resolve; bound and interrupt the stat search |
| `28f865f` | A failed `stat` is not proof the name is free; `NEVER THROWS` true by construction |
| `95a271f` | FIFO queue, source modal, queue strip, truthful collision copy, drain-lock fix |
| `5644618` | Movable, resizable floating keyboard with device-level geometry |
| `2077b87` | Three lint infos that appeared only on integration |

## Decisions worth not relitigating

**`part`/`part of` to split the sheet.** All 20 widgets are library-private
and share 7 private palette constants. Independent files would force them
public and rewrite ~100 references — a rename sweep instead of a verifiable
move, publishing an internal API with exactly one consumer.

**Keyboard minimum is 370dp**, derived as 7×48 + 16 + 6×3, with letter
height keeping its 44dp clamp. Two stricter readings were rejected on
arithmetic, and the numbers are in the code: 44dp-WIDE letters derive
522dp, and the unclamped height formula reaching 44dp derives 458.87dp. A
phone in portrait is 384–412dp, so either floor makes the keyboard
impossible on the only target device. A constraint that forbids the primary
use case is the wrong constraint.

**Keyboard geometry is device-level, not per-profile.** Font size varies per
host because remote content wants different density; where the panel sits
is a property of the hand and the screen. Three servers must not mean three
keyboard positions, and a profile export must not carry one device's
ergonomics to another. Persisted through an injected `shared_preferences`
store following `DownloadDestinationStore`.

**One transfer in flight.** Each upload opens its own SFTP channel; twenty
concurrent channels on one SSH connection is a different, riskier change.

**Queue strip shows the active item plus precomputed counts**, not a row
per item. Twenty rows eat the phone screen to say what two numbers say.
Cancel-all at queue level rather than per-item controls, keeping the
one-dismiss rule the download strip already documented.

**Upload/download duplication was deliberately NOT abstracted.** They look
like mirrors but diverge where it matters: download publishes to SAF with a
viewer and a persisted destination; upload has none of that. And
cancellation differs for a measured reason recorded at
`sftp_upload_service.dart:21-22` — upload cancels for real between chunks,
download polls.

## What the reviews caught that green tests did not

Two adversarial reviews found three real defects behind a passing suite.

1. **Cancellation was ignored during the final name resolution.** After all
   bytes arrived, a second free-name search ran without consulting the
   cancellation, so cancelling an item mid-search still reported
   `UploadCompleted`. Fixed in `ce817d2`.
2. **The drain lock was never released on a throw.** `_draining` went true
   with no `try/finally`; one throw wedged the queue permanently, and
   `cancelAll()` could not free it. Fixed in `95a271f`.
3. **`_exists` treated every `stat` failure as "free"**, including
   permission-denied, so an occupied name could be selected and OpenSSH's
   silent-overwriting `rename` would destroy the file. Data loss, not
   inconvenience. Fixed in `28f865f`.

Finding 3 had been deferred once as pre-existing. That was wrong: the
resolver went from calling `_exists` once per upload to up to a hundred
times, and the queue multiplies it again. **Probability is what the
decision turns on, not code age.**

One hypothesis of mine was disproved by review: the second resolution pass
does NOT create two destructive publication windows. Only the final rename
publishes, so it NARROWS exposure to final-stat-through-rename.

## Known limits, stated rather than hidden

- Upload and the gallery picker are **Android only**; SAF has no iOS
  counterpart, and no control is shown where it cannot work.
- The native Photo Picker needs **Android 13+**; below that it falls back to
  a filtered document pick.
- The free-name search is **bounded at 100**; past that the upload is
  refused rather than guessing.
- **The stat-to-rename race remains.** Narrowing was never closing:
  OpenSSH's `rename` silently replaces its destination.
- Boundary containment guarantees an *outcome*, not recovery — an
  unexpected failure may leave a `.helmpart` behind.
- The queue cannot guarantee remote cleanup if a defective service throws
  before finishing its own.

## Not verified on hardware

Everything in this block ran against test doubles. The Android picker and
the SAF / Photo Picker APIs reach a method channel no test host has, and
the PTY evidence for the floating panel came from a fake SSH service rather
than a live server. The S22's Android version could not be read — no device
was attached over adb — so the sub-API-33 fallback is treated as real.

Device validation is deliberately deferred to ONE pass at the end, by the
user's preference. The ordered checklist is `odd/tasks/device-validation.md`.

## Orchestration lessons

**Branch a dependent worktree AFTER integrating its prerequisites.** The
queue worktree was cut from the feature branch before the media and naming
slices were merged in, so its writer found APIs that genuinely were not
there and stopped without writing a line.

**Allowed edit surfaces must follow the blast radius of the decision, not
the directory of the file being changed.** Four of five writer stops came
from this one mistake: a shared test fake in `test/helpers/`, generated
files behind a profile field, a storage key in `AppConstants`, and two
parallel slices handed the same `test/features/files/**` glob.

**Lint is a property of the integrated tree.** Two branches each reporting
`analyze` clean produced three infos when merged.

**Appending-only instructions prevent conflicts.** Three slices touched
`semantic_ids.dart` and it auto-merged, because every brief said append
without reordering.

**Delegate route matters.** Everything routed to `anthropic` died on an
expired OAuth refresh token; `openai-codex` worked. The error is one line in
`~/.pi/agent/gentle-agents/sessions/<id>.jsonl` — read it before theorising.

**A huge delegate seed starves the child.** One review launched with 194KB
of projected context and ~15k tokens of runway, read 1 of 4 files, and
stopped. Scope delegate prompts narrowly or use a worktree subagent.
