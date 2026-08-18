```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:c554a7adb528e10654b5f953012a3489bfe5e1d510e2ed939bf06bfd5811175c
verdict: fail
blockers: 1
critical_findings: 1
requirements: 20/23
scenarios: 32/35
test_command: flutter test
test_exit_code: 0
test_output_hash: sha256:4688bb200d49611d74058235e3ac0bd498b5405ec700ab333096c77d1d38a355
build_command: flutter analyze
build_exit_code: 0
build_output_hash: sha256:8e1fe722ec57b9abdf4616387f989d0dafcde8a544f7272a04f61ffb5795568a
```

## Verification Report

**Change**: host-session-contract
**Version**: N/A (first version, `openspec/specs/` was empty before this change)
**Mode**: Strict TDD

### Completeness

| Metric | Value |
|--------|-------|
| Tasks total | 100 |
| Tasks complete | 100 |
| Tasks incomplete | 0 |

All six slices (1, 2, 3a, 3b, 4, 5, 6, 7) are committed on `main` through `c0f2af2`. `git status` is clean; working tree has no uncommitted changes. `HANDOFF.md` (last rewritten at `e274fa9`, before slice 6) is stale on this point — it still lists slice 6 as `0/17 — only irreversible slice`. `tasks.md` (5 commits later, `ea6f7e1`…`c0f2af2`) is the authoritative source and marks every slice-6 task `[x]`. Treat `HANDOFF.md` §1–2 as outdated; everything else in it (herdr findings, dartssh2 findings, known debt) still checks out against current source.

### Build & Tests Execution

**Build**: ✅ Passed

```text
$ flutter analyze
Analyzing helm...
No issues found! (ran in 1.7s)
```

**Tests**: ✅ 234 passed / ❌ 0 failed / ⚠️ 0 skipped

```text
$ flutter test
...
00:01 +228: /Users/gian/Desktop/Proyectos Personales/helm/test/widget_test.dart: placeholder
00:01 +229: .../fake_host_command_runner_test.dart: run records every call in invocation order
00:01 +230: .../fake_host_command_runner_test.dart: run throws when a command has no scripted result...
00:01 +231: .../fake_host_command_runner_test.dart: runScript returns the exact result registered for that script
00:01 +232: .../fake_host_command_runner_test.dart: runScript throws when a script has no scripted result...
00:01 +233: .../fake_host_command_runner_test.dart: satisfies the HostCommandRunner contract...
00:01 +234: All tests passed!
```

Exit code `0` for both commands. 234/234, matching the claimed count exactly. No `Process.run`/shell-execution based tests exist anywhere in the suite — everything runs in-process against fakes; this is relevant to a finding below.

