# voice-input-cross-platform

Dictate to an agent from the phone, transcribed on the Mac. Task 3 of
`voice-and-share-input.md`, reopened for BOTH platforms after the owner
moved from a Samsung S22 to an iPhone 16.

That earlier document assumed Android only. Its design, its measured
Whisper numbers and its push-to-talk decision all still hold; what
changes is that every surface now needs an iOS half, and that the UI has
to work on both.

## Specs

- **S1** — "con la voz, tenemos que hacerlo" and "para las 2 plataformas,
  recuerda que le damos soportes a ambos". Voice dictation ships for iOS
  **and** Android. Neither is a follow-up.
- **S2** — "ve el tema responsive etc". The recording UI must hold up
  across the phone sizes the app already supports, including the floating
  keyboard that can overlap the terminal.
- **S3** — "ve si no estamos exponiendo nada o quizas temas de seguridad,
  porque es repo abierto". The repository is public and a friend will use
  the app. Nothing added here may leak the owner's infrastructure, and
  the audio path must not become a shell-injection or data-retention
  hole.
- **S4** (inherited, `voice-and-share-input.md` task 3) — Push-to-talk,
  **not a toggle**: "a toggle left recording in a pocket is a microphone
  nobody asked for."
- **S5** (inherited) — 16 kHz mono wav, uploaded through the existing
  `SftpUploadService`, transcribed through the existing
  `HostCommandRunner` with `whisper-cli` and `ggml-large-v3-turbo` plus a
  maintained vocabulary prompt. **Delete the remote audio after
  transcription.**
- **S6** (inherited, task 1, already shipped) — The transcript is typed at
  the prompt **un-sent**. The user reviews before pressing enter.

## Measured constraints carried over

From `voice-and-share-input.md`, with `say`-generated speech, 5.3s of
audio, `ggml-large-v3-turbo`:

| | Time | Output |
| --- | --- | --- |
| No prompt | 1.92s | "on-task removed en Darts 2 ... ripo de ELM" |
| With vocabulary prompt | 1.35s | "onTaskRemoved en dartss2 ... ripo de helm" |

0.26x real time, and the vocabulary prompt fixed terms while running
faster. `repo` was missing from the prompt and stayed wrong: the term
list is the lever.

That was clean synthetic speech. Real speech in a noisy room is worse, so
this is an optimistic bound.

## Security boundary for this change

Audited before writing any code, for S3.

- **`shellQuote` already exists and is correct**
  (`lib/core/host/shell_quote.dart`, POSIX `'\''` idiom, 13 callers,
  covered by `test/core/host/shell_quote_test.dart`). The audio path
  reaches `whisper-cli` through a remote login shell, so it goes through
  `shellQuote` or it is a command-injection hole.
- **The remote audio must be deleted even when transcription fails.**
  Deleting only on the happy path leaves recordings of the owner's voice
  on the Mac.
- **The local temp file must be deleted too**, on the same terms.
- **The transcript must never be logged.** Dictation can contain
  secrets; the existing loggers print at info level.
- **No real hostnames, tailnet names or Team IDs** in code, tests,
  fixtures or docs. Commit `557d712` already paid for this once.

## Tasks

- [x] 1. Barrido read-only de responsive y paridad de plataforma
  - Route: `gentle-ai-explore`, read-only. **NOT OpenAI**: `bg_delegate`
    projects the whole conversation into the child, and this session no
    longer fits `openai-codex/gpt-5.6-luna`'s 243328-token input budget
    (measured 247539 bytes with a minimal prompt). Recorded because the
    owner asked for OpenAI specifically.
  - Findings landed in `## Barrido: hallazgos verificados` below.
  - Commit: n/a

