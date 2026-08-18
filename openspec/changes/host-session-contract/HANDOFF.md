# Handoff — host-session-contract

Rewritten 2026-08-18, updated after slice 6 and the verify cycle. Read this first when resuming.

> **Keeping this accurate is part of the work, and it has gone stale twice.** First it was written before slice 6 landed and still called slice 6 untouched. Then it was corrected, two more commits landed, and it was stale again — `sdd-verify` caught both, because nothing in the build, test or verify pipeline reads this file. Only a human keeps it honest.
>
> **The snapshot below is pinned to a commit for exactly that reason.** If `git rev-parse --short HEAD` does not match it, treat every number here as suspect and cross-check `tasks.md` and `git log`. Silent staleness is the failure mode; a visible mismatch is the defence.

---

## 1. Snapshot — describes commit `ad15caf`

| | |
|---|---|
| Implementation | **complete** — all 10 slice units (1, 2, 3a, 3b, 4, 5a, 5b, 5c, 6, 7) |
| Tasks | **100 of 100** |
| Commits for this change | 24 |
| Test suite | 39 → **250**, all green |
| `flutter analyze` | clean |
| Working tree | clean |
| Branch | `main` |
| Verify | 21/23 requirements fully compliant, **0 blockers, 0 CRITICAL** |
| Archive | **not yet** — see §2 |

```
68dbe36  fix(ssh): verify host keys with trust-on-first-use
65d7791  docs(sdd): plan host-session-contract change
1e41c31  feat(host): add HostCommandRunner port and dartssh2 adapter          # 1a
0c76ede  refactor(shortcuts): run remote FS commands through HostCommandRunner # 1b
631e23a  feat(host): add the v1 host probe script and wire contract doc        # 2a
6ce3e3d  feat(host): parse host probe output into a report model               # 2b
55966bf  feat(host): add MultiplexerAdapter with a tmux implementation         # 3a
2da0180  feat(host): add a zellij multiplexer implementation                   # 3b
0fe623c  feat(host): add a herdr multiplexer adapter with agent-state support   # 4
a2a0e31  test(terminal): characterize TerminalSession connect, reconnect, ...   # 5a
dd33c8b  fix(terminal): attach via exec-with-pty and close the abandoned shell  # 5b
ce7cbc1  feat(ssh): classify PTY denial with a dedicated actionable message     # 5c
f3d6d08  feat(host): report linger and Tailscale host problems without fixing   # 7
e274fa9  docs(sdd): rewrite the host-session-contract handoff
ea6f7e1  feat(connection): add a neutral session reference to ConnectionProfile  # 6a
cb523eb  feat(shortcuts): add a neutral session reference to ProjectShortcut     # 6b
e99313a  feat(terminal): add a neutral session reference to TabSnapshot          # 6c
5a8adc2  feat(host): mirror the session reference into the legacy field          # 6d
c0f2af2  refactor(terminal): delete the superseded TmuxService                   # 3a.12
3f7db57  fix(terminal): report what the attach session's exit status says        # C1
92903ae  docs(sdd): correct the attach exit status requirement to match reality
949caab  docs(sdd): bring the handoff back in line with what actually shipped
cf77550  test(host-probe): run the real escaping function under a real shell   # W1
ad15caf  fix(host-probe): stop tmux enumeration creating a socket directory     # footprint
```

---

## 2. What is left

Implementation is done. What remains is a decision, not code.

Three verify runs have landed. The latest reports **22/23 requirements, 36/37 scenarios, 0 blockers, 0 CRITICAL** — and still a `fail` verdict, because `gentle-ai sdd-verify-validate` refuses a `pass` whenever completed requirements or scenarios are below total, regardless of severity. That is a schema property, not a defect.

**One scenario remains, and it cannot be closed from here**: `host-command-port` — *"No file left behind on the host."* Satisfying it in the completeness accounting needs an automated assertion about a **remote host's filesystem**, which a Flutter test harness structurally cannot make.

It is, however, now **true and measured** rather than merely asserted — see §8, because getting there disproved the previous answer.

So the remaining choice is only: archive with that single gap recorded as a standing, disclosed limitation, or invest in an integration harness that can assert against a live host.

### Verify findings carried forward

