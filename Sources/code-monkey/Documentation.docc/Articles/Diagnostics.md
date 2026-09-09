# Diagnostics

`doctor` answers which binary is running, and the audit log answers what it did.

## Overview

```bash
code-monkey doctor
code-monkey doctor --json
```

`doctor` reports the provenance of the running binary, the project root, the
index path, the schema version, WAL mode, the audit destination, freshness, and
actionable warnings.

## Provenance

Provenance is the part worth explaining. `doctor` prints, for the running
executable, the checkout it is being run against, and the MCP peer beside it:

```
built_from=/path/to/checkout commit=abc1234 build=#20
```

It warns whenever those disagree. More than one repository can build a binary of
this name, and when the wrong one is on `PATH` the symptoms are indirect. A
schema mismatch, or an MCP tool list that does not match the CLI. So the question
"which checkout produced this?" is worth a direct answer.

Two things make that answer possible. Build information is committed, so the
commit it names describes the source and not the working copy that ran the
compiler, and `make install` writes a manifest beside the binaries recording the
source root, commit, build sequence, and build date.

Staleness is decided by build sequence, never by modification time. `make
install` copies, and a copy always lands with a fresh timestamp, so a date
comparison would report every stale install as current.

The checkout's own identity is read out of the committed source rather than by
executing the debug binary, because a diagnostic should not depend on the binary
it is diagnosing being runnable.

`doctor` identifies the binary actually running. It does not scan `PATH`.

## The audit log

Every invocation appends one metadata-only JSON line: timestamp, command,
project path, the full argv it was dispatched with, a status of `ok` or an exit
code, elapsed milliseconds, and the tier and target the command reported. SQL
text and source bodies are never logged.

```bash
code-monkey file log --last 20
code-monkey file log --last 200 --argv          # replay it as command lines
code-monkey file log --last 200 --argv --failed # only what did not exit 0
code-monkey file log --last 500 --stats         # usage summary
```

The record is written from the single dispatch point both the CLI and the
interactive shell go through, after argument normalization, so a compact level
flag is stored in its split form and a recorded line re-parses as written.
`--argv` prints those lines back, oldest first, shell-quoted.

The positional argument to `query` is replaced with a placeholder before writing,
so the promise that SQL never reaches the log survives argv recording.

`--stats` summarizes instead of listing. Every figure is derived by resolving the
recorded argv against the command tree that exists now, so an option a later
build dropped is reported as a line that no longer parses rather than silently
miscounted. The sections are per-command counts, failures, median and 90th
percentile timings, the depth distribution for `code` and `get`, the argv the
parser refused, and targets read twice within two minutes by different reads.

Appends use an in-process mutex, a cross-process file lock, and append-only
opens, so concurrent processes cannot interleave records.

## Sandbox-escape file operations

The `file` command reads and writes paths outside the project, with every
operation audited.

```bash
code-monkey file read ~/foo.json
code-monkey file read ~/big.log --lines "-50"
code-monkey file read ~/src.swift --lines "1-30"
echo "content" | code-monkey file write ~/out.json --context "why"
echo "line"    | code-monkey file append ~/log.txt
```

## Concurrency model

The database is a Swift actor, and the SQLite handle never leaves actor
isolation. Results travel as sendable row and value types rather than untyped
dictionaries.

Read commands open the existing index read-only, set query-only mode, and never
bootstrap or update schema metadata, so independent readers run concurrently
without changing the index file.

The `index` command and the write commands open a writable connection. WAL mode
permits readers during a write transaction. A busy timeout waits briefly for a
competing writer instead of failing immediately, then returns an actionable
writer-busy error. Write transactions begin immediately, so writer contention
resolves before any index mutation starts.

Transaction closures receive an isolated database and contain no suspension
points, so an entire multi-statement transaction stays one actor-isolated
critical section.

## The interactive shell

`repl` opens an interactive shell that tab-completes commands, options, and their
values. It parses lines the process argv never sees, and dispatches them through
the same path the CLI uses, so audit records and argument normalization apply
identically.

## See Also

- <doc:Configuration>
- <doc:TheMCPServer>
