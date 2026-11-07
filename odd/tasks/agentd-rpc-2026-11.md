# agentd-rpc-2026-11

helm grows from "remote terminal" into "agent control panel": a process on
the Mac (`helm-agentd`) drives Pi in RPC mode and talks a structured protocol
to the phone. Phases 0-1 of the plan approved on 2026-11-06.

## Specs

- **S1** — "tratemos de ver esos repos a fondo y poder crecer como tal el
  app, para que escale tambien". The design follows the studied repos
  (gentle-dot, dot-whatsapp) where they are proven, and avoids their
  documented gaps (per-token broadcast with no coalescing, ignored `seq`,
  no push on `needs_you`).
- **S2** — "si go aprobado" (approving the phased plan): Phase 0 = CI plus a
  fake agent; Phase 1 = `helm-agentd` on the Mac (Pi RPC supervisor plus
  WebSocket over Tailscale with `seq`, `requestId`, a single derived agent
  state, delta coalescing; the herdr PTY lane stays as a fallback) and the
  push notifier moved into the repo. Phases 2-3 (app RPC client, split
  `TerminalSession`, approvals from the phone, channel layer) are later
  features, not this document.
- **S3** — Language decision, user's answer verbatim: "Dart, en el mismo
  repo (recomendado)". `helm-agentd` is Dart in this repository and
  shares the protocol models with the app.
- **S4** — Pi RPC framing rule, from Pi's own `docs/rpc.md`: "split records
  only on LF. Strip an optional preceding carriage return" and "Do not use
  a generic line reader that treats Unicode line or paragraph separators
  as record boundaries." The decoder must keep U+2028/U+2029 inside a
  record.
- **S5** — Every change keeps `flutter analyze` and `flutter test` green
  and runs in CI (`.github/workflows/ci.yml`); new Dart packages get their
  own `dart analyze` and `dart test` step in that workflow.
- **S6** — Repository is public: no tailnet name, host name, token or
  owner path may appear in code, fixtures, docs or test output.

## Tasks

| ID | Specs | Task | Route | Commit |
|---|---|---|---|---|
| T1 | S2, S5 | CI: analyze + tests on push and PR | inline | cc90de5 |
| T2 | S2-S6 | `packages/helm_protocol` (LF-only JSONL codec, Pi RPC records) + fake Pi RPC agent with scripted scenarios + CI step | worker | d6e92de, f5316c5, 638aa22 |
| T3 | S1-S5 | `helm-agentd` supervisor: spawn `pi --mode rpc`, restart backoff, `interrupted`, orderly shutdown; tested against the fake agent | worker | c33c2da, f708f9c |
| T4 | S1-S5 | `helm-agentd` WebSocket server: `hello{token,protocol}`, per-connection `seq`, `requestId` idempotency, `deriveState()`, delta coalescing | worker | e569564, f4a9458, 3d70318, a9aab95, fb34c04, 6871989, af3d6a0 (PR #4) |
| T4b | S1 | History and resync: on a `seq` gap the phone asks for `get_messages` (Pi) so it can rebuild the transcript | pending | |
| T4c | S1, S5 | Per-client backpressure: bound each socket's outgoing queue, drop or disconnect a slow client without stalling the others | pending | |
| T4d | S1, S6 | Cap concurrent unauthenticated connections and pre-auth buffering in helm-agentd | pending | |
| T4e | S6 | Replace owner-specific path fixtures in the app tests with neutral ones | pending | |
| T5 | S2, S5, S6 | Move the push notifier into the repo as a versioned component | worker | |

## Log

- **L1** (2026-11-06) — User: "tratemos de ver esos repos a fondo y poder
  crecer como tal el app, para que escale tambien" (repos:
  github.com/ipproyectosysoluciones/dot-whatsapp,
  gentlemanprogramming.com/gentle-hub/?type=extension,
  github.com/Gentleman-Programming/gentle-dot).
- **L2** — Study done by three read-only explorers; findings saved in
  Engram `helm/architecture/scaling-plan`.
- **L3** — User: "si go aprobado" (plan approved, phase 0 first).
- **L4** — User chose "Dart, en el mismo repo (recomendado)" for
  `helm-agentd`.
