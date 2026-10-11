# voice-and-share-input

Baseline `main` = `1abc5fc`, pushed, clean tree, 1492/1492 passing.

## What the owner asked for

1. Dictate to agents by voice from the Android phone, using the Mac as the
   transcription engine.
2. Get text that lives on the phone — a WhatsApp message, anything — into the
   agent session, and the Mac's clipboard into the phone.

## The shape this takes, and why

Both requests end in the SAME place: text arriving in the terminal's input
field, where the owner reads it and presses enter himself. So this is one seam
with several sources, not several features.

The review step is a decision, not a default. Measured transcription of clean
synthetic speech already produced `dartss2` for "dartssh2" and `ripo` for
"repo"; sending that straight to a shell with a newline turns a mis-heard word
into an executed command, in a session where agents are working. One tap to
read a line is cheap; an executed mistake is not.

## Measured constraints that shaped the design

### The Android clipboard cannot be read in the background

Android's own documentation: "Unless your app is the default input method
editor (IME) or is the app that currently has focus, your app cannot access
clipboard data on Android 10 or higher." The framework agrees —
`ClipboardService.clipboardAccessAllowed` gates `OP_READ_CLIPBOARD` on
`mWm.isUidFocused(uid)` — and is explicit that `OP_WRITE_CLIPBOARD` is
"allowed without focus".

So the capability is ASYMMETRIC:

| Direction | Works |
| --- | --- |
| Mac to Android clipboard | yes, no focus needed |
| Android to Mac, copying inside helm | yes, helm has focus |
| Android to Mac, copying in another app | NO |

The apps that do the third case use an overlay window that steals focus,
`READ_LOGS` granted over adb, or Shizuku. Each costs a visible overlay, a
permission that must be re-granted from a computer, or a service that dies on
reboot.

### The share sheet makes the third case unnecessary

`ACTION_SEND` is the OS-sanctioned path for moving text between apps. It needs
no clipboard read, no focus, no extra permission. It is also SAFER than
clipboard sync: only what the owner deliberately shares travels, so a token
sitting in the clipboard never leaves by accident.

This replaces clipboard sync in the phone-to-Mac direction entirely.

### Whisper on the Mac is fast enough, and the prompt is a real lever

Measured with `say`-generated speech, 5.3s of audio, `ggml-large-v3-turbo`:

| | Time | Output |
| --- | --- | --- |
| No prompt | 1.92s | "on-task removed en Darts 2 ... ripo de ELM" |
| With vocabulary prompt | 1.35s | "onTaskRemoved en dartss2 ... ripo de helm" |

0.26x real time, and the prompt fixed `onTaskRemoved` and `helm` while running
FASTER. `repo` was missing from the prompt and stayed wrong, which is the
lever: the term list is worth maintaining.

Honest limit: `say` is clean synthetic speech. Real speech in a noisy room will
be worse, so this is an optimistic bound, not the average case.

## Tasks

- [x] 1. A seam that types text at the remote prompt, without sending it
  - Surfaces: `lib/features/terminal/data/terminal_session.dart`,
    `test/features/terminal/data/**`
  - Measured correction to this plan, made before writing code: **there is no
    input field.** `TextField`, `TextEditingController` and `EditableText`
    appear nowhere under `lib/features/terminal/`; `TerminalKeyboard` takes the
    terminal and writes straight to it, and the only path to the host is
    `terminal.onOutput` (`terminal_session.dart:1233`). There is no buffer to
    stage text in.
  - So the review surface ALREADY EXISTS and it is the remote prompt. Writing
    the text **without a trailing newline** leaves it typed at the prompt,
    exactly as if the owner had typed it: he reads it there, edits it with the
    shell's or the agent's own keys, and presses enter himself. Zero new UI.
  - The precedent is one character away. The drawer's QUICK ACTIONS section,
    deleted in `098fc09`, did `session.terminal.onOutput?.call('${action.command}\n')`
    WITH a newline, so it executed on tap. That `\n` is the whole difference
    between that feature and this one.
  - Honest limit: this types into whatever is reading stdin. At a shell or an
    agent prompt that is exactly right; with an interactive program in the
    foreground the text goes to that program. Same behaviour as typing, so it
    surprises nobody, but it is worth stating.
  - Test first.
  - Commit: e0a8873

