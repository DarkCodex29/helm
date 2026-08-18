# Host Diagnostics Specification

## Purpose

Explain otherwise-silent failure modes — session death on logout, Tailscale SSH owning
port 22 — with display-only findings that never execute remediation on the user's
behalf.

## Requirements

### Requirement: Diagnostics Are Display-Only

No diagnostic remediation MUST ever be executed by the system. A diagnostic MUST only
report a finding and its remediation copy for the user to act on manually.

#### Scenario: Tailscale remediation is shown, never executed

- GIVEN a diagnostic finding that Tailscale SSH is intercepting the connection
- WHEN the finding is surfaced to the user
- THEN the system MUST display the finding and remediation copy
- AND MUST NOT execute any remediation command

#### Scenario: Linger remediation is shown, never executed

- GIVEN a diagnostic finding that session-killing on logout is possible
- WHEN the finding is surfaced to the user
- THEN the system MUST display the finding and remediation copy
- AND MUST NOT execute any remediation command

### Requirement: Systemd Absence Reported as Unsupported, Never Disabled

On a host without systemd, the logout-persistence diagnostic MUST report an
unsupported state and MUST NOT report a disabled state.

#### Scenario: Non-systemd host reports the check as unsupported

- GIVEN a host that has no systemd
- WHEN the logout-persistence diagnostic runs
- THEN the result MUST be reported as unsupported
- AND MUST NOT be reported as disabled

### Requirement: No False Alarm When Sessions Are Already Protected

When session-persistence-on-logout is off but the host's process-killing-on-logout
setting is also off, the diagnostic MUST report an ok state, not a warning.

#### Scenario: Both settings off yields ok

- GIVEN a systemd host where session-persistence-on-logout is off and
  process-killing-on-logout is off
- WHEN the diagnostic runs
- THEN the result MUST be reported as ok

#### Scenario: Persistence off and process-killing on yields a warning

- GIVEN a systemd host where session-persistence-on-logout is off and
  process-killing-on-logout is on
- WHEN the diagnostic runs
- THEN the result MUST be reported as a warning that sessions may die on logout

### Requirement: Tailscale SSH Detected Post-Connect

When the connected host reports that Tailscale SSH is intercepting port 22, the
system MUST warn the user with remediation copy, evaluated only after a connection is
already established.

#### Scenario: Tailscale interception triggers a post-connect warning

- GIVEN a successfully connected host that reports Tailscale SSH is intercepting port
  22
- WHEN diagnostics evaluate the connected host
- THEN the system MUST warn the user with remediation copy
