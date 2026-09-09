# Querying the index

Read-only SQL against the database, for the questions the read commands cannot
express.

## Overview

`query` is the escape hatch beneath `get` and `code`: counts, distributions, and
cross-cutting searches neither of those can phrase. Reach for it to decide what
is worth reading, then read that with `code`.

```bash
code-monkey query "SELECT name, path FROM declarations d
                     JOIN files f ON f.id = d.file_id
                    WHERE kind='func' AND container='Database'"
```

Only `SELECT`, `WITH`, and `PRAGMA` run. Anything else is refused.

## Recipes

A few queries are worth having by heart, and ship as named recipes.

| Recipe | Returns |
|---|---|
| `sections` | the sections the author declared, the cheapest map of a project |
| `mass` | declarations per file, densest first, showing where the code actually is |
| `invariants` | every `ai:invariant`, with the declaration it guards |
| `protocols` | which protocols the project leans on, most-conformed first |

## Two joins that bite

`declarations` carries no path column. Join `files` on `file_id`.

And `decl_id` names two different things. On `declarations` it is the stable text
handle you hand to `get`. On `directives` and `doc_comments` it is an integer
foreign key to `declarations.id`. Equating the two matches nothing and reports no
error.

## See Also

- <doc:SchemaReference>
- <doc:TheReadModel>
