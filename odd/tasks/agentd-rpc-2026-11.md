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
| T4 | S1-S5 | `helm-agentd` WebSocket server: `hello{token,protocol}`, per-connection `seq`, `requestId` idempotency, `deriveState()`, delta coalescing | pending | |
| T5 | S2, S5, S6 | Move the push notifier into the repo as a versioned component | pending | |

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
