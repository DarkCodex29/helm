# Tasks: Host Session Contract

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~2,180 authored + ~90 generated (freezed/json) |
| 400-line budget risk | High (aggregate, unsliced) / Low–Medium per work unit after slicing |
| Chained PRs recommended | Yes |
| Suggested split | Slice 1 → 2 → 3a → 3b → 4 → 5 → 6 → 7 (stacked to main) |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

**Slice 3 split decision**: split into **3a** (`MultiplexerAdapter` + `TmuxAdapter`) and **3b** (`ZellijAdapter`). Proposal estimated slice 3 at ~400 lines — the budget ceiling — and design's own risk table pre-agreed this exact mitigation ("zellij splittable out of slice 3"). Zellij parsing is independently flagged High-likelihood-risk (ANSI output, no JSON, undocumented `--short`), so isolating it also isolates that risk.

### Suggested Work Units

| Unit | Goal | PR | Focused test command | Runtime harness | Rollback boundary |
|---|---|---|---|---|---|
| 1 | `HostCommandRunner` port + adapter + fake; adopt in `RemoteFsService` | PR 1 | `flutter test test/core/host/ test/features/shortcuts/data/remote_fs_service_test.dart` | Manual: connect to a real Linux host, open Shortcuts screen, confirm detected-projects list unchanged pre/post adopt | Revert `lib/core/host/{host_command_runner,ssh_host_command_runner}.dart`, `test/helpers/fake_host_command_runner.dart`, `remote_fs_service.dart`/`remote_fs_provider.dart` — no stored data touched |
| 2 | Probe script + parser + `HostReport` + `docs/host-contract/v1.md` | PR 2 | `flutter test test/core/host/probe/ test/core/host/shell_quote_test.dart` | Manual: `ssh <host> 'sh -s' < probe_script_v1.sh`, diff against `docs/host-contract/v1.md` fixtures | Revert `lib/core/host/probe/*`, `shell_quote.dart`, the doc — additive only |
| 3a | `MultiplexerAdapter` + `TmuxAdapter` | PR 3a | `flutter test test/core/host/multiplexer_adapter_test.dart test/core/host/adapters/tmux_adapter_test.dart` | Manual: `tmux new -d -s test` on real host, compare to `TmuxAdapter.listSessions()` | Revert `multiplexer_adapter.dart` + `tmux_adapter.dart`; `TmuxService` still exists until this lands |
| 3b | `ZellijAdapter` | PR 3b | `flutter test test/core/host/adapters/zellij_adapter_test.dart` | Manual: `zellij attach test -c` on real host, compare to `zellij list-sessions --no-formatting --short` | Revert `zellij_adapter.dart` only; 3a unaffected |
| 4 | `HerdrAdapter` + agent-state capability | PR 4 | `flutter test test/core/host/adapters/herdr_adapter_test.dart` | **Required**: task 4.1 against a real herdr host IS this slice's harness | Revert `herdr_adapter.dart` only; additive |
| 5 | Exec-with-PTY attach + `TerminalSession` tests | PR 5 | `flutter test test/features/terminal/data/terminal_session_test.dart test/features/connection/data/ssh_service_test.dart` | Manual: attach to a real running session; verify no race; revoke PTY server-side, verify dedicated message | Revert `terminal_session.dart` + `ssh_service.dart` `describeError`; `_bridgeIO` unchanged by design |
| 6 | Persisted-model migration off `tmuxSession` | PR 6 | `flutter test test/features/connection/domain/ test/features/shortcuts/domain/ test/features/terminal/data/session_snapshot_repository_test.dart` | N/A — pure serialization, no host I/O; proven by round-trip unit test (6.8) | Dual-key writer (6.5) is what makes this revertable; legacy key never removed |
| 7 | Diagnostics: linger/`KillUserProcesses` + Tailscale | PR 7 | `flutter test test/core/host/host_diagnostics_test.dart` | Manual: `loginctl enable-linger` off + `KillUserProcesses=yes` on real systemd host; Tailscale SSH host, confirm post-connect-only, never executed | Revert `host_diagnostics.dart` only; display-only, cosmetic |

