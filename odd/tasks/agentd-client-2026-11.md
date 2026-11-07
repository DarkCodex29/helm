# agentd-client-2026-11

Phase 2 of the scaling plan: the phone talks to `helm-agentd` (phase 1,
`odd/tasks/agentd-rpc-2026-11.md`) instead of only driving raw terminal
bytes. The herdr PTY lane stays as the fallback throughout.

## Specs

- **S1** — "si hay que hacerlo ya": phase 2 starts now, in the order
  proposed: first a self-contained protocol client in the app (connect,
  hello, automatic reconnect, agent state), tested against the real daemon
  with the fake Pi; then the host install, the UI, splitting
  `TerminalSession` and approvals from the phone, each in its own PR.
- **S2** — Token provisioning, approved as "esta bien tu propuesta": the
  app copies the token ONCE over the existing SFTP connection from
  `~/.helm-agentd/token` and stores it in the iPhone Keychain. Never logged,
  never shown, never sent anywhere but the `hello` frame. New secure-storage
  items use `first_unlock_this_device` (a new item needs no migration).
- **S3** — The client honours the daemon's protocol v1 exactly as
  `packages/helm_protocol` models it, and the phase 1 lessons: reconnect
  with backoff 1s→30s that resets only after a typed server answer;
  4401/4400 are fatal (no retry loop); every command carries a `requestId`
  so a retry is never executed twice; `seq` gaps are detected.
- **S4** — Every change keeps `flutter analyze`, `flutter test` and all
  package jobs green in CI.
- **S5** — Public repository: no tailnet name, host, token or owner path
  in code, fixtures, docs or test output.
