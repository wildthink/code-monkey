---
name: code-monkey
description: >
  Use this skill whenever working with Swift source files — locating decls,
  reading just enough to answer, finding callers, or making a surgical edit.
  ALWAYS use this instead of cat/read_file/grep on .swift files: code-monkey
  exposes a SQLite index of the project with a tiered API — cheap reads first,
  bodies only on explicit request — and a single safe write primitive. Trigger
  whenever the user asks about a Swift type, function, property, or file; wants
  callers/callees of a Swift symbol; or mentions decl_id, `//# ai:` directives,
  or `.code-monkey/`. Works through the code-monkey-mcp tools (any
  `code_monkey_*` tool) when connected, or the `code-monkey` CLI via shell
  otherwise — check which is available before starting.
---

# code-monkey skill

Drive Swift code work through code-monkey — the MCP tools when they are
connected, the CLI otherwise. Read in tiers; body bytes are the most expensive
thing and must be opted into. Never `cat` or `read_file` a Swift source: use
the index.

## Two ways in: MCP tools or the CLI

code-monkey is reachable two ways. Use whichever is connected — both run the
identical code (the MCP server shells out to the same binary), so everything
below describes the behavior once.

1. **MCP tools** (preferred — no subprocess/shell overhead from your side).
   Tools are *generated from the CLI's own command tree*, so don't work from a
   memorized list: call `tools/list` and match on the `code_monkey_*` suffix.
   The server prefix varies by how the MCP client labeled the connector
   (e.g. `mcp__code-monkey__code_monkey_get`) — never hardcode it.
   - Naming is `code_monkey_<subcommand>`; a command that only groups
     subcommands expands to its children, so `file read` is
     `code_monkey_file_read`.
   - `repl` and `help` are never exposed. `--json` is injected by the server
     and is not a parameter you can set.
   - The server may advertise a *profile* rather than the whole surface:
     `read`, `nav`, `write`, or `all`. `write` is a superset of `read` and
     carries the whole write surface — `clip`, `move` and `rename`; every
     profile includes `init`/`index`/`doctor`/`version`. If a tool you expect
     is absent, the server was started on a narrower profile — say so rather
     than falling back to `cat`.
2. **CLI via shell** (fallback when no matching MCP tool exists): the
   `code-monkey` binary, same subcommands as positional args.

Flag ⇄ argument mapping is 1:1: CLI `--limit 5` ⇄ `{"limit": 5}`, CLI
`--fields signature,body` ⇄ `{"fields": "signature,body"}`. Examples below show
the CLI form; translate the same way. Two MCP-only arguments have no flag:
`new_body` (the declaration text for `code_monkey_clip`) and `content` (bytes
for `code_monkey_file_write`/`_append`) arrive as arguments rather than stdin.
`new_body` is optional, because `cut` removes a declaration and reads nothing —
but the paste modes require it, and you must set exactly one mode yourself:
none is injected.

---

## Rules (never break)

- Never read an **indexed** Swift file with `cat` / `read_file` to learn its
  structure. Use code-monkey. A Swift file outside `sources` in
  `.code-monkey.toml` — `Package.swift` above all — is not in the index, so read
  it directly; `query "SELECT path FROM files"` settles which is which. `rg` is
  not banned, it is scoped: see *Neighbours* below.
- Always `index` before the first read in a session.
- **Always name the project explicitly.** MCP: pass `project` on every call.
  CLI: run inside the project tree, or pass `--project`. An MCP server's default
  root is whatever directory the *host* launched it from, not necessarily the
  user's project.
- Read at the lowest tier that answers the question. Climb only when needed.
- `decl_id` is the stable handle. Every cheap read returns it. Pass it to heavy reads.
- Disambiguate by `--file` when multi-match. Don't guess.
- Tie every command to one explicit uncertainty. Stop when its answer resolves that uncertainty.
- Report each use: command category, question answered, and why it was cheaper than direct source inspection.

