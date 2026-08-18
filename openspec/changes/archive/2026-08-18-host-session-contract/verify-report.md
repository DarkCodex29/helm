```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:722029a7a9a7093108ec19deb1ee3aa72cf1b1f9000000000000000000000000
verdict: pass_with_warnings
blockers: 0
critical_findings: 0
requirements: 23/23
scenarios: 39/39
test_command: flutter test
test_exit_code: 0
test_output_hash: sha256:79fa1a8ee00f154b2f13ecbf94a26edc915218389f59e37fe60541c0519898dc
build_command: flutter analyze
build_exit_code: 0
build_output_hash: sha256:707f8674efb72f5060a17ce78be9d2533f82b384040b57b36f1ccc0ac0644077
```

## Verification Report

**Change**: host-session-contract
**Version**: N/A (first version, `openspec/specs/` was empty before this change)
**Mode**: Strict TDD
**Re-run context**: fifth verify pass, and the confirmation run this project's `HANDOFF.md` and the native dispatcher were both explicitly waiting on. HEAD at this run: `722029a7a9a7093108ec19deb1ee3aa72cf1b1f9`. Working tree clean. Two commits landed since the prior verify report (pinned to `e1cb1686a4f4c0ccf23123867b52d214ff09d51b`): `7e90562` (five new tests) and `722029a` (docs only). `git diff --stat e1cb168 722029a -- lib/ test/` touches exactly one file, `test/core/host/probe/probe_script_v1_tmux_gate_test.dart` (+285/-4 lines) — confirmed independently, not assumed from the commit message.

### Skill Resolution

`skill_resolution: paths-injected` — 5 skills loaded from the exact paths given in the launch prompt: `sdd-verify`, `testing`, `flutter`, `security`, `software-engineering`.

---

### Scenario-to-Test Mapping — the three `host-command-port` gate scenarios

| Scenario | Test(s) | Status |
|---|---|---|
| No command is invoked when there is nothing for it to report | `probe_script_v1_tmux_gate_test.dart`: 3 branch tests (2, 3, 4) **plus 2 new consequence tests** — "does not invoke tmux list-sessions when tmux is installed but no server is running" and "emits the same session-record stream (none) whether tmux is installed with no server or entirely absent" | ✅ **COMPLIANT** (upgraded from ⚠️ PARTIAL) |
| An undetectable server never becomes a silent absence | `probe_script_v1_tmux_gate_test.dart` test 5 ("fails OPEN... when ps is not available on PATH at all") | ✅ **COMPLIANT** (unchanged) |
| Detection is independent of relocatable paths | `probe_script_v1_tmux_gate_test.dart` **3 new tests**: TMUX_TMPDIR relocation + server running, TMUX_TMPDIR relocation + no server (with a real artifact on disk), and an explicit `-S`-style `TMUX` socket path + server running | ✅ **COMPLIANT** (upgraded from ❌ UNTESTED) |

**Net effect**: the prior run's sole CRITICAL finding (C2 — zero coverage on the path-independence scenario) and its sole ⚠️ PARTIAL (non-invocation/record-identity not directly asserted) are both closed. 39/39 scenarios now ✅ COMPLIANT, 0 ⚠️ PARTIAL, 0 ❌ UNTESTED.

---

### Verdict on the four posed questions

**1. Are GAP1's three scenarios (test cases) now genuinely covered?**

Yes, and independently re-verified rather than accepted from the docstring. All three new tests (6, 7, 8) run through `_runGate`, which extracts `_tmux_server_running()` as a **byte-for-byte substring of the real `probeScriptV1`** via `_extractTmuxGatePrelude()` (`indexOf` on the literal marker `_tmux_server_running() {`, substring to the matching close-brace) — the same extraction technique the suite already used for `_esc()`, and one that throws `StateError` if the marker ever goes missing, so it cannot silently drift from the real script. This is the real script's logic under a real `/bin/sh`, not a reimplementation the test also wrote.

