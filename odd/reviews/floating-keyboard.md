# Floating keyboard — adversarial source review

Source-only review. No Flutter test/analyze command was run; the reported green suite was not independently verified. No production or test files were changed. Findings below distinguish source-demonstrable defects from conditional risks; no patches are proposed.

## Defects (severity order)

### D1 — High: scrolling the shrunken keyboard can send unintended terminal input

- **Locations:** `lib/features/terminal/presentation/widgets/terminal_keyboard.dart:168`, `:868`, `:896`, `:1051`, `:1070`.
- **Trigger:** resize the panel vertically to 144dp (or use the short landscape layout). Only 48dp remains for the scrollable keyboard after the two 48dp chrome rows. Begin a scroll on ESC/TAB/an arrow or a letter/backspace, leave the finger down long enough for tap-down recognition (the ordinary tap-down timeout), then move beyond vertical drag slop. Holding a repeating key longer also permits repeats before scrolling begins.
- **Wrong behavior:** key handlers emit input in `onTapDown`, before the tap has won the arena. The enclosing vertical scrollable can subsequently win the drag and call `onTapCancel`, but cancellation only releases the pressed state/timers; already emitted bytes cannot be undone. A slow scroll can therefore send ESC, TAB, letters, or destructive backspace/arrow input. The scrollable is necessary to access the hidden keys in this state, so this is not merely a hypothetical gesture on an otherwise static grid. Narrow split-window horizontal scrolling has the same conflict.
- **Boundary:** the separate panel move handle itself does not wrap keys and cannot win a gesture that starts on a key. This defect is the new *key-scroll* arena, not handle/key hit-test overlap.

### D2 — Medium: seven 48dp-wide keys are not seven 48dp touch targets

- **Locations:** `lib/features/terminal/presentation/widgets/terminal_keyboard.dart:378`, `:963`, `:1079`.
- **Trigger:** resize to 370dp on an ordinary viewport, then press CTRL or any other top-bar key.
- **Wrong behavior:** the width arithmetic is correct: `(370 - 16 - 18) / 7 = 48`. But CTRL's gesture box is only 44dp tall, and the other six gesture boxes are also 44dp tall. The enclosing strip's 5dp padding above/below is outside those recognizers; it does not enlarge their targets. Thus the claimed 48dp target floor is met in width only, not both axes. This is a defect if “48dp targets” means the usual 48×48 minimum; the narrower width-only claim is true.
- **Letters:** at 370dp their painted height really is 44dp (`keyWidth = 332/11`, proportional height below 44); the lower height clamp is enforced. At wide sizes it increases up to 56dp, rather than staying identically 44dp.

### D3 — Medium: sufficiently short viewports remove the panel and its only reset control

- **Locations:** `lib/features/terminal/presentation/widgets/terminal_keyboard.dart:51`, `:153`; `lib/features/terminal/presentation/home_screen.dart:159`.
- **Trigger:** rotate or shrink a split window until the terminal body is under 96dp high. For example a 600×240 logical viewport with 24dp top and bottom safe insets, the default 56dp app bar and the 80dp safe-area bottom shelf leaves about 56dp for the body (without a recovery banner). An appearing system keyboard inset can also reduce the body through Scaffold's default inset resizing.
- **Wrong behavior:** `FloatingKeyboardPanel` returns `SizedBox.shrink()` even while keyboard state remains visible. There are no keys, drag handle, resize grip, or reset button. The FAB can toggle visibility but cannot restore a panel in the same viewport or clear stored geometry. Reset requires first enlarging the viewport/dismissing the inset. This contradicts unconditional panel/reset reachability, although it does not demonstrate an off-screen panel: the panel is absent entirely.

## Latent risks (conditional, not reproduced)

### R1 — Medium: multiple pan updates before a rebuild discard earlier deltas

- **Location:** `lib/features/terminal/presentation/widgets/terminal_keyboard.dart:52–93`, `:102`.
- **Trigger:** two `onPanUpdate` callbacks arrive between widget rebuilds, such as high-frequency pointer input relative to frame rate. For example, deliver two +10dp horizontal drag updates without an intervening build.
- **Behavior:** both callbacks calculate from the same captured `left`/`width`/`top`/`height`, rather than the geometry written by the previous callback. The second sets the same +10dp geometry instead of accumulated +20dp. Resizing has the same lost-delta pattern. This can make movement/resizing lag the finger under event batching or slow rendering. Actual device callback/frame cadence was not measured.

### R2 — Low: hydration protection does not preserve unsaved geometry across provider recomputation

- **Location:** `lib/features/terminal/presentation/providers/keyboard_provider.dart:44–53`.
- **Trigger:** change/invalidate the watched geometry-store provider after a user has dragged but before gesture-end persistence, then complete the new store read with older geometry.
- **Behavior:** recomputation returns a fresh default `KeyboardState`, losing the current geometry and modifiers/visibility. The new hydration token is valid, so the new read can restore older geometry. The token correctly blocks an *old* read after drag/reset/disposal, but does not preserve edits across a new build. No routine production invalidation of this fixed store provider was established, so this remains a lifecycle risk rather than a demonstrated normal-use defect.

