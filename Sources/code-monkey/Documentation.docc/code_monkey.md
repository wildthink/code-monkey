# ``code_monkey``

A Swift code index for humans and AI agents, with literate metadata and tiered reads.

## Overview

code-monkey parses a project with SwiftSyntax and builds a SQLite database of
every declaration — kind, container, signature, access, doc comments, `//# ai:`
directives, byte offsets — then exposes it through a CLI and an MCP server.

Reads are tiered. You drill from "what is here" to "show me that body" without
dumping the whole tree at every step, and you pay only for the slice you ask
for. Writes address the same byte offsets the reads report, so an edit lands on
a declaration rather than on a line number you had to guess.

Nothing requires a build. Everything the index knows comes from the shape of the
source, so it works on code that does not currently compile and finishes in well
under a second on a large project.

```bash
code-monkey index                    # build the index
code-monkey get --kind func          # every function, signatures only
code-monkey code MyType -L1          # a readable outline, one rung down
code-monkey calls MyType.save        # who reaches this?
```

### Two problems, one tool

**Reading Swift in chunks.** When you need only a signature you should not pay
for the whole file. When you need a body you should not have to know its line
numbers. Every read returns exactly the slice you asked for, keyed by a stable
`decl_id`.

**Keeping intent next to code.** Doc comments cover what a declaration is. The
`//# ai:` directives cover why it exists, what must hold, and what an editor
should never "fix". The index makes both queryable, and `weave` projects them
back as a Markdown book of the codebase.

### The command surface

Fifteen subcommands, in four groups.

| Group | Commands |
|---|---|
| Bootstrap and diagnose | `init`, `index`, `doctor`, `version` |
| Read | `get`, `code`, `calls`, `imports`, `query`, `stats` |
| Write | `clip`, `move`, `rename` |
| Project out | `weave`, `file`, `repl` |

Run any command with `--help` for its full option list.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Configuration>

### Reading the index

- <doc:TheReadModel>
- <doc:ReadableOutlines>
- <doc:TheCallGraph>
- <doc:QueryingTheIndex>

### Changing source

- <doc:TheWriteModel>

### Literate metadata

- <doc:Directives>
- <doc:LiterateProjection>

### Access and visibility

- <doc:AccessAndSPI>

### Operating the tool

- <doc:Diagnostics>
- <doc:TheMCPServer>
- <doc:KnownLimitations>

### Reference

- <doc:SchemaReference>
- <doc:DeclarationIdentifiers>