- [x] 2. Captura de audio con permiso y push-to-talk
  - Surfaces: `lib/features/voice/**`, `pubspec.yaml`,
    `ios/Runner/Info.plist`, `android/app/src/main/AndroidManifest.xml`,
    `test/features/voice/**`
  - Delivered by `gentle-ai-worker`. Covers S1 (capture half, both
    platforms) and S4 in full.
  - `record: 7.1.2`, pinned. **Verified from the resolved package's own
    pubspec, not from the report**: it declares `default_package` for
    `android`, `ios` and `web`, so the platform split belongs to the
    dependency rather than to an assumption here. That is the opposite
    risk shape from `saf_util`, which turned out android-only.
  - No `Platform.isIOS` branch exists because `record` is federated;
    there is nothing to fork in this app.
  - Commit: pending

- [ ] 3. Transcripción remota y borrado garantizado
  - Surfaces: `lib/features/voice/**`, `lib/core/host/**`, `test/**`
  - Upload through `SftpUploadService`, run `whisper-cli` through
    `HostCommandRunner` with every path `shellQuote`d, type the result at
    the prompt un-sent through the task-1 seam.
  - Remote and local audio deleted in a `finally`, proven by a test that
    makes transcription throw.
  - Commit: pending

- [x] 4a. Safe area inferior del teclado flotante
  - Surfaces: `terminal_keyboard.dart`,
    `test/features/terminal/presentation/widgets/`
  - Delivered by OpenAI (`gpt-5.6-luna`) through a direct `pi` process.
    Introduces `safeHeight` and applies it to all five sites that used
    the raw viewport height, including the drag clamp and the stored
    geometry normalisation. Verified by grep that no unprotected
    `viewport.height` remains.
  - Commit: pending

- [x] 4b. Resto de los hallazgos del barrido
  - Surfaces: `session_recovery_banner.dart`,
    `test/features/terminal/presentation/widgets/`
  - Delivered by OpenAI, which was told to VERIFY before fixing. It did,
    and the two findings split:
    - **Text scaling in the 48dp keys and footer: NOT REPRODUCED.** The
      overflow list came back empty at `TextScaler.linear(2.0)` on a
      narrow viewport, so there was no RED and no fix was made.
      `terminal_keyboard.dart` was left carrying only the safe-area
      change. A reported defect nobody can reproduce is not a defect.
    - **Recovery banner: REPRODUCED and fixed.** Now a `LayoutBuilder`
      that adapts instead of a single non-wrapping `Row`.
  - The Finding A test is kept as a preventive guard. It passes with and
    without any change, so it proves nothing today; it exists to catch a
    future regression.
  - Commit: pending

## Barrido: hallazgos verificados

The sweep reported these; each one below was re-measured by the parent
before being accepted, because a subagent's finding is a lead, not a
fact.

### CONFIRMED, and the sweep missed the cause

**The floating keyboard can sit under the home indicator.**
`terminal_keyboard.dart:72-88` subtracts only `padding.horizontal`;
vertical travel uses the full viewport. The sweep called this a blocker
and it is right, but the interesting part is WHY. The code justifies
itself with:

> `// Home's AppBar and fixed safe-area FAB shelf already consume`
> `// vertical insets.`

**That shelf no longer exists.** `home_screen.dart:349` records its
removal verbatim: "NO reserved shelf. This used to be a
`bottomNavigationBar: SizedBox(height: 80)`", dropped to give terminal
rows back. A `Scaffold` without a `bottomNavigationBar` does not wrap its
body in `SafeArea`, so the bottom inset is inside the viewport the panel
receives. The comment outlived its premise.

This matters for S2 and for this feature specifically: the push-to-talk
control is going in the keyboard footer, which is the exact edge that can
land under the home indicator.

### CONFIRMED as deliberate, not defects

- **370dp minimum width** (`keyboardMinimumWidth`, 7*48 + 16 + 6*3). A
  360dp phone scrolls the strip horizontally. The code documents the
  tradeoff and the arithmetic that rules out the alternatives, and names
  the 384..412dp phones it optimises for. Not a defect; a priced
  decision.
- **Terminal not resized when the keyboard appears.** Deliberate: the
  PTY is never resized by toggling the keyboard.