## Efficient selection

Start from known context, not mechanically from the cheapest read:

1. Use `fd`, config, manifests, and non-Swift docs for project shape — see
   *Neighbours* below for the split of labour.
2. Run one `code-monkey index` before Swift semantic reads.
3. If symbol is known, call `get <decl_id>` directly. Skip filtered enumeration.
4. If ownership is unknown, run `get` with `--path`/`--kind`/`--container`/`--name-like`/`--tag` to enumerate.
5. Add `--fields` only for attributes you actually need; omit it for the cheapest locate-only view.
6. Use `--fields body` only after a bare `get` shows doc/directives suggest the body matters.
   When the body only makes sense beside its siblings, use `code <Type> --expand <member>` — one call, not two.
7. Batch independent read-only commands when useful. If one lock occurs, serialize remaining calls.
8. Reach for `rg` when the question is about **text inside a body** and `fd` when
   it is about **files the index doesn't hold**. The index cannot answer either.
9. Stop using `code-monkey` when setup and lookup cost exceeds direct non-Swift inspection value.

At task end, report calls that produced findings, failed or duplicated calls, and broad source reads avoided.

When developing `code-monkey` itself, use `.build/debug/code-monkey` after
building.

**Run `code-monkey doctor` first in any session that uses the CLI or the MCP
server.** More than one repository can build a binary of this name, from
histories that are not related, and the failure is silent: a tool list that
disagrees with the CLI, or a schema mismatch. `doctor` reports `built_from`,
`commit` and `build=#N` for the running executable, for the checkout it is run
against, and for the `code-monkey-mcp` peer beside it, and warns when they
differ. It identifies the binary actually running; it does not scan `PATH`.

---

## Neighbours: `rg` and `fd`

The index models **declarations** — names, kinds, containers, signatures, doc
comments, `//# ai:` directives, imports, SPI groups, and call-site names. It
stores bodies as byte offsets rather than text, and indexes only the Swift files
under `sources`. Two classes of question therefore sit outside it at every tier:

| Question | Tool | Why not the index |
|---|---|---|
| String literal, error message, magic number, `TODO`, any token inside a body | `rg` | no body text is stored — `query` cannot see inside a body |
| Anything in `.toml`, `.md`, `.json`, fixtures, `Package.swift` | `rg` / `fd` | non-Swift and out-of-`sources` files are not indexed |
| Does this file exist / what is its path for `--file` | `fd` | cheaper than a query, and sees unindexed files too |

Note what is *not* on that list: `import` lines are indexed here, so use the
`imports` command rather than `rg '^import '` — it carries `@_spi` groups and
`@testable` marks that a text match cannot see.

- **Structure → `code-monkey`.** What exists, where, what it's called, what
  documents it, what reaches it.
- **Text → `rg`.** What a body literally says.
- **Files → `fd`.** What is on disk, indexed or not.

```bash
rg -n 'PRAGMA journal_mode' Sources           # a literal only a body can hold
rg -l --type swift 'BEGIN IMMEDIATE'          # which files, not which lines
rg -c 'ai:invariant' Sources                  # counts before reading anything
fd -e swift . Sources                         # the file set on disk
fd 'Get' -e swift                             # locate a file for `--file`
fd -e md -d 1                                 # BOOK.md / sidecars `weave` reads
```

`rg` respects `.gitignore`, so `.build/` and `.code-monkey/` stay out without
flags.

### Hand rg's answer back to the index

`rg` is a locator of last resort, not a reader. Its output is `file:line`;
convert that to a `decl_id` and resume the tiered read rather than widening the
match with `-A`/`-B`:

```bash
rg -n 'BEGIN IMMEDIATE' Sources               # → Sources/Database.swift:212
code-monkey get --path Sources/Database.swift    # locate-only, find the owner
code-monkey get Database.write --fields body --body-mode full
```

### Corroborating a graded call edge

