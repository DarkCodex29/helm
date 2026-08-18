```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:a0683d3a220f2d9e574e7693721c6aa1ad86ed00474af0eeca30a884ff559288
verdict: fail
blockers: 0
critical_findings: 0
requirements: 22/23
scenarios: 36/37
test_command: flutter test
test_exit_code: 0
test_output_hash: sha256:c3c95ed2988bbe9ab49038c3a4006378af9bf7eb9244bc69cb0bcf96a872db0f
build_command: flutter analyze
build_exit_code: 0
build_output_hash: sha256:8e78fbae955094f14513060c6ad1732c81a1bf52e408abbff6002dfdab8a65e7
```

## Verification Report

**Change**: host-session-contract
**Version**: N/A (first version, `openspec/specs/` was empty before this change)
**Mode**: Strict TDD
**Re-run context**: third verify pass for this change. HEAD at this run: `ad15caff463c57f338e5729a59304f8714c17556`. Working tree clean. Two commits landed since the prior verify report (`92903ae`): `cf77550` (encoder-side test for W1) and `ad15caf` (a real, previously-undetected footprint defect found and fixed on live host measurement, superseding this run's own prior "holds by inspection" classification for that scenario).

### Completeness

| Metric | Value |
|--------|-------|
| Tasks total | 100 |
| Tasks complete | 100 |
| Tasks incomplete | 0 |

Confirmed by direct grep: `- [x]` count 100, `- [ ]` count 0.

### Build & Tests Execution

**Build**: PASSED

```text
$ flutter analyze
Analyzing helm...
No issues found! (ran in 3.6s)
```

**Tests**: 250 passed / 0 failed / 0 skipped

```text
$ flutter test
...
00:02 +249: .../fake_host_command_runner_test.dart: satisfies the HostCommandRunner contract...
00:02 +250: All tests passed!
```

Exit code 0 for both commands, run twice this session with identical results. 250/250, up from the prior report's 239/239 — the delta is exactly the 11 new tests: 6 in `probe_script_v1_test.dart` (encoder-side Escaping Round-Trip, closes W1) + 5 in `probe_script_v1_tmux_gate_test.dart` (tmux-server detection gate logic, closes the footprint defect at the decision-logic level).

**Coverage**: not run (unchanged from prior reports; not part of `sdd/helm/testing-capabilities`).

---

### Verdict on the Footprint Fix — answers to the four posed questions

**1. Is the "No file left behind on the host" scenario now satisfied?**

The underlying product defect is genuinely fixed, and I independently reproduced both directions on the live production host (`ssh contabo`, Ubuntu 24.04.4, tmux 3.4), not merely trusting the commit message:

- Extracted the exact `probeScriptV1` constant (lines 10–118, byte-for-byte, no retyping) and piped it to `sh -s` over SSH with no PTY, matching the app's real delivery path, with no tmux server running. Confirmed: `env`/`mux` records only, no `session` record, exit 0, and `ls /tmp/` showed **no `tmux-*` directory** before or after — the fix holds.
- Started a real detached tmux session (`helm_verify_probe_test`), re-ran the same extracted script: the session was correctly enumerated (`session	tmux	helm_verify_probe_test	active	0`).
- Checked out the **pre-fix** script at `cf77550` (before `ad15caf`), extracted it the same way, and ran it against the *same live session*: output for the `mux`/`session` lines was **byte-for-byte identical** to the fixed script's output. Added a second session and repeated — still byte-for-byte identical for both sessions, in order.
- Directly confirmed the detection string on the real host: `ps -u deployer -o comm=` reports the running server's process name as literally `tmux: server` — exactly the literal the gate's `grep -Fxq 'tmux: server'` matches against. This is not a simulated assumption; it is the real host's real process table.
- Killed the server and cleaned up; host left exactly as found.

So: **the defect is real, was correctly diagnosed, and is correctly fixed** — I did not just accept this on the strength of prose in `HANDOFF.md` or the commit message; I reproduced the causal chain myself on the same production host.

**However**, per this skill's hard rule — "a spec scenario is compliant only when a covering test passed at runtime" — my live SSH measurement, and the original author's, are **not** a covering test in the sense this schema counts. They are **recorded live evidence**, a distinct evidentiary category from an automated test in the `flutter test` harness, and no automated test in this suite executes `runScript()` against a real remote filesystem and inspects it afterward (nor can one, without a live host fixture this project does not have). The five gate-logic tests in `probe_script_v1_tmux_gate_test.dart` prove the **branch selection** (`_tmux_server_running` → `SERVER_RUNNING`/`SERVER_NOT_RUNNING`) under a real `/bin/sh` with a controlled fake `ps`, which is real and valuable evidence, but it is not itself a test that asserts the absence of a file on a host.

**Verdict: still not COMPLIANT under the strict schema — still UNTESTED by the letter of the rule — but the underlying claim it was previously held to by inspection is now independently confirmed true by live measurement, twice, including by me this run.** This is a meaningfully different and stronger epistemic position than the prior report's "holds by inspection," which I judge below to have actually been **wrong** (see the meta-finding after Q2).

**2. Is the fail-open branch defensible or a hole?**

Read literally, the spec's scenario text has no carve-out: "the host MUST show no new file, directory, or cached artifact created by the call" is unconditional. The fail-open branch (`command -v ps` unavailable → assume a server may exist → enumerate anyway) means that on a host with **both** no running tmux server **and** no `ps` binary, the fix's own gate cannot detect that absence and the original defect (an empty `tmux-$UID` socket directory) reappears. This is a genuine, narrow exception to the letter of the requirement, and it is worth stating plainly rather than waving away.

That said, judged on engineering merits rather than the letter of the spec text: `ps` is a POSIX-baseline utility present on effectively every general-purpose Linux host capable of running an interactive multiplexer session for SSH terminal work (the entire reason this app exists) — a host missing `ps` but running tmux for a user's persistent terminal session is a vanishingly unlikely combination, and if it did occur, the alternative failure mode (silently reporting "no sessions" on a host that has real ones) directly contradicts this app's core purpose: finding an already-running session. An ephemeral, empty, `0700`-mode directory in `/tmp` is a strictly lower-severity outcome than lying to the user about session existence. The tradeoff is disclosed in the commit message, not hidden, and the harm is bounded (no data, no permissions issue, no persistence beyond the directory itself).

**Judgment: defensible as an engineering tradeoff, but it is a real, disclosed gap in the literal guarantee, not a non-issue.** I am recording it as a new WARNING (W6) rather than accepting the commit's own framing uncritically or promoting it to CRITICAL — it doesn't break the spec at the level this suite's static/runtime evidence can prove wrong in the overwhelming majority of real deployments, but the unconditional spec text and the actual implementation now diverge in one named edge case.

**3. Did the fix regress enumeration?**

**No — independently confirmed, not just trusted.** See the live-host comparison in Q1: pre-fix and fixed script produce byte-for-byte identical `mux`/`session` output against the same real server, with one and then two real sessions. The gate cannot skip a host that genuinely has sessions because detection reads the invoking user's own process table for the exact string `tmux: server` — which I confirmed is the real comm name tmux 3.4 reports on this host — and is unaffected by `TMUX_TMPDIR`/`-S` socket relocation (the gate never inspects the socket path at all, only the process list).

**4. Does the gate itself introduce a new footprint or side effect?**

`ps -u "$(id -un)" -o comm=`, `id -un`, and `grep -Fxq` are all read-only operations against the process table and stdin; none of them write to the filesystem. No new footprint. The only new cost is CPU/process overhead (three additional short-lived subprocesses per probe call), which is not the kind of artifact the spec's scenario is concerned with.

**Meta-finding, not asked for but load-bearing**: the prior verify report's classification of this scenario as "holds by inspection: no file-writing primitive exists in the code path" was **methodologically correct and substantively wrong at the same time** — the source code genuinely contains no write primitive, and the report said so accurately, but the conclusion drawn from that fact ("therefore no footprint") was false, because the script *calls* `tmux`, and `tmux`'s own client creates its socket directory as a side effect of the call, independent of anything the probe script itself writes. This is exactly the kind of gap "inspection of behavior one layer removed" cannot catch, and it is a genuinely new category of miss for this change, distinct from W1's "encoder never executed" gap (that one was about the format's own logic; this one is about an external binary's undocumented side effect). I am recording this explicitly because the task asked me to be sceptical of exactly this claim, and the honest answer is: the inspection-based verdict this project shipped in two prior verify reports was wrong, and only live measurement — first the author's, now independently mine — caught it.

---

### C1 Status: CLOSED (unaffected by this run's commits)

`session-attach`'s exit-status requirement remains implemented in `terminal_session.dart` (commit `3f7db57`), covered by 5 tests, unchanged since the prior report — confirmed by `git diff --stat 92903ae..ad15caf -- lib/ test/`, which shows only `probe_script_v1.dart` and its two test files touched. No re-verification of this domain was needed; carrying forward the prior report's independently-derived verdict, which itself was an adversarial re-derivation, not a restated assumption.

### W1 Status: CLOSED

`probe_script_v1_test.dart` (added at `cf77550`) runs the real `_esc()` function — extracted byte-for-byte from the `probeScriptV1` constant via a marker-based substring extraction that throws `StateError` if the marker vanishes, never retyped — under a real `/bin/sh`, for all four reserved byte classes individually, combined, and in a delimiter-adjacency stress case. Each test also runs a structural well-formedness check (no raw TAB/LF/CR survives, every backslash starts a valid two-character escape) before decoding through the real `HostProbeParser`, so a bug that happened to survive round-trip equality (a bare CR, a lone backslash) would still be caught. Confirmed by direct read: this is a genuine runtime test, not a restated assumption, and all 6 tests pass. **`host-probe-contract`'s Escaping Round-Trip requirement moves from PARTIAL to fully COMPLIANT.**

### W2, W3, W4 Status: unchanged, reconfirmed by direct grep this run

- **W2** — `HostDiagnostics` still has no production call site. `rg -n "HostDiagnostics" lib/` returns only its own file and one doc-comment cross-reference in `terminal_session.dart`. **Blocks archive: No.** Owner has seen this and requested no change; not re-litigating.
- **W3** — the agent-state surface still has no external caller. `rg -n "\.agents\b" lib/` returns only `multiplexer_adapter.dart` itself and generated freezed code. **Blocks archive: No.** Same as W2.
- **W4** — `first_time_setup_screen.dart:92`'s `ConnectionProfile(...)` construction still omits `sessionRef`/`multiplexer`/`tmuxSession`, bypassing the mirroring helper. Confirmed by direct read of the current file. **Blocks archive: No.** Does not violate "Legacy Key Is Not Deleted" (the generated `toJson()` always emits both keys regardless of value); pre-existing, unregressed, outside this migration's scope.

### W5 Status: NOT closed — stale again, independently discovered this run

The task briefing described W5 as closed by `949caab`. I verified this claim rather than accepting it, and **it does not hold at HEAD**: `HANDOFF.md` was accurate at `949caab`, but the two commits that landed immediately after it (`cf77550`, `ad15caf`) were not reflected back into the file, so it has drifted stale again — the exact failure mode its own warning banner describes ("Nothing in the build, test or verify pipeline reads this file... only a human keeps it honest").

Specifically, at current HEAD `HANDOFF.md`:

- §1 snapshot table still reads `Test suite | 39 → 239, all green` — actual is **250**.
- §1's commit log block ends at `92903ae` — does not list `cf77550` or `ad15caf`.
- §2 "What is left" still frames **both** the encoder-side Escaping Round-Trip gap and the footprint scenario as **open, undecided** work ("So the choice is: close that gap with a shell smoke test, or archive with both recorded as accepted limitations") — but the encoder gap **is now closed** (`cf77550`) and the footprint scenario **is now fixed and live-verified**, not merely still-open.
- §2's carried-forward WARNING list still names W1 as open.

**Blocks archive: No**, by the same letter-of-the-gate reasoning as before (`sdd-status-contract.md` conditions archive readiness on task completion and verification passing, not handoff-document accuracy) — but this is now the file's **second** documented staleness episode, both caught only by an SDD verify pass rather than by anything in the build/test pipeline, which is exactly the pattern the file's own banner warns about. Recommend a text fix as part of any handoff after this run, same recommendation as before, now with added weight.

### W6 (new this run): Zero-footprint guarantee has a narrow, disclosed exception

See "Verdict on the Footprint Fix," Q2 above. When `ps` is unavailable on the target host, the tmux-server detection gate fails open and calls `tmux list-sessions` unconditionally, which can recreate the original footprint defect in that narrow combination (no `ps` AND no running tmux server). Defensible as an engineering tradeoff favoring correct session enumeration over an absolute zero-footprint guarantee, and disclosed in the commit message — but the spec text itself carries no such carve-out. **Blocks archive: No** — narrow, low-probability, low-harm, disclosed; a policy decision for the repository owner, same category as W1–W5.

---

### Requirement-by-Requirement Trace Table — changes since prior run

Only `host-probe-contract` and `host-command-port` are affected; all four other domains are unchanged (confirmed by `git diff --stat` above) and their prior verdicts are carried forward.

#### Domain: host-probe-contract (6 requirements / 10 scenarios)

| Requirement | Scenario | Implementing symbol | Proving test | Verdict |
|---|---|---|---|---|
| Escaping Round-Trip | Each reserved byte class round-trips exactly | `_esc()` (`probe_script_v1.dart:17`), `HostProbeParser` | `probe_script_v1_test.dart` — 6 tests: backslash, TAB, LF, CR, combined, delimiter-adjacent, each running the real `_esc()` under real `/bin/sh`, structurally checked, then decoded through the real parser | ✅ **NEW — was ⚠️ PARTIAL** |

All five other `host-probe-contract` requirements unchanged from the prior report (✅, unaffected by this diff).

#### Domain: host-command-port (3 requirements / 5 scenarios)

| Requirement | Scenario | Implementing symbol | Proving test | Verdict |
|---|---|---|---|---|
| Script Delivery With Zero Host Footprint | Script delivered over stdin, no pseudo-terminal | `SshHostCommandRunner.runScript` | `ssh_host_command_runner_test.dart` | ✅ (unchanged) |
| Script Delivery With Zero Host Footprint | No file left behind on the host | `_tmux_server_running()` gate (`probe_script_v1.dart:83-105`) | Decision logic: `probe_script_v1_tmux_gate_test.dart` (5 tests, real `/bin/sh`, controlled fake `ps`). End-to-end filesystem absence: **live-host measurement only** (this run, independently reproduced — see above); no automated covering test exists or can exist in this harness | ❌ **UNTESTED (unchanged classification) — underlying defect now fixed and live-verified, but no covering runtime test exists per the strict schema** |

The other requirement in this domain (`Single-Command Execution`, `Swappable Transport Implementations`) is unchanged, ✅.

### Updated Counts (whole change, all 6 domains)

| | Prior run (92903ae) | This run (ad15caf) |
|---|---|---|
| Requirements traced with a passing test (fully or partially) | 23/23 | **23/23** (unchanged) |
| Requirements fully compliant (every scenario ✅ by a covering test) | 21/23 | **22/23** |
| Requirements traced with recorded live evidence only (no covering test, but genuinely investigated on a live host) | 0/23 | **1/23** — `host-command-port`'s Script Delivery requirement |
| Requirements not satisfied (zero evidence of any kind) | 0/23 | **0/23** |
| Scenarios total | 37 | **37** (unchanged) |
| Scenarios ✅ COMPLIANT (covering test passed at runtime) | 35/37 | **36/37** |
| Scenarios ⚠️ PARTIAL | 1/37 (W1) | **0/37** |
| Scenarios ❌ UNTESTED, traced only by recorded live evidence | 1/37 | **1/37** (unchanged: "No file left behind on the host" — the underlying claim is now independently confirmed true by live measurement, but remains outside the strict schema's "covering test" bucket) |

### Correctness (Static Evidence) and Coherence (Design)

Unchanged from the prior report for all five domains untouched by this diff. For the tmux gate: `_tmux_server_running()` follows this change's own established house convention ("never return an empty collection or a bare boolean where 'could not determine' is possible") in spirit — it is a boolean gate, but its two outcomes (`SERVER_RUNNING`/enumerate vs `SERVER_NOT_RUNNING`/skip) are both explicit and neither collapses "could not determine" into a silent default; the fail-open branch is the one place a genuinely undetectable state is resolved to a specific choice rather than surfaced as a third state, which is the crux of the W6 finding above — a sealed three-state result (`running`/`not-running`/`undetermined-fail-open`) would have been more consistent with the convention than a boolean, though the practical behavior (enumerate) is the same either way.

### Issues Found

**CRITICAL**: None.

**WARNING** (carried forward, reconfirmed this run; repository owner has seen W1–W4 and requested no changes)

- **W2** — `HostDiagnostics` has no production call site. Blocks archive: No.
- **W3** — the agent-state surface has no caller outside its own tests. Blocks archive: No.
- **W4** — `first_time_setup_screen.dart:92` bypasses the mirroring helper. Blocks archive: No.
- **W5 (recurred)** — `HANDOFF.md` is stale again, independent of the task's framing that it was closed; see full detail above. Blocks archive: No.

**WARNING (new this run)**

- **W6** — the zero-footprint guarantee's fail-open branch is a narrow, disclosed exception to the literal spec text when `ps` is unavailable on the host. Blocks archive: No.

**SUGGESTION**: unchanged from the prior report (S1, S2 — neither is a compliance finding). Additionally suggest: consider a sealed three-state result for `_tmux_server_running()` (`serverRunning`/`serverNotRunning`/`undetermined`) instead of a boolean with an internal fail-open default, matching this change's own stated house convention more literally — cosmetic, not a spec violation.

### Verdict

**FAIL** — improved from the prior run (22/23 requirements, 36/37 scenarios, up from 21/23 and 35/37), zero CRITICAL findings, zero blockers, one prior WARNING (W1) closed, one prior WARNING (W5) reopened by independent discovery, one new WARNING (W6) disclosed.

The verdict is `fail`, not `pass_with_warnings`, for the same reason as the prior run: this project's hard rule admits no exception for "unprovable by this test suite, but independently confirmed true by live measurement," and the admission validator enforces that literally — a passing verdict with any incomplete requirement/scenario count is rejected on admission regardless of blocker/critical counts.

Exactly one scenario remains non-compliant under the strict schema: `host-command-port`'s "No file left behind on the host." Unlike the prior two reports, this is **not** a case of "believed correct by inspection, never proven" — it is now a case of **defect found, defect fixed, fix independently reproduced live twice** (by the implementer and by this verification), with the single remaining gap being the schema's insistence on a `flutter test`-runtime covering test, which cannot exist for a live-remote-filesystem assertion in this harness.

### Ready to Archive

**Not unconditionally, per the strict SDD gate — and the blocking condition has narrowed, not widened, since the prior run.**

What's true: tasks are 100/100 complete, `flutter analyze` is clean, all 250 tests pass, zero CRITICAL findings, C1 remains closed and unaffected, W1 is now genuinely closed with a real runtime test, and the footprint defect that the prior two verify reports could only assess "by inspection" has been found to be a real defect, fixed, and independently confirmed live by two separate parties (the implementer and this verification) rather than merely asserted.

What's not true: this verification still does not reach a clean `pass` — one scenario (`host-command-port`'s "No file left behind") remains outside what a Flutter unit test can prove at runtime, exactly as the prior two reports already disclosed, and the new W6 finding (a narrow, disclosed fail-open exception) means even the live-verified claim now carries one documented edge-case caveat rather than being unconditionally true.

**What exactly blocks a clean pass**: a single scenario needing runtime evidence this test suite cannot produce on its own. This is now demonstrably not a matter of missing implementation work or unresolved uncertainty about correctness — the code is correct, and that correctness has been independently confirmed live, twice — it is purely a completeness-count artifact of a schema that only recognizes automated covering tests, applied to a claim about remote-filesystem state that a Flutter test harness structurally cannot assert.

**This is the same policy decision the repository owner already faced in the prior report, now on stronger footing**: archiving with this one gap accepted as a standing, disclosed limitation (as W1–W6 already are) is a defensible choice — the strict schema will still represent that choice as `fail`, not `pass`, because a completeness count that cannot be reached from this test harness is exactly what it is, and this report is saying so plainly rather than rounding it up.

**Also recommend, independent of the above**: fix `HANDOFF.md`'s renewed staleness (W5) before archiving — this is now its second documented drift, both caught only by verify, never by the build/test pipeline itself.
