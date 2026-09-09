# Configuration

What `.code-monkey.toml` controls, and what a project without one gets.

## Overview

`init` writes a config file at the project root. Every value below is also the
built-in default, so a project with no config file behaves exactly as if it had
this one.

```toml
sources = ["Sources", "Tests"]
exclude = ["**/.build/**", "**/.git/**", "**/DerivedData/**", "**/Generated/**"]

# Optional. Relative paths resolve from project root.
audit = ".code-monkey/audit.log"

[index]
path = ".code-monkey/index.db"
follow_gitignore = true

[parse]
include_private = true
extract_doc_comments = true
extract_ai_directives = true

# Powers `calls` and `get --fields callers,callees`. Roughly quadruples the
# index file; set false if you don't need the call graph.
extract_call_sites = true
```

## Why the defaults include Tests

The default and the generated file used to disagree. `init` wrote `["Sources",
"Tests"]` while the built-in fallback was `["Sources"]` alone. A project that had
never been through `init` therefore indexed no test code, and `calls --tests`
reported "nothing covers this" as a fact about the code when it was really a fact
about the config. They now agree.

## Turning off the call graph

Call sites are most of the index file, roughly four rows per declaration. The
`bindings` and `conformances` that resolve their receivers ride along with them.

Set `extract_call_sites = false` to drop all three, or pass `--no-call-sites` and
`--call-sites` to a single `index` run. The flag overrides the config only when
actually passed.

Disabling clears the table and records the fact. `calls` then fails with a
message telling you how to turn it back on rather than reporting an empty graph,
`get` prints `callers: not indexed` instead of `none found`, and `doctor` shows
`call_sites=off`. Nothing else depends on it.

## Where the audit log goes

The root-level `audit` key chooses the destination. Without it, the fallback is
`~/.code-monkey/audit.log`.

The `file read`, `file write`, and `file append` operations always use the
fallback, because they do not resolve project config. `file log` does resolve it
and honors `--project`.

## See Also

- <doc:GettingStarted>
- <doc:TheCallGraph>
- <doc:Diagnostics>
