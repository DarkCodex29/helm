```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:e1cb1686a4f4c0ccf23123867b52d214ff09d51b000000000000000000000000
verdict: fail
blockers: 0
critical_findings: 1
requirements: 22/23
scenarios: 37/39
test_command: flutter test
test_exit_code: 0
test_output_hash: sha256:3c2bdddea61142db2a40671fee01238e57293b0c15bc7245256ceb1db742fc0e
build_command: flutter analyze
build_exit_code: 0
build_output_hash: sha256:f00f18aab81cb945c6429a89e7f93c2af1a6f7eee994d157964be69a07bdd2b6
```

## Verification Report

**Change**: host-session-contract
**Version**: N/A (first version, `openspec/specs/` was empty before this change)
**Mode**: Strict TDD
**Re-run context**: fourth verify pass. HEAD at this run: `e1cb1686a4f4c0ccf23123867b52d214ff09d51b`. Working tree clean. This run exists because the native dispatcher rejected the prior report's `scenarios: 36/37` — one docs-only commit, `e1cb168`, landed since the prior run and amended `host-command-port`'s "No file left behind on the host" requirement, changing the true total from 37 to **39** scenarios workspace-wide. `git diff 029c5d4..e1cb168 -- lib/ test/` is empty: this commit touched only `specs/host-command-port/spec.md`. No implementation or test changed.

### Skill Resolution

`skill_resolution: paths-injected` — 5 skills loaded from the exact paths given in the launch prompt: `sdd-verify`, `testing`, `flutter`, `security`, `software-engineering`.

---

### Verdict on the Amendment — answers to the four posed questions

**1. Is the requirement still a real constraint, or was it hollowed out so the count would close?**

Still a real constraint — not hollowed out. The requirement's own MUST-NOT text is retained **verbatim**: "the system MUST provide a `runScript` operation that... MUST NOT create, write, install, or cache any file on the remote host." Nothing in that sentence changed. What changed is the *scenario* enumeration underneath it: one scenario that asserted about a remote host's filesystem — genuinely inexpressible in a Flutter unit-test harness with no live host — was replaced by three scenarios that assert about the script's own decision logic, which a `flutter test` process *can* exercise under a real `/bin/sh`. The spec text is explicit that "the original scenario asked for the host to be inspected after the call and show no new artifact. That is the true statement of intent, and it is retained as the requirement" (lines 56–58 of the amended spec) — the amendment states its own intent-preservation in writing, not just in the commit message.

Confirmed independently: `git diff 029c5d4..e1cb168 -- lib/ test/` returns **zero lines**. Nothing about what the code does changed. Only the description of how that behavior is evidenced changed.

**Verdict: legitimate. The obligation is unchanged; only its evidentiary framing moved.**

**2. Do the three new scenarios have genuine covering tests?**

No — one of the three does not. See the full mapping table below. Summary:

