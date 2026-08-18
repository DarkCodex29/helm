# Proposal: Host Session Contract

## Intent

**Governing principle: the client attaches to work already running on the host. It never launches the agent.** A process launched as a child of an SSH session dies with the connection, so any agent Helm starts cannot survive a phone locking, a network drop, or an app kill.

Today the app cannot honour that principle:

| Gap | Evidence |
|---|---|
| Attach races the shell prompt | `terminal_session.dart:67-70` writes `tmux new-session -A -s <n>\n` into an open PTY's stdin; nothing sequences it after rc-file output |
| tmux is the only multiplexer | 10 hand-written files reference tmux, incl. 3 persisted models |
| Nothing is reusable | `TmuxService` / `RemoteFsService` bind directly to `SSHClient` — no transport seam |
| Failures are unexplainable | "tmux not found" is often a lie: the binary exists but is off the non-interactive `PATH` |

## Scope

### In Scope
- **Wire contract**: versioned POSIX-`sh` probe emitting a documented, delimited record stream (`helm-probe/1`). Language-neutral — no Dart-only encoding.
- **`HostCommandRunner` port**: narrow `run(command) → HostCommandResult` seam; `dartssh2` becomes one adapter.
- **`MultiplexerAdapter`** with declared capabilities; `herdr` first-class, `tmux`/`zellij` degraded.
- **Race-free attach** via `SSHClient.execute(cmd, pty:)` (PTY sent before exec — confirmed in dartssh2 2.16.0 source).
- **`PATH` repair + reporting**: probe reports inherited `PATH` *and* resolved binary path.
- **Diagnostics** (Linux): systemd linger + `KillUserProcesses`; Tailscale SSH post-connect warning.
- **Persisted-model migration** off `tmuxSession` / `tmuxSessionName`.

