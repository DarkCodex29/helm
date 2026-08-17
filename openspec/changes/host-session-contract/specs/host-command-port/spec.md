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

#### Scenario: No file left behind on the host

- GIVEN a `runScript` call has completed, whether it succeeded or failed
- WHEN the remote host is inspected afterward
- THEN the host MUST show no new file, directory, or cached artifact created by the
  call

### Requirement: Swappable Transport Implementations

The system MUST allow more than one implementation — at minimum a live transport
adapter and a scripted stand-in — to satisfy the same `run`/`runScript` contract, so a
caller's behavior is identical regardless of which implementation is wired in.

#### Scenario: Scripted stand-in satisfies the same contract as the live adapter

- GIVEN a scripted implementation that returns canned results for known commands
- WHEN a caller invokes `run` or `runScript` through the port only
- THEN the caller MUST behave the same as it would against a live transport adapter
  given the same result