- **C1** — closed at `3f7db57` plus the spec amendment at `92903ae`
- **W1** — closed at `cf77550`: the probe's shell-side `_esc()` encoder now runs under a real `/bin/sh`, extracted byte-for-byte from the script constant
- **W5** — the staleness of this very file. Closed once at `949caab`, then reopened by the two commits after it. Pinning the snapshot to a commit is the attempt to stop that recurring.
- **W6** — the footprint gate **fails open** when its detection tool is unavailable: it enumerates anyway and may then create the socket directory. A deliberate tradeoff, since silently reporting zero sessions on a host that has them is far worse than an empty directory — but it is a real, narrow exception to the spec's unconditional wording, not a non-issue.

### Verify findings carried forward, all accepted by the owner

- **W1** — the probe script's `_esc()` encoder is never executed by a test (the gap above)
- **W2** — `HostDiagnostics` has **no production call site**. Every unit requirement passes; nothing surfaces it to a user.
- **W3** — the agent-state surface (`AgentSupport.resolve`, `HerdrAdapter.agents`) likewise has no caller outside its own tests.
- **W4** — a fourth `ConnectionProfile` write path at `first_time_setup_screen.dart:92` bypasses the mirroring helper. Not a spec violation — both keys are still emitted and the read-side fallback covers it — but task 6.15's "every write path" audit covered three of at least four construction sites.

**W2 and W3 together are the honest summary of what this change is**: a contract layer, built and tested, whose consumers are future work. The plumbing is in; the faucet is not connected. No task in the plan asked for that wiring. Decide it deliberately rather than discovering it later.

---

## 3. Session settings (cached — do not re-ask)

| Setting | Value |
|---|---|
| Execution mode | `auto` |
| Artifact store | `both` (OpenSpec files + Engram) |
| Delivery strategy | `auto-chain` |
| Chain strategy | `stacked-to-main` |
| Review budget | **400 lines of PRODUCTION code only** |

Tests travel with their production code and never count against the ceiling. Apply agents must report line counts **split production/test**; a combined total is not actionable and gets rejected.

The repository owner decides **every** commit boundary. Apply agents never commit.

---

## 4. Locked product decisions

1. **Language-neutral wire contract, not a Dart package.** The second consumer (`../web-estimaciones/estimaciones-app`) is Next.js + TypeScript.
2. **No portal integration layer.** Explicit non-goal.
3. **Linux only.**
4. **herdr is first-class.** Agent state is an optional advertised capability via a nullable sub-interface. tmux and zellij are degraded implementations.
5. **Probe delivery: heredoc per connection, zero host footprint.**
6. **Probe enumerates all three multiplexers.**
7. **Migration adds a neutral field with a back-compat reader** and does not delete the legacy key.

### Explicitly out of scope

- Detecting whether the current shell is already inside a multiplexer. Proven unsatisfiable: the probe runs in a fresh shell that is never inside one.
- macOS host support.
- Any portal, remote-job, multi-tenancy, identity, or audit surface.

---

## 5. Slice status

| # | Slice | Tasks | Status |
|---|---|---|---|
| 1 | `HostCommandRunner` port + dartssh2 adapter + fake | 12/12 | ✅ 2 commits |
| 2 | Probe script + parser + `HostReport` + contract doc | 22/22 | ✅ 2 commits |
| 3a | `MultiplexerAdapter` + capabilities + `TmuxAdapter` | 14/14 | ✅ 1 commit (+ `3a.12` closed later, `c0f2af2`) |
| 3b | `ZellijAdapter` | 5/5 | ✅ 1 commit |
| 4 | `HerdrAdapter` + agent-state capability | 8/8 | ✅ 1 commit |
| 5a | `TerminalSession` characterization tests | 2/2 | ✅ 1 commit, 0 production lines |
| 5b | Exec-with-PTY attach + abandoned-shell close | 2/2 | ✅ 1 commit |
| 5c | PTY-denied classification + regression guards | 7/7 | ✅ 1 commit |
| 6 | Persisted-model migration | 17/17 | ✅ 4 commits — **was the only irreversible slice** |
| 7 | Diagnostics: linger / `KillUserProcesses` + Tailscale | 11/11 | ✅ 1 commit |
| C1 | Attach exit status classification (verify remediation) | — | ✅ 1 commit + spec amendment |