- [ ] 2. Receive shared text from any app
  - Surfaces: `android/app/src/main/AndroidManifest.xml`,
    `android/app/src/main/kotlin/com/darkcodex/helm/**`,
    `lib/features/terminal/**`, `test/**`
  - `ACTION_SEND` + `text/plain` intent-filter, delivered to Dart over a
    MethodChannel. Prefer the existing native-plugin pattern
    (`SessionHoldPlugin`) over adding a dependency: the codebase already owns
    that seam and a plugin would be a third-party surface for ten lines.
  - Must handle BOTH a cold start from the share sheet and a share arriving
    while helm is already open.
  - Commit: pending

- [ ] 3. Dictate by voice, transcribed on the Mac
  - Surfaces: `android/app/src/main/AndroidManifest.xml`, `pubspec.yaml`,
    `lib/features/voice/**`, `lib/features/terminal/**`, `test/**`
  - Push-to-talk, not a toggle: a toggle left recording in a pocket is a
    microphone nobody asked for.
  - 16 kHz mono wav (~32 KB/s measured). Upload through the existing
    `SftpUploadService`, transcribe through the existing `HostCommandRunner`,
    using `whisper-cli` with `ggml-large-v3-turbo` and a maintained vocabulary
    prompt. Delete the remote audio after transcription.
  - Needs `RECORD_AUDIO`, a runtime permission with a real prompt.
  - Commit: pending

- [ ] 4. Write the Mac's clipboard to the phone
  - Surfaces: `lib/features/terminal/**`, `test/**`
  - Writing needs no focus, so this direction can be automatic. It is still
    worth a deliberate trigger rather than a background poll.
  - Commit: pending

## Order, and why

Task 2 ships first after the seam: it is the smallest piece, it needs no new
permission and no new dependency, and it alone answers "let me copy WhatsApp
messages". Voice is the largest and should not block it.

## Security note, raised deliberately

A clipboard carries secrets — tokens, passwords, keys — and helm stores SSH
private keys. The share sheet avoids this by construction for the outbound
direction. For task 4, syncing the Mac's clipboard INTO the phone is the lower
risk direction, but it still means whatever is on the Mac's pasteboard can land
on the phone, so the trigger stays explicit rather than a poll.

## Out of scope, recorded deliberately

- Background clipboard reading on Android via overlay, `READ_LOGS` or Shizuku.
  Each has a real cost and the share sheet makes them unnecessary.
- On-device Android speech recognition. It is tuned for everyday speech and
  mangles the technical vocabulary that is the whole use case; the measurement
  above is the argument.
- Streaming or continuous dictation. Push-to-talk on bounded clips first.

## Task 2 follow-up: `connected` is not `ready`

Device validation split the feature in two, and only measurement could have
told them apart.

The WARM path works, confirmed on the S22: a share arriving while helm is open
landed as `▎ echo HELM_HOT_d5f8` inside the pi agent's input box — typed,
un-executed, exactly as designed.

The COLD path did not. Every piece of plumbing reported success — Kotlin
captured the intent, the pending buffer held it across 2.9s, the write was
issued — and the text reached no pane at all. helm was writing 2ms before
`Session connected`, while herdr was still attaching and repainting, and a
full-screen TUI discards input in that window.

Fixed with `TerminalSession.waitForOutputToSettle`: a 500ms quiet window with
a 5s cap, armed lazily so the dozens of tests that connect without sharing pay
no Timer for it.

Two defects found while finishing it, both worth keeping:

1. `_armOutputSettleTracking()` ran AFTER `statusNotifier.value = connected`.
   A `ValueNotifier` runs its listeners synchronously, so the share listener
   asked whether output had settled one line before the answer existed, took
   the "nothing to wait for" early return, and reintroduced the exact defect
   the tracking exists to fix. The order is now load-bearing and says so.
2. Four of the five tests asserted only the end state and passed throughout.
   Only the one asserting the intermediate state caught it. See
   `odd/notes/measurement-traps.md`.

- [x] 2. Receive `ACTION_SEND` + `text/plain`
  - Warm path verified on device; cold path fixed and green in the suite.
  - Commit: pending
  - **Owed: re-run the cold start on the S22.** The cable dropped four times
    this session and the last attempt died in `- waiting for device -`. The
    phone found this defect once with the suite green, so its verdict is the
    one that closes this task — not the 1517 passing tests.
