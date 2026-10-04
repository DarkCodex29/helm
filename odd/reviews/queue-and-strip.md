# Queue provider tests, browser sheet and transfer strip — adversarial review

Source-only review. No production/test files changed; no Flutter commands or mutation tests run. The reported 1540 passing tests and clean analysis are supplied context, not independently verified here. Findings below are source-derived; triggering sequences were not executed.

## Defects (severity ordered)

### Medium — successive upload refreshes can restore an older listing

**Location:** `lib/features/files/presentation/file_browser_sheet.dart:413`; `lib/features/files/presentation/providers/file_browser_provider.dart:213–217`.

Each successful owned upload starts a refresh without waiting for the preceding refresh. The browser accepts a reply whenever its path equals the current path; it does not distinguish two requests for that same path. Consequently, exactly-once observation of upload IDs does not ensure a fresh final listing.

**Trigger:** Upload A and B to the same displayed directory. A completes and refresh R1 obtains a listing containing A but not B; R1 remains unfinished (for example, resolving a symlink in that listing). B completes and refresh R2 returns a listing containing both files. R1 then finishes and overwrites R2 with the older entries. The sheet can omit B despite two successful receipts. The service's `list` has asynchronous per-symlink resolution and no listing serialization (`lib/features/files/data/sftp_file_service.dart:90–113`).

### Medium — write-dialog continuations outlive the sheet

**Location:** `lib/features/files/presentation/file_browser_sheet.dart:270–272`, `294–296`, `378–381`.

Unlike `_upload`, create-folder, rename and delete do not check `mounted` after their dialogs return. Delete calls `setState` on a disposed State. Create-folder and rename can still issue remote mutations through the captured, shared browser notifier; `_report`'s mounted check only suppresses the later toast, not the operation.

**Trigger:** Open one of these root-navigator dialogs, remove its underlying sheet while retaining the dialog, then confirm. Delete hits `setState` after disposal. Create-folder/rename still perform the write. If another sheet has meanwhile rebound the browser notifier, the old confirmation can operate through the new sheet's service/current directory. This is conditional on external route removal, not an ordinary back press (which dismisses the dialog first).

### Medium — successful-upload tests do not prove the listing contains the upload

**Location:** `test/features/files/presentation/file_browser_upload_test.dart:421–430`, `253–259`; `test/helpers/fake_sftp_session.dart:306–353`.

The tests count listing calls and inspect `writtenBytes`, but never assert that the refreshed browser entries contain the uploaded files. The fake's upload finalization moves bytes but deliberately does not insert an untracked uploaded file into `_directories`. Thus these tests pass with an empty refreshed listing, contrary to the successful-upload test's explanation that an omitted file would be dishonest.

**Trigger:** The existing successful-upload fixture starts with an empty directory and uploads `report.docx`. Rename populates `writtenBytes`, refresh lists the still-empty `_directories`, and all existing assertions can pass. The two-media completion test has the same blind spot. Additionally, `_pumpSheet` returns the same session for browsing and every transfer (`:81–89`); it keeps using that fake after upload closes it, behavior a real closed SFTP channel does not support. Shared filesystem state is sensible; this shared session lifetime is not faithful coverage of the production channel contract.

### Low — widget tests use elapsed wall time as completion/scheduling evidence

**Location:** `test/features/files/presentation/file_browser_upload_test.dart:101–114`, `187–209`, `524–535`.

`_tapUpload` waits 50 ms rather than observing completion. The media test expects the first item still active with zero done after that wait even though its source only delays each chunk by 200 ms. The dedicated cancellation test waits 30 ms to infer an upload has started, then waits another 50 ms for cancellation to settle. Real-clock scheduling does not guarantee these milestones: the test isolate may resume after more than one source timer has fired, or before setup has finished.

**Trigger:** A delayed/loaded test runner changes which upload phase has been reached when those waits resume. Correct implementation can fail the active/count/cancelled assertions. These tests do require `cancelled`, not “cancelled or completed”; the problem is an uncontrolled cancellation window, not an either-outcome assertion. The provider tests do not have this particular problem.

### Low — failed/cancelled queue receipts lose file identity

**Location:** `lib/features/files/presentation/sheet/transfer_strip.dart:120–135`.

Success and name-exhaustion receipts identify the picked file; cancellation and general failure receipts do not. Once the active line moves to the next item, the strip no longer tells the user which file failed or was cancelled.

**Trigger:** Pick multiple files, let one fail, then let later items run/finish. The receipt retains only a generic reason. Multiple failures/cancellations yield indistinguishable receipts, leaving the user unable to identify individual retry targets from the strip.

## Latent risks