### R3 — Low: write ordering is per notifier, not per persisted preference

- **Location:** `lib/features/terminal/presentation/providers/keyboard_provider.dart:41`, `:65–74`.
- **Trigger:** dispose a container with a pending save, construct another container using the same underlying preference, and reset/save there before the old write finishes.
- **Behavior:** queued writes continue after disposal and each notifier owns a separate queue. An older notifier's late write can finish after the new notifier's reset/save and restore stale persisted geometry. Ordinary drag/reset operations within one notifier are serialized correctly. This needs slow storage plus container replacement; no normal app path producing that overlap was established.

## Cosmetic

- **Location:** `lib/features/terminal/presentation/widgets/terminal_keyboard.dart:74–77`, `:175–187`.
- “Minimum size”/“Maximum size” is remembered until another update or reset; a rotation that changes the actual clamp can leave a stale limit message. This is feedback state, not an out-of-bounds geometry finding.

## Claims not proven by the tests

- **Target dimensions:** `test/features/terminal/presentation/home_screen_floating_keyboard_test.dart:165–185` genuinely resizes to 370dp at an 800dp viewport, so its *width* assertion is not vacuous. However it measures painted `AnimatedContainer` width only, never top-bar gesture height. The 384dp test (`:342–385`) proves ordinary-width letter dimensions/modifiers, not the complete minimum-resize contract. Neither proves access to every row at minimum height.
- **PTY isolation:** the tests at `:214` and `:293` observe xterm/session geometry and fake-service resize counts during one resize/hide path; they do not validate a live PTY or a connected rotation/inset transition. Source inspection supports panel-only geometry isolation: Home's `StackFit.expand` gives the terminal unchanged constraints, and panel geometry is consumed only by its overlay. External body changes (rotation, system inset, recovery banner) can still reach `TerminalView` → `Terminal.onResize` → `TerminalSession.onResize` and resize the PTY; that is not evidence that panel dimensions feed back into terminal constraints.
- **On-screen/recovery guarantees:** rotation tests use roomy 800×800 → 400×700 and 500×400 viewports. They do not exercise body height below 96dp, appearing viewInsets, minimum-height reset, or a stored oversized geometry restored in a different orientation. The reset test (`:200`) uses a roomy 800×800 viewport and does not assert reset reachability in edge states.
- **Gesture honesty:** the key test (`:115`) is a stationary tap; the touch-down test (`:390`) deliberately waits 150ms and verifies early emission. Neither scrolls from a key after that emission, tests near-boundary drags, or sends several pan updates without a build. No handle recognizer is an ancestor of the keys; no source evidence was found that a normal key tap becomes a *panel* micro-drag.
- **Persistence:** `test/features/terminal/keyboard_geometry_test.dart:32` covers malformed/incomplete/wrong-type input, one out-of-range x, and one negative width. It does not cover absent initial keys explicitly, y bounds, zero/negative height, huge positive dimensions, non-finite numeric encodings, or actual platform read/write/remove failures. Source catches storage/decode/type failures, rejects non-finite values and invalid position/nonpositive dimensions. Positive out-of-range dimensions are accepted by the store but clamped by panel build (`terminal_keyboard.dart:52–53`), so no restored oversized/undersized panel bypass was found. “Out-of-range reads as absent” is broader than the implemented dimension policy.
- **Hydration/lifecycle:** `keyboard_geometry_test.dart:57` meaningfully covers late original reads after drag/reset/container disposal. It does not cover watched-provider recomputation, overlapping old/new notifier write queues, delayed write/reset ordering, or store errors. The reconstruction test uses an immediately completing in-memory store, not a pending write during reconstruction.

## Files read

Fully read:

- `lib/features/terminal/presentation/widgets/terminal_keyboard.dart`
- `lib/features/terminal/presentation/home_screen.dart`
- `lib/features/terminal/presentation/providers/keyboard_provider.dart`
- `lib/features/terminal/data/keyboard_geometry_store.dart`
- `test/features/terminal/keyboard_geometry_test.dart`
- `test/features/terminal/presentation/home_screen_floating_keyboard_test.dart`
- `lib/features/terminal/presentation/widgets/terminal_view_widget.dart`

Additionally read `lib/features/terminal/data/terminal_session.dart` lines 1–1144, including terminal construction/onResize registration, viewport sizing, connect, resize forwarding and disposal; the unrelated remainder was not read.

CodeGraph was unavailable for this checkout: MCP exposed no explore tool and `codegraph status` reported uninitialized. Initializing an index would write outside the review-only surface, so review used direct reads of the named source and the two PTY-path dependencies. No execution-based reproduction is claimed.
