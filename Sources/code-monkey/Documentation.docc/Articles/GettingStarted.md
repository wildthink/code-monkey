# Getting started

Install the binaries, bootstrap a project, and make your first read.

## Overview

code-monkey requires Swift 6.3 or later, which means Xcode 17 and macOS 26.

## Install

```bash
git clone https://github.com/wildthink/code-monkey.git
cd code-monkey
make install
```

`make install` builds release and puts both `code-monkey` and `code-monkey-mcp`
in `~/.local/bin`. Override the destination with `make install
PREFIX=/usr/local/bin`. To build without installing, run `swift build -c
release`.

Verify with `code-monkey --help`.

## First run

Point the tool at any Swift project.

```bash
cd path/to/your/swift/project
code-monkey init                          # writes .code-monkey.toml + .code-monkey/
code-monkey index                         # builds .code-monkey/index.db
code-monkey get                           # everything, cheapest possible read
```

`init` is idempotent except for the config file. Pass `--force` to overwrite an
existing one.

The index lives at `.code-monkey/index.db`. Add `.code-monkey/` to
`.gitignore`, and commit `.code-monkey.toml` so the project's parse rules travel
with it.

Every command walks up from the working directory to find the config file or the
`.code-monkey/` directory, so you can run from any subdirectory. Override the
root with `--project`.

## Choosing what to read

Start from context you already have. Do not mechanically walk every tier.

1. Use filenames, manifests, config, and non-Swift docs to establish shape.
2. Run one `index` before any Swift semantic read.
3. If you know the symbol, call `get <decl_id>` directly.
4. If ownership is unknown, enumerate with `--path`, `--kind`, `--container`,
   `--name-like`, or `--tag`.
5. Add `--fields` only for the attributes the question actually needs.
6. Reach for `--fields body` only when the implementation is required.
7. Stop as soon as the current command resolves the uncertainty.

When developing code-monkey itself, run `.build/debug/code-monkey` after a local
build. A stale binary on `PATH` otherwise hides local fixes.

## Keeping the index current

There is no file watcher. Run `index` after any edit made outside `clip`,
`move`, or `rename`. Indexing is incremental, keyed on SHA-256 per file.

```bash
code-monkey index                                       # incremental
code-monkey index --full                                # rebuild from scratch
code-monkey index --check                               # report stale state, no writes
```

Schema versions are rebuilds, not migrations. Every table is derived from
source, so when the schema version moves, `index` drops the old tables and
rebuilds. Writable commands refuse to run against an index of the wrong version
rather than discarding it behind your back.

## See Also

- <doc:Configuration>
- <doc:TheReadModel>
- <doc:Diagnostics>