`calls` grades edges by name, not by type, so `low` and `medium` edges are
leads. `rg` is the cheapest way to promote or kill one — and the required
follow-up after `rename`, which reports call sites and never rewrites them.

### Anti-patterns

- `rg 'func '` to enumerate declarations — `get --kind func` is cheaper, exact,
  and returns `decl_id`s.
- `rg -A 40 'func createUser'` to read a body — that is `get --fields body`.
- `rg` to find callers — that is `calls`; use `rg` only to grade its output.
- `rg '^import '` — that is `imports`, which knows about SPI and `@testable`.

---

## `get` — the one read command

Everything that isn't editing, querying, or projecting goes through `get`.
A bare positional argument resolves to one record (ambiguous matches list
candidates — pick one and rerun with exact `decl_id`). Any of `--path`,
`--kind`, `--container`, `--name-like`, `--tag` — or omitting the positional
entirely — switches to enumerate mode and returns every match instead.

```bash
code-monkey get                                    # everything (cap 500)
code-monkey get --path Sources/MyApp                # subtree
code-monkey get --kind func --container UserService
code-monkey get --name-like "*User*"
code-monkey get --tag ai:invariant                  # decls carrying a directive
code-monkey get --spi any                           # everything behind @_spi
```

Enumerate mode with no `--fields` prints one decl per line:
`<decl_id>  <kind>  <container>  <file>:<line>` — the cheapest possible read,
no extra per-row queries. A decl behind `@_spi` carries a trailing
`@_spi(<groups>)` tag; single-target reads report it as an `// @_spi:` line.

### Pick fields

```bash
code-monkey get createUser                                          # default: signature,summary,invariants
code-monkey get createUser --fields signature
code-monkey get createUser --fields ownership,dependencies --format json
code-monkey get "UserService.createUser(email:String,role:UserRole)"
```

`get` accepts exact `decl_id`, plain name, or substring. Choose any
combination of `signature`, `summary`, `invariants`, `ownership`,
`dependencies`, `body`, `callers`, `callees`. Unrequested fields cost nothing
and are omitted from JSON entirely (no `null` padding). On a single resolved
target, omitting `--fields` defaults to `signature,summary,invariants`; while
enumerating, omitting it shows locate fields only. Elision signals
(`doc_lines`, `body_lines`, `directive_count`) are included automatically when
resolving a single target.

`callers`/`callees` return real edges when call sites are indexed. They are
matched by name and graded `high`/`medium`/`low` — see `calls` below — and the
grade is part of the answer, not decoration. An empty result says whether edges
were suppressed by the confidence floor or genuinely absent; `callers: not
indexed` means call sites are turned off, which is a different fact again.

### Read the body

```bash
code-monkey get createUser --fields body                                    # ref only: {file,start_line,end_line}
code-monkey get createUser --fields body --body-mode full                   # whole decl text
code-monkey get UserService --fields body --body-mode fold                  # type, member bodies as `{ ... }`
code-monkey get UserService --fields body --body-mode fold --deep           # nested types keep members
code-monkey get UserService --fields body --body-mode fold --keep createUser # one body inlined, siblings folded
code-monkey get UserService.createUser --fields body --body-mode fold --deep # auto-context: enclosing type, this body kept
```

`--body-mode` defaults to `ref` (cheap, no source bytes). `full` returns the
whole declaration. `fold` is the "type context plus selected bodies" view —
default skips member bodies; `--keep` selectively inlines; `--deep` on a leaf
swaps the target to its enclosing container. For the old `fold "Container.*"`
glob use case, combine `--container`/`--kind`/`--name-like` (enumerate mode)
with `--fields body --body-mode fold` instead — no glob syntax needed.

---

## `code` — outlines at a chosen rung

`get` answers facts *about* declarations; `code` renders the declarations
themselves as readable (not compilable) Swift. `--level` is the dial:

