# Multiplexer Abstraction Specification

## Purpose

One adapter contract across every supported multiplexer for the operations that are
genuinely uniform, with divergent capabilities — such as agent state — declared and
negotiated explicitly rather than assumed present everywhere.

## Requirements

### Requirement: Explicit State on List Failure, Never an Empty List

When a multiplexer cannot enumerate sessions because its server or daemon is not
reachable, the adapter MUST report a typed "server not running" state and MUST NOT
return an empty session list.

#### Scenario: No server running for the queried multiplexer

- GIVEN a multiplexer whose server or daemon process is not running on the host
- WHEN the adapter attempts to list sessions
- THEN the adapter MUST report a typed "server not running" state
- AND MUST NOT return an empty list

#### Scenario: A session that has exited is reported as exited, not omitted

- GIVEN a multiplexer session that exists but is in an exited, non-attachable state
- WHEN the adapter lists sessions
- THEN that session MUST appear in the result with an explicit exited state
- AND MUST NOT be silently dropped from the list

### Requirement: Agent-State Capability Is Advertised, Not Assumed

A caller asking for agent state from an adapter that does not advertise the
agent-state capability MUST receive a typed unsupported result and MUST NOT receive
an empty agent list.

#### Scenario: Agent state requested from an adapter without the capability

- GIVEN an adapter that does not advertise agent-state support
- WHEN a caller asks for agent state
- THEN the caller MUST receive a typed unsupported result
- AND MUST NOT receive an empty list that could be mistaken for "no agents working"

#### Scenario: Agent state requested from an adapter with the capability

- GIVEN an adapter that advertises agent-state support and a server that is reachable
- WHEN a caller asks for agent state
- THEN the caller MUST receive the reported agent states, not an unsupported result

### Requirement: Uniform Core Operations Across Adapters

Every adapter, regardless of which multiplexer it wraps, MUST implement: detecting
whether the multiplexer is installed and its version, listing sessions, testing
whether a named session exists, and producing the command used to attach to a named
session.

#### Scenario: Detect reports install and version state for any multiplexer

- GIVEN any supported multiplexer adapter
- WHEN `detect` is called
- THEN the result MUST report whether the multiplexer is installed and, if so, its
  version

#### Scenario: Existence test does not require listing every session

- GIVEN any supported multiplexer adapter and a session name
- WHEN the adapter is asked whether that session exists
- THEN the adapter MUST answer true or false for that specific name