Both slice 4 and slice 5b **failed their orchestrator gate on the first attempt with a fully green harness**, and were corrected on the second. See §8.

---

## 6. The host: a real herdr box now exists

The Contabo VPS is the always-on Linux host this change targets. Verified 2026-08-18:

| | |
|---|---|
| Access | `ssh contabo` → `deployer@158.220.106.131`, sudo NOPASSWD |
| OS | Ubuntu 24.04.4 LTS, kernel 6.8.0-136 |
| Uptime | weeks — genuinely always-on |
| `Linger` | **`yes`**, already enabled for `deployer` |
| `KillUserProcesses` | `#KillUserProcesses=no` — commented, compiled-in default |
| `systemctl --user` | `running` |
| Multiplexers | tmux `/usr/bin/tmux`, **herdr 0.8.0** at `~/.local/bin/herdr`; no zellij |
| Tailscale | **not installed** |

**It is production**: 58 containers, 7 live services, and a `docker volume prune` once destroyed a live database there. Anything done on it must stay userland under `deployer` — no root, no Docker, no ports, no Traefik. herdr was installed exactly that way: one 21.7MB binary, nothing else, no server started, no `~/.config/herdr` created.

`~/.local/bin` is **not** on a non-interactive SSH shell's PATH. That is the exact failure mode the probe repairs, confirmed live.

---

## 7. Verified technical findings — do not re-derive these

### herdr 0.8.0 (protocol 19, schema_version 1)

The contract came from the binary's own bundled schema: `herdr api schema --json` (251KB). Not documentation.

- **The CLI is a thin JSON shim over a unix socket API** — its own `--help` says every subcommand is a "helper over the socket API".
- Success envelope `{id, result}`; `agent list` result is `{type, agents: AgentInfo[]}`.
- Error envelope `{id, error: {code, message}}` — `code` is a string and is **always present**.
- `AgentInfo` **required**: `terminal_id`, `agent_status`, `workspace_id`, `tab_id`, `pane_id`, `focused`, `revision`. `name`, `title`, `cwd`, `agent` are **optional** — never assume a name exists.
- **Two distinct state types, not a docs contradiction**: `AgentStatus` = `idle, working, blocked, done, unknown` (5, agent-level rollup); `PaneAgentState` = `idle, working, blocked, unknown` (4, pane-level detection). `done` means "finished and you have not looked at it yet" — seen/unseen bookkeeping a pane cannot know. Map `AgentStatus`.
- **No server**: exit 1, stdout empty, stderr `{"error":{"code":"server_not_running", ...}}`. Match the code, never the exit status.
- **`session list --json` is asymmetric with `agent list` and this is the trap.** `session list` is a **local** operation reading the session directory — it returns `session_dir` and `socket_path`, uses a **bare `{sessions:[...]}` envelope with no `result` key**, and **exits 0 even with no server**. `agent list` is a socket call. Parsing one by analogy to the other decodes a key that is not there.
- Per-session liveness is the `running` boolean. There is **no** `status: active|exited` field.
- `herdr status` / `herdr status server` work with **no server**, exit 0, plain `key: value` text, not JSON. Better for `detect()` than `agent list`.
- Socket lives at `~/.config/herdr/herdr.sock` — under the config dir, **not** `$TMPDIR`. The zellij `$TMPDIR` hazard does not apply.
- Exists but unverified, left for later: `herdr agent wait`, `herdr agent explain`, `herdr api snapshot`, `herdr --remote <ssh-target>`, `herdr session attach|stop|delete`.

### dartssh2 2.16.0