```bash
code-monkey code Walker              # -L0  struct Walker {}
code-monkey code Walker -L1          #      + properties and enum cases
code-monkey code Walker -L2          #      + member signatures
code-monkey code Walker -L3          #      + bodies
code-monkey code Walker:isEx         # only members matching "isEx" (implies -L2)
code-monkey code . --types           # every type in the project, one shell each
```

**Reading one body with its context is one call, not two.** `--expand` renders
matches in full and leaves everything else at `--level`:

```bash
code-monkey code Walker --expand isExcluded   # that body, siblings as signatures
code-monkey code Walker -L0 --expand isExcluded   # that body and nothing else
code-monkey code Walker --fold --expand isExcluded   # siblings as `{ ... }`
```

Do **not** reach for `Walker:isExcluded --body` when you want surrounding
context — `:member` hides the siblings it filters past, so that costs a second
call for the outline. `--expand` implies `-L2`, forces its match in even below
the rung that would have listed it, and is inherited by anything nested inside
a matched type. An explicit `--access`/`--spi` floor still outranks it.

`code --fold --expand X` is the outline twin of `get X --fields body
--body-mode fold --keep X`. Use `code` for the synthetic uniform view, `get`
when you need byte-accurate source.

---

## decl_id format

Stable handle. Format: `[Container.]name[(label:Type,label:Type)]`

- Type: `UserService`, `Database`, `Indexer`
- Nested type: `FileCmd.Read`
- Method: `UserService.createUser(email:String,role:UserRole)`
- Init: `Database.init(path:URL)`
- Property: `Indexer.project`
- Top-level free func: `relativePath(_:String,root:URL)`
- Extension method: `Int64.bind(stmt:OpaquePointer?,index:Int32)`

Argument types disambiguate overloads. `name`-only lookups still work for
single-match decls; fall back to exact `decl_id` for overloaded names.

---

## Project state

Discovery: each command walks up from cwd until it finds `.code-monkey.toml`
or `.code-monkey/`. No `--project` flag needed when run inside the tree.

```bash
code-monkey index                                  # sha256-skipped per file (incremental, default)
code-monkey index --check                          # stale-state report, no writes
code-monkey index --full                           # rebuild from scratch
```

`clip`, `move` and `rename` auto-refresh the touched file. Manual edits require
a manual `index`.

Read commands open the existing index read-only and do not bootstrap or mutate schema metadata.
`index` and `clip` retain writable access.
Database actor owns SQLite handle. Typed `Sendable` rows cross actor boundary.
Write transactions use `BEGIN IMMEDIATE` and an isolated, non-suspending closure.

`--json` emits envelope fields: `schema_version`, `command`, `tier`,
`result_count`, `warnings`, `freshness`, and `data`.

Use `code-monkey doctor` for executable, index, schema, WAL, audit, and
freshness diagnosis.

---

## Editing

`clip` is write-only — it writes a declaration, it does not read one. To read a
decl's body, use `get --fields body`. Exactly one of `--paste-replacing`,
`--paste-after`, `--paste-before` or `--cut` is required.

```bash
# Stdin = declaration text including attrs/signature/body.
code-monkey clip createUser --paste-replacing < new.swift
code-monkey clip createUser --file Sources/UserService.swift --paste-replacing < new.swift  # disambiguate
code-monkey clip createUser --paste-after < sibling.swift                                   # insert after
code-monkey clip createUser --paste-before < sibling.swift                                  # insert before
code-monkey clip createUser --cut > removed.swift                                           # delete, keeping source
```

Resolution is two-tier, as in `get`: exact `decl_id` first, then
`name`/`decl_id`/signature substring. The exact tier wins, so a container name
targets the type itself, not its members — `clip Box --paste-replacing` replaces
the whole of `Box`, and stdin must then carry every member. Multiple matches
abort with the candidate list and nothing is written; narrow with `--file`.

