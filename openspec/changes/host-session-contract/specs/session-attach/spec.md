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

When an attached session ends, the reported exit status MUST reflect the multiplexer
session's own exit, so a detach is distinguishable from the session being killed.

#### Scenario: Detach and session-killed produce different outcomes

- GIVEN an attached session
- WHEN the user detaches versus when the session is killed on the host
- THEN the client MUST be able to distinguish the two outcomes from the reported exit
  status