- **L5** — T1 merged as PR #1 (`cc90de5`); first CI run green
  (run 42331063751, 3 min).
- **L6** — T2 built (S2-S6). `packages/helm_protocol`: pure Dart, own
  `pubspec.yaml` (`sdk: ^3.11.3`, dev deps `test`, `lints`) and
  `analysis_options.yaml`, committed `pubspec.lock`. Layout: `lib/src/jsonl_codec.dart`
  (`JsonlDecoder` splits on bytes at LF, so multi-byte chars cut between
  chunks and U+2028/U+2029 are safe; bad lines become `JsonlMalformed`,
  non-object JSON and invalid UTF-8 included; `encodeJsonl`),
  `lib/src/pi_records.dart` (commands, records, `UnknownRecord`; `parsePiRecord`
  never throws, a known type with wrong field shapes degrades to
  `UnknownRecord`), `tool/fake_pi.dart` (dart:* only, no shared code with the
  codec), tests under `test/`. Decisions: a final line with no LF is still
  delivered at EOF; the fake emits tool events BEFORE the reply
  (`agent_start, tool_execution_start, tool_execution_end, message_*`); a
  cancelled `ask:*` finishes with "Stopped: ..." and `agent_settled
  aborted:false` (only `abort` yields `aborted:true`); `abort` answers only after
  `agent_settled`, like Pi; queued `steer`/`followUp` messages are recorded and
  announced via `queue_update` but never executed. CI: new `helm_protocol` job
  (`dart pub get`, `dart analyze`, `dart test`) reusing the pinned actions. The
  root `flutter analyze` also walks `packages/**` and fails with unresolved
  imports unless the nested package is resolved, so the `flutter` job runs
  `dart pub get` in `packages/helm_protocol` before analyzing (a workspace
  would avoid that but needs root `pubspec.yaml` changes, out of this task's
  surface).
- **L7** — T2 committed as three slices, each green on its own: codec
  (`d6e92de`, 16 tests), Pi records (`f5316c5`, 31), fake Pi + integration
  (`638aa22`, 52). The parent added `--fatal-infos` to the package's
  `dart analyze` in CI, because one info-level lint had passed unnoticed.
  Slice boundary: T2 ships as its own PR; T3 starts a new branch from
  `main` after it merges.
- **L8** — T3 built (S1-S5, respecting S6). `packages/helm_agentd`: pure Dart,
  path dependency on `helm_protocol`, same SDK/lints as it. `lib/src/pi_supervisor.dart`
  is `PiSupervisor` with injectable process starter, timer factory, clock,
  args/binary and grace periods; `bin/helm_agentd.dart` only starts it and logs
  state to stderr (the WebSocket server is T4). Typed errors: `PiNotRunning`,
  `PiProcessExited`, `PiCommandTimeout`. Events are `PiRecordEvent` or
  `InterruptedEvent`; stderr and malformed stdout lines are diagnostics.
  Policies decided: (1) spawn failure (starter throws, e.g. ENOENT) is retried
  with the same backoff up to `maxSpawnAttempts` (3) consecutive attempts, then
  `failed` is terminal and `failure` holds the error; the CLI exits 69.
  (2) A process that starts and keeps crashing is retried forever at the capped
  30 s rate (reference behaviour); backoff resets after 30 s of uptime.
  (3) After a respawn, `get_state` then `switch_session{sessionPath}` run BEFORE
  `running` is published, so callers cannot hit the wrong session; failures there
  are diagnostics, not fatal. The session file is learned from `get_state`
  (`data.sessionFile`), so the supervisor also sends one `get_state` after the
  first start (`probeOnStart`, default on). (4) `PiCommand` is sealed in
  `helm_protocol`, so `switch_session` is written as a raw map inside the
  supervisor instead of a model. (5) A Pi exit with code 0 that was not
  requested is still restarted. (6) `extension_ui_response` has no reply, so it
  goes through `sendUiResponse`, not `send`. Note: the fake `hang` scenario
  exits on stdin close, so SIGTERM/SIGKILL escalation against a real process is
  tested with `test/support/stubborn_agent.dart` (ignores EOF and SIGTERM).
  CI: new `helm_agentd` job (`dart pub get`, `dart analyze --fatal-infos`,
  `dart test`), and the `flutter` job resolves the nested package too.
