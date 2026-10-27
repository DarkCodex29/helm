# Text-scaling verification report

## Scope and method

Both reported findings were tested at a 320dp-wide viewport with:

```dart
MediaQueryData(
  size: Size(320, 600),
  textScaler: TextScaler.linear(2.0),
)
```

The widget tests capture Flutter's `RenderFlex` overflow error text rather than inferring a problem from source inspection.

## Finding A — terminal keyboard fixed-height controls

**Result: not reproduced.** No production change was made to `terminal_keyboard.dart`.

Test: `Finding A: terminal keyboard controls do not report a RenderFlex overflow`

Initial verification output:

```text
00:00 +0: Finding A: terminal keyboard controls do not report a RenderFlex overflow
00:00 +1: Finding B: recovery banner remains within a narrow scaled viewport
```

The Finding A test passed in the initial run. Its captured overflow list was empty, so there was no RED state and no fix was justified. The existing 48dp keyboard targets and the protected geometry constants were left unchanged.

## Finding B — session recovery banner

**Result: reproduced and fixed.**

Initial RED output before the fix:

```text
00:00 +0: Finding A: terminal keyboard controls do not report a RenderFlex overflow
00:00 +1: Finding B: recovery banner remains within a narrow scaled viewport
Expected: empty
  Actual: ['A RenderFlex overflowed by 179 pixels on the right.']
00:00 +1 -1: Finding B: recovery banner remains within a narrow scaled viewport [E]
00:00 +1 -1: Some tests failed.
```

Root cause: the banner placed its message and both 48dp-minimum action buttons in one non-wrapping `Row`. At 320dp and a 2.0 text scaler, the row exceeded its horizontal constraint.

Fix: `SessionRecoveryBanner` now measures its available width with `LayoutBuilder`; below 420dp it places the actions on a second line, and the actions themselves use `Wrap` so scaled labels can wrap without shrinking the 48dp touch targets. The wide layout remains horizontal.

GREEN output after the fix:

```text
00:00 +0: Finding A: terminal keyboard controls do not report a RenderFlex overflow
00:00 +1: Finding B: recovery banner remains within a narrow scaled viewport
00:00 +2: All tests passed!
```

## Regression checks

Existing recovery-banner tests:

```text
00:00 +0: SessionRecoveryBanner speaks the same language as the rest of the app
00:00 +1: SessionRecoveryBanner gives both buttons at least 48dp of height, because one of them discards work the user has not seen yet
00:00 +2: SessionRecoveryBanner routes each button to its own callback
00:00 +3: All tests passed!
```

Existing keyboard tests (`terminal_keyboard_repeat_test.dart` and `terminal_keyboard_safe_area_test.dart`):

```text
00:00 +0: holding backspace repeats it
00:00 +1: keeps the floating panel above the bottom safe area
00:00 +2: a single tap on backspace deletes exactly once
00:00 +3: holding a letter does NOT repeat it
00:00 +4: holding Enter does NOT repeat it
00:00 +5: holding TAB does NOT repeat it
00:00 +6: holding an arrow repeats it
00:00 +7: All tests passed!
```

`flutter analyze`:

```text
Analyzing helm...
No issues found! (ran in 4.4s)
```

## Limitations

Verification covered the requested 320dp width and `TextScaler.linear(2.0)` setting. No device/emulator run was performed. No commit was created. Pre-existing changes in unrelated paths, including the concurrent `lib/features/voice/**` work, were not modified.