- `SSHClient.execute(cmd, pty:)` sends the **pty-req before the exec request** and returns the same `SSHSession` type as `shell()`, so `_bridgeIO` works unchanged across both. This is what makes exec-with-PTY attach possible.
- **It cannot be faked from outside the package.** `_openSessionChannel` needs a live authenticated connection and `SSHSession`'s internals are library-private.
- **`SSHSocket` is a genuinely public, exported, swappable interface. `SSHSession` has no public constructor at all** outside a live connection. That asymmetry decides whether a fake needs a production seam.
- Channels from `shell()` and `execute()` are **fully independent** — each gets its own id from `_channelIdAllocator` and its own controller, and `close()` only ever touches that channel's own EOF/close state. Closing one cannot disturb the client or another channel.
- **`SSHSession.close()` is `void`, not `Future<void>`**, and delegates to an `async` method with **no `await`** in its body. Any close-time exception is captured into a discarded Future and never reaches the caller synchronously. **A `try/catch` around it catches nothing** — do not write one.
- **Never throw from `onVerifyHostKey`.** The library routes the error to `closeWithError` typed `(SSHError, …)`; a non-`SSHError` triggers a `TypeError` inside the handler, the `done` completer never completes, and the connection **hangs instead of failing**. Return `false`.
- A rejected host key surfaces as `SSHAuthAbortError`, which implements `SSHAuthError`. **This is why the `HostKeyMismatchException` branch must stay first** in `describeError` — below the auth branch, a man-in-the-middle would be reported as a wrong password.
- **`SSHChannelRequestError` implements `SSHError`**, so a denied PTY was *mis*classified into the generic branch, not left unclassified. The fix is a branch **before** the generic one.
- dartssh2 **reuses `SSHChannelRequestError` for five different failures** — `'Failed to start pty'`, `'Failed to request agent forwarding'`, `'Failed to request x11 forwarding'`, `'Failed to execute'`, `'Failed to start shell'`. Discriminate by **exact message equality**, never by type alone. The literal is pinned by `pubspec.lock` with no semver contract, so it lives in one named constant.

### Probe and wire format

- `execute('/bin/sh -s')` with the script on **stdin**, then close stdin. **No PTY.** Passing the script as the command string fails because sshd runs it as `$SHELL -c` with the user's login shell, and fish/csh cannot parse POSIX. No PTY because the tty echoes stdin into stdout and corrupts the stream.
- Delimited records, **not JSON**: a JSON escaper in POSIX `sh` loses the whole document on one bad byte; a delimited stream loses one record. **This applies to records the shell generates — not to herdr's own JSON**, which is parsed with `dart:convert` in Dart.
- Evolution: unknown `kind` → skip; extra trailing fields → ignore; missing `end` → **truncated**, never "no sessions"; `helm-probe/2` → refuse.
- **PATH is the real failure mode and a PTY does not fix it.** The probe repairs `PATH` itself and reports both the inherited PATH and the resolved absolute path, so `found=1, on_inherited_path=0` reads as "installed at X but off your non-interactive PATH" instead of the lie "not found".
- Probe v1 emits only `env`/`mux`/`session` (tmux only). **It does not return zellij or herdr sessions**, and emits no `agent` or `diag` records.

### Diagnostics (slice 7)

- `loginctl show-user <user> --property=Linger` → single `Linger=yes` line, exit 0. Clean.
- **`systemctl show systemd-logind --property=KillUserProcesses` returns EMPTY output with exit 0** on a real host. Success with no signal, which is not a value. Absence is never evidence of a negative answer.
- The setting normally sits **commented out** in `logind.conf` as a compiled-in default, so an unanchored grep misreads it. Anchor on an uncommented line.
- **An unprivileged user cannot see the owning process of port 22** — `ss -tlnp` shows the listener with no process name. Detecting "tailscaled owns port 22" that way silently never fires. It was rejected for exactly that reason.
- The Tailscale preference read is **unverified**: Tailscale is not installed on the measured host. An unreadable preference maps to `unknown`, never `ok`.

### Codebase facts

- `openspec/specs/` is empty, so all six capabilities in this change are new.
- The tmux coupling spanned **10 hand-written + 4 generated files**, not 7.
- **House convention, enforced at every gate**: never return an empty collection or a bare boolean where "could not determine" is possible. Use a sealed result or an explicit unknown variant so the compiler forces the caller to handle it. **A thrown exception is not an acceptable substitute** — it is invisible to the type system, the same defect a boolean guard has.
- **`spec.md` wins over `design.md`.** Design interface sketches are non-normative pseudocode. Established four times: slice 3a's sealed `MuxSessionsResult`, slice 4's envelope asymmetry, slice 5b's leak, slice 7's data source.

---

## 8. What the gate caught, twice, with a green harness