### ACCEPTED, unverified by the parent

- Text scaling is unbounded in the 48dp command keys and the footer, so a
  large accessibility font can overflow them
  (`terminal_keyboard.dart:229-241`, `:1159-1188`).
- `session_recovery_banner.dart:25-36` is a non-wrapping `Row` with fixed
  48/64dp buttons.

### Platform parity, measured

Every platform branch in `lib/` is a seam with an injectable flag, not a
scattered `Platform.is*` check. Android-only today: session hold
(`foreground_service_host.dart`), incoming shared text
(`shared_text_receiver.dart`, degrades through `MissingPluginException`),
chosen download folder, and push (`firebase_options.dart:25` throws on
iOS). Uploads already have both halves.

### The seam pattern the voice work must follow

The platform decision lives in ONE provider
(`file_upload_provider.dart:14-27`), never in consumers. Reuse, do not
reinvent: `SftpUploadService.upload` for the wav,
`TerminalSession.hostRunner` for `whisper-cli`, and
`TerminalSession.typeAtPrompt` (`terminal_session.dart:1145-1184`) for
the transcript, which already flattens newlines and writes no trailing
newline.

Put push-to-talk in the keyboard **footer**, beside Hide/Resize. Not in
the command strip, which is fixed at seven 48dp controls and exactly
consumes the 370dp minimum. Not in the app-bar overflow, which needs a
selection rather than a press-and-hold.

## Order, and why

Task 1 runs in parallel with task 2 because it is read-only and informs
the UI, not the plumbing. Task 3 depends on task 2 having a recording to
upload. Task 4 is last by construction.

## Log

- **L1** (owner, verbatim): "con la voz , tenemos que hacerlo , ve si no
  estamos exponiendo nada o quizas temas de seguridad , porque es repo
  abierto"
- **L2** (owner, verbatim): "para las 2 plataformas , recuerda que le
  damos soportes a ambos, ve el tema responsive etc , pero manda a openia
  a realizar un barrido de eso, mientras mandas a subagente a hacer la
  integracion, usa odd para este todo OK"
- **L3** (audit, this session): no secrets are committed; the only
  sensitive-looking tracked file is `android/app/google-services.json`,
  whose client API keys are public by design. Signing material is
  gitignored. The owner's tailnet remains recoverable from git history
  through the diff of `557d712`, which that commit argues is low risk
  (CGNAT, non-resolving MagicDNS) — not addressed here, flagged to the
  owner.
- **L4** (measured, this session): `shellQuote` exists, is correct, and
  is the defence this feature must use.
- **L5** (verification, this session): both deliveries were accepted only
  after mutation testing by the parent, because green alone proves
  nothing.
  - Safe area: reverting the fix makes the new test fail. Its two
    assertions live in ONE `testWidgets`, so the mutation only exercises
    the first; the drag clamp was isolated into a throwaway probe and
    shown to have teeth of its own, then deleted.
  - Pocket microphone: two mutants of `PushToTalkRecorder.dispose` —
    calling `stop()` instead of `cancel()`, and calling nothing — are
    BOTH caught. The test distinguishes cancel from stop, not merely
    presence from absence.
  - Temp-file deletion: neutering `_deleteIfExists` kills
    "the platform throwing on stop deletes the file it had written".
  - One of my own mutation attempts named a method that does not exist
    (`_deleteQuietly` for `_deleteIfExists`), so it mutated nothing and
    the suite passed trivially. A mutation that changes no bytes is not
    evidence; verify the mutant actually landed.
- **L6** (orchestration, this session): the worker flagged an unexpected
  modification to `terminal_keyboard.dart` as a possible contract breach
  by the read-only sweep. It was not: the sweep (`gentle-ai-explore`)
  edited nothing. That file was written by the OpenAI process launched
  afterwards, with an explicitly disjoint edit surface. Raising it was
  correct behaviour by the worker — it had no way to know.
