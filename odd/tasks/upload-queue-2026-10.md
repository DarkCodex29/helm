# Upload queue and media source (2026-10)

Branch: `feat/upload-queue-2026-10`, off `main` = `12515e9`.

## Why

Attaching a photo from the phone was effectively impossible. The upload
button existed and worked, but `UploadSourcePicker.pick()` calls
`saf_util.pickFile()` with NO mime filter (`document_tree_gateway.dart:195`),
which opens the *document* picker: reaching a camera photo meant navigating
to `DCIM/Camera` by hand and recognising the filename.

The user asked for a modal on the files icon offering "Mac files" or "phone
files". That framing does not hold: the files icon opens the REMOTE browser,
and a local-only file browser has no destination and no purpose. The real
fork is the SOURCE of an upload — document or photo — so the modal belongs
on the upload button.

## Audit findings that shaped the plan

1. **The service layer is already queue-ready and is not being changed.**
   `SftpUploadService.upload()` is a clean single-file primitive: pre-flight
   `stat` (`:128`), writes to `.helmpart` then renames (`:71`), cleans the
   partial up on failure (`:294`), 30s PER-CHUNK timeout (`:59-65`), real
   cancellation between chunks (`:258,285`). A queue calls it N times.

2. **"One upload in flight" lives only in UI/state**, four sites that get
   REPLACED rather than generalised: `FileUploadState`,
   `FileUploadNotifier.start` (replaces instead of enqueueing,
   `file_upload_provider.dart:88-90`), `_upload()`'s `isRunning` refusal
   (`file_browser_sheet.dart:182`), and `_UploadStatusBar` (`:534`).

3. **Name collision is a dead end, and the queue makes it unbearable.**
   `UploadDestinationExists` only prints "Rename it on the host, or choose a
   different file" (`file_browser_sheet.dart:597-602`). With 20 gallery
   photos named `IMG_2026...jpg`, a collision on item 7 with that message is
   unusable. The correct pattern ALREADY EXISTS in this repo, in the other
   direction: `copyInto` never overwrites, lets the platform mint
   `report(1).docx`, and returns the name actually created
   (`document_tree_gateway.dart:66-67,178-186`).

4. **Upload/download duplication is NOT being abstracted.** They look like
   mirrors but diverge where it matters: download publishes to SAF with a
   viewer and a persisted destination, upload has none of that; and
   cancellation differs for a measured reason documented at
   `sftp_upload_service.dart:21-22` — upload cancels for real between
   chunks, download polls. Unifying them would fuse two things at their
   point of divergence.

5. **`file_browser_sheet.dart` was 1604 lines across 20 classes.** This is
   what blew the 400-line review budget three slices running (847, 482,
   602), recorded as "pendiente de criterio: the fix would be structural".
   Splitting it first IS that structural fix.

6. **`saf_util 2.2.0` already ships the native Photo Picker**:
   `pickMedia(mode:'photo')` → `MediaStore.ACTION_PICK_IMAGES`
   (`SafUtilPlugin.kt:584`). Real gallery, no storage permission.
   **Trap: it throws `NOT_SUPPORTED` below API 33** (`SafUtilPlugin.kt:563-566`),
   so a fallback to `pickFile(mimeTypes: ['image/*','video/*'])` is not
   optional.

## Tasks

- [ ] **1. Split the sheet along its existing seams.** Pure byte move using
  `part`/`part of`, no renames, no behaviour change. `part` rather than
  independent files because all 20 widgets are library-private and share 7
  private palette constants: independent files would force them public and
  rewrite ~100 references, which stops being a verifiable move and exposes
  an internal API nothing else consumes.
  Verification: the 1469 existing tests stay green untouched, `analyze` clean.

- [ ] **2. Name resolution in `SftpUploadService`.** `foto.jpg` → `foto(1).jpg`
  when taken, mirroring `copyInto`. Test-first: today the service returns
  `UploadDestinationExists`; it must return the derived name instead.
  Surfaces: `data/sftp_upload_service.dart`, `domain/upload_outcome.dart`.

- [ ] **3. Media seam in the gateway.** `pickMedia` plus the sub-API-33
  fallback to `pickFile(mimeTypes:)`.
  Surfaces: `data/document_tree_gateway.dart`, `data/saf_upload_source.dart`.

- [ ] **4. Queue in the notifier.** A list of items each with its own state,
  one in flight at a time, cancel-one and cancel-all. Replaces the four
  sites from finding 2. Depends on task 2's outcome shape.
  Surfaces: `presentation/providers/file_upload_provider.dart`.

- [ ] **5. Source modal and queue strip.** "Document" / "Photo or video",
  plus the per-item queue strip, on an already-split file.
  Depends on 1, 3, 4.

## Parallelism

Tasks 1, 2 and 3 touch disjoint files and ran in parallel across git
worktrees under `../helm-worktrees/`, explicitly authorised by the user.
Tasks 4 and 5 are serialized behind them.

## Not verified on device

Everything SFTP-write in this feature, like the slice before it, runs
against fakes. The Android picker and the SAF/Photo-Picker APIs reach a
method channel no test host has. The sub-API-33 fallback is treated as real
rather than theoretical because the S22's Android version could not be
read — no device was attached over adb during this session.

## Session note

Subagent delegation failed twice at the start of this session with 1 turn
and 0 tool calls. The cause was NOT the pinned tool-collision trap: it was
an expired Anthropic OAuth refresh token on the subagent route
(`invalid_grant`, "Refresh token not found or invalid"), read from
`~/.pi/agent/gentle-agents/sessions/...jsonl`. Re-authenticating fixed it.
