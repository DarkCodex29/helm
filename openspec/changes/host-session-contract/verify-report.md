```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:a585ad8d7e62426ddaf54b523faa6e80906f081e8210ba2228468f02e8a951f5
verdict: fail
blockers: 0
critical_findings: 0
requirements: 21/23
scenarios: 35/37
test_command: flutter test
test_exit_code: 0
test_output_hash: sha256:9add5e69b388b8bc19c2f86ce553bb85dbca62fd4de54e4b8bf135833b9c4df9
build_command: flutter analyze
build_exit_code: 0
build_output_hash: sha256:69517e383509d614b3689f03bcf67005189ce61f62a08added0e7fa211823463
```

## Verification Report

**Change**: host-session-contract
**Version**: N/A (first version, `openspec/specs/` was empty before this change)
**Mode**: Strict TDD
**Re-run context**: this is a re-verification after the prior run's single CRITICAL finding (C1) was implemented and, separately, the requirement it targeted was amended to match a real, measured constraint on tmux/zellij exit-status reporting. HEAD at this run: `92903aed898672d4a6ea734a6a156af830ea6dd3`.

### Completeness

| Metric | Value |
|--------|-------|
| Tasks total | 100 |
| Tasks complete | 100 |
| Tasks incomplete | 0 |

`tasks.md` still marks all 100 tasks `[x]` (confirmed via direct read: zero `[ ]` occurrences). Working tree clean at `92903ae`, 13 commits ahead of `origin/main`.

### Build & Tests Execution

**Build**: ✅ Passed

```text
$ flutter analyze
Analyzing helm...
No issues found! (ran in 1.8s)
```

**Tests**: ✅ 239 passed / ❌ 0 failed / ⚠️ 0 skipped

```text
$ flutter test
...
00:01 +231: .../project_shortcut_test.dart: Round-trip: shortcut written by the pre-migration app version loading then re-saving a pre-migration shortcut keeps every original field value and adds the neutral key alongside the untouched legacy key
00:01 +232: .../widget_test.dart: placeholder
00:01 +233: .../fake_host_command_runner_test.dart: run returns the exact result registered for that command
00:01 +234: .../fake_host_command_runner_test.dart: run records every call in invocation order
00:01 +235: .../fake_host_command_runner_test.dart: run throws when a command has no scripted result...
00:01 +236: .../fake_host_command_runner_test.dart: runScript returns the exact result registered for that script
00:01 +237: .../fake_host_command_runner_test.dart: runScript throws when a script has no scripted result...
00:01 +238: .../fake_host_command_runner_test.dart: satisfies the HostCommandRunner contract...
00:01 +239: All tests passed!
```

Exit code `0` for both commands, run twice in this session with identical results and hashed each time. 239/239, up from the prior run's 234/234 — the delta is exactly the 5 new tests in `terminal_session_test.dart`'s `TerminalSession — attach exit status (C1: ...)` group.

**Coverage**: not run (unchanged from the prior report; not part of `sdd/helm/testing-capabilities`).

### Spec Amendment Verdict — `session-attach`'s "Attach Exit Status Reflects the Multiplexer Session"

**Legitimate correction, not a weakened contract.** Assessed on the four questions posed:

1. **Is the amended requirement still a real constraint, or was it hollowed out?** Still real. The new text still forbids the dishonest behavior the original was trying to prevent (overclaiming a detach), it just no longer demands an outcome that was measured to be physically unavailable from the mechanism named (exit status). "MUST NOT claim more than that status actually proves" is a falsifiable normative constraint, not a no-op — code that reported `AttachEndedCleanly` as "Detached" instead of "session ended, cause undetermined" would violate it, and code that silently treated a missing exit status as a clean end would also violate it. Both are exactly the failure modes an implementer under time pressure would reach for.
2. **Do the three new scenarios forbid the dishonest behaviors?** Yes, precisely the two named in this task's brief:
   - "claiming a confident detach on an ambiguous exit" → forbidden by Scenario 1 ("MUST NOT be reported as a detach").
   - "collapsing an absent status into a clean end" → forbidden by Scenario 3 ("MUST NOT be reported as a clean end").
   - Scenario 2 adds a positive obligation (abnormal exits must carry their evidence) that has no equivalent in the original requirement — the amendment is not purely subtractive.
