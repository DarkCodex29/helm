# Session Reference Storage Specification

## Purpose

A neutral session-reference field carried across the persisted profile, shortcut, and
snapshot models, so records written by the current app version still load after this
change, without deleting the legacy field consumers may still depend on.

## Requirements

### Requirement: Legacy Field Still Readable

A persisted record written before this change, containing only the legacy session-name
key, MUST still load successfully after this change, with its value available under
the new neutral field.

#### Scenario: Old-format record loads under the neutral field

- GIVEN a persisted record written before this change, containing only the legacy
  session-name key
- WHEN the record is loaded after this change
- THEN the load MUST succeed
- AND the legacy value MUST be available under the new neutral field

### Requirement: Legacy Key Is Not Deleted

Writing a record MUST NOT remove the legacy key. Both the legacy key and the new
neutral key MUST be present after any write made by this change, including a write of
a newly created record.

#### Scenario: Save after this change emits both keys

- GIVEN a record being saved after this change, whether newly created or updated
- WHEN the record is written to storage
- THEN the written data MUST contain both the legacy key and the new neutral key

### Requirement: Neutral Field Takes Precedence When Both Are Present

When both the new neutral field and the legacy field are present in a persisted
record, reading MUST use the new neutral field's value.

#### Scenario: Record with both keys set to different values resolves to the neutral value

- GIVEN a persisted record where the legacy key and the new neutral key hold different
  values
- WHEN the record is loaded
- THEN the resolved session reference MUST equal the new neutral field's value
