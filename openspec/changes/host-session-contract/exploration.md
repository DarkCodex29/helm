# Exploration: host-session-contract

Investigation of a host-side contract that lets a client **attach to already-running**
AI coding agents on a remote always-on host, instead of launching them as children of
an SSH session. Covers connection preflight, a multiplexer abstraction
(`herdr | tmux | zellij`), and host diagnostics.

Everything asserted below is verified against source or primary documentation, with the
citation inline. Anything unverified is marked **[UNVERIFIED]** and listed as an open
question rather than stated as fact.

---

## Current State

The tmux coupling is **not** confined to `TmuxService`. It is spread across seven files,
three of which are **persisted JSON models** — so this is a data-migration problem, not
only a refactor.

| Location | Coupling | Persisted? |
|---|---|---|
| `lib/features/terminal/domain/services/tmux_service.dart` | Whole class; takes `SSHClient` directly | No |
| `lib/features/terminal/data/terminal_session.dart:67-70` | Writes `tmux new-session -A -s <name>\n` into an open PTY's stdin | No |
| `lib/features/shortcuts/data/remote_fs_service.dart:41` | `tmux display-message -p '#{pane_current_path}'` | No |
| `lib/core/constants/app_constants.dart:8` | `defaultTmuxSession = 'helm'` | No |
| `lib/features/connection/domain/connection_profile.dart:26` | field `String? tmuxSession` | **Yes** (`helm_connection_profiles`) |
| `lib/features/shortcuts/domain/project_shortcut.dart` | field `String tmuxSession` | **Yes** (shortcuts repo) |
| `lib/features/terminal/data/session_snapshot_repository.dart:12` | `TabSnapshot.tmuxSessionName` | **Yes** (`helm_session_snapshot`) |

Two further structural facts matter:

1. **`TmuxService` and `RemoteFsService` both take `SSHClient` directly.** There is no
   transport seam. Any second consumer that is not a `dartssh2` client cannot reuse a line
   of this. This is the single most important thing to fix for reuse.
2. **`TerminalSession` has no test coverage** (codegraph blast radius: *"⚠️ no covering
   tests found"* for `TerminalSession`, `connect`, `connectAndOpenShell`, `resizeTerminal`,
   `disconnect`). The stdin-race fix lands in the least-covered file in the feature.

`SSHService.connectAndOpenShell` (`ssh_service.dart:101`) calls `client.shell(pty: ...)`.
`TerminalSession.connect` then writes the tmux command into that shell's stdin. That write
races the shell's prompt and rc-file output — nothing sequences it after the prompt.

---

## A. Multiplexer CLI surfaces (verified)

### herdr