The three tests are not vacuous. The extracted gate function contains **no reference at all** to `TMUX_TMPDIR` or `TMUX` (confirmed by reading `probe_script_v1.dart:83-105` directly) — it reads only `ps -u "$(id -un)" -o comm=`. Test 7 is the meaningful one: it places a **real relocated socket artifact on disk** (`tmux-9999/default` under a fake `TMUX_TMPDIR`) with a `ps` fake reporting no server, and asserts `SERVER_NOT_RUNNING`. If a future change accidentally started checking for artifact presence at the relocated path instead of process state, this test would fail. That is a genuine regression guard, not a tautology.

I independently confirmed the isolation claim underpinning why `ps` must still be faked rather than run against a real local tmux server: this dev machine's real `tmux`/`zellij` live at `/opt/homebrew/bin`, not `/usr/bin` or `/bin` (`command -v tmux` → `/opt/homebrew/bin/tmux`; `/usr/bin/tmux` and `/bin/tmux` do not exist) — so the disclosed reasoning ("macOS's `ps` reports only `tmux`, not `tmux: server`") is not just asserted, it is the actual reason a live-tmux test would be unsound here, verified directly.

One scope caveat, not a gap: the scenario's second THEN clause ("a host with real sessions MUST still have them enumerated") is proven only at the gate-decision level (the `if` condition that gates the `list-sessions` call), not by asserting actual enumerated session content under a relocated path. That is a reasonable, structurally justified boundary — once the gate returns true, `list-sessions` is invoked unconditionally against `$TMUX_ABS`, and correctly reading a relocated socket from there is `tmux`'s own binary responsibility (inherited environment), not probe-script logic. Noted as a caveat, not downgraded.

**Verdict: genuinely covered, exercising the real extracted script logic, with a meaningful regression guard, not the harness agreeing with itself.**

**2. Is GAP2 actually proven, or only better-argued?**

Proven. Both new tests use `_runFullProbe`, which runs the **complete, unmodified `probeScriptV1`** exactly as production delivers it: `Process.start('/bin/sh', ['-s'], ...)`, the full script text written to stdin, stdin closed, no PTY. I cross-checked this against the actual production caller, `SshHostCommandRunner.runScript` (`lib/core/host/ssh_host_command_runner.dart:55-60`): `client.execute('/bin/sh -s')`, `channel.stdin.add(utf8.encode(script))`, `channel.stdin.close()` — same command string, same stdin-then-close pattern, no `pty:` argument (so no PTY). The test harness's delivery model matches production, not an approximation of it.

Test 1 asserts `list-sessions` never appears among the fake `tmux`'s recorded invocations when `tmuxInstalled: true, tmuxServerRunning: false`. I confirmed this state is real, not asserted for free: with a fake `tmux` on `PATH`, `_probe_mux tmux tmux` finds it (`TMUX_FOUND=1`), still invokes it once for `--version` (correctly not covered by this assertion, which only forbids `list-sessions`), and the gate itself runs for real against the faked `ps`. Test 2 asserts the `session\t...`-prefixed stdout lines are empty and identical between "installed, idle" and "absent" — a state PATH curation makes genuine on this machine too (verified separately: this dev machine's real tmux/zellij are at `/opt/homebrew/bin`, outside the test's curated `<tempDir>:/usr/bin:/bin`).

**Verdict: proven by executing the real script under production's own delivery model, with an independently-confirmed fake `tmux` on `PATH` and a confirmed isolation boundary — not merely a stronger argument for the same untested claim.**

**3. Is the `session`-subset interpretation of "identical records" honest, or does it dodge the scenario?**