`--paste-after`/`--paste-before` insert stdin as a new decl beside the matched
one, in the same scope — use them to add a member rather than rewriting its
container. They re-indent stdin's first line to match the neighbouring decl,
supply their own blank-line separator, and trim trailing newlines.
`--paste-before` inserts *above the decl's doc comment*, not between a doc
comment and the decl it describes.

`--cut` deletes the decl together with its comment block and echoes the removed
source to stdout, collapsing the blank lines around the hole. The payload is
content-first (no leading indent), so it pastes straight back:

```bash
code-monkey clip Box.note --cut > removed.swift
code-monkey clip Box.tail --paste-before < removed.swift   # exact restore
```

All four modes print status to **stderr**; stdout carries payload only, so
`--cut`'s redirect captures exactly the removed source.

`clip` writes at index-derived byte offsets, so it verifies the file's SHA-256
against the one recorded at index time and refuses if they differ — an edit made
outside `clip` shifts every later offset and would otherwise splice into the
middle of a token. Run `code-monkey index` after any non-`clip` edit. There is no
override.

`decl_offset` is the declaration itself: attributes included, comments excluded
(their text lives in `doc_comments`/`directives`). So `--paste-replacing` leaves
the commentary above a decl alone — **and therefore its payload must not repeat
the doc comment**, which would land under the existing one. `clip` refuses that;
pass `--with-doc` to replace the comment block along with the decl, which is how
a doc comment is edited through `clip`.

---

## Moving and renaming

```bash
code-monkey move "Box.note()" --to Sources/Other.swift               # append at end
code-monkey move "Box.note()" --to Sources/Other.swift --after tag   # place precisely
code-monkey rename "Box.note()" --to observe
```

`move` takes the decl **and its comment block**, closes up the source, and
re-indents the block to its new nesting depth while preserving the nesting
inside it. Use it instead of `--cut` + `--paste-after` across files. It does not
check that the decl is legal at its destination, and the destination file must
already exist.

`rename` changes the **declaration only** and prints the call sites that may
refer to it, with confidence grades. It never rewrites them: `call_sites` stores
line numbers rather than byte offsets, and the edges are graded syntactic
guesses, so an automatic update would rename unrelated code. Rename, read the
list, then fix each site with `clip`.

Before editing:
1. `code-monkey get <id>` — read doc + `//# ai:` directives.
2. Honor `ai:invariant`, `ai:prompt`, `ai:requires`, `ai:warn`, `ai:spec`.
3. Make the change.
4. Index auto-refreshes for that file.

---

## Querying the index

Anything `get` can't express, run SQL directly:

```bash
code-monkey query "SELECT name, file_path FROM declarations d
                     JOIN files f ON f.id=d.file_id
                    WHERE kind='func' AND container='Database'"
```

Read-only: SELECT/WITH/PRAGMA only.

Schema:
- `files(id, path, mtime, sha256, last_indexed)`
- `declarations(id, decl_id, file_id, container, container_kind, kind, name,
                signature, access, spi, modifiers, start_line, end_line,
                decl_offset, decl_length, body_offset, body_length)`
- `imports(id, file_id, module, path, kind, spi, testable, line)`
- `doc_comments(decl_id, text)`
- `directives(id, decl_id, tag, value, line)`
- `narrative(id, file_id, kind, path, text)`

---

## `//# ai:` directive taxonomy

Recognized tags (any others pass through as `ai:<word>`):

| Tag | Meaning |
|---|---|
| `ai:section: "<name>"` | Literate chunk label — groups decls in `weave`. |
| `ai:why` | Rationale prose. |
| `ai:spec` | Behavioral contract (pre/post). |
| `ai:invariant` | Guarantee the body must preserve. |
| `ai:prompt` | Instruction to an AI editing this decl. |
| `ai:example` | Usage example. |
| `ai:see: <name>` | Cross-reference. |
| `ai:depends: <name>` | Narrative dependency. |
| `ai:warn` | Intentional pattern; do not "fix". |
| `ai:requires` | Caller precondition. |