The brief assumed herdr has *"spaces and tabs"*. **That is wrong.** The real hierarchy is
`session → workspace → tab → pane → agent`
(source: <https://herdr.dev/docs/concepts/>, <https://herdr.dev/docs/cli-reference/>).

| Capability | Command |
|---|---|
| List sessions | `herdr session list --json` |
| Attach session | `herdr session attach <name>` |
| Create-or-attach (idempotent) | `herdr` (default) / `herdr --session <name>` — docs: *"launch or attach to a named session"* |
| Stop / delete | `herdr session stop <name> [--json]` / `herdr session delete <name> [--json]` |
| Detect installed | `herdr --version` |
| Health | `herdr status` / `herdr status server` / `herdr status client` |
| Full state bootstrap | `herdr api snapshot` (the `session.snapshot` socket method as JSON) |
| Protocol contract | `herdr api schema --json` (full JSON Schema, bundled with the binary) |
| **Agent inventory** | `herdr agent list` |
| **Agent state wait** | `herdr agent wait <target> --until <status> [--timeout MS]` |
| Attach one agent only | `herdr agent attach <target> [--takeover]` |
| In-session detection | env `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID` |

Two herdr capabilities have **no tmux/zellij equivalent** and are decisive for consumer #2:

- Every pane is classified `working | blocked | done | idle`, rolled up to tab and
  workspace. Herdr detects ~20 agents (Claude Code, Codex, opencode, Cursor, Grok…) via
  lifecycle hooks or screen manifests.
- `agent.wait` is *server-owned and event-driven*, and "pins the resolved pane occupant so
  a replacement cannot satisfy the wait" — i.e. a real edge-triggered await, not polling.

Note a collision: `herdr --remote <host>` is herdr's *own* SSH bridge, and
`herdr terminal session control <target>` streams newline-delimited JSON frames with
base64 ANSI. These overlap with what Helm does. Whether Helm should render herdr's UI or
bypass it is an open product question.

### tmux

| Capability | Command | Notes |
|---|---|---|
| List sessions | `tmux list-sessions -F '#{session_name}'` | already used |
| Existence test | `tmux has-session -t <name>` | exit 0 / 1 — the correct check, no output parsing |
| Create-or-attach | `tmux new-session -A -s <name>` | `-A` = attach if it exists |
| Attach | `tmux attach-session -t <name>` | |
| In-session detection | `$TMUX` non-empty | |

Gotcha (verified, unix.stackexchange.com/q/657776): with no server running, `tmux ls`
writes `no server running on /tmp/tmux-<uid>/default` **to stderr** and exits non-zero.
Piping stdout alone silently yields empty. The existing `TmuxService.listSessions` already
handles this with `2>/dev/null || true`. Nesting is refused by default:
`sessions should be nested with care, unset $TMUX to force`.

### zellij

| Capability | Command | Notes |
|---|---|---|
| List sessions | `zellij list-sessions --no-formatting --short` | **`--no-formatting` is mandatory** |
| Create-or-attach | `zellij attach --create <name>` (`-c`) | verified in `src/commands.rs::attach_with_session_name` |
| Attach | `zellij attach <name>` | prefix matching; ambiguous prefix exits 1 |
| Kill | `zellij kill-session <name>` | |
| In-session detection | `$ZELLIJ == "0"`, `$ZELLIJ_SESSION_NAME` | |

Three zellij-specific traps, all verified:

1. **ANSI colour codes in output by default.** `zellij list-sessions` emits SGR escapes;
   naive parsing produces `No session with the name 'zippy-megalodon' found!`
   (zellij-org/zellij#3057). Fix is `--no-formatting --short` — and `--short` was reported
   as *not listed in `--help`*.
2. **No JSON output for `list-sessions`.** Open request in #3057. Only `zellij action
   current-tab-info --json` returns JSON, and that requires an active session.
3. **A dead-but-resurrectable session state exists** — `(EXITED - attach to resurrect)`.
   Neither tmux nor herdr has this. Additionally, attaching to the *current* session
   `panic!`s by design (`src/commands.rs`), and CLI actions break when `$TMPDIR` changes
   under the session (issue #3637, the Nix case).

### Honest least common denominator

| Operation | herdr | tmux | zellij | Uniform? |
|---|---|---|---|---|
| List sessions | ✅ JSON | ✅ `-F` | ⚠️ ANSI text | **Yes**, with per-impl parsing |
| Existence test | ✅ | ✅ exit code | ⚠️ derive from list | **Yes** |
| Create-or-attach | ✅ | ✅ `-A` | ✅ `-c` | **Yes** |
| Detect installed + version | ✅ | ✅ | ✅ | **Yes** |
| In-session detection (env) | ✅ | ✅ | ✅ | **Yes** |
| Session working directory | via `pane list` | `display-message -p` | ⚠️ `dump-layout` only | **No** |
| **Agent state (working/blocked/idle)** | ✅ | ❌ | ❌ | **No — herdr only** |
| **Await state change** | ✅ `agent wait` | ❌ | ❌ | **No — herdr only** |
| Structured/JSON output | ✅ | ❌ | ❌ | **No** |
| Dead-session resurrection | ❌ | ❌ | ✅ | **No** |
| Windows/tabs/panes model | 4 levels | 3 levels | 3 levels | **No** |

**The core interface can honestly promise only the first five rows.** Everything else must
be a declared, queryable capability — not a method that throws `UnimplementedError` on two
of three implementations.

---

## B. Preflight command shape

### The PATH failure mode is real and is *not* fixed by allocating a PTY

`ssh host 'cmd'` runs the user's shell as `$SHELL -c cmd` — non-interactive. Bash's
`INVOCATION` section does say it reads `~/.bashrc` when stdin is a socket, **but** the
Debian/Ubuntu stock `~/.bashrc` opens with:

```sh
case $- in *i*) ;; *) return;; esac
```

so everything after it — including every `PATH` addition — is skipped. Measured result
(unix.stackexchange.com/q/543157):

```
$ ssh remote           # then: printenv PATH
/usr/local/sbin:/Users/me/perl5/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/X11/bin
$ ssh remote printenv PATH
/usr/bin:/bin:/usr/sbin:/sbin
```

Critically: **allocating a PTY does not make the shell interactive.** `-c cmd` is
non-interactive regardless of tty. These two concerns are orthogonal and are routinely
conflated. The probe must therefore repair `PATH` itself:

```sh
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/run/current-system/sw/bin:$HOME/.nix-profile/bin:$PATH"
```

and report **both** the inherited `PATH` and each resolved binary path, so a diagnostic can
say *"tmux exists at `/opt/homebrew/bin/tmux` but is not on your non-interactive PATH"* —
which is actionable, unlike "tmux not found".

### Approaches compared

**1. Single POSIX-sh probe emitting a versioned, delimited record stream** *(recommended)*

One `execute()`; a heredoc-delivered `sh` script; output like
`helm-probe/1<TAB>mux<TAB>tmux<TAB>3.4<TAB>/opt/homebrew/bin/tmux`.

- Pros: one RTT; atomic snapshot; no host dependencies (`sh`, `command -v`, `test` only);
  no escaping trap — the delimiter is chosen outside the value domain; versioned first line
  lets the contract evolve; trivially reimplementable by a non-Dart consumer.
- Cons: needs a hand-written parser on the client; delimiter choice must be defended
  against session names containing whitespace (tmux allows spaces).
- Effort: **Medium**

**2. Single POSIX-sh probe emitting hand-rolled JSON**

- Pros: familiar shape; consumer #2 gets JSON for free; maps to `freezed` models.
- Cons: **the escaping is where this breaks.** Session names, labels and paths are
  user-controlled and can contain `"`, `\`, and newlines. Correct JSON escaping in pure
  POSIX `sh` without `jq`/`python` requires a hand-rolled escaper that is easy to get
  subtly wrong and hard to test on a real host. A malformed value corrupts the whole
  document, whereas a delimited stream degrades to one bad record.