---

## Slice 1: Host Command Port — FIRST AUTONOMOUS UNIT (no behavior change, pure seam)

- [x] 1.1 Create `lib/core/host/host_command_runner.dart`: `HostCommandRunner` interface (`run`, `runScript`) + `HostCommandResult` (stdout, stderr, exitCode?, timedOut). Pure types, no RED test.
- [x] 1.2 Create `test/helpers/fake_host_command_runner.dart`: scripted stdout/exit/timeout per command.
- [x] 1.3 [RED] `test/core/host/ssh_host_command_runner_test.dart` — `run()`: success (stdout/stderr/exitCode, `timedOut=false`) + timeout (`timedOut=true`). `flutter test test/core/host/ssh_host_command_runner_test.dart` → FAIL
- [x] 1.4 [GREEN] Create `lib/core/host/ssh_host_command_runner.dart` — implement `run()` via `client.execute` + timeout → PASS
- [x] 1.5 [RED] Same file — `runScript()`: exec string is exactly `/bin/sh -s`, no `pty:`, stdin written then closed, no other command issued (host-command-port spec: Script Delivery scenarios) → FAIL
- [x] 1.6 [GREEN] Implement `runScript()` → PASS
- [x] 1.7 [RED] `test/helpers/fake_host_command_runner_test.dart` — fake satisfies same `run`/`runScript` contract as the adapter (Swappable Transport scenario) → FAIL
- [x] 1.8 [GREEN] Fix fake until contract test passes → PASS
- [x] 1.9 [RED] `test/features/shortcuts/data/remote_fs_service_test.dart` (new — first tests for this service) — characterize `detectProjects`/`getCurrentDirectory` via the fake → FAIL
- [x] 1.10 [GREEN] Modify `lib/features/shortcuts/data/remote_fs_service.dart`: ctor takes `HostCommandRunner`; `_runCommand` calls `runner.run(command)`; command strings unchanged (tmux command stays until 3a's adapter exists) → PASS
- [x] 1.11 Modify `lib/features/shortcuts/data/remote_fs_provider.dart`: wire `SshHostCommandRunner`
- [x] 1.12 Verify: `flutter analyze` (0 issues) && `flutter test` (all green)

Commits: (a) port + adapter + fake (1.1–1.8) — feat(host); (b) adopt in RemoteFsService (1.9–1.12) — refactor(shortcuts)

## Slice 2: Probe Contract

- [x] 2.1 Create `docs/host-contract/v1.md`: grammar, escape table, record kinds, evolution rules (per design's Wire Contract v1)
- [x] 2.2 Create `lib/core/host/probe/probe_script_v1.dart`: POSIX `sh` string emitting env/mux/session/agent/diag/err/end records, PATH repair, bounded traversal
- [x] 2.3 [RED] `test/core/host/probe/host_probe_parser_test.dart` golden fixtures — version match/mismatch (Version Gate scenarios) → FAIL
- [x] 2.4 [GREEN] Implement version gate in `host_probe_parser.dart` → PASS
- [x] 2.5 [RED] Same — missing `end` → truncated; complete stream reflects status (Truncation Is Explicit) → FAIL
- [x] 2.6 [GREEN] Implement → PASS
- [x] 2.7 [RED] Same — unknown kind skipped; extra trailing fields ignored (Forward-Compatible Record Reading) → FAIL
- [x] 2.8 [GREEN] Implement → PASS
- [x] 2.9 [RED] Same — malformed record isolated, siblings unaffected (Record-Level Fault Isolation) → FAIL
- [x] 2.10 [GREEN] Implement → PASS
- [x] 2.11 [RED] Same — `\`/TAB/LF/CR round-trip exactly (Escaping Round-Trip; threat-matrix "Untrusted host output") → FAIL
- [x] 2.12 [GREEN] Implement unescaper → PASS
- [x] 2.13 [RED] Same — found-but-off-PATH vs genuinely-absent (Installed-but-Off-PATH scenarios) → FAIL
- [x] 2.14 [GREEN] Implement PATH classification → PASS
- [x] 2.15 Create `lib/core/host/probe/host_report.dart`: freezed model (env, mux, sessions, agents, diagnostics)
- [x] 2.16 [RED] `test/core/host/shell_quote_test.dart` — `x; rm -rf ~`, `$(id)`, backticks, embedded `'`, leading `-` (threat-matrix "Shell argument composition") → FAIL
- [x] 2.17 [GREEN] Implement `lib/core/host/shell_quote.dart` (`'\''` idiom) → PASS
- [x] 2.18 [RED] Extend `ssh_host_command_runner_test.dart` — probe delivery: exec is the fixed literal `/bin/sh -s`, no pty (threat-matrix "Probe delivery") → FAIL
- [x] 2.19 [GREEN] Wire `runScript(probeScriptV1)` call path → PASS
- [x] 2.20 [RED] Timeout test — bounded traversal, `timedOut=true`, no partial-report accepted (threat-matrix "Unbounded host traversal") → FAIL
- [x] 2.21 [GREEN] Implement timeout handling; consumer treats `timedOut` as no report → PASS
- [x] 2.22 Verify: `flutter analyze` && `flutter test`

Commits: (a) docs + probe script (2.1–2.2); (b) parser scenarios (2.3–2.14); (c) report model + shell_quote + wiring + timeout (2.15–2.21)

## Slice 3a: MultiplexerAdapter + TmuxAdapter

- [x] 3a.1 Create `lib/core/host/multiplexer_adapter.dart`: `MultiplexerId`, `MuxCapability`, `MultiplexerAdapter`, `AgentAwareMultiplexer` (AD-2)
- [x] 3a.2 [RED] `test/core/host/adapters/tmux_adapter_test.dart` — no server running → typed `serverNotRunning`, never `[]` (Explicit State scenario) → FAIL
- [x] 3a.3 [GREEN] Create `lib/core/host/adapters/tmux_adapter.dart`: `listSessions()` → PASS
- [x] 3a.4 [RED] Same — exited session reported, not omitted → FAIL
- [x] 3a.5 [GREEN] Implement → PASS
- [x] 3a.6 [RED] Same — `agents == null` on `TmuxAdapter`; caller gets typed unsupported, never `[]` (Agent-State Capability scenario) → FAIL
- [x] 3a.7 [GREEN] Implement `agents` getter → `null` → PASS
- [x] 3a.8 [RED] Same — `detect()` reports install + version (Uniform Core Operations) → FAIL
- [x] 3a.9 [GREEN] Implement `detect()`/`hasSession()` → PASS
- [x] 3a.10 [RED-NOTE] `test/core/host/adapters/attach_command_test.dart` — quoting via `shellQuote`, absolute path, per-adapter (threat-matrix "Shell argument composition"). NOT a genuine RED: `attachCommand()` was already implemented in 3a.3's cycle (required to satisfy `implements MultiplexerAdapter`); this test file passed 8/8 on first run. Disclosed honestly, same category as slice 1's task 1.7.
- [x] 3a.11 [GREEN] `attachCommand()` uses resolved `abs_path` + `shellQuote` → PASS (implemented in 3a.3, confirmed by 3a.10's test file)
- [ ] 3a.12 **DEFERRED — explicit orchestrator override.** Original task said delete `lib/features/terminal/domain/services/tmux_service.dart` (superseded). This apply batch's instructions explicitly overrode that: "do not delete it in this slice... leave the old class in place and note it for a later cleanup, so this unit stays reviewable." Left untouched, unreferenced by any new slice-3a code. Deletion remains a follow-up once slice 5 (which currently owns the only other tmux-attach code path) also lands.
- [x] 3a.13 Modify `lib/features/shortcuts/data/remote_fs_service.dart`: `getCurrentDirectory` uses `TmuxAdapter` (design's File Changes literally permits "TmuxAdapter/MultiplexerAdapter" — concrete `TmuxAdapter` chosen since `sessionWorkingDirectory` has no defined execution sub-interface in this slice, unlike `agentState`'s `AgentAwareMultiplexer`) instead of hardcoded `tmux display-message`
- [x] 3a.14 Verify: `flutter analyze` (0 issues) && `flutter test` (101/101 passed)

## Slice 3b: ZellijAdapter (split out — see risk rationale above)

- [x] 3b.1 [RED] `test/core/host/adapters/zellij_adapter_test.dart` — ANSI stripped, `--no-formatting` parsed (NOT `--short` — empirically found unreliable for exited-state detection, see below), `EXITED` mapped to exited state (Explicit State scenarios; threat-matrix "Untrusted host output") → FAIL
- [x] 3b.2 [GREEN] Create `lib/core/host/adapters/zellij_adapter.dart` → PASS
- [x] 3b.3 [RED, consolidated into 3b.1's file] `agents == null`; `deadSessionResurrection` capability advertised → covered by the same test file/run as 3b.1 (same precedent as slice 3a's 3a.6/3a.7 consolidation — the class must implement the full `MultiplexerAdapter` interface to compile at all, so all groups in the single test file compile and run together)
- [x] 3b.4 [GREEN, consolidated into 3b.2] Implement → PASS
- [x] 3b.5 Verify: `flutter analyze` (0 issues) && `flutter test` (120/120 passed)

## Slice 4: HerdrAdapter — GATED on real-host verification

- [x] 4.1 **[BLOCKING, do first]** Resolved via schema-verified evidence recorded at Engram topic `sdd/host-session-contract/herdr-contract` (herdr 0.8.0 installed on a real VPS host, `herdr api schema --json` read directly, protocol 19). Resolves design Open Questions 1–3 for the SOCKET-backed `agent list`: (1) JSON envelope `{id, result}`/`{id, error: {code, message}}`; (2) `AgentStatus` (5 values: idle/working/blocked/done/unknown) is the correct domain for `AgentState`, not the 4-value `PaneAgentState`; (3) no-server maps to `error.code == "server_not_running"`, exit 1, empty stdout. **CORRECTION ROUND**: a first apply attempt wrongly parsed the LOCAL `session list --json` command by structural analogy to the socket-backed `agent list` envelope — the two are distinct wire contracts. A second, real invocation of `herdr session list --json` with no server running was captured verbatim (exit 0, bare `{sessions: [...]}`, per-session `running` boolean, no `status` string, no `{id, result}` wrapper) and is now the ground truth for that command. `herdr --version` reporting `herdr 0.8.0` is also independently confirmed, not merely assumed by analogy. Residual gap unchanged: a live successful `agent list` sample with a running server and a real agent process was still not captured (needs a pty + live agent).
- [x] 4.2 [RED] `test/core/host/adapters/herdr_adapter_test.dart` — agent-state capability: `agents != null`, reports states (Agent-State scenario). Initial cycle observed FAIL: compile error (`HerdrAdapter` undefined), consolidated with 4.4/4.6 per the usual whole-interface-must-compile precedent. **Correction round**: a second, targeted RED reproduced the real defect — session fixtures rebuilt from the verbatim capture above crashed the ORIGINAL implementation with `type 'Null' is not a subtype of type 'Map<String, dynamic>'` (the wrong-envelope bug), and a further RED (compile error) was observed after widening `AgentAwareMultiplexer.listAgents()`'s return type to the sealed `MuxAgentsResult`.
- [x] 4.3 [GREEN] `lib/core/host/adapters/herdr_adapter.dart`: `agentState`/`structuredOutput` capabilities (`agentWait` REMOVED per the correction — `waitForAgent` never advertises a capability it does not back with a real wait), `agents => this`. 29/29 pass after the corrected implementation.
- [x] 4.4 [RED, consolidated] `listSessions()` — no server running → typed `MuxSessionsAvailable` with the session's `running: false` mapped to `MuxSessionState.exited` (CORRECTED: herdr's `session list --json` succeeds even with no server, so `MuxServerNotRunning` is not reachable via that path for herdr; a non-zero exit for an unspecified reason still returns `MuxServerNotRunning` as the closest available typed signal — see the apply report's D2).
- [x] 4.5 [GREEN, consolidated] `_parseSessions` reads the bare `{sessions: [...]}` envelope (no `result` wrapper) and derives `MuxSessionState` from the `running` boolean, not a nonexistent `status` string.
- [x] 4.6 [RED, consolidated] `listAgents()` now returns the sealed `MuxAgentsResult` (`MuxAgentsAvailable`/`MuxAgentServerNotRunning`) instead of throwing for the expected "server not running" case, per the 5-value `AgentStatus` domain confirmed in 4.1; an unrecognized `error.code` (not `server_not_running`) still throws, so it is never silently collapsed into the common case. `waitForAgent()` no longer accepts an unused `timeout` parameter.
- [x] 4.7 [GREEN, consolidated] Implemented per 4.6. `waitForAgent()` remains a single-shot check against `listAgents()`'s current result, not a real poll/block — `herdr agent wait` remains explicitly out of scope for this slice, and the adapter no longer advertises `MuxCapability.agentWait` because of it.
- [x] 4.8 Verify: `flutter analyze` (0 issues) && `flutter test` (149/149 passed: 120 baseline + 29 corrected herdr tests).

## Slice 5: Exec-with-PTY Attach — characterization tests land FIRST

- [x] 5.1 [RED] `test/features/terminal/data/terminal_session_test.dart` — characterize CURRENT `connect`/`reconnect`/`dispose`/`onResize`/`_bridgeIO` (zero coverage today); build any needed seam (e.g. `test/helpers/fake_ssh_service.dart`). `flutter test test/features/terminal/data/terminal_session_test.dart` → FAIL (file/fakes did not exist; compile error)
- [x] 5.2 [GREEN] Built the seam (test-only; zero production changes — see apply-progress for the dartssh2-internal-import disclosure) + 28 tests until green against CURRENT `terminal_session.dart`, unmodified → PASS. Production code NOT touched.
- [x] 5.3 [RED] Extend same file — attach command sent as part of the PTY exec request, never written to a separately-opened shell's stdin (Attach Without a Stdin Race) → FAIL against current impl (writes `tmux new-session` to stdin at lines 67–70)
- [x] 5.4 [GREEN] Modify `lib/features/terminal/data/terminal_session.dart`: delete the stdin write; attach via `client.execute(adapter.attachCommand(ref), pty:)` → PASS
- [x] 5.5 [RED] `test/features/connection/data/ssh_service_test.dart` — `SSHChannelRequestError('Failed to start pty')` classified before the generic `SSHError` branch (PTY Denial; AD-4) → FAIL
- [x] 5.6 [GREEN] Modify `lib/features/connection/data/ssh_service.dart` `describeError()`: add PTY-denied branch before `if (error is SSHError)` → PASS
- [x] 5.7 [RED] Same — a non-PTY-denial `SSHError` still gets the generic message (regression guard) → FAIL if broken
- [x] 5.8 [GREEN] Confirm branch order; fix only if 5.7 fails → PASS
- [x] 5.9 [RED] Same — host-key mismatch still aborts with MITM message, never "authentication failed" (existing behavior regression guard) → FAIL if broken
- [x] 5.10 [GREEN] No prod change expected; fix only if 5.9 fails → PASS
- [x] 5.11 Verify: `flutter analyze` && `flutter test`

Commits: (a) characterization tests, no prod change (5.1–5.2); (b) attach fix (5.3–5.4); (c) PTY-denied + regression guards (5.5–5.11)

## Slice 6: Persisted-Model Migration — ONLY IRREVERSIBLE SLICE

- [ ] 6.1 [RED] `test/features/connection/domain/connection_profile_test.dart` — old-only-key JSON loads, value under `sessionRef` (Legacy Field Still Readable) → FAIL
- [ ] 6.2 [GREEN] Modify `lib/features/connection/domain/connection_profile.dart`: add `sessionRef`/`multiplexer`; hand-written `fromJson` wrapper normalizes `tmuxSession → sessionRef` before generated `_$ConnectionProfileFromJson` → PASS
- [ ] 6.3 Run `dart run build_runner build --delete-conflicting-outputs` to regenerate `connection_profile.freezed.dart`/`.g.dart`
- [ ] 6.4 [RED] Same — save emits BOTH legacy and neutral keys (Legacy Key Is Not Deleted) → FAIL
- [ ] 6.5 [GREEN] Hand-written `toJson` wrapper emits both keys → PASS
- [ ] 6.6 [RED] Same — both keys present with different values → neutral wins (Neutral Field Takes Precedence) → FAIL
- [ ] 6.7 [GREEN] Implement precedence in `fromJson` → PASS
- [ ] 6.8 [RED] Round-trip test: a profile written by the CURRENT app version (pre-migration JSON shape) still loads correctly after this migration lands → FAIL if regressed
- [ ] 6.9 [GREEN] Confirm round-trip; fix only if 6.8 fails → PASS
- [ ] 6.10 Repeat 6.1–6.9 for `lib/features/shortcuts/domain/project_shortcut.dart` (`test/features/shortcuts/domain/project_shortcut_test.dart`) — same 3 scenarios + round-trip
- [ ] 6.11 Run `dart run build_runner build --delete-conflicting-outputs` again after `project_shortcut.dart` changes
- [ ] 6.12 [RED] `test/features/terminal/data/session_snapshot_repository_test.dart` — `TabSnapshot` hand-written JSON (no codegen), same 3 scenarios → FAIL
- [ ] 6.13 [GREEN] Implement `TabSnapshot.sessionRef` + compat `fromJson`/`toJson` → PASS
- [ ] 6.14 Modify `lib/core/constants/app_constants.dart`: `defaultTmuxSession` → `defaultSessionRef` (value `'helm'` unchanged)
- [ ] 6.15 Modify `profile_edit_screen.dart`, `shortcut_form_sheet.dart`, `tabs_provider.dart`: field rename + multiplexer selection UI
- [ ] 6.16 **Note (no code)**: legacy `tmuxSession` key is NOT deleted in this change (locked decision) — enforced permanently by 6.4/6.6/6.10's tests staying in the suite
- [ ] 6.17 Verify: `flutter analyze` && `flutter test`

Commits: (a) `connection_profile.dart` migration + codegen (6.1–6.3); (b) dual-write + precedence + round-trip (6.4–6.9); (c) `project_shortcut.dart` migration (6.10–6.11); (d) `TabSnapshot` + constants + UI wiring (6.12–6.16)

## Slice 7: Diagnostics (display-only)

- [ ] 7.1 [RED] `test/core/host/host_diagnostics_test.dart` — Tailscale finding displayed, remediation never executed (Diagnostics Are Display-Only) → FAIL
- [ ] 7.2 [GREEN] Create `lib/core/host/host_diagnostics.dart`: `evaluate()` → `warn(tailscaleOwnsPort22)`, display-only → PASS
- [ ] 7.3 [RED] Same — linger finding displayed, never executed → FAIL
- [ ] 7.4 [GREEN] Implement → PASS
- [ ] 7.5 [RED] Same — systemd absent → `unsupported`, never `disabled` → FAIL
- [ ] 7.6 [GREEN] Implement → PASS
- [ ] 7.7 [RED] Same — persistence-off + killing-off → `ok` (no false alarm); persistence-off + killing-on → warn → FAIL
- [ ] 7.8 [GREEN] Implement truth table → PASS
- [ ] 7.9 [RED] Same — Tailscale interception detected only post-connect → FAIL
- [ ] 7.10 [GREEN] Implement post-connect-only call site → PASS
- [ ] 7.11 Verify: `flutter analyze` && `flutter test`

Commits: (a) Tailscale + linger findings (7.1–7.6); (b) truth table + post-connect gating (7.7–7.11)
</content>
