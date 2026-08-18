# Host Probe Contract Specification

## Purpose

A versioned, delimited record stream produced by a single host-side probe, readable in
any language from a documented grammar, where one bad byte degrades only one record.

## Requirements

### Requirement: Version Gate

The system MUST accept a report whose first line is exactly the current major version
marker, and MUST refuse — never guess-parse — a report declaring a different major
version.

#### Scenario: Matching version accepted

- GIVEN a report whose first line is the current major version marker
- WHEN the report is parsed
- THEN parsing MUST proceed to the remaining records

#### Scenario: Mismatched major version refused

- GIVEN a report whose first line declares a different major version
- WHEN the report is parsed
- THEN the system MUST refuse it as a version mismatch and parse no further record

### Requirement: Truncation Is Explicit

A report missing its terminating end-of-report record MUST be classified as
truncated, and MUST NOT be reported as a host with no sessions.

#### Scenario: Complete stream reports its own status

- GIVEN a report that includes a terminating end-of-report record
- WHEN the report is parsed
- THEN the result MUST reflect that record's reported status

#### Scenario: Stream missing the terminating record is truncated

- GIVEN a report whose stream ends before a terminating record appears
- WHEN the report is parsed
- THEN the result MUST be classified truncated, not as zero sessions

### Requirement: Forward-Compatible Record Reading

An unknown record kind MUST be skipped without failing the parse, and extra trailing
fields on a known kind MUST be ignored.

#### Scenario: Unknown record kind is skipped

- GIVEN a report containing a record of an unrecognized kind
- WHEN the report is parsed
- THEN that record MUST be skipped and every other record MUST still parse

#### Scenario: Extra trailing fields on a known kind are ignored

- GIVEN a record of a known kind with more fields than the reader expects
- WHEN the report is parsed
- THEN the reader MUST use only the fields it recognizes and MUST NOT fail the parse

### Requirement: Record-Level Fault Isolation

A malformed record MUST NOT invalidate any other record in the same stream.

#### Scenario: One malformed record does not block its siblings

- GIVEN a report with one malformed record among well-formed ones
- WHEN the report is parsed
- THEN the malformed record MUST be excluded and every well-formed record MUST still
  appear in the result

### Requirement: Escaping Round-Trip

A field value containing a backslash, TAB, LF, or CR MUST be escaped on emission and
MUST decode back to the exact original bytes when read.

#### Scenario: Each reserved byte class round-trips exactly

- GIVEN a value containing a backslash, a TAB, an LF, or a CR
- WHEN the value is emitted then decoded
- THEN the decoded value MUST equal the original, byte for byte

### Requirement: Installed-but-Off-PATH Is Distinguishable From Not-Installed

For each candidate binary, the report MUST include whether it was found, whether the
resolved location is on the inherited PATH, and its resolved absolute path when
found — so a binary reachable only via PATH repair is never reported as not found.

#### Scenario: Binary found only via repaired PATH

- GIVEN a binary present on disk but absent from the inherited PATH
- WHEN the probe resolves it via a repaired PATH
- THEN the report MUST show it found, at its resolved path, with "on inherited PATH"
  false

#### Scenario: Binary genuinely absent

- GIVEN a binary that does not exist anywhere the probe searches
- WHEN the probe attempts to resolve it
- THEN the report MUST show it not found, with no resolved path