- **Orphan root dialog:** `lib/features/files/presentation/file_browser_sheet.dart:207–211`. The upload source dialog belongs to the root navigator and has no sheet-disposal cleanup. Removing the underlying sheet while leaving that navigator alive leaves the source dialog visible until someone dismisses it. Its eventual result is safely ignored by the mounted guard, so this is not a demonstrated dead-context upload. No normal barrier/back route leak was found. Tests embed the sheet as a Scaffold body (`test/features/files/presentation/file_browser_upload_test.dart:81`), so they do not exercise its actual modal-sheet/navigator lifetime.
- **No evidence for asynchronous real session-close exclusion:** `test/features/files/presentation/file_upload_provider_test.dart:144–164`. The twenty-item test genuinely exercises exclusion, but its sessions close immediately. It does not establish that a service implementation returning before channel cleanup would be caught. The throwing-service cleanup test separately models an awaited service lifetime; it is not a delayed real-session `close` test. This is a coverage limit, not a newly found queue-lock defect.

## Cosmetic

- **Hidden receipt overflow affordance:** `lib/features/files/presentation/sheet/transfer_strip.dart:72–83`. Twenty terminal receipts remain in the scrollable child, not deleted or intrinsically unreachable. However, the code provides neither an explicit scrollbar nor a “more receipts” cue, and there is no auto-scroll to new receipts. On mobile, later failures/collision names can sit below the 80-pixel viewport while the user sees only early successes and the aggregate count. Long receipt names wrap inside the horizontally constrained `_EndingLine` and remain vertically scrollable; no source-level horizontal overflow was found. The active name is ellipsized (`:157–159`), potentially hiding its progress percentage too.

## Clean conclusions / refuted suspicions

- **Provider test honesty:** clean for the examined mutual-exclusion, controlled cancellation and aggregate assertions. In the twenty-item test, the first opener is explicitly blocked; all twenty enqueues occur before release. Removing the drain-entry lock lets later openers run before their predecessors close. Their internal expectations can be caught by the real service, but then those openers never increment `opened`, so the final `opened == 20` assertion still fails. This is not merely lucky serial scheduling. This conclusion is source reasoning, not an executed lock-removal experiment.
- **Provider cancellation:** clean. The opener-gated tests cancel before the session is delivered and require `cancelled`/no write. The byte-progress test cancels synchronously in the provider listener; the real pump checks cancellation immediately after invoking progress. It requires partial removal and `cancelled`, not either terminal result. None demonstrates late cancellation by accepting success as cancellation.
- **Provider aggregates:** clean. The mid-drain test blocks the second opener; the first settles while the third cannot start. Its one-done/two-remaining snapshot is pinned by a gate, not a guessed elapsed interval. At-rest assertions follow draining of these immediate fake operations.
- **Owned-ID observation and dismissal:** clean on the normal notification path. The sheet removes an ID from `_uploadDirectories` when it first observes any terminal state, before subsequent progress/dismiss notifications. Completion therefore cannot independently refresh twice for that ID. `dismiss()` cannot erase an active item, and terminal notification is observed before a later user dismiss; the earlier “vanished owned ID loses refresh” suspicion is refuted for this path. Completion while viewing another directory intentionally does not refresh/jump back. The widget-bound listener is removed on unmount, so subsequent completions do not initiate refresh through a dead sheet; a refresh already started can still finish afterward.
- **Collision copy:** clean. `UploadCompleted.name` is the actual saved basename, and `transfer_strip.dart:115` explicitly compares it with the picked name. Equal names render only `Uploaded a.jpg.`; renamed names render `Uploaded a.jpg as a(1).jpg.`
- **Upload async gaps / double-open:** clean for the source-opening callback. `_pickingUpload` is set synchronously before the first await and stays set through platform picking; rapid upload taps cannot open a second source dialog. Mounted checks occur after both the source dialog and picker await. The `finally` only changes a plain field. Download/navigation callbacks do not access widget state after their awaits; `_report` guards context access after write-service awaits. The missing post-dialog guards in the write callbacks are the defect above, not an upload continuation defect.

## Files actually read

Read completely:

- `test/features/files/presentation/file_upload_provider_test.dart`
- `lib/features/files/presentation/providers/file_upload_provider.dart`
- `lib/features/files/presentation/file_browser_sheet.dart`
- `lib/features/files/presentation/sheet/transfer_strip.dart`
- `lib/features/files/presentation/sheet/upload_source_dialog.dart`
- `test/features/files/presentation/file_browser_upload_test.dart`
- `lib/features/files/data/sftp_upload_service.dart`
- `lib/features/files/presentation/providers/file_browser_provider.dart`
- `lib/features/files/domain/upload_outcome.dart`
- `test/helpers/fake_sftp_session.dart`
- `test/helpers/fake_document_tree_gateway.dart`
- `lib/features/settings/presentation/trusted_hosts_screen.dart` (the sheet's cited confirmation precedent; it also lacks a post-dialog mounted guard, so it is not evidence that such continuations are safe).

Read partially: `lib/features/files/data/sftp_file_service.dart`, lines 1–160 (session acquisition fields and listing implementation).

Not read: the remainder of `sftp_file_service.dart`; other sheet parts, picker/platform implementations, download/destination providers, home/router/session teardown code, other tests, and Flutter/Riverpod framework internals. No exhaustion of context prevented reading any of the six requested files. Navigator-removal scenarios are identified as conditional rather than claimed to have been observed in the current app's teardown flow.