Honest, judged on merit rather than accepted from the test's own docstring. Read literally against the whole stdout, "identical records" is self-contradictory with the spec's own record taxonomy: the `mux` record for `tmux` is **supposed** to differ between "installed" and "absent" (`found=1` vs `found=0`, version string present vs empty) — that record's entire purpose, established by a separate part of the same script and already covered by unrelated tests, is to report install status. A literal whole-stdout reading would make the scenario permanently unsatisfiable by design, which cannot be the intended meaning. The scenario's own THEN clause already narrows scope first: "it MUST NOT invoke **that tool's query command**" — a specific operation (`list-sessions`), not general probing (`command -v`, `--version`). "The emitted records" in the following clause most naturally refers to records **produced by that query**, i.e. `session` records, not records produced by an unrelated, always-run operation. The `end` record's elapsed-ms exclusion is not interpretive at all — no test can assert byte-identical timing across two separate process runs; excluding it is a structural necessity, not a choice.

**Verdict: legitimate, non-dodging interpretation — consistent with, not evasive of, the scenario's own scoping.** One SUGGESTION, not a blocker: this scoping currently lives only in a test-file doc comment. The project already has a precedent for the stronger move (the W6 fail-open exception was written directly into the amended spec text rather than left in a verify report). The same treatment here — a short clause in `spec.md` scoping "the emitted records" to session records — would remove the need for a future reader to infer this from test comments.

**4. Does removing counts from `HANDOFF.md` fix the staleness, or just hide it — and independently, is the file accurate at current HEAD?**

**Partially fixes, and reintroduces a different-shaped staleness that is present right now, not eventually.** The four commands replacing the volatile numbers (`git log --oneline`, `flutter test`, `flutter analyze`, `gentle-ai sdd-status ... jq`) genuinely close the failure mode that broke this file three times before: a hardcoded count or commit list cannot drift if it is never written down. That part of the fix is real and structural, not cosmetic.

But the same commit's rewrite of §1's summary table and §2's prose asserts: **"Verify | 0 blockers, 0 CRITICAL across four runs"** and **"Four verify runs have landed, every one with 0 blockers and 0 CRITICAL."** This is false, and was false the moment `722029a` was committed — not eventually, not due to drift. The fourth verify report (`verify-report.md` at that time, still readable at `e1cb1686a4f4c0ccf23123867b52d214ff09d51b` in git history) has `critical_findings: 1` in its own YAML envelope and explicitly names it: **"C2 (new CRITICAL) — 'Detection is independent of relocatable paths' scenario has zero covering test."** `HANDOFF.md`'s own "Verify findings carried forward" list (§2) enumerates C1, W1, W5, W6 — **C2 does not appear anywhere in the rewritten file.** This is not a number that will go stale later; it is a categorical claim about verification history that was wrong at the instant it was written, describing a report sitting in the same repository.

This matters structurally, not just as a one-off error: none of the four replacement commands would ever surface this to a reader. `git log` shows commits, not verify findings. `flutter test`/`flutter analyze` say nothing about a prior run's severity classification. `gentle-ai sdd-status --json` reports `nextRecommended`/`blockedReasons` for the *current* evidence revision, not a historical tally of "how many CRITICAL findings has this change ever had." The fix converted "state that predictably drifts with new commits" into "state that can be wrong on day one with no command that catches it" — a narrower blast radius (one summary line vs. every count in the file) but not a categorically solved problem.

**Verdict: the fix is real for numeric/positional staleness and should be kept. It does not fix, and in this instance currently manifests, narrative/historical-accuracy staleness — a new instance of the same underlying discipline problem (a claim nothing in the pipeline checks), not the identical bug recurring in the identical shape.**

---

### Completeness

| Metric | Value |
|--------|-------|
| Tasks total | 100 |
| Tasks complete | 100 |
| Tasks incomplete | 0 |

Confirmed by direct grep at HEAD: `- [x]` count 100, `- [ ]` count 0 (zero matches, `rg` exit code 1).

### Build & Tests Execution

**Build**: ✅ Passed

```text
$ flutter analyze
Analyzing helm...
No issues found! (ran in 1.3s)
```

