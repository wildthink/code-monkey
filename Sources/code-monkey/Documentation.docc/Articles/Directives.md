# Directives

`//# ai:` comments keep intent next to the code, and make it queryable.

## Overview

Directives live directly above a declaration, with no blank line in between.
They are parsed into the `directives` table and surfaced by `get`, `get --tag`,
and `weave`.

```swift
/// Create a user.
//# ai:invariant: returned User.id is unique
//# ai:prompt: never log the raw email
//# ai:why: domain operation — wraps repository write + audit
public func createUser(email: String, role: UserRole = .user) async throws -> User { ... }
```

## The tags

| Tag | Purpose |
|---|---|
| `ai:section: "<name>"` | Literate chunk label. Groups declarations in `weave`. |
| `ai:why` | Rationale prose. |
| `ai:spec` | Behavioral contract, pre and post. |
| `ai:invariant` | Guarantee the body must preserve. |
| `ai:prompt` | Instruction to an AI editing this declaration. |
| `ai:example` | Usage example. |
| `ai:see: <name>` | Cross-reference. |
| `ai:depends: <name>` | Narrative dependency. |
| `ai:warn` | Intentional pattern. Do not "fix" it. |
| `ai:requires` | Caller precondition. |

Anything else parses as `ai:<word>` and passes through to the index untouched.

## How they split across fields

`get --fields summary` returns the doc comment plus the narrative tags: `why`,
`example`, `see`, `depends`, `prompt`, and `section`.

`get --fields invariants` returns the contract tags: `invariant`, `requires`,
`warn`, and `spec`.

The split is by tag, not by table. Both fields read the same rows.

## Finding them

```bash
code-monkey get --tag ai:invariant
code-monkey query --recipe invariants
code-monkey query --recipe sections
```

The section list is the author's own architecture map, and usually the highest
signal-per-token call available on an unfamiliar project.

## See Also

- <doc:LiterateProjection>
- <doc:QueryingTheIndex>