### Out of Scope (Non-Goals)
- **Portal integration layer, remote job API, multi-tenancy, identity model, audit trail, RBAC.** The portal makes request/response SDK calls today and runs no persistent agents. Leave the door open; do not build the corridor.
- **A Dart package for the portal.** Verified: consumer #2 is Next.js/TypeScript. The reusable artifact is the wire contract.
- **macOS / launchd.** Linux-only host. (`pubspec.yaml`'s "Remote Mac control" wording is stale — follow-up, not fixed here.)
- **"Is the current shell already inside a multiplexer".** Unsatisfiable: the probe runs in a fresh shell that is never inside one, so `$TMUX`/`$ZELLIJ`/`$HERDR_PANE_ID` are always empty and the answer is a meaningless "no".
- **`ssh` vs `sshd` naming check.** If you are connected, SSH works — nothing to detect. Remediation copy only.
- **Pre-connect Tailscale detection.** The only reliable detector runs on the host; reaching the host is what is broken.
- **Executing remediation.** Display-only in v1: `loginctl enable-linger` is sudo-level and `tailscale set --ssh=false` severs the session running it.

## Capabilities

### New Capabilities
- `host-command-port`: transport-neutral command execution seam + fake-testable adapter.
- `host-probe-contract`: versioned probe script, record schema, `PATH` repair, parser, failure modes.
- `multiplexer-abstraction`: adapter interface, capability declaration, herdr/tmux/zellij implementations.
- `session-attach`: exec-with-PTY attach, PTY-denied classification, exit-code semantics.
- `host-diagnostics`: linger + `KillUserProcesses`, Tailscale post-connect, remediation copy.
- `session-reference-storage`: neutral session reference across the 3 persisted models.

### Modified Capabilities
- None. `openspec/specs/` is empty; all capabilities are new.

## Approach

Strategy interface + ports/adapters. `MultiplexerAdapter` (`detect`, `listSessions`, `hasSession`, `attachCommand`, `capabilities`) depends on `HostCommandRunner`, never `SSHClient`.

**Capability model is the core design decision.** Only five operations are honestly uniform: list sessions, existence test, create-or-attach, detect+version, and probe-reported install state. Agent state (`working|blocked|done|idle`) and event-driven `agent wait` are **herdr-only** and are modelled as an *optional advertised capability* with a truthful "unsupported on this host" answer — never a method that throws on two of three implementations. Flattening to the least common denominator would discard the single most valuable signal.

## Sliced Delivery Plan

Strategy: **stacked PRs to main** (`auto-chain`). Each slice compiles, ships value, and keeps `flutter test` green.

| # | Slice | Est. authored lines | Ships |
|---|---|---|---|
| **1** | `HostCommandRunner` port + dartssh2 adapter + fake; adopt in `RemoteFsService` | **~260** | Transport seam; first tests for a currently-untested service |
| 2 | Probe script + record parser + report model + `docs/host-contract/v1.md` | ~390 | Truthful install/`PATH` reporting; the artifact consumer #2 consumes |
| 3 | `MultiplexerAdapter` + capabilities + `TmuxAdapter` + `ZellijAdapter` | ~400 | Multiplexer choice; tmux behaviour preserved |
| 4 | `HerdrAdapter` + agent-state capability | ~310 | The portal's headline signal |
| 5 | Exec-with-PTY attach + `describeError` for PTY-denied + `TerminalSession` tests | ~300 | Kills the stdin race |
| 6 | Persisted-model migration off `tmuxSession` (+~90 generated lines) | ~250 | Neutral storage; unblocks non-tmux users |
| 7 | Diagnostics: linger/`KillUserProcesses` + Tailscale post-connect | ~270 | Explains silent-death failures |

**First autonomous unit: Slice 1.** No behaviour change, pure seam, immediately verifiable.

Slices 1–4 are strictly additive (no existing behaviour changes). Slices 5–6 are the risky ones and depend on 1–3.

## Review Workload Forecast

```
Estimated total changed lines: ~2,180 authored (+ ~90 generated freezed/json)
Chained PRs recommended: Yes
400-line budget risk: High
Decision needed before apply: No
```

Rationale: `delivery_strategy` is already `auto-chain`, so the chained plan above resolves the budget without a further decision. Slice 3 sits at the 400 ceiling — if it grows, split `ZellijAdapter` into its own slice.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `lib/core/host/` | New | Port, probe, parser, adapters, capabilities |
| `docs/host-contract/v1.md` | New | Language-neutral wire schema |
| `lib/features/terminal/domain/services/tmux_service.dart` | Removed | Superseded by `TmuxAdapter` |
| `lib/features/terminal/data/terminal_session.dart` | Modified | Attach via `execute(pty:)`; **zero test coverage today** |
| `lib/features/connection/data/ssh_service.dart` | Modified | Attach path + PTY-denied classification |
| `lib/features/shortcuts/data/remote_fs_service.dart` | Modified | Takes the port; drop `tmux display-message` |
| `connection_profile.dart`, `project_shortcut.dart`, `session_snapshot_repository.dart` | Modified | **Persisted** — stored-data migration |
| `profile_edit_screen.dart`, `shortcut_form_sheet.dart`, `tabs_provider.dart` | Modified | Field rename + multiplexer selection |
| `lib/core/constants/app_constants.dart` | Modified | `defaultTmuxSession` → neutral key |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Persisted-model migration corrupts stored profiles/shortcuts | **High** | Read-old-write-new back-compat reader; migration tests before rename; slice 6 isolated and independently revertable |
| `TerminalSession` (0 tests) receives the riskiest change | **High** | `tdd: true` — characterization tests land *before* the attach change, inside slice 5 |
| zellij parsing brittle (ANSI default, no JSON, `--short` undocumented, `EXITED` state) | **High** | `--no-formatting --short`; degraded capability flags; zellij splittable out of slice 3 |
| PTY-denied is a new unclassified failure class | Medium | Classify `SSHChannelRequestError` in `describeError` within slice 5 |
| herdr CLI churn (young, single-vendor) | Medium | Pin behaviour via `herdr --version` + `herdr api schema --json`; herdr isolated in slice 4 |
| Probe cost/hang on a mobile link | Medium | Bound every host-side traversal, as `detectProjects` already does with `-maxdepth 3 \| head -50` |
| Slice 3 exceeds the 400-line budget | Medium | Pre-agreed split: `ZellijAdapter` becomes slice 3b |
| Over-designing for the portal | Low | Non-goals list is explicit and enforced at review |

## Rollback Plan

Per-slice, in reverse dependency order:

1. **Slices 1–4 (additive)**: revert the slice commit. No stored data touched, no behaviour changed — `TmuxService` still exists until slice 3 lands.
2. **Slice 5 (attach)**: revert restores `shell()` + stdin write. `_bridgeIO` is unchanged by design (`execute` returns the same `SSHSession` type), so the revert is a clean diff.
3. **Slice 6 (migration)** — the only irreversible one: the back-compat reader must accept **both** old and new keys for at least one release, so reverting the code still reads data written by the new build. Ship the reader in slice 6 and do not remove the legacy key in this change.
4. **Slice 7 (diagnostics)**: display-only, so revert is cosmetic.

Full-change abort: revert slices 7→1; `openspec/changes/host-session-contract/` is documentation only and can be archived without code impact.

## Dependencies

- `dartssh2` 2.16.0 `execute(cmd, pty:)` — **verified from pinned source**, no upgrade needed.
- Optional host binaries: `herdr`, `tmux`, `zellij`. Absence is a reported state, not an error.
- Linux host with POSIX `sh`. systemd optional (linger check reports `unsupported`, never `disabled`, when absent).

## Open Questions

Recorded, not assumed. None blocks slice 1.

1. **Migration policy** (blocks slice 6): rename to a neutral field with a back-compat reader (recommended), or keep `tmuxSession` and reinterpret it generically?
2. **Probe enumeration scope** (blocks slice 2): enumerate sessions for all installed multiplexers, or only the configured one? Directly affects mobile-link cost.
3. **Probe delivery** (blocks slice 2): heredoc per connection (zero host footprint) or installed versioned script (faster, cacheable, auditable)?

## Success Criteria

- [ ] Attaching to a running session no longer writes a command into shell stdin — no race remains.
- [ ] A host with `herdr` reports agent state; a `tmux`-only host reports that capability as unsupported without throwing.
- [ ] Probe output is parsed by a non-Dart reader from `docs/host-contract/v1.md` alone.
- [ ] A binary present but off the non-interactive `PATH` is reported with its resolved path, not as "not found".
- [ ] Existing profiles and shortcuts survive the migration; `flutter test` green after each slice.
- [ ] `TerminalSession` has test coverage where it has none today.
- [ ] No slice exceeds 400 authored changed lines without an accepted `size:exception`.