3. **Does the implementation satisfy them, or merely coexist with them?** Satisfies them, verified by direct code read plus 4 targeted tests (below) that assert on the exact message text and the exact `AttachExitOutcome` variant produced for each input. `_classifyAttachExit` in `terminal_session.dart:132-142` implements exactly the three-way split the scenarios describe: `exitSignal != null || (exitCode != null && exitCode != 0)` → abnormal (carries both fields); `exitCode == 0` → clean/ambiguous; otherwise (both null) → unknown. This is not a case of the tests merely restating the code — `test/helpers/fake_ssh_session.dart` overrides the two dartssh2 getters the classifier reads (`exitCode`/`exitSignal`) directly, so the tests drive the classifier through its real public surface with independently chosen inputs, not through a hand-tuned protocol string a shared assumption could corrupt (contrast with W1's `_esc()` risk).
4. **Is the empirical claim plausible and internally consistent?** Independently spot-checked below. The core claim — a killed session (server surviving) and a clean detach are indistinguishable via tmux's exit status — was reproduced. The secondary illustrative claim ("kill-server → exit 1") could not be reliably confirmed or refuted in this sandbox; see below for exactly why, and note that this secondary claim is prose color in the requirement's rationale, not itself a tested MUST scenario, so its uncertainty does not weaken the three scenarios that are normative.

#### Empirical spot-check performed this run

Local `tmux 3.6a` and `zellij 0.44.3` are installed at `/opt/homebrew/bin/` — exact versions the requirement cites.

**Confirmed, reliably, twice:** using a tmux **control-mode** client (`tmux -C attach -t vs`, which communicates over stdin/stdout as text rather than needing a full pty — this was necessary because pty-based automation via `script` in this sandbox destroyed the tmux server unpredictably within ~1-2 seconds of every attach, for reasons that look like this harness's process/pty handling rather than tmux itself), with two sessions (`keepalive` kept the server alive) — killing the attached session (`tmux kill-session -t vs`) while `keepalive` still existed produced client exit code **0**, and the server was still running afterward (`keepalive` still listed). This directly reproduces the requirement's core claim: a session ending "clean" cannot be told apart from a user detach through exit status alone.

**Not reliably confirmed either way:** the requirement's illustrative aside that killing the entire server (`tmux kill-server`) produces exit `1` for a normal client. Every attempt to script a real pty-attached client (`script -q ... tmux attach`) against this sandbox's backgrounded-job handling caused the tmux server to die on its own within 1-2 seconds, before any deliberate kill command ran — visible as "no server running" errors appearing before I had issued one. The one methodology that ran reliably (control mode) is a materially different code path inside tmux (it exchanges text notifications instead of forwarding a pty), and under it `kill-server` also produced exit `0` in my one run — but I do not trust that result as representative of a normal attached client, since control mode's exit path is not necessarily wired the same way. I am reporting this as **unverified**, not as evidence against the requirement's aside, per the task's instruction not to accept or reject on faith. This uncertainty does not affect the verdict above: none of the requirement's three normative scenarios depend on the `kill-server` exit code being specifically `1`.

**Zellij**: attempted, invalidated by my own test-setup error (session-name collision between a sanity-check command and the intended attach command meant the "attach" client never actually attached — confirmed from its own logged error, "Session with name zvs already exists"). No valid zellij measurement was obtained this run; the requirement's zellij claims remain unverified by me, exactly as the prior report already disclosed them as unverified by the implementer.

**Conclusion on the amendment**: the load-bearing part of the empirical claim is confirmed by independent measurement, the requirement's language change is a real (if narrower) constraint rather than a hollowed-out one, its three scenarios forbid the two dishonest behaviors this task named plus add a positive one, and the implementation satisfies them with tests that do not share the implementation's assumptions. This is a legitimate correction.

### C1 Status: CLOSED

**Prior finding**: `session-attach`'s "Attach Exit Status Reflects the Multiplexer Session" requirement had zero implementation and zero test coverage.

**Current status**: implemented in `lib/features/terminal/data/terminal_session.dart` (commit `3f7db57`) and covered by 5 tests in `test/features/terminal/data/terminal_session_test.dart`'s `TerminalSession — attach exit status (C1: ...)` group — 4 map directly to the amended spec's 3 scenarios (one scenario, the abnormal-exit one, gets 2 tests: exit code and exit signal), plus a 5th regression test proving the attach-session classification wins over a later generic `client.done` disconnect firing for the same teardown (no duplicate/conflicting message). All 5 pass. The classification is captured into a local (`attachSession`) before the `.then()` listener is registered, so a later `reconnect()` reassigning `_session` cannot misattribute one session's exit status to another — matches the commit message's stated safeguard, confirmed by direct read of `terminal_session.dart:255-261`.

**Verdict**: satisfied. This requirement now traces to a passing test for all three of its scenarios.

### Requirement-by-Requirement Trace Table — changes since prior run

Only `session-attach` changed. All other five domains are unchanged from the prior report (re-confirmed unchanged by diff: only `terminal_session.dart`, its test file, `fake_ssh_session.dart`, and the two spec/verify-report docs touched since `c0f2af2`).

#### Domain: session-attach (4 requirements / 7 scenarios — was 4/5 before the amendment)

| Requirement | Scenario | Implementing symbol | Proving test | Verdict |
|---|---|---|---|---|
| Attach Without a Stdin Race | Attach command reaches multiplexer, no shell in between | `TerminalSession.connect` | `terminal_session_test.dart` "attaches via an exec request..." | ✅ (unchanged) |
| PTY Denial Classified Before Generic SSH Error | PTY denial produces dedicated message | `SSHService.describeError` | `ssh_service_test.dart` "pty denial" group | ✅ (unchanged) |
| PTY Denial Classified Before Generic SSH Error | Different SSH failure still generic | same | "is distinguished from other channel request failures..." | ✅ (unchanged) |
| Host Key Mismatch Keeps Precedence | Host key mismatch aborts with MITM warning | `describeError`'s `HostKeyMismatchException` branch | `ssh_service_test.dart` "host key mismatch" group | ✅ (unchanged) |
| Attach Exit Status Reflects the Multiplexer Session | A clean exit is reported as ambiguous, never a confident detach | `_classifyAttachExit` (terminal_session.dart:132-142), `AttachEndedCleanly` | "reports the ambiguous 'session ended' message when the attach session exits with code 0 and no signal" | ✅ **NEW — was NOT SATISFIED (C1)** |
| Attach Exit Status Reflects the Multiplexer Session | An abnormal exit carries the evidence that proved it | same, `AttachEndedAbnormally` | "reports an abnormal-exit message with the exit code..." + "...with the signal name..." (2 tests) | ✅ **NEW — was NOT SATISFIED (C1)** |
| Attach Exit Status Reflects the Multiplexer Session | An absent exit status is never collapsed into a clean end | same, falls through to `AttachExitUnknown` | "falls back to the pre-existing generic disconnect message when the attach session ends with no exit status at all" | ✅ **NEW — was NOT SATISFIED (C1)** |

### Updated Counts (whole change, all 6 domains)

| | Prior run | This run |
|---|---|---|
| Requirements traced with a passing test (fully or partially) | 22/23 | **23/23** |
| Requirements fully compliant (every scenario ✅) | 20/23 | **21/23** |
| Requirements with zero test coverage | 1/23 | **0/23** |
| Requirements not satisfied | 1/23 (C1) | **0/23** |
| Scenarios total | 35 | **37** (+2: the amendment replaced 1 scenario with 3) |
| Scenarios ✅ COMPLIANT | 32/35 | **35/37** |
| Scenarios ⚠️ PARTIAL | 1/35 | **1/37** (unchanged: W1) |
| Scenarios ❌ UNTESTED / NOT SATISFIED | 2/35 | **1/37** (unchanged: the host-command-port "no file left behind" scenario, which was never claimed testable by a Flutter unit test) |

The two requirements not fully compliant are the same two the prior report already named and neither is new: `host-command-port`'s "Script Delivery With Zero Host Footprint" (one scenario UNTESTED, unprovable by a Flutter unit test, held only by code inspection) and `host-probe-contract`'s "Escaping Round-Trip" (PARTIAL — decode side only, see W1).

### Correctness (Static Evidence) and Coherence (Design)

Unchanged from the prior report for all five untouched domains. For `session-attach`'s exit-status requirement: `AttachExitOutcome` is a sealed class with three variants, matching this change's own established house convention ("never return an empty collection or a bare boolean where 'could not determine' is possible... use a sealed result") — `AttachExitUnknown` is the honest "could not determine" case, not a thrown exception or a silent default. `_disconnectMessageFor` is an exhaustive `switch` over the sealed type, so a future fourth variant would be a compile error here, not a silently-missed case.

### Issues Found

**CRITICAL**: None.

**WARNING** (carried forward from the prior run; repository owner has seen all four and has not requested changes — confirming status, not re-litigating)

- **W1 — `host-probe-contract`'s Escaping Round-Trip requirement is still proven only on the decode half.** `probe_script_v1.dart:17`'s `_esc()` shell-side encoder is still never executed by any test (`rg -n "Process\.run|Process\.start"` across `test/` returns zero matches). Unchanged since the prior run. **Blocks archive: No.** Not touched by this change's remediation and was already correctly scoped as a WARNING, not a spec violation — the spec's literal scenario is about round-trip correctness and the decode half is genuinely tested against a hand-built wire string; the risk is methodological (same class of risk this repo's own HANDOFF calls out for slice 4), not a missing requirement.
- **W2 — `HostDiagnostics` still has no production call site.** Confirmed by `rg -n "HostDiagnostics" lib/`: the only two matches outside its own file are a doc-comment cross-reference in `terminal_session.dart` and its own class/constructor. **Blocks archive: No.** Consistent with HANDOFF.md's own locked decision framing this change as a contract/infrastructure layer; the individual spec requirements are satisfied and tested at the unit level, and the owner has accepted this scope boundary.
- **W3 — Same unwired pattern for the agent-state surface.** Confirmed by `rg -n "\.agents\b" lib/features/ lib/app/`: zero matches. `AgentSupport.resolve`/`MultiplexerAdapter.agents` are exercised only by their own test files. **Blocks archive: No.** Same reasoning as W2 — disclosed, accepted infrastructure-layer scope.
- **W4 — The fourth `ConnectionProfile` write path at `first_time_setup_screen.dart:92` still bypasses the mirroring helper.** Confirmed by direct read: `_saveAndContinue` constructs `ConnectionProfile(...)` with no `sessionRef`/`multiplexer`/`tmuxSession` argument, so all three default to null — it does not call `resolveOptionalSessionReference` or any mirroring function. **Blocks archive: No.** As the prior report established, this does not violate "Legacy Key Is Not Deleted" (the generated `toJson()` always emits both keys regardless of value) and the file is untouched by this migration — pre-existing, unregressed behavior outside this change's actual scope, correctly disclosed rather than silently left out of the audit claim.

**WARNING (new this run)**

- **W5 — `HANDOFF.md` is still stale, and now more so.** Its §1 snapshot table reports "Slice units delivered: 9 of 10", "Remaining: Slice 6 only — the single irreversible slice", and "Tasks: 82 of 100"; its §2 walks through slice 6 as future work with instructions like "Start it with a fresh session and full attention, not at the tail of a long one"; its §5 slice-status table lists slice 6 as `0/17`, marked `⬜`. All of this is false against the current repository: `tasks.md` shows 100/100 tasks `[x]`, including all 17 of slice 6's tasks, and this has been true since before the prior verify run (which already flagged the same staleness). Two more commits (`3f7db57`, `92903ae`) have landed since `HANDOFF.md` was last touched and neither updated it. This is exactly the kind of defect the task brief warned against treating as a nitpick: `HANDOFF.md` explicitly bills itself as "Read this first when resuming" — a future session picking this up would be told to plan a fresh, careful session for work that has already shipped and been verified. **Blocks archive: No**, by the letter of the archive gate (`sdd-status-contract.md` conditions archive readiness on task completion and verification passing, not on handoff-document accuracy), but this is a real defect in a deliverable that should be corrected before or immediately after archiving — an inaccurate `HANDOFF.md` that ships alongside an archived change is worse than a missing one, because it actively misleads instead of leaving an obvious gap.

**SUGGESTION**: unchanged from the prior report (S1, S2 — neither is a compliance finding).

### Verdict

**FAIL** — but not for the reason the prior run failed, and with zero remaining CRITICAL findings.

C1 is genuinely closed: real implementation, 5 passing tests, all 3 scenarios of the amended requirement covered, and the amendment itself independently verified as a legitimate correction rather than a hollowed-out one. `flutter analyze` is clean and all 239 tests pass (239 = prior 234 + 5 new).

The verdict is `fail`, not `pass_with_warnings`, because this project's own hard rule — "a spec scenario is compliant only when a covering test passed at runtime" — admits no exception for "unprovable by this test suite," and the admission validator enforces that literally: it rejects any passing verdict (`pass` or `pass_with_warnings`) whenever the requirements-completed or scenarios-completed count is below its total, regardless of blocker/critical counts. (Verified empirically this run: a `requirements: 21/23, scenarios: 35/37` envelope with `blockers: 0, critical_findings: 0` is rejected under `verdict: pass_with_warnings` — `Error: verify report admission denied: passing verdict contradicts failing or incomplete evidence` — and admitted only under `verdict: fail`.)

Two scenarios remain non-compliant, and I independently re-verified both by direct source and test-suite inspection rather than carrying the prior report's classification forward on trust:

- `host-command-port`'s "No file left behind on the host" — confirmed by reading `ssh_host_command_runner.dart` end to end: `runScript` contains no `File`/`writeAsString`/any file-write primitive, only stdin piping to a fixed `/bin/sh -s` command. True by inspection. Zero covering test exists (`ssh_host_command_runner_test.dart` has no matching case) — genuinely untestable by a pure Flutter unit test, since it would require a live host filesystem check.
- `host-probe-contract`'s "Escaping Round-Trip", encode side — confirmed by grep: `_esc()` in `probe_script_v1.dart:17` and zero `Process.run`/`Process.start` calls anywhere in `test/`. The decode half is genuinely tested; the shell-side encoder never runs under this suite.

Both are pre-existing: present in the very first verify-report for this change, unrelated to C1 or this remediation round, and already classified WARNING (W1) / SUGGESTION (S2) rather than CRITICAL, because neither breaks a spec at the level static evidence can show and neither is new debt introduced by this change.

### Ready to Archive

**Not unconditionally, per the strict SDD gate — but the blocking condition is unchanged in kind from before this change even started, and is not C1.**

What's true: tasks are 100/100 complete, `flutter analyze` is clean, all 239 tests pass, zero CRITICAL findings remain, C1 (the sole prior blocker) is closed with real implementation and tests on a spec amendment that holds up under independent, adversarial re-derivation — not just re-reading the same reasoning that produced it.

What's not true: this verification does not reach a clean `pass` under `sdd-status-contract.md`'s "archive is ready when tasks are complete and strict verification passes" — because "passes" is a binary the tooling itself enforces (see above), and 2 pre-existing, non-CRITICAL, disclosed scenario gaps remain outside the scope of this remediation round.

**What exactly blocks a clean pass**: `host-command-port`'s "No file left behind on the host" scenario and `host-probe-contract`'s "Escaping Round-Trip" encode-side scenario both need runtime evidence this test suite cannot produce on its own — most plausibly a manual/live-host verification pass (already suggested independently in the prior report as S2 and in this task's own "known and accepted" framing for other live-host-only claims) for the first, and a `Process.run('sh', ...)`-based smoke test that pipes real reserved bytes through the actual probe script for the second. Neither requires more implementation work — the code is believed correct by inspection for both — only proof.

**This is a policy decision for the repository owner, not one this verification can make unilaterally**: if these two gaps are accepted as a standing, disclosed limitation (as W1/W2/W3/W4 already are, explicitly, per this task's brief), archiving with them open is a defensible choice — but it is a choice, and the strict schema will not represent that choice as `pass`. It should be made explicitly, the same way W1-W4 already were, rather than by this report silently rounding a `fail` up to a `pass`.

Also recommend fixing `HANDOFF.md` (W5, below) before or immediately after archiving, independent of the above.