- **L9** — T3 committed as two slices, each green alone: supervisor +
  unit tests (`c33c2da`, 29 tests) and integration tests + CLI
  (`f708f9c`, 34). Parent review read the run loop and checked the
  `switch_session` shape against Pi's `rpc-commands.md`
  (`{"type":"switch_session","sessionPath":...}`); it is not yet
  exercised against the real Pi. Slice boundary: T3 is its own PR.
- **L10** — T4 built (S1-S5, respecting S6), in four slices. (1) Phone
  protocol models in `helm_protocol` (`phone_protocol.dart`, `e569564`).
  (2) `lib/src/token_store.dart` + `lib/src/server.dart`: dart:io only
  (`HttpServer` + `WebSocketTransformer`); binds `127.0.0.1` by default
  (`--host` takes the Tailscale IP, never defaulted to `0.0.0.0`); token =
  32 bytes `Random.secure()` base64url in `~/.helm-agentd/token` (0600 file in
  a 0700 dir, tightened before the secret is written), refused at start if
  group/world-readable, re-read and re-checked on every authentication,
  constant-time compare, never logged or put in an error (the CLI prints the
  FILE path). First frame must be `hello` within 5 s else close 4401; wrong
  token 4401, wrong protocol 4400 (token is checked first, so a bad token
  reveals nothing about the protocol); any `Origin` outside the allowlist
  (default empty) gets HTTP 403 before the upgrade; non-upgrade HTTP gets 426;
  binary frames close 1003, frames over 1 MiB (bytes, not characters) close
  1009. A socket that has not authenticated is never handed to the bridge and
  cannot receive a frame (`send` is a no-op until authenticated). `seq` is
  per connection from 1. Known limit: dart:io delivers whole messages, so the
  1 MiB cap bounds what is processed, not what a hostile peer can make the
  process buffer; reachability (loopback/tailnet) is the first defence.
  (3) `lib/src/bridge.dart`, `delta_coalescer.dart`, `request_ids.dart`:
  `deriveState()` is the one place that decides the state (supervisor
  lifecycle first, then open asks > idle > working > thinking) and
  `agent_state` is broadcast only on change; deltas are coalesced per message
  and flushed every 50 ms or before any other event (activity, `message_done`,
  `interrupted`, `ask`), so text is never dropped or reordered; only assistant
  text deltas are forwarded (thinking and user messages are not). Dialogs
  become `ask`; the first `ui_response` wins and is forwarded once, later ones
  get `error{ask_resolved}`, an answer for an unknown id gets
  `error{unknown_ask}`; non-dialog `extension_ui_request`s (notify,
  setStatus...) are deliberately not forwarded. Pending asks are resolved when
  the supervisor leaves `running` and on `interrupted`. `send` is a `prompt`
  (with `streamingBehavior: steer` when busy); `requestId` idempotency is an LRU
  of 256, a duplicate (even while the first is in flight) is
  `ack{duplicate:true}` and not forwarded, `ack{duplicate:false}` follows Pi's
  acceptance, a failure releases the id so the client can retry and reports
  `error{code,message}` with the requestId in the message (`not_running`,
  `rejected`, `timeout`, `interrupted`). A new client gets `ready` with the
  current state plus the pending asks and the last non-empty queue.
  (4) integration tests (real server + real `PiSupervisor` + the fake Pi + real
  WebSocket clients) and the CLI (`--host`, `--port` default 7480, `--pi`,
  `--session-dir`, `--token-file`, `--help`; exit codes 0/64/69/78; SIGINT and
  SIGTERM close the server, then `supervisor.shutdown()`). `--pi` takes a
  binary only; tests wrap the fake in a launcher script. Port 7480 was chosen
  as a fixed non-privileged default. Hang-proofing: every socket wait in the
  tests is bounded (`bound` = 8 s, 15 s for Pi round trips), every test file
  has a `@Timeout`, servers/clients/supervisors are closed in `tearDown`, and
  every runner invocation was wrapped in `perl -e 'alarm N; exec @ARGV'`.
  Pending (not in T4): T4b history/resync via `get_messages` on a `seq` gap;
  T4c per-client backpressure; a dialog's own `timeout` is not tracked, so an
  expired ask stays listed until answered or the next restart.
