# code-monkey

A Swift code index for humans and AI agents.

code-monkey parses your project with SwiftSyntax and builds a SQLite database
of every declaration — kind, container, signature, access, doc comments,
`//# ai:` directives, byte offsets — then exposes it through a CLI and an MCP
server with **tiered reads**, so you can drill from "what's here" to "show me
that body" without dumping the whole tree at every step.

Think `grep` + `ctags` + Knuth's literate-programming weave, backed by a real
parse and an SQLite file you can `SELECT` against.

```bash
code-monkey index                    # build the index
code-monkey get --kind func          # every function, signatures only
code-monkey code MyType -L1          # a readable outline, one rung down
code-monkey calls MyType.save        # who reaches this?
```

## Why

**Reading Swift in chunks.** When you only need a signature you shouldn't pay
for the whole file; when you need a body you shouldn't have to know its line
numbers. Every read returns exactly the slice you asked for, keyed by a stable
`decl_id`.

**Keeping intent next to code.** Doc comments cover *what*. `//# ai:`
directives cover *why*, what must hold, and what an AI should never "fix". The
index makes both queryable, and `weave` projects them back as a Markdown book
of the codebase.

## Install

Requires Swift 6.3+ (Xcode 17+ / macOS 26+).

```bash
git clone https://github.com/wildthink/code-monkey.git
cd code-monkey
make install
```

That builds in release mode and installs `code-monkey` and `code-monkey-mcp`
into `~/.local/bin`. Override the destination with
`make install PREFIX=/usr/local/bin`.

## First run

```bash
cd path/to/your/swift/project
code-monkey init      # writes .code-monkey.toml + .code-monkey/
code-monkey index     # builds .code-monkey/index.db
code-monkey get       # everything, cheapest possible read
```

## Commands

| | |
|---|---|
| `init` / `index` / `doctor` | lifecycle: configure, build, diagnose |
| `version` | build info |
| `get` | the one read — resolve a decl, or enumerate with filters |
| `code` | readable Swift outlines at a chosen rung of disclosure (`-L0..3`) |
| `calls` | call tree: who reaches a decl, or what it reaches |
| `imports` | import lines with `@_spi` groups and `@testable` marks |
| `query` | read-only SQL against the index |
| `weave` | Markdown literate projection |
| `clip` | the single write primitive — replace one declaration |
| `file` | audited read/write outside the indexed tree |
| `repl` | interactive shell |

## Use with an AI agent

Two ways in, both running identical logic:

- **MCP** — run `code-monkey-mcp`. Its tools are generated from the CLI's own
  command tree, named `code_monkey_<subcommand>`. Start it with
  `--profile read|nav|write|all` to advertise only the surface an agent needs;
  a tool the client can't call still costs its JSON schema in every request.
- **CLI** — the `code-monkey` binary, same subcommands.

[`SKILL.md`](SKILL.md) is a ready-made agent skill covering both paths, the
tiered-read discipline, the `//# ai:` directive taxonomy, and the failure modes
worth recognizing.

To keep the index honest across branch changes, point git at the bundled hooks:

```bash
make hooks
```

`post-checkout`, `post-merge`, and `post-rewrite` reindex after the working
tree moves, so byte offsets never point at the wrong place. `make unhooks`
reverts.

## Docs

- [`GUIDE.md`](GUIDE.md) — the full reference: every command, flag, and the schema
- [`SKILL.md`](SKILL.md) — the agent-facing skill
- [`ROADMAP.md`](ROADMAP.md) — where this is going, and what was deliberately left undone

## License

MIT. See [LICENSE](LICENSE).