Syntax (above the decl, no blank lines between):

```swift
/// Doc comment lives above directives.
//# ai:invariant: returned id is unique
//# ai:prompt: never log raw email
public func createUser(email: String) async throws -> User { ... }
```

---

## Literate projection

```bash
code-monkey weave Sources                          # whole subtree as Markdown
code-monkey weave Sources --summary                # signatures + prose, no bodies
code-monkey weave --section "Authentication"       # only decls with that ai:section
code-monkey weave Sources --access public          # only open + public (API surface)
code-monkey weave Sources --access internal        # adds internal + package
code-monkey weave Sources --access public --spi none   # ...minus anything behind @_spi
```

`weave` reads `BOOK.md` at project root and `<File>.md` sidecars next to Swift
files, interleaving them with decls in source order.

---

## SPI scopes

`@_spi(Group)` is tracked as a **second axis**, not an access level. `access`
still records only the Swift modifier, so a `@_spi(X) public func` reads as
`public` there and `--access public` keeps its old meaning. What it is behind
lives in the `spi` column, and `--spi` filters on it independently:

```bash
code-monkey code . --all --spi any            # the whole SPI surface
code-monkey code . --all --access public --spi none   # the real public API
code-monkey get --spi Internal                # one group
code-monkey weave Sources --spi any           # SPI surface, as prose
```

`--spi` takes `any` (behind some `@_spi`), `none`, or a group name. Group names
match whole, never as a prefix.

SPI is **effective, not declared**: a member inherits every group its enclosing
type or extension carries, the way Swift resolves it. `@_spi(Testing) extension
Plain { func f() }` reports `f` as `@_spi(Testing)` even though nothing is
written on the function.

The consuming side is `imports`:

```bash
code-monkey imports                      # every import line in the project
code-monkey imports --spi any            # the SPI this project reaches for
code-monkey imports --spi Internal       # who consumes that group
code-monkey imports --module Foundation  # every file importing a module
code-monkey imports --testable
```

Ask `code --spi` what the project *exposes*; ask `imports --spi` what it
*consumes*. Renaming or retiring a group needs both.

---

## File ops outside the sandbox

```bash
code-monkey file read ~/path/foo.json
code-monkey file read ~/path/foo.log --lines "-50"
echo "..." | code-monkey file write ~/path/out --context "reason"
echo "..." | code-monkey file append ~/path/log
code-monkey file log --last 20                     # audit trail
code-monkey file log --last 200 --argv             # replay it as command lines
code-monkey file log --last 200 --argv --failed    # only what did not exit 0
code-monkey file log --last 500 --stats           # how the tool is actually being used
```

Every invocation appends one JSONL line carrying the argv it was dispatched with, the
working directory, `status` (`ok` or `exit <n>`), and `ms`. `--argv` renders those back as
the command lines that produced them, oldest first — a readable session history, and one you
can pipe to a shell. The argv is the post-normalization vector, so `-L2` reads back as
`-L 2` and every recorded line re-parses as written.

`file read/write/append` additionally write a semantic entry naming the path they touched;
those carry no `argv`, which is how a reader tells the two kinds apart.

`--stats` summarizes the log instead of listing it: per-command counts, failure counts, p50/p90
latency, and — for `code` and `get` — the distribution of *depths* actually asked for, read off
argv rather than off the tier a command reports about itself. Two sections are worth acting on.
**Usage errors** are the argv the parser refused, verbatim: each one is a command whose help
failed to teach its own spelling. **Re-reads** are the same target read twice inside two
minutes by different reads (`get shell → code L2`), which is the cheaper tier failing to answer.

`query`'s SQL is replaced with `<sql>` before the line is written, so recording argv does not
carry query text into the log.

Configure destination with a root-level TOML key such as `audit = ".code-monkey/audit.log"`;
relative paths resolve from project root. SQL and source bodies are never logged. Without
configuration, fallback remains `~/.code-monkey/audit.log`.

