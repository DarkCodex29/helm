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
| T3 | S1, S4 | UI: per-tab agent state (needs you / working / thinking / idle) from `AgentdClient`, PTY lane untouched | worker | 95ca413, 2b41ff8, 937ce9e, 9772a73, 2bf99aa (PR #11, merge c9f8228) |
| T4 | S1, S4 | Answer `ask` (confirm/select) from the phone; first answer wins | worker | 4cb1f93, adc4230, 50157f3, eb52fb2 (PR #12, merge dca8941) |
| T5 | S1, S4 | Split `terminal_session.dart` (transport / probe / agent watch / transfer): this task covers four behavior-preserving slices (types/timings/factories, `ObservableValueNotifier`, `OutputSettle`, `HostQueries`) | worker | |
| T5b | S1, S4 | Extract agent watch from `terminal_session.dart` (the agent-tracking loop and its 5 interlocking in-flight guards) | worker |  44f1543, c371618, 37c7e07 (pushed to main) |
| T5c | S1, S4 | Extract the host probe from `terminal_session.dart` | worker |  9419a27, bec4790 (pushed to main) |
| T5d | S4 | Pin the host probe's internal order (publication, adoption, advisories, notice) with an event-trace test; add explicit per-await bounds to its characterization tests | worker | uncommitted |
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
- **L12** — T4 built by a worker (S1, S4; S2, S3, S5 respected), uncommitted.
  `agentdAsksProvider` (`data/agentd_asks.dart`) folds the client's messages
  into the open asks: `ask` adds/replaces by id, `ask_resolved` removes,
  `ready` clears (the daemon replays open asks right after it). It never
  connects; it keeps `agentdClientStatesProvider` alive, so one client and
  one socket per profile. Decisions: (1) `input`/`editor` are answered on
  the Mac only: the banner says so and offers Cancel, no text field. (2) No
  client-side timer: the daemon owns the ask's lifetime and sends
  `ask_resolved`. (3) The `AgentAskBanner` sits in the `SessionRecoveryBanner`
  slot of `HomeScreen`, for the ACTIVE tab's profile only, hidden without
  asks or without a connected daemon. (4) First answer wins is the daemon's:
  a late answer's `ask_resolved` rejection shows nothing (the row goes with
  the `ask_resolved` frame); any other failure re-enables the buttons with
  "Could not send, try again". A double tap sends one frame.
- **L13** — The independent verifier failed T4 (S1, S4); fixed test-first by a
  worker, uncommitted. (1) HIGH, late subscribers lost open asks: every tab
  keeps its profile connected but only the ACTIVE profile mounts the banner,
  and `agentdAsksProvider` started from an empty map over a broadcast stream
  with no replay, so an ask for an inactive tab (or one open across a tab
  switch) never showed while the badge said "needs you". The shared
  `AgentdClient` now owns the snapshot: `openAsks` (unmodifiable, arrival
  order) and `openAsksChanges` (snapshot first, then updates). `ask` adds,
  `ask_resolved` removes, `ready` clears (the daemon replays), a fatal
  failure and `close()` clear; a plain drop keeps them until the next
  `ready`. The provider emits the snapshot and follows the changes; it still
  never connects and keeps the states provider alive. (2) A client rebuilt
  by a token change resets the list to the new client's snapshot (tested).
  (3) The banner pruned neither `_sending` nor `_failed` for asks that went
  away, and a late failure re-added a mark for a gone ask: both are pruned on
  every build and a failure only marks an ask still open. (4) Disposing the
  banner with an answer in flight raises nothing (tested). Unverified: real
  device, Linux CI.
- **L14** — T5 built by a worker (S1, S4), uncommitted, behavior-preserving:
  existing tests are the spec and no test file changed. Four slices, each
  compiling and passing alone: (1) pure types, constants and factories to
  `terminal_session_types.dart`, `terminal_session_timings.dart` and
  `session_factories.dart`, re-exported from `terminal_session.dart` with
  `show` lists so import paths and the public API are unchanged (the
  formerly private helpers, which became library-visible names, are NOT
  exported); (2) `ObservableValueNotifier` to
  `observable_value_notifier.dart`; (3) `OutputSettle`
  (`output_settle.dart`), owned by the session with one-line delegations,
  creating no Timer and reading no clock at construction, so timers still
  bind to the zone of `connect()`; `armTracking()` still runs before
  `statusNotifier.value = connected`, and `resolve()` keeps its place in
  `_handleDisconnect` and `dispose`; (4) `HostQueries` (`host_queries.dart`)
  for focus agent, workspace tree, focus tab and session vitality, reading
  adapter, status, host report, agents and disposed state through getters;
  the four in-flight guards moved with it, and `sessionVitalityNotifier`
  stays owned and disposed by `TerminalSession`. Follow-ups recorded as
  T5b (agent watch) and T5c (probe), both high risk and not done here.
  Do NOT split `connect`, `reconnect`, `dispose`, `_handleDisconnect`,
  `_publishAdvisories` or the viewport sizing: their ordering is the
  contract. Comments moved verbatim; the channel-budget documentation
  moved with the constants and the guards that it describes.
- **L15** — User decision: "si primero haz", answering the parent's "¿Validamos
  ya, o prefieres que antes haga T5b y T5c?". T5b built by a worker (S1, S4),
  uncommitted, behavior-preserving. Slice A: 26 characterization tests
  (`agent_watch_characterization_test.dart`) pin exact snapshot values (const
  identity for NotProbed/Unreachable), list/wait counts across observe,
  unobserve and re-observe, 12 toggles holding one wait, the failed-wait
  retry cadence, in-flight refresh, disconnect reset, reconnect only while
  observed, and no adapter call after dispose; all green on the old code.
  Slice B: the loop moved to `agent_watch.dart` (`AgentWatch`: notifier,
  epoch, active, wait-in-flight, observed, poll-in-flight, retry timer and
  the loop methods), comments verbatim. It reads adapter, connected, disposed
  and the vitality judge through getters/callbacks, creates no Timer at
  construction, and `TerminalSession` keeps `agentsNotifier`, `tracksAgents`
  and `refreshAgents` as delegations; `_agentWatch.enable()` replaces the two
  lines in `connect`, and `_agentWatch.stop()` keeps both call positions
  (`_handleDisconnect`, `dispose`). String literals diffed against
  origin/main across all of `data/`: only imports and a second
  `'TerminalSession'` logger tag differ. Mutating the join guard, the
  poll-in-flight guard and the epoch check each fails the new tests.
- **L16** — T5b pushed to main as 37c7e07. Owner's delivery preference,
  verbatim: "pero pushea, no crees PRs, al final solo nosotros trabajamos".
  From now on, push to main and do not open PRs. T5c built by a worker (S1,
  S4), uncommitted, behavior-preserving. Slice A: 18 characterization tests
  (`host_probe_characterization_test.dart`) pin the exact report and
  selection for herdr, tmux, zellij, no-choice default, substituted,
  none-found, thrown and timed-out probes, the exact terminal notice text,
  the advisories, which adapter drives focus (observed through the exact
  command the host runner receives), no probe without a session ref or with
  an explicit adapter, and the reset on dispose and reconnect; all green on
  the old code. Slice B: the probe moved to `host_probe.dart` (`HostProbe`:
  report, selection, `resolve()`, `reset()`), comments verbatim. It takes the
  prober, a runner getter and callbacks to write the notice, publish the
  advisories and adopt the adapter. `TerminalSession` keeps `_muxAdapter` as
  the one source of truth (assigned by the adopt callback at the same point
  as before), the `hostReport` / `multiplexerSelection` getters, the call
  position in `connect` and both reset points. It creates no Timer. String
  literals diffed against origin/main across `data/`: only imports and a
  second `'TerminalSession'` logger tag differ.
- **L17** — Independent verifier on T5c: no production regression. The
  probe keeps its steps and order (probe, report, selection, adoption,
  log, advisories, notice), comments and literals match, the 18
  characterization tests pass on the pre-move code. Two claims were
  corrected rather than code: `_hostProbe` is NOT first touched in
  `connect` (the `hostReport`/`multiplexerSelection` getters and a
  dispose before connect also initialise it; its constructor is inert, so
  behaviour is the same), and the tests pin outcomes, not the order
  between publication, adoption, advisories and the notice, which rests on
  reading the code, as it did before the move. Follow-up T5d: an ordering
  trace test for the probe and explicit per-await bounds in its tests.
- **L18** (2026-11-07) — Physical validation on the iPhone 16 (release build
  from `6ca8ce6`), driven with DeviceLab `maestro-runner` over Wi-Fi, as
  the owner asked: "pero usa maestro para controlar". Results:
  (1) `helm-agentd` installed with `install.sh --load`, bound to the
  Tailscale IP, Pi in RPC mode running. (2) The app connected to the Mac
  profile on its own, copied the daemon token and registered its own ntfy
  topic (host file: 0 FCM tokens, 1 topic, mode 0600). (3) ntfy subscribed
  by Maestro; the topic was checked by shape only, never printed. Notifier
  log after that: `pushed[fcm x0, ntfy x1]`, one delivery per alert. (4)
  Answer from the phone: the probe sent `/gentle:animations` to the daemon,
  the real Pi raised `ctx.ui.select` ("Gentle animations", 4 options), the
  tab went to `needs_you`, Maestro tapped `status` (read-only, writes no
  config) in the banner, and the daemon answered `ask_resolved` for that
  ask and went back to `idle`. T4 is accepted on hardware.
  Lessons: gentle-pi's `ask_user_question`/`ask_user_choice` refuse to run
  in RPC unless `GENTLE_SHELL_INTERACTIVE_HOST=1`, so asking the agent to
  "use the ask tool" produces no dialog; slash commands that call
  `ctx.ui.select` do. The banner only mounts on an open tab for the
  profile, so an app relaunched with no tabs shows nothing. A paste in ntfy
  once picked up unrelated text from the shared clipboard: copy and paste
  must happen back to back, and checks must never print field contents.
  Open, and the main finding: the daemon's Pi is ONE process per Mac,
  separate from the Pi sessions the owner runs in herdr tabs inside
  Ghostty, so the badge and asks in helm describe that daemon agent, not
  the agent visible in the terminal. Owner: herdr, Ghostty, Pi and Gentle
  Shell already have their own ways to ask and approve; helm should connect
  to those instead of running a parallel agent. That design is the next
  decision. ntfy is an external app the owner does not want to depend on;
  native iOS push needs a paid developer account.
- **L19** — T5d built by a worker (S4), uncommitted, tests only (`git diff
  --stat -- lib` empty). New `host_probe_order_test.dart` records one event
  trace through public surfaces (host runner, `advisoriesNotifier`, terminal
  write, attach opener, `statusNotifier`) and pins this order on main: probe
  script, advisories published, terminal notice, attach, `connected`;
  `hostReport` and `multiplexerSelection` are already set at the first
  event, and the herdr adapter is already adopted then (sampled once by
  lifting the status for one synchronous `focusAgent`, which reaches the
  runner only with the adopted adapter). Limit: report, selection and
  adoption run synchronously with no public hook between them, so their
  order among themselves is not distinguishable from outside and is not
  claimed. Mutations, each restored byte for byte: (A) `_publishAdvisories`
  moved after the notice, so the trace shows notice before advisories and
  the test fails; (B) `_adoptAdapter` moved after `_publishAdvisories`, so
  the first snapshot shows `adopted=false` and the test fails.
  `host_probe_characterization_test.dart` now bounds every awaited step
  (connect, reconnect, dispose, focus, drop, event-queue pump) with a 10 s
  `.timeout`; no expected value changed. Checks: `dart format
  --set-exit-if-changed lib test` clean; `flutter analyze` no issues;
  `flutter test` full: 1660 passed, 0 failed.
- **L20** (2026-11-07) — Closing the day. The owner decided "solo
  necesitamos una terminal": helm-agentd was removed (see
  `odd/tasks/remove-agentd-2026-11.md`, `b617b11`). Garbled characters on
  the phone were fixed in `2087b30`: each SSH chunk was decoded alone, so a
  multibyte character split across chunks became U+FFFD and shifted the
  columns; stdout and stderr now go through a streaming UTF-8 decoder
  (RED reproduced `���─ ��`). T5d landed as `922c754`; CI 42428119981
  green. Notifications set aside (S6 deferred): "notificaciones dejaré de
  lado, voy a desinstlaar el app esa, porque lo haremos nativo para no
  tener dependencias". The parent stopped `dev.helm.notifier`, emptied the
  host's `ntfy_topics` and moved the legacy global topic file away, with a
  backup of the plist and both files in
  `~/helm-notifier/backup-20261107-191013-ntfy`. The app still registers
  its ntfy topic on connect and shows the ntfy tile in Settings; the owner
  chose to remove that together with the native push work ("lo dejamos para
  cuando hagamos los de notificaciones"). Native iOS push needs APNs, which
  needs a paid Apple Developer account.