Exit code 0. SHA-256: `707f8674efb72f5060a17ce78be9d2533f82b384040b57b36f1ccc0ac0644077`

**Tests**: ✅ 255 passed / 0 failed / 0 skipped (up from 250 in the prior report — exactly the 5 new tests added by `7e90562`)

```text
$ flutter test
00:00 +0: loading .../test/core/host/session_reference_test.dart
...
00:02 +250: .../probe_script_v1_tmux_gate_test.dart: tmux server detection gate (_tmux_server_running) still reports a running server when TMUX_TMPDIR relocates the socket directory away from its default, with a matching relocated socket artifact physically present on disk at that location
00:02 +251: .../probe_script_v1_tmux_gate_test.dart: tmux server detection gate (_tmux_server_running) still reports no running server when TMUX_TMPDIR relocates the socket directory away from its default, even though a relocated socket artifact exists on disk with no matching process -- proves the decision reads process state, never the filesystem at that path
00:02 +252: .../probe_script_v1_tmux_gate_test.dart: tmux server detection gate (_tmux_server_running) still reports a running server when an explicit -S-style client socket path is set via TMUX, pointing at a location outside any default or TMUX_TMPDIR-relocated directory
00:02 +253: .../probe_script_v1_tmux_gate_test.dart: no command is invoked when there is nothing to report does not invoke tmux list-sessions when tmux is installed but no server is running
00:03 +254: .../probe_script_v1_tmux_gate_test.dart: no command is invoked when there is nothing to report emits the same session-record stream (none) whether tmux is installed with no server or entirely absent from the host
00:03 +255: All tests passed!
```

Exit code 0. SHA-256: `79fa1a8ee00f154b2f13ecbf94a26edc915218389f59e37fe60541c0519898dc`

**Coverage**: not run (unchanged from all prior reports; not part of `sdd/helm/testing-capabilities`).

---

### Spec Compliance Matrix (all 6 domains, 23 requirements / 39 scenarios)

#### Domain: host-command-port (3 requirements / 7 scenarios) — the only domain re-derived this run

| Requirement | Scenario | Test | Result |
|---|---|---|---|
| Single-Command Execution | Command completes successfully | `ssh_host_command_runner_test.dart` | ✅ COMPLIANT |
| Single-Command Execution | Command exceeds the configured timeout | `ssh_host_command_runner_test.dart` | ✅ COMPLIANT |
| Script Delivery With Zero Host Footprint | Script delivered over stdin, no pseudo-terminal | `ssh_host_command_runner_test.dart` | ✅ COMPLIANT |
| Script Delivery With Zero Host Footprint | No command is invoked when there is nothing for it to report | `probe_script_v1_tmux_gate_test.dart` (tests 2,3,4 + 2 new) | ✅ COMPLIANT (upgraded) |
| Script Delivery With Zero Host Footprint | An undetectable server never becomes a silent absence | `probe_script_v1_tmux_gate_test.dart` (test 5) | ✅ COMPLIANT |
| Script Delivery With Zero Host Footprint | Detection is independent of relocatable paths | `probe_script_v1_tmux_gate_test.dart` (3 new tests) | ✅ COMPLIANT (upgraded) |
| Swappable Transport Implementations | Scripted stand-in satisfies the same contract | `fake_host_command_runner_test.dart` | ✅ COMPLIANT |

**Requirement-level**: all 3/3 requirements in this domain now fully compliant (was 2/3).

#### The other 5 domains — carried forward, confirmed unchanged for the third consecutive run

`git diff --stat 92903ae..722029a -- lib/ test/` touches exactly 3 files: `lib/core/host/probe/probe_script_v1.dart`, `test/core/host/probe/probe_script_v1_test.dart`, `test/core/host/probe/probe_script_v1_tmux_gate_test.dart` — all already accounted for above or in prior reports. Nothing in these 5 domains changed.

