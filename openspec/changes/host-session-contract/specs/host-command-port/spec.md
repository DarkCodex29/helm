# Host Command Port Specification

## Purpose

A transport-neutral seam for running commands on a remote host. Callers depend only on
this port, never on a specific transport client, and the port MUST be satisfiable by a
scripted stand-in with no live connection.

## Requirements

### Requirement: Single-Command Execution

The system MUST provide a `run` operation that executes one command over the
configured transport and returns a result containing stdout, stderr, an optional exit
code, and whether the call timed out.

#### Scenario: Command completes successfully

- GIVEN a connected host command runner
- WHEN `run` is called with a command
- THEN the result MUST contain the command's stdout, stderr, and exit code
- AND `timedOut` MUST be false

#### Scenario: Command exceeds the configured timeout

- GIVEN a `run` call made with a timeout duration
- WHEN the remote command does not complete within that duration
- THEN the result MUST report `timedOut = true`
- AND the result MUST NOT be treated as a completed command with a usable exit code

### Requirement: Script Delivery With Zero Host Footprint

The system MUST provide a `runScript` operation that delivers script bytes to the host
over the command channel's input stream, MUST NOT request a pseudo-terminal for that
channel, and MUST NOT create, write, install, or cache any file on the remote host.

#### Scenario: Script delivered over stdin, no pseudo-terminal

- GIVEN a script passed to `runScript`
- WHEN the command channel is opened
- THEN the script bytes MUST be written to the channel's input stream and the stream
  MUST be closed to signal end-of-input
- AND no pseudo-terminal MUST be requested for this channel

The script's own absence of write primitives is **necessary but not sufficient**, and this
was learned the hard way. The v1 probe contained no redirection to a file, no `touch`,
`mkdir`, `cp`, `mv` or `tee` — and still left an empty `/tmp/tmux-<uid>` behind on every
run, because `tmux list-sessions` creates its per-UID socket directory the moment a client
starts, with no server to talk to and even when the call then fails. Measured against a
real Ubuntu 24.04 host: the directory appeared during the call window, was deleted, and
reappeared on an identical re-run. Reading the source proves how the source reads, not
what the execution does.

So the obligation below is on **what the code invokes**, not only on what it writes.

The original scenario asked for the host to be inspected after the call and show no new
artifact. That is the true statement of intent, and it is retained as the requirement — but
it cannot be automated in this project's harness, which is a Flutter test suite with no
remote host. It is evidenced by recorded live measurement instead, and the scenarios below
carry the parts a test can genuinely assert.

#### Scenario: No command is invoked when there is nothing for it to report

- GIVEN a host where a queried tool is installed but has no running server or state to
  report
- WHEN the script runs
- THEN it MUST NOT invoke that tool's query command at all
- AND the emitted records MUST be identical to those for a host where the tool is absent

#### Scenario: An undetectable server never becomes a silent absence

- GIVEN a host where the means of detecting a running server is itself unavailable
- WHEN the script runs
- THEN it MUST attempt the query rather than report nothing
- AND the resulting host artifact is an accepted, disclosed exception to this requirement,
  because reporting no sessions on a host that has them is the greater harm

#### Scenario: Detection is independent of relocatable paths

- GIVEN a host that has relocated a tool's socket or state directory away from its default
- WHEN the script decides whether to query that tool
- THEN the decision MUST NOT depend on that path
- AND a host with real sessions MUST still have them enumerated

### Requirement: Swappable Transport Implementations

The system MUST allow more than one implementation — at minimum a live transport
adapter and a scripted stand-in — to satisfy the same `run`/`runScript` contract, so a
caller's behavior is identical regardless of which implementation is wired in.

#### Scenario: Scripted stand-in satisfies the same contract as the live adapter

- GIVEN a scripted implementation that returns canned results for known commands
- WHEN a caller invokes `run` or `runScript` through the port only
- THEN the caller MUST behave the same as it would against a live transport adapter
  given the same result