**Coverage**: not run (no `--coverage` flag used; not requested and not part of this project's cached testing capabilities per `sdd/helm/testing-capabilities`).

### Requirement-by-Requirement Trace Table

Legend: ✅ COMPLIANT (covering test passed at runtime) · ⚠️ PARTIAL (test covers only part of the scenario) · ❌ UNTESTED (no covering test, or no implementation at all).

#### Domain: host-command-port (3 requirements / 5 scenarios)

| Requirement | Scenario | Implementing symbol | Proving test | Verdict |
|---|---|---|---|---|
| Single-Command Execution | Command completes successfully | `SshHostCommandRunner.run` (ssh_host_command_runner.dart:49) | `ssh_host_command_runner_test.dart` "returns stdout, stderr, exitCode and timedOut=false on success" | ✅ |
| Single-Command Execution | Command exceeds configured timeout | `SshHostCommandRunner._drain`'s `channel.done.timeout()` (line 76) | same file, "reports timedOut=true when the command exceeds the timeout" | ✅ |
| Script Delivery With Zero Host Footprint | Script delivered over stdin, no PTY | `SshHostCommandRunner.runScript` (line 55) — calls `client.execute(command)` with no `pty:` argument | same file, "opens exactly /bin/sh -s, writes the script to stdin, closes it, and issues no other command" | ✅ |
| Script Delivery With Zero Host Footprint | No file left behind on the host | same method — contains no file-write primitive of any kind | **none** — unprovable by a Flutter unit test; holds only by code inspection (no live-host verification) | ❌ UNTESTED |
| Swappable Transport Implementations | Scripted stand-in satisfies the same contract | `FakeHostCommandRunner` (test/helpers/fake_host_command_runner.dart) | `fake_host_command_runner_test.dart` "satisfies the HostCommandRunner contract..." | ✅ |

#### Domain: host-probe-contract (6 requirements / 10 scenarios)

| Requirement | Scenario | Implementing symbol | Proving test | Verdict |
|---|---|---|---|---|
| Version Gate | Matching version accepted | `HostProbeParser.parse` (host_probe_parser.dart:27-31) | `host_probe_parser_test.dart` "matching version marker proceeds..." | ✅ |
| Version Gate | Mismatched major version refused | same | same file, "mismatched major version is refused, no record parsed" | ✅ |
| Truncation Is Explicit | Complete stream reports own status | `parse`'s `end` case (line 88-94) | "a complete stream reflects the end record status" | ✅ |
| Truncation Is Explicit | Stream missing terminating record is truncated | `parse`'s `status: terminal ?? HostReportStatus.truncated` (line 105) | "a stream missing the end record is truncated, not empty" | ✅ |
| Forward-Compatible Record Reading | Unknown record kind skipped | `parse`'s `default: break` (line 95-98) | "an unknown kind is skipped, siblings still parse" | ✅ |
| Forward-Compatible Record Reading | Extra trailing fields ignored | field indexing (`rest[0]`..`rest[4]`) ignores extras | "extra trailing fields on a known kind are ignored" | ✅ |
| Record-Level Fault Isolation | One malformed record doesn't block siblings | per-case `if (rest.length >= N)` guards | "one malformed record does not block its siblings" | ✅ |
| Escaping Round-Trip | Each reserved byte class round-trips exactly | `HostProbeParser._decode` (line 120-147) decode half; `probe_script_v1.dart`'s `_esc()` shell function (encode half) | `host_probe_parser_test.dart` "each reserved byte class round-trips exactly" — **decode side only, against a hand-built synthetic wire string** | ⚠️ PARTIAL — see Finding W1 |
| Installed-but-Off-PATH... | Binary found only via repaired PATH | `parse`'s `mux` case (`onInheritedPath: rest[4]=='1'`) | "binary found only via repaired PATH" | ✅ |
| Installed-but-Off-PATH... | Binary genuinely absent | same | "binary genuinely absent has no resolved path" | ✅ |

#### Domain: multiplexer-abstraction (3 requirements / 6 scenarios)

| Requirement | Scenario | Implementing symbol | Proving test | Verdict |
|---|---|---|---|---|
| Explicit State on List Failure | No server running | `TmuxAdapter.listSessions` / `ZellijAdapter.listSessions` / `HerdrAdapter.listSessions` → `MuxServerNotRunning()` on non-zero exit | `tmux_adapter_test.dart`, `zellij_adapter_test.dart`, `herdr_adapter_test.dart` — each has an explicit "server not running" test | ✅ (all 3 adapters, exceeds the spec's "any" minimum) |
| Explicit State on List Failure | Exited session reported, not omitted | `TmuxAdapter._parseSessionLine` (`pane_dead` → `exited`); `ZellijAdapter._parseSessionLine` (`(EXITED` marker) | "reports an exited session instead of omitting it" (both adapter test files) | ✅ |
| Agent-State Capability Advertised | Requested from adapter without capability | `AgentSupport.resolve` (multiplexer_adapter.dart:196-200) | `multiplexer_adapter_test.dart` "returns typed unsupported carrying the multiplexer id when agents is null" | ✅ |
| Agent-State Capability Advertised | Requested from adapter with capability | same + `HerdrAdapter.agents => this` | same file, "returns available wrapping the non-null agents"; `herdr_adapter_test.dart` "a caller resolving agent support gets the live agent surface" | ✅ |
| Uniform Core Operations | Detect reports install/version | `detect()` on all 3 adapters | "reports installed and the version"/"reports not installed" in all 3 adapter test files | ✅ |
| Uniform Core Operations | Existence test answers true/false for one name | `hasSession()` on all 3 adapters | `hasSession` groups in all 3 adapter test files | ✅ — see Suggestion S1 on how zellij/herdr implement it |

#### Domain: session-attach (4 requirements / 5 scenarios)

| Requirement | Scenario | Implementing symbol | Proving test | Verdict |
|---|---|---|---|---|
| Attach Without a Stdin Race | Attach command reaches multiplexer, no shell in between | `TerminalSession.connect` (terminal_session.dart:130-172) — closes `result.session` before calling `_attachOpener` with PTY | `terminal_session_test.dart` "attaches via an exec request with the pseudo-terminal allocated up front..." — asserts `shellSession.writes` empty, `shellSession.closeCallCount == 1`, attach command sent via `_attachOpener` not stdin | ✅ — strong evidence |
| PTY Denial Classified Before Generic SSH Error | PTY denial produces dedicated message | `SSHService.describeError` (ssh_service.dart:204-215), branch before generic `SSHError` | `ssh_service_test.dart` "pty denial" group (5 tests) | ✅ |
| PTY Denial Classified Before Generic SSH Error | Different SSH failure still generic | same, branch order | "is distinguished from other channel request failures by exact message, not just type" | ✅ |
| Host Key Mismatch Keeps Precedence | Host key mismatch aborts with MITM warning | `describeError`'s `HostKeyMismatchException` branch, checked FIRST (line 191-202) | `ssh_service_test.dart` "host key mismatch" group (5 tests) | ✅ |
| Attach Exit Status Reflects the Multiplexer Session | Detach vs. session-killed produce different outcomes | **none found** | **none found** | ❌ **NOT SATISFIED — CRITICAL, see Finding C1** |

#### Domain: session-reference-storage (3 requirements / 3 scenarios)

| Requirement | Scenario | Implementing symbol | Proving test | Verdict |
|---|---|---|---|---|
| Legacy Field Still Readable | Old-format record loads under neutral field | `ConnectionProfile._readSessionRef`, `ProjectShortcut._readSessionRef`, `TabSnapshot._readSessionRef` | `connection_profile_test.dart`, `project_shortcut_test.dart`, `session_snapshot_repository_test.dart` — each has a genuine "Legacy Field Still Readable" group, and each also has round-trip fixtures **captured verbatim from the pre-migration class's own `toJson()`**, not hand-written | ✅ (all 3 models) |
| Legacy Key Is Not Deleted | Save after this change emits both keys | Plain generated `toJson()` (ConnectionProfile/ProjectShortcut) and hand-written `toJson()` (TabSnapshot) — both fields are real fields, so both keys are always emitted | Corresponding "Legacy Key Is Not Deleted" group in each of the 3 test files | ✅ (all 3 models) |
| Neutral Field Takes Precedence | Both keys present, different values → neutral wins | Same three `_readSessionRef` functions — `neutral != null ? neutral : legacy`, unconditional | "Neutral Field Takes Precedence" group in each of the 3 test files, plus a key-order-independence variant | ✅ (all 3 models) |

Mirroring helper (`lib/core/host/session_reference.dart`) confirmed used by all three claimed write paths: `profile_edit_screen.dart:280` (`resolveOptionalSessionReference`), `shortcut_form_sheet.dart:85` (`resolveRequiredSessionReference`), `tabs_provider.dart:139` (`mirrorSessionReference`) — see Finding W4 for a fourth `ConnectionProfile` construction site not covered by this list.

#### Domain: host-diagnostics (4 requirements / 6 scenarios)

| Requirement | Scenario | Implementing symbol | Proving test | Verdict |
|---|---|---|---|---|
| Diagnostics Are Display-Only | Tailscale remediation shown, never executed | `HostDiagnostics.evaluateTailscaleInterception` (host_diagnostics.dart:134-194) — never calls `_runner.run` with a mutating command | `host_diagnostics_test.dart` "never executes the remediation command..." — proven by the fake's fail-loudly-on-unregistered-call contract, not just an absence check | ✅ |
| Diagnostics Are Display-Only | Linger remediation shown, never executed | `_combineLogoutPersistence` (line 316-373) returns `remediationCopy` as text only | equivalent linger test in same file | ✅ |
| Systemd Absence → Unsupported, Never Disabled | Non-systemd host reports unsupported | `evaluateLogoutPersistence`'s `loginctl` presence gate (line 253-262) | corresponding test in same file | ✅ |
| No False Alarm When Already Protected | Both settings off → ok | `_combineLogoutPersistence`'s `_TriState.no`/`_TriState.no` branch | corresponding test | ✅ |
| No False Alarm When Already Protected | Persistence off + killing on → warn | same, `_TriState.no`/`_TriState.yes` branch | corresponding test | ✅ |
| Tailscale SSH Detected Post-Connect | Interception triggers post-connect warning | `evaluateTailscaleInterception` is a separate method, never called from `evaluateLogoutPersistence` or any connect-time code path | corresponding test | ✅ (structurally correct and tested) — see Finding W2 on end-to-end reachability |

### Counts

| | Count |
|---|---|
| Requirements traced with a passing test (fully or partially) | 22/23 |
| Requirements fully compliant (every scenario ✅) | 20/23 |
| Requirements with zero test coverage and zero implementation | 1/23 (session-attach: Attach Exit Status Reflects the Multiplexer Session) |
| Scenarios ✅ COMPLIANT | 32/35 |
| Scenarios ⚠️ PARTIAL | 1/35 |
| Scenarios ❌ UNTESTED / NOT SATISFIED | 2/35 |

### Correctness (Static Evidence)

| Requirement area | Status | Notes |
|---|---|---|
| `HostCommandResult`/`HostCommandRunner` shape | ✅ Implemented | Matches spec exactly: stdout/stderr/exitCode?/timedOut. |
| Sealed `MuxSessionsResult`/`MuxAgentsResult` | ✅ Implemented | No path returns an empty list on failure across tmux/zellij/herdr — confirmed by direct source read of all three `listSessions`/`listAgents`. |
| `describeError` branch ordering | ✅ Implemented | `HostKeyMismatchException` → `SSHAuthError` → PTY-denial (message-pinned) → generic `SSHError` → `toString()`. Order matches spec precedence exactly. |
| Session-reference mirroring | ✅ Implemented | `session_reference.dart` is the single mirroring point; all three claimed write paths use it; 14 direct unit tests of the pure functions. |
| `TmuxAdapter`/`ZellijAdapter`/`HerdrAdapter` shell-quoting | ✅ Implemented | All three route session names through `shellQuote`; `attach_command_test.dart` + per-adapter tests cover `; `, `$()`, backticks, embedded `'`, leading `-`. |

### Coherence (Design)

| Decision | Followed? | Notes |
|---|---|---|
| AD-1 (probe via stdin, no PTY) | ✅ Yes | `runScript` confirmed. |
| AD-2 (capability advertised for reporting, `agents` nullable accessor for execution) | ✅ Yes | `AgentSupport.resolve` forces the null check at the type level. |
| AD-3 (shellQuote at every shell boundary) | ✅ Yes | Confirmed across all 3 adapters. |
| design.md's `evaluate(HostReport)` sketch for diagnostics | ❌ Deviated, disclosed | `HostDiagnostics` runs its own commands via `HostCommandRunner` directly instead of consuming `HostReport.diagnostics` (which the v1 probe never populates). Documented in the class doc comment as the established "spec.md wins over design.md" precedent. Not a spec violation — WARNING-level deviation, consistent with 3 prior precedents in this same change. |
| Locked decision 7 (migration adds neutral field, never deletes legacy key) | ✅ Yes | Verified directly for all 3 models via round-trip tests. |

### Issues Found

**CRITICAL**

- **C1 — `session-attach` spec's "Attach Exit Status Reflects the Multiplexer Session" requirement has zero implementation and zero test coverage.** No code anywhere in `lib/features/terminal/data/terminal_session.dart` or `lib/features/connection/data/ssh_service.dart` inspects the attached exec session's exit code/status to distinguish a user-initiated detach from the multiplexer session being killed on the host. `TerminalSession._handleDisconnect()` (terminal_session.dart:283-287) unconditionally writes `'\r\n[Helm] Disconnected\r\n'` regardless of cause — `client.done`'s `.then()`/`.catchError()` (lines 178-186) both route to the same `_handleDisconnect()` with no distinguishing signal read from `_session` before it is torn down. Grep across `lib/` and `test/` for `exitStatus`, `onExit`, `detach`, `killed` (case-sensitive and case-insensitive) returns zero matches related to this requirement. This is not a missing-test gap on otherwise-real code — the behavioral capability itself does not exist. This is a normative MUST requirement (RFC 2119) that ships unmet.

**WARNING**

- **W1 — `host-probe-contract`'s Escaping Round-Trip requirement is proven only on the decode half.** `probe_script_v1.dart`'s POSIX-shell `_esc()` function (the encoder, lines 17-24) is never executed by any test — the test suite has zero `Process.run`/shell-execution calls anywhere. `HostProbeParser._decode` is tested against a hand-crafted synthetic wire string (`host_probe_parser_test.dart:94-97`) that assumes the shell script emits exactly that escape format. This is the same "the test encodes the same assumption as the implementation" risk class the HANDOFF explicitly names for slice 4 (146 green tests against a self-consistent fake). Recommend a live-host or `Process.run('sh', ...)` smoke test that pipes real reserved bytes through the actual shell script before trusting this requirement in production.
- **W2 — `HostDiagnostics` (both `evaluateTailscaleInterception` and `evaluateLogoutPersistence`) and the agent-state surface (`AgentSupport.resolve`, `HerdrAdapter.agents`) are correct and unit-tested but have zero production call sites outside their own files.** Grep of `lib/` for `HostDiagnostics(` / `AgentSupport.resolve` / `.agents` finds no caller in any screen, provider, or connection flow. The `host-diagnostics` spec's Purpose statement ("explain otherwise-silent failure modes... to the user") is unmet end-to-end today even though every individual requirement is satisfied at the unit level — a real user never sees a Tailscale or linger warning because nothing in the app calls these methods yet. This is consistent with the change being an infrastructure/contract layer (per HANDOFF §4, decision 4) rather than a UI feature, and is very likely intentional scope — but it should be confirmed as intentional before archiving, since the spec's own scenarios describe "surfaced to the user" as their trigger condition.
- **W3 — Same unwired pattern applies to the multiplexer-abstraction agent-state surface.** `AgentSupport.resolve` and `MultiplexerAdapter.agents` are exercised only by their own test file (`multiplexer_adapter_test.dart`) and `HerdrAdapter`'s own tests; no feature screen or provider calls them. Same caveat as W2: likely intentional (contract layer only), should be confirmed.
- **W4 — A fourth `ConnectionProfile(...)` construction site was not audited by task 6.15's "every write path" claim.** `lib/features/setup/presentation/first_time_setup_screen.dart:92` (`_saveAndContinue`) constructs a persisted `ConnectionProfile` without going through `resolveOptionalSessionReference`/`mirrorSessionReference` — `tmuxSession`, `sessionRef`, and `multiplexer` are all left at their defaults (null). This does **not** violate the "Legacy Key Is Not Deleted" requirement literally — the generated `toJson()` always emits both keys regardless of value (confirmed by reading `connection_profile.g.dart`) — and the file is untouched by this migration (last touched in the initial commit `256ff46`), so this is pre-existing, unregressed behavior, not a new defect. It does mean the claim "all three write paths mirror" is incomplete: there are (at least) four `ConnectionProfile`-persisting construction sites in `lib/`, and only three were in scope for 6.15's audit. `profile_edit_screen.dart:341`'s second `ConnectionProfile(...)` (inside `_testConnection`) is NOT a write path — it is an ephemeral `id: 'test'` object used only to test connectivity and never persisted, so it is correctly out of scope.

**SUGGESTION**

- **S1 — `ZellijAdapter.hasSession`/`HerdrAdapter.hasSession` implement existence checking by calling the full `listSessions()` and filtering**, unlike `TmuxAdapter.hasSession`, which uses a dedicated `tmux has-session -t` query. Both satisfy the spec's literal GIVEN/WHEN/THEN (answer true/false for the specific name), so this is not a compliance finding — but it means every herdr/zellij `hasSession` call pays the cost of a full session enumeration, JSON parse (herdr) or ANSI-strip (zellij), which the requirement's title ("does not require listing every session") arguably intends to avoid.
- **S2 — The "No file left behind on the host" scenario (host-command-port) is unprovable by the current Flutter unit test suite** and holds only by code inspection (no file-write primitive exists in `runScript`). Worth a manual/live-host verification pass before shipping, in the same spirit as the already-disclosed unverified herdr `agent list` sample.

### Verdict

**FAIL**

One normative session-attach requirement ("Attach Exit Status Reflects the Multiplexer Session") has no implementation and no test — this is a genuine unmet MUST, not a documentation or coverage gap on working code. Everything else traced cleanly: `flutter analyze` is clean, all 234 tests pass, and the highest-scrutiny area (`session-reference-storage`'s three-model migration) holds up under close inspection with real pre-migration round-trip fixtures, not fabricated ones. This change is **not ready to archive** until C1 is either implemented+tested or the requirement is explicitly descoped by the repository owner (it is not currently in the "known and accepted" list). W1 (escaping round-trip encode-side) and W2/W3 (diagnostics/agent-state unwired from the UI) should also be explicitly confirmed as intentional scope before archiving, even though they do not block on their own.
