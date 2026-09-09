# The read model

One command, `get`, and you pay only for what you ask for.

## Overview

`get` answers facts about declarations. A bare positional argument resolves to
one record, matching an id, a name, or a `decl_id` substring. An ambiguous match
lists the candidates instead of guessing.

Any of `--path`, `--kind`, `--container`, `--name-like`, `--tag`, or `--spi`
switches to enumerate mode and returns every match, as does omitting the
positional entirely.

`--fields` picks attributes independently of resolve versus enumerate. Omit it on
a single target and you get `signature,summary,invariants` for free. Omit it
while enumerating and you get the cheapest possible locate-only line, with no
per-row queries at all.

| Question | Command |
|---|---|
| What is in this directory? | `get --path Sources/MyApp` |
| What is the API surface? | `get --container UserService --fields signature` |
| What is this for, and does it promise anything? | `get createUser` |
| Show me the implementation. | `get createUser --fields body --body-mode full` |
| Show it with its surroundings. | `code UserService --expand createUser` |

## Locate

The cheapest tier. One declaration per line, as `<decl_id>  <kind>  <container>
<file>:<line>`.

```bash
code-monkey get
code-monkey get --path Sources/MyApp
code-monkey get --kind func --container Database
code-monkey get --name-like "*User*"
code-monkey get --tag ai:invariant
code-monkey get --limit 50 --offset 100
```

## Shape

Signatures, grouped by enumerate order.

```bash
code-monkey get --path Sources/UserService.swift --fields signature
code-monkey get --path Sources --fields signature
```

## Intent

Doc comments, directives, and elision counts. These are the default fields on a
single resolved target.

```bash
code-monkey get Indexer
code-monkey get "Indexer.run(full:Bool)"
code-monkey get createUser --fields signature,summary,invariants
```

On a resolved single target the elision signals `body_lines`, `directive_count`,
and `doc_lines` come back automatically, so you can decide whether to ask for the
body without spending a second call.

## Body

Explicit and opt-in only.

```bash
code-monkey get "Database.query(_:String,_:[Bindable])" --fields body
code-monkey get "Database.query(_:String,_:[Bindable])" --fields body --body-mode full
code-monkey get "..." --fields body --body-mode full --file Sources/A.swift
```

## Fold

A type with its bodies elided. This is the workhorse for context-aware reads,
and the output is real Swift you can read top to bottom: types open, member
signatures are listed, and bodies become `{ ... }` unless kept.

```bash
code-monkey get Indexer --fields body --body-mode fold
code-monkey get Indexer --fields body --body-mode fold --keep run
code-monkey get Indexer --fields body --body-mode fold --keep run --keep relPath
code-monkey get --container Indexer --fields body --body-mode fold
code-monkey get Indexer.relPath --fields body --body-mode fold --deep
code-monkey get FileCmd --fields body --body-mode fold --deep
```

## The fields

| Field | Source | Notes |
|---|---|---|
| `signature` | stored signature text | |
| `summary` | doc comment plus narrative tags: `why`, `example`, `see`, `depends`, `prompt`, `section` | |
| `invariants` | contract tags: `invariant`, `requires`, `warn`, `spec` | split from `summary` by tag, not a separate table |
| `ownership` | file path, configured sources, container | returns `{file, container, module}` |
| `dependencies` | capitalized identifiers in the signature | heuristic and syntactic, resolved against nothing |
| `body` | shaped by `--body-mode` | `ref` gives `{file,start_line,end_line}`, `full` the whole declaration, `fold` the elided form |
| `callers` / `callees` | call sites and the call graph | graded edges, and `not indexed` when call sites are off |

`--format` picks the rendering: `folded` is comment-annotated Swift and the
cheapest in tokens, `markdown` is headed prose, and `json` is the envelope with a
`fields` array. Keys you did not request are omitted rather than set to null.

## The JSON envelope

With `--json`, every command returns a stable shape.

```json
{
  "schema_version": 1,
  "command": "get",
  "tier": "get",
  "result_count": 1,
  "warnings": [],
  "freshness": "fresh",
  "data": {}
}
```

`freshness` appears whenever the command can determine it. Consumers should
branch on `schema_version`, never on output formatting.

## Import lines

`imports` answers the one question `get` does not.

```bash
code-monkey imports                            # every import in the project
code-monkey imports Sources/MyApp              # narrow to a subtree
code-monkey imports --spi any                  # the SPI this project consumes
code-monkey imports --spi Internal             # who consumes that one group
code-monkey imports --module Foundation
code-monkey imports --testable
```

Text output is the file, a tab, and the import as written. JSON gives `{file,
line, module, path, kind, spi, testable}` per row, where `module` is the first
path component, `path` the whole dotted path, and `kind` the scope keyword on a
scoped import.

Nothing is deduplicated. Two files importing the same module are two rows,
because "which files reach for this" is the question being asked.

## See Also

- <doc:ReadableOutlines>
- <doc:DeclarationIdentifiers>
- <doc:TheCallGraph>
