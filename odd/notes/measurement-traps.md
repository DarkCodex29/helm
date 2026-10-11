# Measurement traps paid for in this repository

Tools that return something that looks like a result when they measured
nothing. Each entry below cost real time, and three of them nearly produced a
false report.

The shared shape: **a command that fails still prints numbers, and those
numbers read as evidence.** Separate "the command ran" from "the command
measured".

## `flutter test` truncates its failing-test list

The `Failing tests:` block prints **4 entries and then `... and 24 more`**. Any
per-file attribution built on it sees 4 of 28.

This one reached two commit messages. `098fc09` and `7a32075` both claim the
failures were "confined to `file_browser_sheet_test.dart`, confirmed by
attribution". **That attribution was the truncated block.** The conclusion
happened to hold — and the arithmetic in those commits was real evidence, since
breaking something would have pushed the failure count above 28 — but the cited
proof was never measured.

Measured later: main's 28 were 25 in `file_browser_sheet_test.dart` plus 3 in
`profile_edit_font_size_test.dart`. The claim of one file was wrong.

**Do instead:** run the specific test file on both revisions and compare
counts. Two commands, no parsing:

```sh
git stash push -m x && flutter test <file>; git stash pop && flutter test <file>
```

`--reporter json` is not the shortcut it looks like: for a widget test,
`testStart.url` points at `package:flutter_test/src/widget_tester.dart`, not at
the test file. Prefer `root_url`. A parser that gets this wrong reports
`widget_tester.dart` as the failing file.

## zsh rejects an unquoted `--include=*.dart`

```sh
grep -rn "pattern" --include=*.dart lib test   # zsh: no matches found
```

The command never runs, and `|| echo "(none)"` then prints a clean "(none)".
This hid three real defects for one turn: a Maestro flow asserting a deleted
semantic id, a flow whose comment promised an assertion it never made, and ten
comments citing a deleted file.

**Do instead:** quote it — `--include="*.dart"`.

## `adb shell am task remove` does not exist, and exits 0

`am task remove <id>` and `cmd activity remove-task <id>` both print
`Unknown command` and **return 0**, so a `||` fallback never fires. The
snapshot taken afterwards looks like a measurement of a swipe that never
happened.

**Do instead:** drive the real gesture, and read the card's bounds rather than
guessing coordinates:

```sh
adb shell input keyevent KEYCODE_APP_SWITCH
adb shell uiautomator dump /sdcard/rec.xml
# find bounds for content-desc="helm Helm", then swipe its centre upward
adb shell input swipe 540 1009 540 150 400
```

There can be **more than one card for the same app**. A blind swipe dismisses
whichever card is under the finger — on this device it dismissed unrelated
apps twice.

**The tell that a swipe failed:** the pid is unchanged and the foreground
service is still alive. `helm_session_dirty=1` without
`helm_session_dismissed=1` means the app backgrounded via Home, not a swipe.

## Installing a release APK silently breaks `run-as`

A release build is not debuggable, so `run-as` answers
`package not debuggable` and every SharedPreferences read returns empty. Three
greps came back `0` and were read as "the flag is absent" and "the flag was not
written".

**Do instead:** `flutter build apk --debug`. `applicationId` carries no suffix
(`android/app/build.gradle.kts:49`), so the debug build installs over the
release and keeps the same data.

`adb install -r` never uninstalls: with an incompatible signature it fails and
changes nothing. The destructive step is `adb uninstall`, which wipes the
profiles and the SSH keys.

## `pgrep -f 'herdr server'` is a false negative

Reports nothing while the socket answers and the agents work. Ask the socket,
not the process table: `herdr session list`, `herdr agent list`.

## `git stash pop` can fail while returning 0

The only signal is the last line — `The stash entry is kept in case you need it
again` — instead of `Dropped refs/stash@{0}`. An untracked file that the stash
also carries is enough to cause it. The work stays in the stash and the tree
looks like the base revision.

**Do instead:** check `git status` after every pop. To compare a stash's
contents, `git show 'stash@{0}:<path>'` — `git stash show -p <stash> -- <path>`
returns EMPTY rather than a difference, which reads as "identical".

## `flutter analyze` writes to the repository

It rewrites `analysis_options.yaml` (an `analyzer.exclude` block) on every
invocation, and runs may also touch `pubspec.lock`, `ios/Podfile.lock` and
`android/gradle.properties`. Revert them before committing or they ride along
in the diff.

## The pi-lens hook reformats Kotlin on every turn that touches it

`SessionHoldService.kt` gets reflowed — trailing commas, wrapped assignments,
chained-call indentation — turning 12 functional lines into a 167-line diff.
Fighting it is futile; it is automatic.

**Do instead:** split it. Copy the formatted file aside, `git checkout HEAD --`
the file, remove the functional part, commit the formatting alone, restore the
copy, commit the behaviour. The functional diff then reviews as 51 insertions
with no deletions.

## `adb shell monkey -p <pkg> -c LAUNCHER 1` hangs

Burned a 600s timeout. Use `adb shell am start -n <pkg>/.MainActivity`.

## The USB cable drops mid-measurement

Twice in one session, both times leaving empty output that reads as a result.
Check `adb devices` before interpreting any zero.

## helm opens behind a biometric gate

No agent can pass it, so any scenario needing an authenticated session needs
the owner at the device. `maestro/agent_focus_honesty.yaml` documented this
before it was rediscovered the hard way.

## `adb shell` BLOCKS FOREVER when no device is attached

Not an error, and not an empty result — it prints `- waiting for device -` and
waits. Burned a full 1800s background timeout on a share validation that had
already built the APK and was one command away from its answer.

**Do instead:** gate every adb script on a check that exits rather than waits.

```sh
adb devices | grep -qw device || { echo "no device"; exit 1; }
```

The cable has now dropped FOUR times in one session, so treat this as
mandatory in anything long-running, not as a nicety.

## `herdr pane read --source visible --format text` returns EMPTY, exit 0

A sweep of every pane reported "marker not found" while the instrument itself
was producing nothing. That sweep would have reported the same thing had the
feature been working perfectly, and it came within one step of being written
up as a failure of the code under test.

**Valid form:** `herdr pane read <pane_id> --lines N` — no `--source`, no
`--format`.

**The general rule, now paid for three times in one day** (truncated
`Failing tests:`, unquoted `--include=*.dart`, and this): a tool returning
empty is NOT saying "there is nothing". Before believing a negative result,
run the instrument against a case known to be positive. If the control comes
back empty too, the measurement never happened.

## A test asserting only the END state cannot see a timing defect

The cold-start share had five tests. Four asserted the outcome — "the text was
typed" — and all four passed while the feature wrote into a remote that was
still attaching and dropped it. Only the fifth, asserting the INTERMEDIATE
state ("connected, but output has not settled, so nothing may have been typed
YET"), could tell the difference.

The device found this defect first, with the suite green. When behaviour
depends on WHEN something happens, assert the moment it must not have happened
yet, or the suite will happily agree with a broken implementation.
