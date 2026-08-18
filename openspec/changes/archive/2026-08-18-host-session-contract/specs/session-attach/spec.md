# Session Attach Specification

## Purpose

Attaching to an already-running session without racing a shell prompt, with failure
classes precise enough to be actionable, and without regressing existing connection
safety behavior.

## Requirements

### Requirement: Attach Without a Stdin Race

Attaching to a session MUST allocate the pseudo-terminal before the attach command is
sent, so the attach command reaches the multiplexer directly and is never written into
an already-open shell's input stream.

#### Scenario: Attach command reaches the multiplexer with no shell in between

- GIVEN a running session to attach to
- WHEN the client attaches
- THEN the pseudo-terminal MUST be requested and the attach command MUST be sent as
  part of the same request
- AND no command MUST be written into a separately opened shell's input stream

### Requirement: PTY Denial Is Classified Before the Generic SSH Error

When the host denies the pseudo-terminal request during attach, the system MUST
produce a dedicated, actionable PTY-denied message and MUST NOT surface the generic
SSH error rendering for that failure.

#### Scenario: PTY denial produces a dedicated message

- GIVEN a host that denies pseudo-terminal allocation
- WHEN the client attempts to attach
- THEN the system MUST report a dedicated, actionable PTY-denied message
- AND MUST NOT report the generic SSH error message for this failure

#### Scenario: A different SSH failure still uses the generic message

- GIVEN an SSH failure that is not a PTY denial
- WHEN the client attempts to attach
- THEN the system MUST report the generic SSH error message
- AND MUST NOT report the PTY-denied message

### Requirement: Host Key Mismatch Keeps Precedence Over Authentication Failure

A host key mismatch during connection MUST still abort the connection and MUST still
be reported as a possible man-in-the-middle condition, and MUST NOT be reported as an
authentication failure.

#### Scenario: Host key mismatch aborts with a MITM warning

- GIVEN a connection attempt where the presented host key does not match the trusted
  key
- WHEN the client evaluates the host key
- THEN the connection MUST abort
- AND the failure MUST be reported as a possible man-in-the-middle condition, not as
  an authentication failure

### Requirement: Attach Exit Status Reflects the Multiplexer Session

When an attached session ends, the reported outcome MUST be derived from the
multiplexer session's own exit status, and MUST NOT claim more than that status
actually proves.

An earlier version of this requirement also demanded that a detach be distinguishable
from the session being killed. That was measured against real tmux 3.6a and zellij
0.44.3 and found to be unachievable through exit status: both multiplexers exit `0`
for a user detach **and** for the target session being killed while the multiplexer's
server process survives. Zellij emits no distinguishing signal on any observable
channel. Only the multiplexer's entire server process dying reports differently
(tmux: exit `1`). tmux's farewell line does differ, but it is rendered terminal
output rather than exit status, has no zellij counterpart, and reading it would make
the attach path multiplexer-specific, which it deliberately is not.

The clause was therefore removed rather than satisfied by guesswork. Reporting a
confident "detached" for an end that is genuinely ambiguous would be worse than
reporting the ambiguity.

#### Scenario: A clean exit is reported as ambiguous, never as a confident detach

- GIVEN an attached session that ends with an exit status of `0`
- WHEN the outcome is reported
- THEN it MUST be reported as a clean end whose cause is undetermined
- AND it MUST NOT be reported as a detach, since a killed session is indistinguishable
  from a detach at this layer

#### Scenario: An abnormal exit carries the evidence that proved it

- GIVEN an attached session that ends with a non-zero exit status or an exit signal
- WHEN the outcome is reported
- THEN it MUST be reported as an abnormal end
- AND it MUST carry the exit code or signal that established it

#### Scenario: An absent exit status is never collapsed into a clean end

- GIVEN an attached session that ends without the host sending any exit status or
  exit signal
- WHEN the outcome is reported
- THEN it MUST be reported as unknown
- AND it MUST NOT be reported as a clean end
