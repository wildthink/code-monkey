# The MCP server

`code-monkey-mcp` exposes the CLI's commands as Model Context Protocol tools over
standard input and output.

## Overview

Seventeen tools ship today, covering `init`, `index`, `doctor`, `get`, `code`,
`calls`, `clip`, `move`, `rename`, `query`, `weave`, `imports`, `version`, and the
four `file` operations. This lets an agent use code-monkey as a standing
connection instead of invoking the CLI through a shell each time.

```
swift build
.build/debug/code-monkey-mcp --project /path/to/swift/project
```

`--project` sets the default repository root, and each tool call can override it
with a project argument. `--code-monkey-bin` overrides the binary path, which
otherwise defaults to the sibling of the server in the same build output
directory.

## The tools are not written down

At startup the server runs the CLI's experimental help dump, which is
ArgumentParser's public JSON tree in its versioned schema, and turns that tree
into tool schemas and, on the way back, into argv. Add an option to a command and
it appears here. Nothing needs editing twice.

A small policy table holds only what the dump cannot say: which arguments are
integers, since the schema carries no value types, which value lists are open
rather than exhaustive, which payloads travel on standard input, and which flags
the server drives itself.

No tool description is written in the server. Each one is the command's own
abstract and discussion.

## What that requires of command prose

Everything above an `EXAMPLES` heading is published to MCP clients. Everything
from that heading down is dropped, because it is literal shell invocations a
client cannot run. Write the semantics above the heading and the transcripts
below it.

Flag names are rewritten on the way out, so a hyphenated option on a help screen
reaches a client with an underscore. Spell options as the CLI does and wrap them
in backticks, or the renamed form reads as an ordinary word.

One asymmetry is worth knowing, because getting it wrong is silent.
ArgumentParser's list of value strings is documentation, and is explicitly
allowed to be partial, while a JSON Schema enumeration validates. Only sets
confirmed exhaustive become an enumeration. Options taking a bare group name, and
comma-separated lists, publish their values as prose instead.

It is a thin wrapper, not a reimplementation. Each tool call shells out to the
`code-monkey` binary built alongside it and forwards standard output. No index or
database logic lives in this target.

## Narrowing the advertised surface

Every tool schema is prompt context the client re-sends on every turn, whether or
not it calls the tool. A session that was only ever going to read should not be
quoted the write tools.

| Profile | Tools | Use when |
|---|---|---|
| `all` (default) | 17 | open-ended sessions |
| `read` | 6, centered on `get` and `code` | lookups only |
| `nav` | 9, adding `calls`, `imports`, and `query` | reading and tracing, no edits |
| `write` | 13, adding `clip`, `move`, `rename`, and the four `file` tools | an agent that reads, then applies changes |

The `init`, `index`, `doctor`, and `version` tools are in every profile. A client
that cannot build or diagnose its own index is stranded by the first stale-index
error. The `weave` tool is document generation rather than lookup, so it appears
only in `all`.

The `write` profile builds on `read`, not on the essential four. An edit is a
read followed by a write, and a client that can replace a declaration but cannot
read the one it is replacing has to guess, or open the whole file, which is the
cost this tool exists to avoid.

```
code-monkey-mcp --profile nav
```

The profile is also settable through the `CODE_MONKEY_TOOL_PROFILE` environment
variable. An unknown name is an error, not a silent fallback to `all`, because a
profile that quietly does not apply is worse than no profile.

## See Also

- <doc:Diagnostics>
- <doc:TheReadModel>
