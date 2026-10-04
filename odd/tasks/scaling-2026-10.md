# scaling-2026-10

Work toward helm being usable by people other than its author. Baseline
`11ef564` on `main`, clean, `flutter analyze` clean, 1366/1366 tests.

## The framing that orders this

Merging to `main` published nothing. Three different things block other people,
and they are not the same kind of problem:

- A SIGNING problem on Android, which is one afternoon of work.
- A MONEY problem on iOS, which no amount of code solves.
- A PRODUCT problem: a user who legitimately rebuilds a host hits a dead end
  the app itself told them how to escape, through UI that does not exist.

## Tasks

- [ ] 1. Make release builds signable with a real key
  - Surfaces: `android/app/build.gradle.kts`, `README.md`
  - `build.gradle.kts:45-49` still carries its template TODO and signs release
    with the SHARED PUBLIC debug keystore. Anyone can sign with that key, so a
    third party could ship an update Android accepts as this same app — on a
    device holding the user's SSH private keys.
  - The keystore itself is NOT created here: it needs a password its owner
    chooses and backs up, and losing it means never updating the app again.
    This task makes the build read one, and documents the single command.
  - The debug fallback must survive for anyone who has not made a keystore, or
    `flutter run --release` breaks on a fresh clone — but it must become LOUD.
    Silence is exactly what let this TODO live this long.
  - Commit: pending

- [ ] 2. Let an iOS foreground notification tap reach the app
  - Surfaces: `ios/Runner/AppDelegate.swift`
  - Confirmed absent, not assumed: `rg -c UNUserNotificationCenter` returns 0,
    and `FlutterAppDelegate` does not conform to `UNUserNotificationCenterDelegate`
    either — only `FlutterPluginAppLifeCycleDelegate` does.
  - Verification is inherently manual: it needs a real notification, shown while
    helm is in the foreground, tapped by a human.
  - Commit: pending

- [ ] 3. Give the user a way out of a host key mismatch
  - Surfaces: `lib/features/connection/data/known_hosts_service.dart`,
    `lib/features/settings/presentation/**`, `test/**`
  - `removeHost()` has ZERO call sites in `lib/` — verified again this session.
    Meanwhile `describeError` instructs the user to "forget the pinned key for
    this host and reconnect". The app promises an action it does not offer.
  - Decision already taken and still standing: a trusted-hosts view in
    Settings with an explicit forget action — NOT a button on the mismatch
    warning, because putting "forget and trust" one tap from a MITM alarm
    trains people to dismiss alarms.
  - `KnownHostsService` has no enumeration method; `readAll()` filtered by the
    `helm_known_host_v2_` prefix is the way in.
  - The old objection that a shown fingerprint could not be checked against the
    server died with `44e4622`: it is byte-comparable to `ssh-keygen -lf` now.
  - Commit: pending

## Out of scope, recorded so it is not rediscovered

- Creating the release keystore. Its password is the owner's to choose and to
  back up; an agent inventing one would be handing over a secret nobody wrote
  down.
- iOS distribution. TestFlight and Ad Hoc both require the paid Apple Developer
  Program; a free personal team reaches one device for seven days.
- Restricting the Firebase API key. Console work, and the owner's to do.
- Choosing a licence. A public repository with none is "all rights reserved",
  which contradicts wanting others to use it — but which licence is a decision,
  not a task.