Both failures passed `flutter analyze` and the full test suite before being caught. Neither was found by tests.

**Slice 4 — the fake encoded the same wrong assumption as the code.** The apply agent assumed `herdr session list --json` returned the same socket envelope as `agent list`, wrote the fake that way, and 146 tests went green against its own invention. Real output has no `result` key, so the parser threw a `TypeError` against real bytes.

> A fake written by the same agent that writes the implementation cannot falsify the assumption both share. They inherit the same error. Running the real command for thirty seconds broke the tie.

**Slice 5b — a real defect was disclosed but misattributed as unavoidable.** Moving the attach to exec left the shell from `connectAndOpenShell` abandoned unclosed, leaking an orphan remote login shell per connection, and `reconnect()` compounded it. It was reported as "an unavoidable consequence of the scope boundary". It was not: `result.session` sits in local scope in the very file being edited.

> Disclosing a defect honestly is necessary but not sufficient. A defect filed as "unavoidable, flagging for awareness" is a defect that ships. Audit the framing, not just the disclosure.

**And a third, caught by verify rather than by the gate — the spec itself was wrong.** `session-attach` required that a detach be distinguishable from the session being killed, through the exit status. Nothing implemented it, and when it finally was, real tmux 3.6a and zellij 0.44.3 were measured: both exit `0` for a detach **and** for the session being killed while the server survives. Zellij gives no distinguishing signal on any observable channel. Only the whole server dying differs (tmux: `1`).

> The requirement was not badly written. It rested on an assumption about tmux that nobody had tested, and that is false. A spec can be the thing that is wrong, and only measurement finds out.

The clause was removed and the measurement recorded inside the requirement so it is not reintroduced by someone reasoning from the same untested assumption. The implementation reports three states instead — ambiguous clean end, verified abnormal end, unknown — rather than faking a binary it cannot honestly claim.

**And a fourth: "holds by inspection" was correct about the source and wrong about the behaviour.** Verify listed *"No file left behind on the host"* as untested but holding by inspection — and inspection was right, the script has no write primitive anywhere. Measured against a real host before amending the scenario, the probe turned out to leave an empty `/tmp/tmux-<uid>` behind every single run. Deleting it and re-running brought it straight back; `tmux list-sessions` alone was the culprit. tmux creates its per-UID socket directory the moment a client starts, with no server to talk to and even when the call then fails.

> The script does not write. It invokes tmux, and tmux writes. Reading the source proves how the source reads, not what the execution does. The intended next step had been to amend the scenario to say it held by inspection — which would have written a false promise into the contract with a straight face.

---

## 9. Known debt, with owners

- ~~Task 3a.12 — delete `tmux_service.dart`.~~ **Closed** at `c0f2af2`, once slice 5b moved the last tmux-attach path onto the adapter and a repo-wide grep confirmed the class was referenced nowhere but its own 88-line file.
- **`connectAndOpenShell` still opens a shell unconditionally**, including on the attach path where slice 5b immediately closes it again. The clean fix is not opening it at all — but **host-key mismatch detection is coupled to that shell open**: `onVerifyHostKey` only *captures* the mismatch into a local, and it is rethrown inside the `catch` wrapping `client.shell()`. Removing the shell without first relocating that rethrow risks **silently regressing the MITM fix from `68dbe36`**. `connectAndOpenShell` also has **zero test coverage**. Needs its own unit, characterization first.
- **`TerminalSession.dispose()` is not safe to call twice** — `statusNotifier.dispose()` has no guard, and the second call throws `FlutterError`. Pinned by a passing test, deliberately not fixed. Owner chose a separate follow-up.
- **`TerminalSession.reconnect()` can propagate an uncaught exception** — it constructs `SSHKeyService()` with no seam and awaits `getPrivateKey()` **outside** the try/catch that only wraps the later `connect()`. Pinned, not fixed. Same follow-up decision.
- **`test/helpers/fake_ssh_session.dart:21` imports `package:dartssh2/src/ssh_channel.dart`** — an unexported internal path, because `SSHSession` has no public constructor. It builds one permanently inert channel to satisfy the superclass; every member actually used is overridden. No semver contract; pinned by the lockfile, so a bump breaks the test build **visibly**. **Remove it when a later unit opens `SSHService` for injection.**
- **`_UnusedHostCommandRunner` in `terminal_session.dart`** is a throwing stub satisfying `TmuxAdapter`'s constructor, since `attachCommand` is pure and never calls the runner. **Replace it with the real runner once slice 6 lands the persisted multiplexer choice.**
- **TOFU host key pinning has a known limitation**, documented in `68dbe36`: dartssh2 exposes only an MD5 digest, so the pinned value is `SHA256(MD5(hostkey))`. It does not match `ssh-keygen -lf`, cannot be verified out of band, and its collision resistance is bounded by MD5. Needs an upstream change.
- **`removeHost()` exists and is tested but nothing calls it.** After a legitimate server rebuild the user is locked out with no in-app recovery. Highest-priority security follow-up.
- **`pubspec.yaml` still says "Remote Mac control"** while the decision is Linux-only.

