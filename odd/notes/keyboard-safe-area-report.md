# Floating keyboard safe-area defect

## Diagnosis

Confirmed. `lib/features/terminal/presentation/widgets/terminal_keyboard.dart:72-88` previously subtracted only `MediaQuery.padding.horizontal`; `travelY` used the full `widget.viewport.height`. `lib/features/terminal/presentation/home_screen.dart:349-351` explicitly says `NO reserved shelf` and records removal of the former `bottomNavigationBar` shelf. The bottom inset therefore remains inside the panel viewport.

## Verification

### New test RED (before the fix)

Command:

```text
flutter test test/features/terminal/presentation/widgets/terminal_keyboard_safe_area_test.dart
```

Output:

```text
00:00 +0: loading <repo>/test/features/terminal/presentation/widgets/terminal_keyboard_safe_area_test.dart
00:00 +0: keeps the floating panel above the bottom safe area
══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞════════════════════════════════════════════════════
Expected: a value less than or equal to <766.0>
  Actual: <788.0>
  Which: is not a value less than or equal to <766.0>
00:00 +0 -1: keeps the floating panel above the bottom safe area [E]
00:00 +0 -1: Some tests failed.
```

### New test GREEN (after the fix)

```text
00:00 +0: loading <repo>/test/features/terminal/presentation/widgets/terminal_keyboard_safe_area_test.dart
00:00 +0: keeps the floating panel above the bottom safe area
00:00 +1: All tests passed!
```

The test asserts the rendered panel rectangle and repeats the assertion after dragging the panel fully downward.

### Existing widget tests

Command:

```text
flutter test test/features/terminal/presentation/widgets/terminal_keyboard_repeat_test.dart
```

Output:

```text
00:00 +0: loading <repo>/test/features/terminal/presentation/widgets/terminal_keyboard_repeat_test.dart
00:00 +0: holding backspace repeats it
00:00 +1: a single tap on backspace deletes exactly once
00:00 +2: holding a letter does NOT repeat it
00:00 +3: holding Enter does NOT repeat it
00:00 +4: holding TAB does NOT repeat it
00:00 +5: holding an arrow repeats it
00:00 +6: All tests passed!
```

### Flutter analyze

Command:

```text
flutter analyze
```

Output:

```text
Analyzing helm...

  error • Target of URI doesn't exist: 'package:helm/features/voice/data/record_plugin_voice_recorder.dart'. Try creating the file referenced by the URI, or try using a URI that does exist • test/features/voice/record_plugin_voice_recorder_test.dart:13:8 • uri_does_not_exist
  error • The function 'RecordPluginVoiceRecorder' isn't defined • test/features/voice/record_plugin_voice_recorder_test.dart:133:24 • undefined_function
  error • The function 'RecordPluginVoiceRecorder' isn't defined • test/features/voice/record_plugin_voice_recorder_test.dart:146:26 • undefined_function
  error • The function 'RecordPluginVoiceRecorder' isn't defined • test/features/voice/record_plugin_voice_recorder_test.dart:161:24 • undefined_function
  error • The function 'RecordPluginVoiceRecorder' isn't defined • test/features/voice/record_plugin_voice_recorder_test.dart:172:24 • undefined_function
  error • The function 'RecordPluginVoiceRecorder' isn't defined • test/features/voice/record_plugin_voice_recorder_test.dart:187:24 • undefined_function
  error • The function 'RecordPluginVoiceRecorder' isn't defined • test/features/voice/record_plugin_voice_recorder_test.dart:203:24 • undefined_function

7 issues found. (ran in 3.9s)
```

The analyzer failure is in the concurrently changing `lib/features/voice/**` area and was not modified.

## Change

The panel now derives `safeHeight` by subtracting `MediaQuery.padding.bottom` and uses it for height limits, vertical travel, and drag clamping. The stale shelf comment was replaced with a measured explanation that the shelf was removed and the viewport includes the system inset.

No commit was created, as requested.