Concurrent appends use Swift `Mutex`, cross-process `flock`, and `O_APPEND`.
`code-monkey file log --project <path>` tails configured project log.

---

## Failure modes you'll hit

- **`project_root` is wrong, or `index_exists: false` despite a real index** —
  you didn't pass `project` (MCP) or aren't inside the tree / didn't pass
  `--project` (CLI). Confirmed failure mode: `doctor` with no `project`
  reported `project_root: "/"` and `index_exists: false` while a real index sat
  at the actual root. Suspect this before anything else when results are empty
  or odd for a project you know is indexed.
- **A tool you expect isn't in `tools/list`** — the server was started with a
  narrower `--profile`, or `repl`/`help` (never exposed). Not a reason to `cat`.
- **`no decl: X`** — index missing or stale. Run `code-monkey index`.
- **`ambiguous (N matches)`** — same name in multiple files OR overloaded
  signature. Use exact `decl_id` (with arg types) or `--file`.
- **`clip is write-only`** — you tried to read with `clip`, or passed no mode
  flag. Use `get --fields body` to read.
- **`... changed since it was indexed`** — the file was edited outside `clip`.
  Run `code-monkey index` and retry; nothing was written.
- **tools that don't exist, or a schema you didn't write** — you are talking to a
  binary built from another checkout. Run `doctor` and read `built_from`.
- **`only SELECT/WITH/PRAGMA allowed`** — `query` is read-only.
- **`UNIQUE constraint failed`** — pre-fix schema; run `rm -rf .code-monkey/` then `index`.
- **`index schema is version N, expected M`** — the index predates the current
  binary. Run `code-monkey index --full`; it drops and rebuilds from source
  (nothing is lost — every table is derived).

---

## Quick reference

```
init        write .code-monkey.toml + .code-monkey/
index       full or incremental build (--full to rebuild, --check for stale report, no writes)
doctor      provenance (built_from/commit/build #, MCP peer)
            + index/schema/WAL/audit/freshness diagnostics

get         field-selectable read; bare positional resolves one record,
            any of --path/--kind/--container/--name-like/--tag/--spi enumerates
            --fields signature,summary,invariants,ownership,dependencies,
                     body,callers,callees
            --body-mode ref|full|fold   (fold: --keep <pat>, --deep)
            --format folded|markdown|json
            --limit/--offset            (enumerate mode)

code        readable Swift outlines at a chosen rung of disclosure
            selector: Name | Name:member | file | directory | . (whole project)
            -L0..3                      shell | +properties | +signatures | +bodies
            --expand <substring>        full bodies for matches, rest at --level
            --vars/--funcs/--types/--cases/--all   exact slice instead of a rung
            --body/--fold --access <level> --spi any|none|<group> --doc --numbers

calls       call tree: who reaches a decl (default) or what it reaches (--callees)
            --both --depth N --limit N --include-refs --file <path>
            --min low|medium|high       (default medium; edges are graded guesses)
            --tests                     only branches reaching a test ("what covers this?")
            --summary                   blast-radius block instead of the tree

clip        write-only: --paste-replacing [--with-doc] | --paste-after
                      | --paste-before | --cut   <decl_id/name>
            (--file to disambiguate)
            status on stderr; --cut echoes removed source to stdout
move        relocate a decl + comment block: --to <file> [--after <decl>]
rename      rename a decl: --to <identifier>; refs reported, not rewritten
query       read-only SQL
weave       Markdown literate projection
imports     import lines with their @_spi groups and @testable marks
            --module <name> --spi any|none|<group> --testable
file        sandbox-escape read/write/append/log
version     build info
```

```
rg          body text and non-Swift files — what the index omits
fd          file discovery, including files outside `sources`
```

Always prefer the cheapest read that answers the question. Climb deliberately.
Structure through `code-monkey`; text through `rg`; files through `fd`.