---

## 10. How to resume

Every runtime-bearing apply goes through the native attempt ledger.

```sh
gentle-ai sdd-status host-session-contract --cwd "$PWD" --json | jq -c '{nextRecommended, blockedReasons}'

gentle-ai sdd-attempt acquire \
  --cwd "$PWD" --change host-session-contract \
  --request-id "sliceN-acq-$(date +%s)" \
  --work-unit "slice-N-name" \
  --evidence-goal "..." --max-attempts 2 --max-changed-lines 400
# proceed only on state: proceed; keep the token

gentle-ai sdd-attempt settle \
  --cwd "$PWD" --change host-session-contract --token "<token>" \
  --request-id "sliceN-settle-$(date +%s)" \
  --outcome passed|failed|interrupted \
  --evidence-revision "sha256:<64 lowercase hex>" \
  --diagnosis "..." --harness-disposition reused \
  --cleanup-evidence "..." --process-evidence "..."
```

Two things that will bite:

- **All the free-text flags must be single-line, trimmed and bounded.** A multi-line or long `--diagnosis` fails with `invalid diagnosis`. Long detail belongs in Engram, not the ledger.
- **A correction round re-acquires with the ORIGINAL `--work-unit` and `--evidence-goal`, verbatim.** Changing either reads as opening a new objective to get a fresh budget, and the ledger returns `blocked` / `maintainer_decision` offering `rescope`, which needs a human `--actor`. Attempt 2 of the same objective is not a new objective.

Verification for every slice: `flutter analyze` and `flutter test`, with verbatim output. Never accept a success claim without it — two of them were green while broken.

---

## 11. Artifacts

| Path | What |
|---|---|
| `openspec/changes/host-session-contract/exploration.md` | 495 lines, design space |
| `.../proposal.md` | scope, non-goals, slice plan, rollback |
| `.../design.md` | 419 lines, 6 ADRs, 2 mermaid diagrams |
| `.../specs/` | 6 domains, 23 requirements, 35 Given/When/Then scenarios |
| `.../tasks.md` | 100 tasks, 82 marked done |
| `docs/host-contract/v1.md` | 181 lines — what an external TypeScript consumer reads |
| `lib/core/host/` | port, adapter, probe, multiplexer abstraction, 3 adapters, diagnostics, shellQuote |
| `lib/features/connection/data/known_hosts_service.dart` | TOFU pinning |

Engram topic keys (project `helm`): `sdd-init/helm`, `sdd/helm/testing-capabilities`, `sdd/helm/review-budget-policy`, `sdd/host-session-contract/{explore,proposal,design,spec,tasks,apply-progress,herdr-contract,slice-5}`.

---

## 12. Context beyond this change

- The competing app is **Moshi** (`getmoshi.app`). Its **free tier** is the bar to match, not Pro: Mosh and multiplexer pairing are paid, and the video's author sidesteps both by keeping herdr running on the host so a plain SSH connection lands inside it.
- Moshi's `moshi-hook` writes `.opencode/plugins/moshi-hooks.ts` into a project. Gentle AI also uses OpenCode plugins — **coexistence is unverified**.
- Second consumer: `../web-estimaciones/estimaciones-app`, Next.js + TypeScript + Supabase, no git initialized.
- The source video's transcript was at `/tmp/opencode/ytdown/transcript.txt`. **`/tmp` is volatile — assume it is gone.**