| Domain | Requirements | Scenarios | Status |
|---|---|---|---|
| host-diagnostics | 4/4 fully compliant | 6/6 ✅ | unchanged |
| host-probe-contract | 6/6 fully compliant | 10/10 ✅ | unchanged |
| multiplexer-abstraction | 3/3 fully compliant | 6/6 ✅ | unchanged |
| session-attach | 4/4 fully compliant | 7/7 ✅ | unchanged |
| session-reference-storage | 3/3 fully compliant | 3/3 ✅ | unchanged |

**Compliance summary**: 39/39 scenarios ✅ COMPLIANT. 23/23 requirements fully compliant.

### Correctness (Static Evidence)

Unchanged from prior report for the 5 untouched domains. For `host-command-port`'s amended requirement: `_tmux_server_running()` (`probe_script_v1.dart:83-105`) is name-based, references no path variable — confirmed by direct read and now backed by runtime regression tests (GAP1) that would fail if that changed. The full-script `if [ "$TMUX_FOUND" = "1" ] && _tmux_server_running; then ... fi` gate (line 107) correctly wires detection to invocation — confirmed by direct read and now backed by the GAP2 non-invocation/record-identity tests running the real script end-to-end.

### Coherence (Design)

Unchanged from prior report. The house convention ("never return an empty collection or bare boolean where 'could not determine' is possible") is followed in spirit but not the letter by `_tmux_server_running()`'s boolean return — carried forward as a SUGGESTION, not a new finding.

---

### C1, W1–W6 Status

| ID | Status | Blocks archive |
|---|---|---|
| C1 — Attach exit status classification | **CLOSED**, unaffected this run (`git diff --stat 92903ae..722029a -- lib/ test/` touches only the three probe files above) | No |
| W1 — encoder-side `_esc()` never executed | **CLOSED** at `cf77550`, unaffected this run | No |
| W2 — `HostDiagnostics` has no production call site | Owner-accepted, not re-litigated this run | No — owner-accepted |
| W3 — agent-state surface has no external caller | Owner-accepted, not re-litigated this run | No — owner-accepted |
| W4 — `first_time_setup_screen.dart:92` bypasses the mirroring helper | Owner-accepted, not re-litigated this run | No — owner-accepted, pre-existing, outside migration scope |
| W5 — `HANDOFF.md` staleness | **Numeric-drift form CLOSED** by `722029a`'s structural fix. **Reopened in a new, narrower form**: the file's own rewritten summary ("0 blockers, 0 CRITICAL across four runs") is false — the 4th run's report records `critical_findings: 1` (C2) and C2 is absent from the file's own findings list. See Q4 above. | No (per `sdd-status-contract.md`, archive readiness tracks task/verify completion, not handoff-document accuracy) |
| W6 — zero-footprint fail-open exception | Unchanged, not re-litigated this run | No — narrow, disclosed, low-harm, written into spec text |

---

### `HANDOFF.md` accuracy at current HEAD (`722029a`)

**Structurally improved, not accurate.** The commit-log and count sections are now genuinely resistant to drift — they instruct the reader to run live commands instead of reading stale numbers, which directly fixes the specific failure mode that broke this file three times ("first written before slice 6 landed... corrected, two more commits landed, stale again"). That is a real and useful improvement; keep it.

But it is not accurate right now: §1's table and §2's prose both assert "0 blockers, 0 CRITICAL across four runs," and this is false as of the commit that wrote it — the fourth verify report recorded exactly one CRITICAL finding (C2), and C2 does not appear in this file's own findings list at all. A reader trusting this file's "durable" claims (as opposed to the volatile numbers it deliberately stopped stating) would be misled about this change's verification history, and none of the four commands the file recommends running would catch it.