- **L11** — T4 committed in four slices: protocol models (`e569564`,
  61 tests), auth + server (`f4a9458`, 65), bridge (`3d70318`, 106), CLI +
  integration (`a9aab95`, 131). The first worker hung on a test that never
  returned and was relaunched with every dart command under a `perl alarm`
  and every await bounded. Parent mutants: token check, Origin check, flush
  before other events, second ask answer, duplicate forwarding and failure
  release were all caught; pre-auth send survives but is unreachable
  (attach only after auth), confirmed equivalent by the verifier.
- **L12** — Independent verifier (gentle-ai-verify): network auth PASS;
  FAIL on (a) token file race in a directory others can enter, plus
  followed symlinks, and (b) the requestId LRU evicting in-flight ids.
  Fixed test-first: `fix(agentd)` token store refuses symlinks and loose
  directories (3 RED on old code), and the cache pins in-flight ids
  (RED: methods missing). Package tests 136 green. Lesson: run mutants in a
  separate worktree, never in the checkout a verifier is testing (one
  verifier run was invalidated that way).
- **L13** — Deferred, recorded as T4d: cap concurrent unauthenticated
  connections and the pre-auth buffer (dart:io buffers whole messages;
  reachability is loopback or the Tailscale IP only, so medium). Also
  noted: pre-existing owner-path fixtures in the app tests (e.g.
  `test/features/files/domain/remote_path_test.dart:15`) violate S6
  repo-wide; recorded as T4e.
- **L14** — PR #4 merged (`74a8b65`). First CI run failed 10 helm_agentd
  tests on Linux only: Dart temp directories are 0755 there (0700 on
  macOS), and the hardened token store correctly refused them. Fixed in
  the tests (`af3d6a0`, chmod 700 on their temp dirs), reproduced locally
  with TMPDIR at 0755 first; rerun 42354088485 green on all three jobs.
- **L15** — T5 built (S2, S5, S6), uncommitted. The out-of-repo Python
  LaunchAgent is now `host/notifier/`: `notifier.py`, `fcm.py`,
  `provision_fcm.py`, plus new `config.py` (all paths from `HELM_*` env vars)
  and `hlog.py` (rotating, redacting log), `helm-notifier.plist.template`,
  `install.sh` (POSIX sh, `--dry-run`, prints `launchctl bootstrap`, runs it
  only with `--load`, never touches credentials/tokens/the old agent), a
  `.gitignore` (credentials, tokens, topic, logs, pem, json except fixtures),
  stdlib `unittest` tests with fake fixtures, and a `notifier` CI job
  (system python3, no setup-python). Still system Python plus openssl only.
  Sanitizations (kinds, no values): the FCM project id hardcoded in
  provisioning became `--project` / `HELM_FCM_PROJECT_ID`; the owner home
  paths for install dir, credentials, tokens and log became env-derived with a
  `~/helm-notifier` default; the owner-specific LaunchAgent label and absolute
  paths became `__LABEL__`/`__INSTALL_DIR__`/`__PYTHON__` placeholders with a
  generic default label; the ntfy topic became optional config (file or env)
  instead of a crash at import, and is never logged; the provisioning and
  selftest output no longer prints the project id or the service-account
  e-mail; prose that named the owner and a specific host in comments was
  rewritten generically; fixtures use fake ids and tokens only. Behavior
  changes vs the live script: rotating 1 MB x 3 log, umask 077; the message
  body, token suffixes and topic are no longer logged (titles clipped to 40);
  `describe()` returned 3 values on lookup failure while the caller unpacks 4
  (alert dropped) and now returns 4; missing `topic` no longer kills startup;
  malformed token entries are dropped; non-https or non-JSON FCM responses
  raise RuntimeError. Migrating the live install is a manual step for the
  owner and was not done.