- *"An undetectable server never becomes a silent absence"* — **✅ COMPLIANT.** Test 5 in `probe_script_v1_tmux_gate_test.dart` directly exercises the exact GIVEN (`ps` unavailable on PATH) and asserts the exact THEN (the gate reports `SERVER_RUNNING`, i.e. "attempt the query"), under a real `/bin/sh`. Direct, faithful match.
- *"No command is invoked when there is nothing for it to report"* — **⚠️ PARTIAL.** Three tests (2, 3, 4) prove the branch-selection function `_tmux_server_running()` correctly returns false in three distinct negative cases, under a real shell — genuine runtime evidence, not inspection. But none of the five tests assert the scenario's own THEN clauses: that `list-sessions` is *actually not invoked*, or that emitted records are *byte-identical* to a host where the tool is absent. Both claims are true by reading the surrounding `if [ "$TMUX_FOUND" = "1" ] && _tmux_server_running; then ... fi` gate in `probe_script_v1.dart:107`, not by an executed assertion. The precondition itself (`TMUX_FOUND=1`, i.e. "tool installed") is also never set up in the test harness — it tests the gate function in isolation, independent of that flag.
- *"Detection is independent of relocatable paths"* — **❌ UNTESTED.** No test in this suite sets `TMUX_TMPDIR`, a `-S` socket path, or any equivalent relocation and confirms detection is unaffected. `rg -n "TMUX_TMPDIR|relocat|socket_path"` across `test/` and `lib/core/host/` returns exactly one hit: the doc-comment in `probe_script_v1.dart` itself explaining *why* the design is path-independent (line 85). This scenario currently holds **only by inspection** — the gate is name-based (`ps -u ... | grep -Fxq 'tmux: server'`) and structurally never references a path variable, which is visibly true from reading the code, but is exactly the same evidentiary category — "inspection proves how the source reads, not what the execution does" — that `HANDOFF.md` §8 already documents as **wrong once** for this identical requirement (the original footprint defect held "by inspection" for two prior verify passes and was empirically false). Unlike the original scenario this amendment replaced, this gap is **not structurally untestable** — a sixth test following the exact pattern of the existing five (set `TMUX_TMPDIR` or an equivalent relocated variable in the harness's `env`, confirm the gate still returns the correct value) would close it in this same harness, no live host required.

**Verdict: two of three genuinely covered at runtime to different degrees (one fully, one partially); one asserted only by the same kind of inspection this project has already found unreliable once, for a gap that is closable in this exact test file.**

**3. Is recording the fail-open branch as an accepted exception legitimate, or does it launder a violation into compliance?**

Legitimate, judged on merit. The fail-open branch (`ps` unavailable → assume a server may exist → enumerate anyway) is not new — it was already disclosed as WARNING **W6** in the prior verify report. What changed in `e1cb168` is that the exception is now written **into the requirement's own scenario text** ("the resulting host artifact is an accepted, disclosed exception to this requirement, because reporting no sessions on a host that has them is the greater harm") rather than living only in a verify report a future reader might not see. That is the correct direction for a genuine, narrow, rationale-backed edge case: naming it in the normative document itself, with the reasoning for why the alternative is worse, is stronger disclosure than the status quo before this commit, not weaker. It does not broaden the general MUST-NOT obligation — the exception is scoped to exactly the "no `ps`" branch, not to the requirement as a whole. This is the opposite of laundering: laundering would be softening the general text to quietly permit the edge case everywhere; this amendment narrows the disclosed exception to precisely the one combination where it applies and leaves the general prohibition untouched.

**Verdict: legitimate spec authorship of a known, bounded tradeoff — not a violation dressed up as compliance.**

**4. Did the amendment weaken the zero-footprint promise in practice? Confirm the behavior did not change.**

Confirmed. `git diff 029c5d4..e1cb168 -- lib/ test/` returns 0 lines. `git show e1cb168 --name-only` touches exactly one file: `openspec/changes/host-session-contract/specs/host-command-port/spec.md`. `flutter analyze` is clean and all 250 tests pass identically to the prior run (the same 250; no test added or removed by this commit). The behavior at HEAD is byte-identical to the behavior at `029c5d4`, the commit the prior verify report already assessed. Only the spec's description of that behavior changed.

**Verdict: no practical weakening. This is a documentation-only commit, confirmed by diff, not asserted from the commit message.**

---

### Scenario-to-Test Mapping — the three new `host-command-port` scenarios

| Scenario | Test(s) | Status |
|---|---|---|
| No command is invoked when there is nothing for it to report | `probe_script_v1_tmux_gate_test.dart` tests 2 ("reports no running server when ps lists no tmux server process at all"), 3 ("does not treat a bare 'tmux' comm... as a running server"), 4 ("is scoped to the invoking user... empty scoped list means no server") | ⚠️ **PARTIAL** — branch condition genuinely tested under a real shell; non-invocation and record-identity claims not directly asserted |
| An undetectable server never becomes a silent absence | `probe_script_v1_tmux_gate_test.dart` test 5 ("fails OPEN -- reports a possible server -- when ps is not available on PATH at all") | ✅ **COMPLIANT** — direct match of GIVEN/WHEN/THEN |
| Detection is independent of relocatable paths | none | ❌ **UNTESTED** — zero test coverage; true only by code inspection |

---

### Completeness

| Metric | Value |
|--------|-------|
| Tasks total | 100 |
| Tasks complete | 100 |
| Tasks incomplete | 0 |

Confirmed by direct grep: `- [x]` count 100, `- [ ]` count 0.

### Build & Tests Execution

**Build**: ✅ Passed

```text
$ flutter analyze
Analyzing helm...
No issues found! (ran in 1.5s)
```

Exit code 0. `sha256sum`: `f00f18aab81cb945c6429a89e7f93c2af1a6f7eee994d157964be69a07bdd2b6`

**Tests**: ✅ 250 passed / 0 failed / 0 skipped

```text
$ flutter test
...
00:02 +246: .../fake_host_command_runner_test.dart: run throws when a command has no scripted result...
00:02 +247: .../fake_host_command_runner_test.dart: runScript returns the exact result registered for that script
00:02 +248: .../fake_host_command_runner_test.dart: runScript throws when a script has no scripted result...
00:02 +249: .../fake_host_command_runner_test.dart: satisfies the HostCommandRunner contract...
00:02 +250: All tests passed!
```

Exit code 0. `sha256sum`: `3c2bdddea61142db2a40671fee01238e57293b0c15bc7245256ceb1db742fc0e`

**Coverage**: not run (unchanged from all prior reports; not part of `sdd/helm/testing-capabilities`).

---

### Spec Compliance Matrix (all 6 domains, 23 requirements / 39 scenarios)

#### Domain: host-command-port (3 requirements / 7 scenarios) — the only domain re-derived this run

| Requirement | Scenario | Test | Result |
|---|---|---|---|
| Single-Command Execution | Command completes successfully | `ssh_host_command_runner_test.dart` | ✅ COMPLIANT |
| Single-Command Execution | Command exceeds the configured timeout | `ssh_host_command_runner_test.dart` | ✅ COMPLIANT |
| Script Delivery With Zero Host Footprint | Script delivered over stdin, no pseudo-terminal | `ssh_host_command_runner_test.dart` | ✅ COMPLIANT |
| Script Delivery With Zero Host Footprint | No command is invoked when there is nothing for it to report | `probe_script_v1_tmux_gate_test.dart` (tests 2, 3, 4) | ⚠️ PARTIAL |
| Script Delivery With Zero Host Footprint | An undetectable server never becomes a silent absence | `probe_script_v1_tmux_gate_test.dart` (test 5) | ✅ COMPLIANT |
| Script Delivery With Zero Host Footprint | Detection is independent of relocatable paths | none | ❌ UNTESTED |
| Swappable Transport Implementations | Scripted stand-in satisfies the same contract | `fake_host_command_runner_test.dart` | ✅ COMPLIANT |

**Requirement-level**: "Single-Command Execution" ✅, "Swappable Transport Implementations" ✅, "Script Delivery With Zero Host Footprint" **not fully compliant** (2 of 4 scenarios not ✅) → 2/3 requirements fully compliant in this domain.

#### The other 5 domains — carried forward unchanged (confirmed by `git diff --stat 92903ae..e1cb168 -- lib/ test/`, which touches only the three probe files already accounted for; nothing in these domains changed)

| Domain | Requirements | Scenarios | Status |
|---|---|---|---|
| host-diagnostics | 4/4 fully compliant | 6/6 ✅ | unchanged |
| host-probe-contract | 6/6 fully compliant | 10/10 ✅ (Escaping Round-Trip closed at `cf77550`, unaffected by this run) | unchanged |
| multiplexer-abstraction | 3/3 fully compliant | 6/6 ✅ | unchanged |
| session-attach | 4/4 fully compliant | 7/7 ✅ (C1 closed, see below) | unchanged |
| session-reference-storage | 3/3 fully compliant | 3/3 ✅ | unchanged |

**Compliance summary**: 37/39 scenarios ✅ COMPLIANT, 1/39 ⚠️ PARTIAL, 1/39 ❌ UNTESTED. 22/23 requirements fully compliant.

### Correctness (Static Evidence)

Unchanged from prior report for the 5 untouched domains. For `host-command-port`'s amended requirement: the `_tmux_server_running()` gate (`probe_script_v1.dart:83-105`) correctly implements name-based detection (`ps -u "$(id -un)" -o comm= | grep -Fxq 'tmux: server'`), never references a socket/tmp path, and the surrounding `if` gate correctly wires the detection result to invocation — confirmed by direct read, not proven by an executed test for the path-independence claim.

### Coherence (Design)

Unchanged from prior report. The house convention ("never return an empty collection or bare boolean where 'could not determine' is possible") is followed in spirit but not the letter by `_tmux_server_running()`'s boolean return — carried forward from the prior report's SUGGESTION, not a new finding.

---

### C1, W1–W6 Status

| ID | Status | Blocks archive |
|---|---|---|
| C1 — Attach exit status classification | **CLOSED**, unaffected by `e1cb168` (`git diff --stat 92903ae..e1cb168 -- lib/ test/` touches only `probe_script_v1.dart` and its two test files) | No |
| W1 — encoder-side `_esc()` never executed | **CLOSED** at `cf77550`, unaffected this run | No |
| W2 — `HostDiagnostics` has no production call site | Unchanged, reconfirmed: `rg -n "HostDiagnostics" lib/` returns only its own file | No — owner-accepted |
| W3 — agent-state surface has no external caller | Unchanged, reconfirmed: `rg -n "\.agents\b" lib/` returns only `multiplexer_adapter.dart` and generated code | No — owner-accepted |
| W4 — `first_time_setup_screen.dart:92` bypasses the mirroring helper | Unchanged, reconfirmed by direct read | No — owner-accepted, pre-existing, outside migration scope |
| W5 — `HANDOFF.md` staleness | **NOT closed — stale a third time**, and a fourth issue found this run: see full detail below | No (per `sdd-status-contract.md`, archive readiness tracks task/verify completion, not handoff-document accuracy) |
| W6 — zero-footprint fail-open exception | Unchanged substantively; **now written directly into the spec text** by `e1cb168` rather than living only in this verify report | No — narrow, disclosed, low-harm |

**New this run**:

- **C2 (new CRITICAL)** — "Detection is independent of relocatable paths" scenario has zero covering test. Unlike W6/the original footprint scenario, this gap is **closable in this exact harness**: a sixth test in `probe_script_v1_tmux_gate_test.dart`, following the identical pattern as tests 1–5, setting a relocated `TMUX_TMPDIR` (or equivalent) in the harness `env` and confirming the gate's return value is unaffected, would close it without any live host. Blocks a clean PASS under this schema's hard rule ("spec scenario has no passing covering test → CRITICAL UNTESTED"). Does not block archive under the same letter-of-the-gate reasoning as W1–W6 (task completion + build/test passing are the archive gate, not verify's requirement/scenario completeness), but it is a real, actionable gap the owner should weigh differently from W1–W6 because it is fixable, not structural.

---

### HANDOFF.md accuracy at current HEAD (`e1cb168`)

**Not accurate.** Verified directly rather than accepting the task briefing's premise that it was fixed at `029c5d4`. Specific findings:

1. **Header pin is now one commit behind.** §1 states "describes commit `ad15caf`"; current HEAD is `e1cb168`. Per the file's own defensive banner, this alone signals every number should be treated as suspect.
2. **Commit log block (§1) ends at `ad15caf`** — does not list `e1cb168`.
3. **§2's framing of "what is left" is now describing a scenario that no longer exists.** It says: *"One scenario remains, and it cannot be closed from here: `host-command-port` — 'No file left behind on the host.'"* That exact scenario text was replaced by three new scenarios in `e1cb168`. The underlying tradeoff (W6) is still substantively accurate, but the sentence describing *why* archival is blocked now refers to spec text that no longer exists.
4. **A pre-existing internal inconsistency, independent of `e1cb168`, found this run**: §1's own table states "Verify | **21/23** requirements fully compliant" — but the verify-report.md linked from this same handoff, pinned to the same commit `ad15caf`, reports **22/23**, and §2's own prose two paragraphs later correctly says "22/23 requirements, 36/37 scenarios." The table cell was never updated to match either the linked report or the file's own later prose — this is a staleness that predates `e1cb168` and was not caught by the prior two verify passes.

**This is now the file's third documented staleness episode** — closed once at `949caab`, reopened by `cf77550`+`ad15caf`, "closed" a second time in framing but never actually fixed for the `21/23` table cell, and now stale a third time relative to `e1cb168`. Nothing in the build, test, or verify pipeline reads this file; only a human — or a verify pass — catches it. Recommend a text fix as part of any handoff after this run, with explicit attention to the §1 table cell in addition to the pinned commit and commit log.

---

### Updated Counts (whole change, all 6 domains, current spec text)

| | Prior run (`ad15caf`, rejected by dispatcher) | This run (`e1cb168`) |
|---|---|---|
| Requirements total | 23 | **23** (unchanged) |
| Requirements fully compliant | 22/23 | **22/23** (unchanged in count, different requirement composition: "Script Delivery With Zero Host Footprint" was not-fully-compliant before for one reason — 1 untested scenario of 2 — and remains not-fully-compliant now for a different reason — 2 not-✅ scenarios of 4) |
| Scenarios total | 37 (rejected — actual was 39) | **39** (confirmed: 7+6+10+6+7+3 across the six domains, recounted directly from spec text) |
| Scenarios ✅ COMPLIANT | 36/37 | **37/39** |
| Scenarios ⚠️ PARTIAL | 0/37 | **1/39** (new: "No command is invoked...") |
| Scenarios ❌ UNTESTED | 1/37 ("No file left behind on the host" — structurally untestable) | **1/39** ("Detection is independent of relocatable paths" — closable, not structural) |

---

### Issues Found

**CRITICAL**:
- **C2 (new)** — `host-command-port`'s "Detection is independent of relocatable paths" scenario has zero covering test in this suite. Closable in-harness; not structurally blocked like the scenario it replaced. See detail above.

**WARNING** (carried forward, owner has seen W1–W4, no change requested):
- **W2** — `HostDiagnostics` has no production call site. Blocks archive: No.
- **W3** — the agent-state surface has no caller outside its own tests. Blocks archive: No.
- **W4** — `first_time_setup_screen.dart:92` bypasses the mirroring helper. Blocks archive: No.
- **W5 (recurred a third time, plus a newly found pre-existing internal inconsistency)** — `HANDOFF.md` is stale at current HEAD; see full detail above. Blocks archive: No.
- **W6** — the zero-footprint guarantee's fail-open branch is a narrow, disclosed exception, now written directly into the amended spec text (an improvement over living only in this verify report). Blocks archive: No.

**SUGGESTION**: unchanged from prior report (S1, S2, and the sealed three-state-result suggestion for `_tmux_server_running()` — cosmetic, not a spec violation).

### Verdict

**FAIL**

22/23 requirements fully compliant, 37/39 scenarios ✅ COMPLIANT (1 ⚠️ PARTIAL, 1 ❌ UNTESTED), 0 blockers, 1 CRITICAL finding (a closable test gap, not a product defect). The amendment at `e1cb168` is judged legitimate on all four posed questions — the requirement is not hollowed out, the fail-open exception is honestly disclosed rather than laundered, and the behavior did not change (confirmed by diff, not by trusting the commit message) — but the amendment's own new scenario set is not fully covered: one of the three new scenarios ("Detection is independent of relocatable paths") currently holds only by the same kind of code-inspection reasoning this project's own `HANDOFF.md` §8 already found to be wrong once, for this exact requirement.

### Ready to Archive

**Not unconditionally — and the blocking condition has changed in kind, not just count, since the prior run.**

What's true: tasks are 100/100 complete, `flutter analyze` is clean, all 250 tests pass, C1 and W1 remain closed, the amendment is legitimate and did not weaken behavior (confirmed by diff), and the fail-open exception (W6) is now honestly documented in the spec itself rather than only in a verify report.

What's not true: a clean pass still isn't reached — and unlike the prior two verify passes, the remaining gap is no longer "provably impossible to test in this harness." One new scenario ("Detection is independent of relocatable paths") has zero test coverage and, unlike the scenario it replaced, **can be closed with a sixth test in this exact suite** — no live host required, following the identical pattern already established by the five existing gate tests. The "no command is invoked" scenario is also only partially covered (branch logic tested; invocation and record-identity claims are not).

**Recommendation, distinct from the disclosed W1–W6 limitations**: before treating this domain as closed, either (a) add the closable test for path-independence and strengthen the "no command invoked" test to assert non-invocation directly (e.g., stub `TMUX_ABS` with a marker script and assert it was never executed), or (b) have the repository owner explicitly accept these two as disclosed gaps the same way W1–W6 already are. Option (a) is available and inexpensive in this harness; option (b) is a legitimate policy choice but should be made deliberately, the same way every other disclosed gap in this change already was, not left implicit.

**Also recommend, independent of the above**: fix `HANDOFF.md`'s renewed staleness (W5) — now a third episode, plus the pre-existing `21/23`-vs-`22/23` internal table/prose inconsistency found this run, both caught only by verify, never by the build/test pipeline itself.