**Recommend** (non-blocking, since archive readiness does not track this file): correct the "0 blockers, 0 CRITICAL across four runs" claim to describe what actually happened — the 4th run found and disclosed one CRITICAL finding, closed by the 5th run's added tests — and add C2 to the findings-carried-forward list as closed, the same way C1, W1, and W6 are already tracked there.

---

### Updated Counts (whole change, all 6 domains, current spec text)

| | Prior run (`e1cb168`) | This run (`722029a`) |
|---|---|---|
| Requirements total | 23 | **23** (unchanged) |
| Requirements fully compliant | 22/23 | **23/23** |
| Scenarios total | 39 | **39** (unchanged; recounted directly: 7+6+10+6+7+3) |
| Scenarios ✅ COMPLIANT | 37/39 | **39/39** |
| Scenarios ⚠️ PARTIAL | 1/39 | **0/39** |
| Scenarios ❌ UNTESTED | 1/39 | **0/39** |

---

### Issues Found

**CRITICAL**: None.

**WARNING**:
- **W2** — `HostDiagnostics` has no production call site. Blocks archive: No. Owner-accepted, not re-litigated.
- **W3** — the agent-state surface has no caller outside its own tests. Blocks archive: No. Owner-accepted, not re-litigated.
- **W4** — `first_time_setup_screen.dart:92` bypasses the mirroring helper. Blocks archive: No. Owner-accepted, not re-litigated.
- **W5 (reopened in a new form)** — `HANDOFF.md`'s rewritten summary ("0 blockers, 0 CRITICAL across four runs") is currently false; C2 is missing from its own findings list. Blocks archive: No (per project policy). See Q4 detail above.
- **W6** — the zero-footprint guarantee's fail-open branch is a narrow, disclosed exception, written into the spec text. Blocks archive: No.

**SUGGESTION**:
- S1, S2 — carried forward unchanged from prior report (cosmetic; `_tmux_server_running()`'s sealed three-state-result suggestion and the other item already on record).
- **S3 (new)** — write the "session-record subset" scoping of "identical records" (host-command-port, "No command is invoked..." scenario) directly into `spec.md`, following the same precedent already set for W6's fail-open exception, rather than leaving it in a test-file doc comment.

### Verdict

**PASS WITH WARNINGS**

23/23 requirements fully compliant, 39/39 scenarios ✅ COMPLIANT, 0 blockers, 0 CRITICAL findings. Both scenarios flagged by the prior run — the untested path-independence scenario (C2) and the partially-covered non-invocation scenario — are now genuinely covered by tests that exercise the real, unmodified script under its real production delivery model, independently re-verified rather than accepted from their own docstrings. Five WARNING-level items remain, all non-blocking by this project's own stated policy: three are unchanged owner-accepted items (W2–W4), one is unchanged and already written into the spec (W6), and one (W5) is reopened in a narrower, different-shaped form — a documentation file's own historical-accuracy claim is currently false, though it does not affect requirement/scenario compliance or the build/test evidence.

### Ready to Archive

**Yes.**

Tasks are 100/100 complete, `flutter analyze` is clean, all 255 tests pass, C1/W1 remain closed, and — the specific condition the native dispatcher named as blocking (`critical_findings must be zero for archive readiness`) — this run's evidence shows `critical_findings: 0`, `blockers: 0`, `requirements: 23/23`, `scenarios: 39/39`. Both remaining gaps from the prior run were closed with tests, not with argument or a scope reduction: GAP1's three tests exercise the real, byte-extracted `_tmux_server_running()` under a real shell with a genuine on-disk regression artifact; GAP2's two tests run the complete, unmodified probe script exactly as `SshHostCommandRunner.runScript` delivers it in production, independently cross-checked against that production code rather than trusted from the test's own comments.

The only open item is `HANDOFF.md`'s own currently-false "0 CRITICAL across four runs" claim (W5, reopened) — a documentation-accuracy issue this project's own conventions already exclude from the archive gate, but one the owner should still correct given this exact file has now gone stale in some form across five consecutive verify runs.