- Effort: **Medium-High** (the escaper is the cost, and it is a correctness risk)

**3. N separate `execute()` calls, one fact each**

- Pros: simplest code; each failure isolated; matches today's `RemoteFsService` style.
- Cons: N × RTT on a mobile link — the exact latency the preflight exists to avoid;
  no atomic snapshot (state can change between calls); N channel setups.
- Effort: **Low**

**Recommendation: Approach 1.** Same round-trip cost as 2, strictly lower correctness risk,
and the record stream is as portable to a TypeScript/Python consumer as JSON is. If the
probe later needs richer nesting, herdr already emits real JSON via `herdr api snapshot` —
delegate to it rather than hand-rolling JSON in `sh`.

Failure modes the probe must define, not assume: no shell / restricted shell; command
timeout (an unbounded `find` over a network mount can hang — the existing
`RemoteFsService.detectProjects` already caps with `-maxdepth 3 … | head -50`); partial
output; non-zero exit with usable stdout.

### One requirement in the brief cannot be satisfied as written

> *"whether the current shell is already inside one"*

A preflight probe runs in a **fresh non-interactive shell** that is inside no multiplexer.
`$TMUX` / `$ZELLIJ` / `$HERDR_PANE_ID` will be empty every time, so the probe will always
answer "no" and the answer is meaningless. The check is only meaningful **inside the
interactive `shell()` session** (where a user's rc-file autostart — `zellij setup
--generate-auto-start`, or a `tmux new-session -A` line in `.bashrc` — may already have
attached them). This needs a product decision (see Open Questions).

---

## C. Attaching without the stdin race — confirmed dartssh2 API

**Verified by reading `~/.pub-cache/hosted/pub.dev/dartssh2-2.16.0/lib/src/ssh_client.dart`
(the version pinned in `pubspec.lock`, sha256 `3aef8ed…`).**

```dart
// lib/src/ssh_client.dart:401
Future<SSHSession> execute(
  String command, {
  SSHPtyConfig? pty,
  SSHX11Config? x11,
  Map<String, String>? environment,
}) async
```

Internal ordering (lines 407-463) — this is what makes it correct:

1. `_openSessionChannel()`
2. `sendEnv(...)` per `environment` entry
3. optional agent forwarding
4. **`sendPtyReq(terminalType:, terminalWidth:, terminalHeight:, …)` — if `pty != null`**
5. optional `sendX11Req(...)`
6. **`sendExec(command)`**
7. `return SSHSession(channelController.channel)`

So the PTY is allocated **before** the exec request. This is exactly `ssh -tt host 'cmd'`
semantics, and it eliminates the race: there is no shell, no prompt and no rc-file output
to race against — the multiplexer binary *is* the channel's process.

The returned `SSHSession` is the **same type** `shell()` returns
(`lib/src/ssh_session.dart`): `stdin`, `stdout`, `stderr`, `done`, `resizeTerminal(...)`,
`kill(SSHSignal)`, `int? exitCode`. **`TerminalSession._bridgeIO` therefore works
unchanged**, and `SSHService.resizeTerminal` keeps working.

Concrete replacement for the racing write at `terminal_session.dart:67-70`:

```dart
// Instead of: client.shell(pty: …) then writing the command into stdin.
final session = await client.execute(
  attachCommand,                                   // from the multiplexer strategy
  pty: SSHPtyConfig(type: 'xterm-256color', width: columns, height: rows),
);
```

Confirmed limitations:

- `SSHPtyConfig` exposes only `type`, `width`, `height`, `pixelWidth`, `pixelHeight`
  (const constructor, same file). **There is no terminal-modes / termios field**, so
  encoded terminal modes cannot be sent.
- If the server denies the PTY request, `execute` **closes the channel and throws**
  `SSHChannelRequestError('Failed to start pty')` — a distinct failure that today's
  `shell()` path does not produce and that `describeError` does not yet classify.
- `exitCode` now reflects the **multiplexer's** exit, not a login shell's. Detach
  (`ctrl+b q`) and "session killed" become distinguishable — a genuine improvement, but it
  changes `_handleDisconnect` semantics.
- `execute` runs the command through the user's login shell as configured by sshd, so
  section B's `PATH` caveat applies here too: `attachCommand` should use an absolute
  binary path resolved by the preflight, not a bare name.

---

## D. Host diagnostics — detectability assessed honestly

| Condition | Detectable? | Mechanism | Ship? |
|---|---|---|---|
| No multiplexer installed | **Yes, reliably** | Preflight output — it *is* the probe's primary result | **Yes** |
| systemd linger disabled | **Yes, on systemd hosts only** | `loginctl show-user "$USER" --property=Linger --value` → `yes`/`no`; equivalently `test -e /var/lib/systemd/linger/$USER` | **Yes, gated on systemd** |
| Tailscale SSH owning port 22 | **Partially** — post-connect only | `tailscale debug prefs` → `RunSSH: true` | **Yes, as post-connect warning** |
| Tailscale SSH — pre-connect | **No, only inferable** | ~60s hang then auth error while other ports answer instantly | **No** — hint on auth failure only |
| `ssh` vs `sshd` service naming | **Not a fault** | — | **No** — remediation copy only |

**Linger.** Verified against `loginctl(1)`: *"If enabled for a specific user, a user manager
is spawned for the user at boot and kept around after logouts. This allows users who are
not logged in to run long-running services."* And `logind.conf(5)` states directly:
*"Note that setting `KillUserProcesses=yes` will break tools like screen(1) and tmux(1)."*
That is the exact failure this architecture must prevent, from the primary source. The
probe should report `Linger` **and** the effective `KillUserProcesses` /
`KillExcludeUsers`, because `KillUserProcesses=no` (the Debian default) already protects
tmux even without linger — reporting only linger would produce false alarms. Remediation:
`loginctl enable-linger <user>`.
**Hard gate: this check must be skipped entirely on non-systemd hosts.** `pubspec.yaml`
describes Helm as *"Remote Mac control via SSH and tmux"* while the brief describes an
"always-on Linux box" — on macOS `loginctl` does not exist and the whole check is
meaningless. The probe must branch on `uname -s` and report `unsupported`, not `disabled`.

**Tailscale SSH.** The mechanism is confirmed by official docs
(<https://tailscale.com/docs/features/tailscale-ssh>): *"Tailscale takes over port 22 for
SSH connections incoming from the Tailscale network… Your SSH configuration
(`/etc/ssh/sshd_config`) and keys (`~/.ssh/authorized_keys`) files will not be modified"* —
i.e. a valid key is never consulted. Remediation `tailscale set --ssh=false` is confirmed.
The brief's warning about not running it from the dependent session is directly supported:
official docs warn that `tailscale set --ssh` *"will cause any existing SSH connections you
have to the host's Tailscale IP to hang."*
The chicken-and-egg is the honest limit: **the only reliable detector runs on the host, and
reaching the host is what is broken.** Therefore ship the post-connect check
(`tailscale debug prefs` → `RunSSH`) as a proactive warning *before* the user hits the
failure. The ~60s-hang signature is third-party-documented only **[UNVERIFIED against
Tailscale primary sources]**; use it as a phrasing hint in the auth-failure message, never
as a positive assertion. Note also tailscale/tailscale#19328: port 22 was intercepted on
one node with `RunSSH: false`, so `RunSSH: false` does not fully exonerate Tailscale.

**`ssh` vs `sshd`.** Verified but **not worth shipping as a check**: if the client is
connected, SSH is working — there is nothing to detect. On Debian/Ubuntu the unit is
`ssh.service` with `Alias=sshd.service`; that alias broke on Ubuntu 24.04 (LP:#2087949,
fixed in `openssh 1:9.9p1-3ubuntu1`), and 24.04 moved to socket activation, so the correct
command is now `systemctl status ssh.socket`. Encoding this into a live check would embed
distro-version trivia in the client that goes stale. It belongs in remediation copy.

---

## E. Second consumer — the estimations portal

The portal needs to: start long-running agent jobs; keep them alive independently of any
client; **learn when a job finishes or blocks on a human decision**; let a human answer
remotely.

**Finding that changes the design:** requirement three is natively satisfied by exactly one
of the three multiplexers. `herdr agent wait <target> --until blocked` is server-owned and
event-driven. tmux and zellij expose **no** agent state at all — emulating this means
screen-scraping pane output and heuristically classifying it, which is a different and much
larger product. So the portal's headline requirement is a **capability of herdr**, not of
the abstraction. The contract must expose it as an optional capability with an honest
"unsupported on this host" answer, and the portal must decide whether it *requires* herdr.

Implications for the contract's shape:

1. **Transport neutrality is the non-negotiable one.** Today `TmuxService({required
   SSHClient client})` and `RemoteFsService.detectProjects(SSHClient client)` bind directly
   to `dartssh2`. The contract's entry point must be a narrow port — conceptually
   `Future<HostCommandResult> run(String command, {Duration timeout})` — with the
   `dartssh2` implementation as one adapter. This also makes the whole thing testable with
   a hand-written fake, matching the project's existing `test/helpers/` convention and its
   ctor-injection-with-real-default pattern.
2. **Placement depends on whether the portal is Dart.** If yes, extract to a separate
   package (`packages/helm_host_contract`) — `lib/core/` is not extractable and would still
   drag in Flutter. If the portal is TypeScript/Python (likely for an internal web portal),
   then **the reusable artifact is the wire contract — the probe script plus its output
   schema — not the Dart code.** That is a materially different deliverable and it is
   currently undecided. Designing a Dart package for a non-Dart consumer would be waste.
3. **Genuinely different requirements — do not unify these:**

   | Concern | Mobile client (single user) | Portal (multi-user) |
   |---|---|---|
   | Credentials | One key in `flutter_secure_storage`, biometric-gated | Service account or per-user identity; secrets manager; rotation |
   | Identity | Implicit — the phone's owner | Explicit — who asked, who answered |
   | Audit | None needed | Who ran what, when, against which repo |
   | Authorization | None | "May user X answer agent Y's prompt?" |
   | Source code | User's own | **Company code — data residency / compliance** |
   | Session ownership | One human owns everything | Jobs outlive their requester; handoff required |

4. **Do NOT generalize prematurely.** Multi-tenancy, RBAC, an audit-log schema and job
   queueing belong to the portal, not to this contract. The contract should stay one
   sentence: *given a way to run a command on a host, report what multiplexers and sessions
   exist, produce the correct attach command, and surface any agent state the host can
   actually provide.* Identity and audit sit **above** it, in each consumer.
5. One thing *is* worth generalizing now: **capability declaration**. Both consumers need to
   ask "can this host tell me when an agent is blocked?" and get a truthful answer. Bake
   that in from the start; retrofitting capability negotiation is expensive.

---

## Approaches for the multiplexer abstraction

**1. Strategy interface + per-multiplexer implementations, transport behind a port**
*(recommended)*
`MultiplexerAdapter` (`detect`, `listSessions`, `hasSession`, `attachCommand`,
`capabilities`) with `HerdrAdapter`, `TmuxAdapter`, `ZellijAdapter`, each depending on a
`HostCommandRunner` port rather than `SSHClient`.
- Pros: matches `openspec/config.yaml` design rule verbatim; the honest LCD is small enough
  to be genuinely uniform; capability flags keep divergence explicit instead of throwing;
  fake-testable with no SSH; directly extractable for consumer #2.
- Cons: three parsers to maintain; zellij's ANSI/no-JSON output stays brittle; more files.
- Effort: **Medium-High**

**2. Extend `TmuxService` with a `MultiplexerKind` enum and branch internally**
- Pros: smallest diff; no new abstractions.
- Cons: **explicitly forbidden** by `openspec/config.yaml` design rule ("not a tmux-only
  extension"); branching grows quadratically with capability divergence; keeps the
  `SSHClient` coupling, so consumer #2 gets nothing.
- Effort: **Low** — and wrong.

**3. Delegate everything to herdr; treat tmux/zellij as attach-only fallbacks**
- Pros: one rich JSON/socket API (`herdr api schema --json` is a machine-readable
  contract); agent state and `agent wait` come free; solves the portal's hardest
  requirement outright.
- Cons: hard dependency on a young, single-vendor tool; users with existing tmux/zellij
  setups are second-class — contradicting "attach to work that is already running";
  `herdr --remote` overlaps with Helm's own transport.
- Effort: **Medium**

**Recommendation: Approach 1**, with the capability model deliberately shaped so that
herdr's agent-state surface is a first-class *optional* capability rather than an
afterthought. This satisfies the config rule, keeps tmux/zellij users first-class for
attach, and gives the portal a clean upgrade path to herdr for the state-awaiting
requirement without forcing that dependency on the mobile app.

---

## Risks

- **Persisted-model migration.** Three JSON models carry `tmuxSession` / `tmuxSessionName`.
  Renaming to a neutral term breaks stored `SharedPreferences` payloads for existing users;
  keeping the name makes every future reader think it is tmux-specific. Needs an explicit
  decision plus a migration path.
- **Least-covered code changes most.** `TerminalSession` has zero tests today and receives
  the exec-with-PTY change. `config.yaml` sets `tdd: true` — tests must land first.
- **zellij parsing is inherently brittle.** No JSON, ANSI by default, `--short` undocumented
  in `--help`, plus the `EXITED - attach to resurrect` state and `$TMPDIR`-sensitivity
  (issue #3637). Expect zellij to be the flakiest adapter.
- **herdr CLI churn.** Young project; the CLI is broad and evolving. Mitigate by probing
  `herdr --version` and pinning behaviour against `herdr api schema --json`.
- **PTY-denied is a new failure class.** `execute(pty: …)` throws
  `SSHChannelRequestError('Failed to start pty')`, which `SSHService.describeError` does not
  classify — it would surface as a raw `toString()`.
- **Preflight cost on mobile links.** Probing three multiplexers plus diagnostics plus
  recent project directories in one command risks a slow or hanging connect. Every host-side
  traversal needs a bound, as `detectProjects` already does.
- **Diagnostics that suggest remediation invite running it.** `loginctl enable-linger` and
  `tailscale set --ssh=false` are `sudo`-level and the latter can sever the connection
  executing it. Display-only vs. execute-with-consent is unresolved.

---

## Open Questions — need a product decision (do not resolve in design)

1. **Is the estimations portal a Dart consumer?** Decides whether the reusable artifact is a
   Dart package or a language-neutral wire contract (probe script + output schema). This
   changes the deliverable, not just the packaging.
2. **Linux only, or macOS too?** `pubspec.yaml` says *"Remote Mac control"*; the brief says
   *"always-on Linux box"*. If macOS is in scope, the linger diagnostic does not exist there
   and needs a `launchd` story or an explicit "unsupported" state.
3. **Is herdr a first-class target or a nice-to-have?** The portal's "learn when a job blocks
   on a human decision" requirement is satisfied *only* by herdr. Accept a dependency on a
   young single-vendor tool for that capability, or drop the requirement for tmux/zellij
   hosts?
4. **Migration policy for the persisted `tmuxSession` fields** — rename with a migration, or
   keep the field name and reinterpret it as a generic session name?
5. **Does preflight enumerate sessions for all installed multiplexers, or only the configured
   one?** Directly affects probe cost on a mobile link.
6. **Is the probe delivered as a heredoc per connection, or installed on the host as a
   versioned script?** Installed is faster, cacheable and auditable; heredoc leaves zero host
   footprint. The portal likely prefers installed; the mobile app likely prefers heredoc.
7. **Does "is the current shell already inside a multiplexer" stay in scope?** It cannot be
   answered by a non-interactive probe (§B). Either drop it, or redefine it as an
   interactive-session-only check.
8. **Display-only or execute-with-consent for remediation?** Especially
   `tailscale set --ssh=false`, which can kill the very session running it.
9. **Multi-user identity for the portal:** one service account, or the requesting human's OS
   user? Changes the credential model and whether the contract needs a user dimension at all.

---

## Ready for Proposal

**Yes, with caveats.** The technical unknowns are resolved: the `dartssh2` exec-with-PTY API
is confirmed from source, all three multiplexer CLI surfaces are established from primary
docs, and the diagnostics have been triaged into detectable vs. inferable.

Questions **1, 2 and 3** materially change the design (deliverable format, whether a whole
diagnostic exists, and whether the abstraction's most valuable capability is required or
optional). The orchestrator should put those three to the user before `sdd-propose`. The
remaining six can be recorded as proposal-time decisions.

The proposal should also be told up front that the tmux coupling spans **seven** files
including **three persisted models** — this is not a `TmuxService` swap, and scoping it as
one will produce a wrong task breakdown.