- **S6** — Push per device. User, after the parent pointed out that ntfy
  was one hand-set topic per Mac and that the notifier used ntfy only when
  no FCM token existed: "pero no seria que para cada dispositivo? estas
  amarrando al mio", then "claro por dispositivos pues". Every phone gets
  its own delivery channel, registered automatically when it connects, and
  the notifier delivers to every registered device independently (no
  either/or between FCM and ntfy). Verified constraint: the ntfy iOS app
  does NOT support `ntfy://` subscribe links (ntfy issue #450, still open;
  reported "Unsupported Data" in 2026); Android does
  (docs.ntfy.sh/subscribe/phone/#ntfy-links).

## Tasks

| ID | Specs | Task | Route | Commit |
|---|---|---|---|---|
| T1 | S1-S5 | App protocol client `AgentdClient` + token provisioning over SFTP into the Keychain; tested against an in-process `AgentServer` + fake Pi | worker | 8102e58, c993ef6, 75b4b3e, 1b924f4, 06f2b74, 5dc51ba (PR #10, merge b5e0c88) |
| T2 | S1, S4, S5 | Run `helm-agentd` on the Mac as a LaunchAgent bound to the Tailscale IP (installer like the notifier's) | worker | 8df6919, b333ec0, 93ad16a, 44f63de, e2f44c2 (PR #9, merge 960ca7d) |
| T3 | S1, S4 | UI: per-tab agent state (needs you / working / thinking / idle) from `AgentdClient`, PTY lane untouched | worker | |
| T4 | S1, S4 | Answer `ask` (confirm/select) from the phone; first answer wins | pending | |
| T5 | S1, S4 | Split `terminal_session.dart` (transport / probe / agent watch / transfer) | pending | |
| T6 | S4-S6 | Push per device: each phone without FCM registers its own random ntfy topic over SSH (like the FCM token); notifier delivers to every FCM token and every device topic; Settings screen to subscribe this device in ntfy | worker | fad0a2c, a56c216, 524cdab, fa8eea8, 56e2ac7 (PR #8, merge bef361c) |

## Log

- **L1** (2026-11-07) — After phase 1 closed, the parent proposed starting
  phase 2 with the protocol client and asked whether to start now; user:
  "si hay que hacerlo ya".
- **L2** — Parent proposed copying the token once over SFTP from
  `~/.helm-agentd/token` into the Keychain (alternative: QR); user:
  "esta bien tu propuesta".
- **L3** — Notifier migration done by the parent at the user's request
  ("tu hazlo"): `dev.helm.notifier` running, old agent unloaded and backed
  up; first real pushes logged as `fcm x1` per pane.
- **L4** — iPhone validation: helm would not launch (free-team profile
  expired after 7 days; Xcode had no account). Owner signed in to Xcode;
  `--release` rebuilt from `main`, trusted and launched (profile expires
  2026-11-14). Root cause of missing pushes: FCM on iOS was never set up
  (`firebase_options.dart` throws for ios, no `GoogleService-Info.plist`, no
  `aps-environment`), and a free Personal team cannot get Push. Every
  `fcm x1` went to the stale Samsung S22 token from 2026-10-17. Owner chose
  ntfy (free) and removing the S22 token; the parent removed it (backup in
  `~/helm-notifier/backup-20261107-083740/device-tokens.json.s22`).
- **L5** — Owner asked for per-device delivery (S6); T6 added.
- **L6** — Owner disconnected the iPhone: "el iphone lo he desconectado,
  termina todo para luego al final solo validar". Every task is finished
  and merged first; on-device checks happen once, at the end, in a single
  validation pass.
- **L7** — T1 built (S1-S5), uncommitted; Route `worker`. The first worker
  was cancelled mid-task by a session restart; a second worker kept its
  pubspec, domain, token store and test files unchanged and added the rest.
  `AgentdClient` (`data/agentd_client.dart`) with an `AgentdChannel` seam,
  injectable connector, timers, backoff and request ids. Decisions: (1)
  backoff 1,2,4,8,16,30 s resets only on a typed server message (garbage and
  unknown types do not); 4401/4400 and a `ready` with another protocol are
  fatal, no retry. (2) A command is keyed by its uuid `requestId`; an `ack`
  (also `duplicate:true`) resolves it; an `error` is matched to its command
  by the `request <id>` text the daemon puts in the message; answers to an
  `ask` resolve on `ask_resolved` and fail on an `error` naming `ask <id>`;
  commands sent before `ready` wait for it. (3) A sent, unanswered command is
  re-sent once after the next `ready` with the SAME id; a second drop fails
  it with `disconnected`. Fatal close, `close()` and timeouts fail commands
  with typed `AgentdCommandException` (kind, daemon code, requestId, never
  text). (4) `seq` gaps go to a `diagnostics` stream (`SeqGap`), per
  connection; frames without seq are not gaps. (5) The token only goes into
  `hello`; nothing logs it or message text. (6) `agentdClientProvider.family`
  (FutureProvider keyed by profile id) builds the client from the profile
  host plus the daemon's default port and the stored token, resolves null
  when either is missing, closes on dispose, and does NOT connect. (7)
  Integration test launches the fake Pi with the `dart` binary from
  `$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart`, else `dart` on PATH, because
  `Platform.resolvedExecutable` is the Flutter tester under `flutter test`;
  the temp dir is chmod 700 for the token store (Linux CI makes it 0755).
  Verified locally: analyze clean, full `flutter test` 1629 green, package
  tests unchanged and green. Unverified: Linux CI run, real WebSocket
  against a Tailscale address.
- **L8** — T6 merged as PR #8 (`bef361c`), CI 42382924043 green on all four
  jobs. The independent verifier failed the first version on four points,
  all fixed test-first in `fa8eea8` and `56e2ac7`: host file modes (umask
  077, 0700 dir, 0600 file, tightening an existing 0644), topics in
  exception logs (type only), ntfy lost when FCM fails to import
  (`devices.py`), and a failed delivery consuming the event (2 retries,
  dedupe restored). The parent replaced a macOS-only `stat -f` in a test
  with `FileStat` so it runs on Linux CI. Deployed to the Mac from `main`
  (backup `~/helm-notifier/backup-20261107-094650`). Deferred: an Android
  "Open in ntfy" button (needs `url_launcher`), ruff findings, and two
  phones registering at the same instant.
- **L9** — The independent verifier failed T1 on four findings plus three
  test gaps; all fixed test-first (worker, uncommitted). (1) A command
  `error` was matched by regex over free text, so another command's id in
  the detail could reject the wrong command, and the bridge's answer failure
  had no id (the answer hung to its timeout): `ErrorMessage` gained an
  optional `requestId` (encoded only when set, decoded tolerantly), the
  bridge sets it on every command and answer error, and the client
  correlates by it; without it only an exact leading `request <id>:` /
  `ask <id> ` prefix counts, never a scan of the body. (2) The client
  provider did not rebuild on a token write/delete or a profile edit: the
  token store now notifies (`agentdTokenVersionProvider`) and the endpoint
  provider watches `profilesProvider`; the old client is closed on rebuild.
  (3) `write()`/`read()`/`delete()` propagated storage exceptions whose text
  can hold the token: they now throw `AgentdTokenStoreException(kind)` with
  no text and no cause. (4) `WebSocket.connect(...).timeout` left a late
  socket open: the client bounds the connect itself (injected timer) and
  closes a socket that arrives after the timeout or after `close()`.
  Added adversarial tests: stale-channel frame/close after a reconnect,
  `close()` during an in-flight connect, duplicate `ready` not re-sending.
  Unverified: Linux CI run, real WebSocket against a Tailscale address.
- **L10** — T1 merged as PR #10 (`b5e0c88`), CI green. T2 merged as PR #9
  (`960ca7d`). The independent verifier failed the installer on canonical
  IPv4 parsing, control characters reaching sed/XML and argv boundaries in
  the fakes; fixed in `93ad16a` with ThrottleInterval 10. Linux CI then
  exposed two phase-1 tests that only passed by luck: the SIGKILL
  escalation test raced the stubborn agent's SIGTERM handler (`44f63de`,
  the agent now reports ready first) and the notifier install test
  rejected any `__`, which a temp dir named `tmp__…` contained (`e2f44c2`).
- **L11** — T3 built by a worker. Parent review found that putting the
  agentd badge in place of the herdr builder unmounted herdr's listener,
  which disarms the herdr agent poll: the PTY lane was not untouched.
  Pinned by a new arming test (RED: 0 host polls under an agentd badge);
  fixed by keeping the `agentsNotifier` listener mounted in every branch
  and switching only what is drawn.
