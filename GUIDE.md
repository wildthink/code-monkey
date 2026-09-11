# code-monkey

A Swift code index for humans and AI agents. Builds a SQLite database of every
declaration in your project — kind, container, signature, doc comments, `//#
ai:` directives, byte offsets — and exposes it through a CLI with tiered reads
so you can drill from "what's here" to "show me that body" without dumping the
whole tree at every step.

Think of it as `grep` + `ctags` + Knuth's literate-programming weave, all
backed by a SwiftSyntax parse and an SQLite file you can actually `SELECT`
against.

---

## Why this exists

Two problems, one tool:

1. **Reading Swift in chunks.** When you only need a function's signature, you
   shouldn't have to read its whole file. When you need its body, you shouldn't
   have to remember its line numbers. The CLI returns exactly the slice you
   asked for, identified by stable `decl_id`.

2. **Keeping intent next to code.** Doc comments cover what; `//# ai:`
   directives cover why, what must hold, and what an AI should never "fix".
   The index makes them queryable. `weave` projects them back as a Markdown
   book of the codebase.

---

## Install

Requires Swift 6.3+ (Xcode 17+ / macOS 26+).

```bash
git clone https://github.com/wildthink/code-monkey.git
cd code-monkey
make install                 # builds release, installs both binaries
```

`make install` puts `code-monkey` and `code-monkey-mcp` in `~/.local/bin`.
Override with `make install PREFIX=/usr/local/bin`. To build without
installing, `swift build -c release`.

Verify:

```bash
code-monkey --help
```

The DocC catalog in `Sources/code-monkey/Documentation.docc/` covers the same
ground as this guide, as a browsable archive:

```bash
make docs             # writes .build/docs
make docs-preview     # serves it locally
```

---

## First run, on any Swift project

```bash
cd path/to/your/swift/project
code-monkey init                          # writes .code-monkey.toml + .code-monkey/
code-monkey index                         # builds .code-monkey/index.db
code-monkey get                           # everything, cheapest possible read
```

`init` is idempotent except for the config file (use `--force` to overwrite).

The index lives at `.code-monkey/index.db`. Gitignore it:

```
.code-monkey/
```

Commit `.code-monkey.toml` so the project's parse rules travel.

---

## Config (`.code-monkey.toml`)

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

A project with no `.code-monkey.toml` gets exactly these defaults — including
`Tests`. They used to disagree: `init` wrote `["Sources", "Tests"]` while the
built-in fallback was `["Sources"]` alone, so an un-`init`ed project indexed no
test code and `calls --tests` would have reported "nothing covers this" as a
fact about the code rather than about the config.

Each command walks up from the working directory to find this file (or the
`.code-monkey/` dir). You can run `code-monkey` from any subdirectory.

Override the root with `--project <path>`.

---

## Efficient selection

Start from known context. Do not mechanically walk every tier.

1. Use filenames, manifests, config, and non-Swift docs to establish project shape.
2. Run one `code-monkey index` before Swift semantic reads.
3. If symbol is known, call `get <decl_id>` directly.
4. If ownership is unknown, use `get` with `--path`/`--kind`/`--container`/`--name-like`/`--tag` to enumerate.
5. Add `--fields` only for the attributes the question actually needs.
6. Use `--fields body` only when implementation is required.
7. Stop when current command resolves uncertainty.

For auditable AI use, report command category, question answered, and why read
was cheaper than direct source inspection. At task end, report useful calls,
failed or duplicated calls, and broad source reads avoided.

When developing `code-monkey` itself, run `.build/debug/code-monkey` after a
local build. A stale `code-monkey` on `PATH` can otherwise hide local fixes.

---

## The read model

One command, `get`. Pay only for what you ask for.

A bare positional argument resolves to one record (id, name, or decl_id
substring; ambiguous matches list candidates instead of guessing). Any of
`--path`, `--kind`, `--container`, `--name-like`, `--tag` — or omitting the
positional entirely — switches to enumerate mode and returns every match.

`--fields` picks attributes independently of resolve-vs-enumerate:
`signature`, `summary`, `invariants`, `ownership`, `dependencies`, `body`,
`callers`, `callees`. Omit it on a single target and you get
`signature,summary,invariants` for free. Omit it while enumerating and you get
the cheapest possible locate-only line, no extra per-row queries.

| Question | Command |
|---|---|
| "What's in this dir?" | `get --path Sources/MyApp` |
| "What's the API surface?" | `get --container UserService --fields signature` |
| "What's this for? Any invariants?" | `get createUser` (default fields) |
| "Show me the implementation." | `get createUser --fields body --body-mode full` |
| "Show it with its surroundings." | `code UserService --expand createUser` |

On a resolved single target, elision signals (`body_lines`, `directive_count`,
`doc_lines`) come back automatically — no separate call needed to decide
whether to ask for the body.

With `--json`, commands return a stable envelope:

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

`freshness` is present when command can determine it. Consumers should branch
on `schema_version`, not output formatting details.

---

## The write model

`clip`, `move`, and `rename` all write at byte offsets taken from the index.
Everything below follows from that one fact, and is worth reading once before
using any of them.

### Where a declaration begins

`decl_offset` points at the declaration's **first token onward**. Attributes are
tokens of the node, so `@MainActor` and friends are part of the declaration.
Comments never are — their text is stored in `doc_comments` and `directives`
instead, and the bytes above a decl belong to no declaration at all.

```swift
/// Doc for note.              <- doc_comments
//# ai:invariant: returns one  <- directives
@MainActor                     <- decl_offset starts here
func note() -> Int { 1 }       <- ...through here
```

That single rule explains what each write addresses:

| Operation | Byte range it writes |
|---|---|
| `clip --paste-replacing` | the declaration only |
| `clip --paste-replacing --with-doc` | comment block + declaration |
| `clip --paste-after` | inserts at the declaration's last byte |
| `clip --paste-before` | inserts above the comment block |
| `clip --cut`, `move` | comment block + declaration, separators collapsed |

`--paste-before` and `--cut` need the commentary, which `decl_offset` cannot give
them, so they re-derive it from the source: `leadingBlockStart` climbs contiguous
`//` lines upward from the declaration's own line. This is deliberate rather than
a workaround — it also keeps them correct regardless of what the extractor decides
a declaration's bytes are.

The scan is textual. A blank line between a doc comment and its declaration breaks
the association, and the comment is then left behind.

### Indentation

A declaration's stored bytes begin at the declaration, **not** at the start of its
line, so the whitespace positioning it is not part of what these commands see.
That is why `--paste-replacing` never has to think about indentation, and why
inserting does:

- The **paste** modes re-indent stdin's *first line* to match the neighbouring
  declaration and leave its interior alone, matching same-depth insertion.
- **`move`** re-indents the *whole block*, stripping the source's indent prefix
  per line and applying the destination's. A move usually changes nesting depth —
  that is the point of it — so first-line-only would misalign the body. Nesting
  inside the block is preserved.

### Round trips

Two contracts hold exactly, and both are covered by tests:

```bash
code-monkey clip Box.note --cut > removed.swift
code-monkey clip Box.tail --paste-before < removed.swift   # byte-identical
```

`--cut` echoes the block from its first *content* byte rather than the line start,
because the paste modes supply the indent themselves; a payload carrying its own
indentation would come back double-indented. Moving a declaration out of a type
and back likewise returns the original text.

### Three write guards

Writing at index-derived offsets has three failure modes worth refusing outright.

**Stale index.** An edit made outside these commands — a `sed`, an editor save, a
`git checkout` — shifts every later offset while the index still points at the old
ones. A shifted offset that happens to stay in range passes a bounds check and
splices into the middle of a token, corrupting the file silently. So the file is
compared against the SHA-256 recorded at index time:

```
Sources/App/Box.swift changed since it was indexed — refusing to write at stale
offsets. Run `code-monkey index` and retry.
```

There is no override; `index` is the remedy and it is incremental. This does not
make outside edits safe — it makes them loud.

**Empty payload.** A paste mode given empty or whitespace-only stdin refuses. An
empty payload is never a real edit — it is a failed `cat`, a closed pipe, or a
typo'd heredoc — and writing it silently deletes the declaration. Pass `--cut` to
delete deliberately.

**Duplicated doc.** Because a declaration's bytes stop below its comment block, a
`--paste-replacing` payload carrying its own doc comment lands *underneath* the
existing one rather than overwriting it. `clip` refuses when stdin starts with a
comment and the declaration already has a block; `--with-doc` is the explicit path,
and is also the only way to edit a doc comment through `clip`. A doc-carrying
payload for a declaration with no block is allowed — that legitimately adds one.

### What is not checked

These are positional writes at stable addresses, not AST operations.

- **The payload is never parsed.** A replacement that redeclares a sibling
  surfaces as `invalid redeclaration` from the compiler, not from `clip`. Replace
  the *narrowest* declaration that covers what you are changing.
- **`move` does not check the destination is legal.** Moving a `private` member
  out of its type, or a method that uses `self`, produces code that does not
  compile. It relocates bytes; whether they belong there is your call.
- **`rename` changes the declaration only.** References are reported with
  confidence grades and never rewritten — see below for why.

---

## Commands

### `code` — readable outlines, dialled up

`get` answers *facts about* declarations. `code` renders *the declarations
themselves* at whatever level of detail you want, as Swift you can read.

Disclosure is a ladder. Start at the bottom and turn the dial:

```bash
code-monkey code Walk           # -L0  struct Walker {}
code-monkey code Walk -L1       #      + properties and enum cases
code-monkey code Walk -L2       #      + member signatures
code-monkey code Walk -L3       #      + bodies
```

```swift
// -L2
struct Walker {
    let project: Project
    func enumerateSwiftFiles() -> [URL] {}
    private func relPath(_ url: URL) -> String {}
    private func isExcluded(_ url: URL) -> Bool {}
}
```

**Selectors.** A name, a `Name:member` pair, a file, a directory, or nothing:

```bash
code-monkey code Walker                      # by name (substring — matches are not an error)
code-monkey code Walk:enum                   # only members whose name contains "enum"
code-monkey code Sources/App/Walker.swift    # every decl in one file
code-monkey code Sources/App:fold            # decls named *fold* under a directory
code-monkey code .                           # the whole project
```

A `:member` filter with no explicit `-L` starts at rung 2 — rung 0 would hide
the very thing you filtered for. So `code Walk:enum` renders the shell plus the
matching members, and nothing else.

**Kind flags** take an exact slice instead of a rung. They compose:

```bash
code-monkey code Walker --vars               # properties only
code-monkey code Walk:enum --funcs           # just the functions matching "enum"
code-monkey code Walk:enum --funcs --body    # ...with bodies expanded
code-monkey code Walker --funcs --access public   # the public call surface
code-monkey code . --types                   # every type in the project, one shell each
code-monkey code . --all --access public --spi none   # the real public API
```

`--vars` covers `var` and `let` together; `--funcs` covers `func`/`init`/
`deinit`/`subscript`; `--types` covers nested types plus the other named
declarations (`typealias`, `associatedtype`, `operator`, `precedencegroup`);
`--cases` covers enum cases; `--all` is everything.

A nested type survives a kind filter it doesn't match if something inside it
does — `--funcs` shows methods that live in a nested type, wrapped in that
type's shell, rather than dropping them.

**Body depth** is independent of which members are shown: `--body` expands
them, `--fold` renders `{ ... }`, and the default `{}` keeps one member per
line.

**`--expand` lifts one member above the rung.** Everything named by it renders
in full; everything else stays where `--level` put it. This is the read a
`:member` filter cannot express, because `:member` also *hides* the siblings it
filters past — `code Walker:isEx --body` gives you the body with no context,
and `code Walker -L2` gives you the context with no body:

```bash
code-monkey code Walker --expand isEx        # one body, siblings as signatures
code-monkey code Walker -L0 --expand isEx    # the shell and that body, nothing else
code-monkey code Walker --fold --expand isEx # siblings as `{ ... }`
```

```swift
// code Walker --expand isEx
struct Walker {
    let project: Project
    func enumerateSwiftFiles() -> [URL] {}
    private func relPath(_ url: URL) -> String {}

    private func isExcluded(_ url: URL) -> Bool {
        let rel = relPath(url)
        for pat in project.config.exclude {
            if Glob.match(pattern: pat, path: rel) { return true }
        }
        return false
    }
}
```

Three rules make it predictable:

- Like `:member`, it defaults `--level` to 2 — a body among its siblings is the
  point, and rung 0 has no siblings. Say `-L0` for the shell alone.
- It **forces the match in** even below the rung that would have listed it, so
  `-L0 --expand` is not a silent no-op. An explicit `--access` or `--spi` floor
  still outranks it.
- Expansion is **inherited**: naming a type expands what is nested inside it,
  rather than doing nothing because the match was not a leaf.

`code --fold --expand X` is the outline-view twin of `get X --fields body
--body-mode fold --keep X`. Reach for `code` when you want the synthetic,
uniformly-indented view, and `get` when you need byte-accurate source.

`--spi` filters the *other* access axis, independently of `--access`: `any`
keeps everything standing behind some `@_spi(...)`, `none` keeps everything
that is not, and a group name keeps that group. See **SPI scopes** below.

**Also:** `--doc` interleaves `///` comments and `//# ai:` directives,
`--numbers` annotates each decl with its line range, `--no-header` drops the
`// path` comments, `--limit` caps top-level decls (default 200), and `--json`
emits `{id, kind, file, start_line, end_line, code}` per decl.

> `code` output is a **readable outline, not compilable Swift** — a stubbed
> non-`Void` function has no return statement. For a faithful excerpt of real
> source, use `get --fields body --body-mode fold`, which does byte-accurate
> elision on the file itself.

### `calls` — syntactic call tree

What reaches a declaration, or what it reaches. Use it for blast radius before
a change, and for orientation in code you don't know.

```bash
code-monkey calls Fold.apply                # who reaches it, two levels up
code-monkey calls Indexer.run --callees     # what it reaches
code-monkey calls sliceFile --depth 3       # further out
code-monkey calls Walker --both             # both directions
code-monkey calls Extractor.extract --tests # which tests reach it
code-monkey calls Indexer.run --summary     # blast radius as one block
```

```
// what Indexer.run(full:Bool) reaches — depth 1, calls only, confidence ≥ medium
Indexer.run(full:Bool)  Sources/code-monkey/Index.swift:427
├─ Database.run(_:String,_:[Bindable])  Sources/code-monkey/Index.swift:452  [high] ×8
├─ Extractor.extractAll(source:String,file:String)  Sources/code-monkey/Index.swift:465  [high]
└─ Indexer.relPath(_:URL,root:URL)  Sources/code-monkey/Index.swift:437  [medium] ×4
```

**Every edge is a guess.** The index records names, not types: `foo.bar()`
stores the name `bar` and the text `foo`, and nothing resolves `foo`. Each edge
is therefore graded, and the grade is the point:

| Grade | Earned by |
|---|---|
| `high` | The receiver names the declaration's container (`Fold.apply`), **or** resolves to it by declared type (`db.query` where `db` is a `Database`), **or** there's no receiver and the name is unique project-wide |
| `medium` | A unique name reached through a receiver that couldn't be resolved; a sibling in the same container or file; or an edge that crossed dynamic dispatch |
| `low` | The name matched and nothing corroborates it — including when the receiver resolved to something else entirely |

Three rules do most of the work.

**Receivers are typed, nearest scope first.** A receiver is looked up as a local
or parameter bound inside the calling declaration, then as a property of the
calling type, and its declared type read off. That is what separates
`db.query()` from `out.append()` — and, because locals count, what lets
`let graph = CallGraph(db: db); graph.resolve(...)` be charted as a fact rather
than a name collision. Sugared types are desugared rather than abandoned, so a
receiver known to be an `Array` actively refutes a project declaration named
`append` instead of merely failing to explain it.

**A corroborated match refutes its rivals.** Once `db.run(...)` resolves to
`Database.run`, the eight other declarations named `run` are dropped from that
site rather than listed.

**Dispatch is followed across protocols.** `saver.persist()` where `saver` is
`any Saver` lands on `Saver.persist()` — the requirement, where no work happens.
The conforming implementations are charted behind it at `medium`, tagged
`via Saver.persist()`, and the reverse question ("who reaches
`FileSaver.persist`?") is answered by whoever reaches the requirement. Only one
implementation actually runs, so these are possibilities, never facts.
Conformances written on an `extension` count, and one level of protocol
refinement is followed.

```
├─ Saver.persist()        Sources/Client.swift:4  [high]
├─ FileSaver.persist()    Sources/Client.swift:4  [medium]  via Saver.persist()
└─ MemorySaver.persist()  Sources/Client.swift:4  [medium]  via Saver.persist()
```

**Coverage: `--tests`.** Keeps only the branches that end at a test, which
answers "what covers this?" rather than "which of its direct callers happens to
be a test". A test is recognised by convention — a path component named `Tests`
or ending in `Tests`, or a container ending in `Tests`/`TestCase` — so a suite
that follows neither reads as production code. An empty result here is phrased
as a coverage finding, not a lookup failure.

**Summary: `--summary`.** One block instead of the tree, for the question people
actually ask before a change:

```
// blast radius of Extractor.extractAll(source:String,file:String,callSites:Bool)  —  confidence ≥ medium, depth 2
direct callers    4  (4 high)
transitive        15 across 3 files
tests             13 (1 file)
```

`tests` reads `none — this change is not covered from here` when nothing does,
`via dispatch` appears when edges crossed a protocol requirement, and
`below --min` reports what the floor excluded from the totals. If the tree hit
`--limit`, the summary says so rather than reporting a total it knows is short.
The counts are the same edges the tree shows; the summary is presentation, not
a second analysis.

Defaults to `--min medium`; pass `--min low` to see every name match and treat
those as leads. When the floor removes edges, the output says so rather than
printing a bare `(none)` — an empty result must be a fact about the threshold,
not a claim about the code. `--include-refs` adds property and type mentions to
the calls. `--limit` caps edges per node, `--depth` the levels followed. Cycles
are detected and marked rather than followed.

**What it will still get wrong:** a receiver that is an expression, a tuple
element, or a `for` binding never resolves, so correct edges through them land
at `medium` or `low`. A project declaration sharing a name with a standard
library member can attract a false edge. Conformances declared in a dependency
aren't visible, so dispatch through them stops at the receiver's type. The
grades exist so these stay legible as leads: treat `high` as a fact, `medium`
as likely, and `low` as a name that matched and nothing more. A tool built on
a semantic index (one that consumes Apple's IndexStore, and so requires a
build) can answer these outright; code-monkey trades that for needing no build
at all.

`get --fields callers,callees` gives the same edges for a single declaration,
without the tree.

**Turning it off.** Call sites are most of the index file — roughly four rows
per declaration, which quadrupled this repo's database. The `bindings` and
`conformances` that type their receivers ride along with them. If you don't want
the call graph, disable it:

```toml
[parse]
extract_call_sites = false
```

Or per run: `index --no-call-sites` / `index --call-sites` (the flag overrides
the config only when actually passed). Disabling clears the table and records
the fact, so `calls` fails with a message telling you how to turn it back on
rather than reporting an empty graph, `get` prints `callers: not indexed`
instead of `none found`, and `doctor` shows `call_sites=off`. Nothing else
depends on it.

### `get` — the one read command

Locate, shape, intent, and body all go through `get`. A bare positional
resolves one record; any of `--path`/`--kind`/`--container`/`--name-like`/
`--tag` enumerates every match instead.

**Locate** (cheapest — no per-row queries):

```bash
code-monkey get
code-monkey get --path Sources/MyApp                  # subtree
code-monkey get --kind func --container Database
code-monkey get --name-like "*User*"
code-monkey get --tag ai:invariant                     # decls carrying that directive
code-monkey get --limit 50 --offset 100
```

One decl per line: `<decl_id>  <kind>  <container>  <file>:<line>`.

**Shape** (signatures, grouped naturally by enumerate order):

```bash
code-monkey get --path Sources/UserService.swift --fields signature
code-monkey get --path Sources --fields signature      # recursive over a dir
```

**Intent** (doc, `//# ai:` directives, elision counts — default fields on a single target):

```bash
code-monkey get Indexer                                # name match
code-monkey get "Indexer.run(full:Bool)"               # exact decl_id
code-monkey get createUser --fields signature,summary,invariants
```

Shows file:line range, container, signature, modifiers, doc comment,
`//# ai:` directives, and elision counts (the last three only on a single
resolved target).

**Body** — explicit, opt-in only:

```bash
code-monkey get "Database.query(_:String,_:[Bindable])" --fields body                    # ref only
code-monkey get "Database.query(_:String,_:[Bindable])" --fields body --body-mode full   # whole decl
code-monkey get "..." --fields body --body-mode full --file Sources/A.swift              # disambiguate
```

**Fold** — type with bodies elided, the workhorse for context-aware reads:

```bash
code-monkey get Indexer --fields body --body-mode fold                       # struct, member bodies = { ... }
code-monkey get Indexer --fields body --body-mode fold --keep run            # all folded except run's body
code-monkey get Indexer --fields body --body-mode fold --keep run --keep relPath  # multiple kept
code-monkey get --container Indexer --fields body --body-mode fold          # each member, folded (replaces old glob)
code-monkey get Indexer.relPath --fields body --body-mode fold --deep        # auto-context: container w/ relPath inline
code-monkey get FileCmd --fields body --body-mode fold --deep                # nested types keep members visible
```

Folded output is real Swift you can read top-to-bottom: types open, member
signatures listed, bodies replaced by `{ ... }` unless `--keep`'d.

Available `--fields`:

| Field | Source | Notes |
|---|---|---|
| `signature` | stored signature text | |
| `summary` | doc comment + narrative `ai:` tags (`why`, `example`, `see`, `depends`, `prompt`, `section`) | |
| `invariants` | contract `ai:` tags (`invariant`, `requires`, `warn`, `spec`) | split from `summary` by tag, not a separate table |
| `ownership` | file path + `Config.sources` + container | `{file, container, module}` |
| `dependencies` | capitalized identifiers in `signature` | heuristic, syntactic — not resolved against stdlib or project symbols |
| `body` | `--body-mode` controls shape | `ref` (default, `{file,start_line,end_line}`), `full` (whole decl text), `fold` (members/body elided, see `--keep`/`--deep`) |
| `callers` / `callees` | `call_sites` + `CallGraph` | graded edges, same as `calls`; `not indexed` when call sites are off |

`--format`: `folded` (comment-annotated Swift, cheapest tokens), `markdown`
(headed prose), or `json` (envelope with `fields: [...]`; unrequested keys are
omitted, not nulled).

### `query` — read-only SQL

```bash
code-monkey query "SELECT name, file_path FROM declarations d
                     JOIN files f ON f.id=d.file_id
                    WHERE kind='func' AND container='Database'"
```

SELECT/WITH/PRAGMA only. The schema is documented at the end of this guide.

### `stats` — project shape, before the first read

```bash
code-monkey stats                            # every section
code-monkey stats --section mass --top 20    # the files worth reading first
code-monkey stats --section fold             # the case for reading at level 0
code-monkey stats --section docs             # where the prose is missing
code-monkey stats Sources/MyApp              # narrow to a subtree
```

A sizing pass. `doctor` says whether the index is usable and `query` answers one
question at a time; `stats` answers the standing ones at once, off the index
alone, without opening a source file.

| Section | What it answers |
|---|---|
| `overview` | file, declaration and byte totals, production vs test |
| `kinds` | declarations per kind, with the line span each occupies |
| `mass` | declarations per file: p50/p90/max, concentration, densest files |
| `fold` | body bytes against source bytes — what `code -L0` never emits |
| `docs` | doc coverage by access, directive tags, files no section claims |
| `coupling` | most-imported modules, most-conformed protocols |
| `hotspots` | longest bodies, and undocumented names with the widest fan-in |

`--section` is repeatable and narrows the work as well as the output: a section
nobody asked for runs no query.

Three figures carry caveats. `span` nests, so a struct's span covers its members
and the column does not sum to a file total. Byte totals count top-level
declarations only, for the same reason. And `hotspots` fan-in counts only call
edges the receiver corroborates, which makes it a **lower** bound: a call reached
through a closure parameter has no indexed receiver and is dropped rather than
guessed. Matching on the callee name alone would be the other error, and it ranks
`append` and `String` at the top of every project.

### `weave` — literate projection

```bash
code-monkey weave Sources                              # everything, Markdown to stdout
code-monkey weave Sources --summary                    # prose + signatures, no bodies
code-monkey weave --section "Authentication"           # one ai:section chunk
code-monkey weave Sources --access public              # only open + public (API doc)
code-monkey weave Sources --access internal            # adds internal + package
code-monkey weave Sources --access public --spi none   # ...minus anything behind @_spi
code-monkey weave Sources -o BOOK.draft.md
```

`--access` takes a minimum level: `public` keeps `open` + `public`; `internal`
also keeps `internal` + `package`; `private` keeps everything. Decls without
an explicit access modifier count as `internal` (Swift's default).

Pulls `BOOK.md` (project root) as a preamble and `<File>.md` sidecars as
per-file prose. Decls interleave in source order. `//# ai:` directives render
as block quotes.

### `imports` — import lines, with their SPI groups

```bash
code-monkey imports                            # every import in the project
code-monkey imports Sources/MyApp              # narrow to a subtree
code-monkey imports --spi any                  # the SPI this project consumes
code-monkey imports --spi Internal             # who consumes that one group
code-monkey imports --module Foundation        # every file importing a module
code-monkey imports --testable
```

Text output is `<file>:<line>\t<the import, as written>`; `--json` gives
`{file, line, module, path, kind, spi, testable}` per row. `module` is the
first path component, `path` the whole dotted path, and `kind` the scope
keyword on a scoped import (`import struct Foo.Bar` → `struct`).

Nothing is deduplicated — two files importing the same module are two rows,
because "which files reach for this" is the question being asked.

### `clip` — write-only replace, insert, or cut by decl_id

```bash
code-monkey clip "UserService.createUser(email:String)" --paste-replacing < new.swift
code-monkey clip createUser --file Sources/UserService.swift --paste-replacing < new.swift
code-monkey clip createUser --paste-after < sibling.swift
code-monkey clip createUser --paste-before < sibling.swift
code-monkey clip createUser --cut > removed.swift
```

`clip` only writes — exactly one of `--paste-replacing`, `--paste-after`,
`--paste-before`, or `--cut` is required. To read a decl first, use `get --fields body`. Resolves the same way
as `get`: exact `decl_id`, then name/signature substring; `--file` narrows when
a name matches in more than one file. Either mode auto-refreshes the index for
the touched file.

Because the exact tier wins, a container name resolves to the type itself
rather than to its members — `clip Box --paste-replacing` replaces the whole of
`Box`, bodies included, so stdin must carry the entire declaration.

**`--paste-replacing`** swaps the matched decl's bytes for stdin, verbatim. Those
bytes stop below the decl's comment block, so stdin should carry the declaration
*without* its doc comment. If stdin starts with a comment and the decl already has
one, `clip` refuses rather than leaving both:

```
note() already has a comment block and stdin starts with one — replacing would
leave both. Drop the comment from stdin, or pass --with-doc to replace the block too.
```

**`--with-doc`** (with `--paste-replacing` only) widens the replacement to cover
the comment block, so stdin carries doc, directives, and declaration together.
That is the way to edit a decl's doc comment through `clip`.

**`--paste-after`** inserts stdin as a new declaration immediately following the
matched one, in the same scope — after a member it lands inside the container,
after a top-level decl it lands at top level. A declaration's stored bytes begin
at the declaration and not at the start of its line, so the indentation that
positions it is not part of what `clip` sees; `--paste-after` reads the indent of
the decl it follows and applies it to the first line of stdin, leaving stdin's
own interior indentation alone. It supplies its own blank-line separator and
trims trailing newlines from stdin so they don't stack.

**`--paste-before`** is the mirror of `--paste-after`, with one difference that
matters: it inserts *above the decl's comment block*, not between a declaration
and the doc comment describing it.

**`--cut`** deletes the declaration together with the comment block introducing
it, and echoes the removed source to **stdout** so the deletion is recoverable.
It collapses the blank-line separators around the hole, so cutting the first or
last declaration in a file doesn't leave the file opening or ending on a blank
line.

```bash
# add a sibling method inside Box, indented to match
printf 'func added() -> Int { 2 }' | code-monkey clip "Box.note()" --paste-after

# delete it again, keeping the source
code-monkey clip "Box.note()" --cut > removed.swift

# put it back exactly as it was
code-monkey clip "Box.tail()" --paste-before < removed.swift
```

That round trip is exact — see [The write model](#the-write-model) for why the
echoed payload starts where it does.

**Status output.** All four modes write their confirmation to **stderr**, leaving
stdout for payload. Only `--cut` produces payload, so `clip … --cut > out.swift`
captures exactly the removed source.

**Guards.** `clip` refuses a stale index, an empty payload, and a doc-carrying
payload for a declaration that already has one. All three are described under
[The write model](#three-write-guards).

### `move` — relocate a declaration

```bash
code-monkey move "Box.note()" --to Sources/Other.swift                     # append at end
code-monkey move "Box.note()" --to Sources/Other.swift --after "Crate.tag" # place it precisely
code-monkey move helper --to Sources/Same.swift --after other              # reorder within a file
```

Moves the declaration **and its comment block** — the `///` docs and `//# ai:`
directives that introduce it travel with it. The source is closed up the way
`clip --cut` closes it: separators collapse, and a decl that was the last member
of its type doesn't leave a blank line dangling before the closing brace.

**The block is re-indented to its new depth**, preserving the nesting inside it,
so a moved function keeps the shape of its own body. Moving a decl out and back
returns the original text. See [The write model](#indentation).

Both files are hash-checked before either is written, the same guard `clip` uses.
`--after` is resolved in the destination file, and naming the decl being moved is
refused. `move` does not check that the declaration is legal at its destination.

### `rename` — rename a declaration, report its references

```bash
code-monkey rename "Box.note()" --to observe
```

```
renamed Box.note() to `observe` in Sources/A.swift
2 sites may reference `note` — none were changed:
  [medium] Sources/B.swift:3  usesIt(b:Box) via b
  [medium] Sources/B.swift:4  alsoUses(b:Box) via b
Each is a syntactic guess. Fix them with `clip`, or use `swiftmind` for semantic answers.
```

`--to` must be a bare Swift identifier. The rename touches the declared name and
nothing else; the status line goes to stderr and the reference report to stdout.

**References are reported, never rewritten** — deliberately, for two concrete
reasons. `call_sites` records a line number and no byte offset, so there is
nothing to patch precisely. And every edge is a graded syntactic guess: rewriting
a `medium` or `low` one renames unrelated code that merely shares a name. A
correct automatic update needs a semantic index — that is `swiftmind`'s job.

So the workflow is: rename, read the graded list, fix each site with `clip`.

### `file` — sandbox-escape ops

```bash
code-monkey file read ~/foo.json
code-monkey file read ~/big.log --lines "-50"          # last 50 lines
code-monkey file read ~/src.swift --lines "1-30"
echo "content" | code-monkey file write ~/out.json --context "why"
echo "line"    | code-monkey file append ~/log.txt
code-monkey file log --last 20                          # audit trail
code-monkey file log --last 200 --argv                 # replay it as command lines
code-monkey file log --last 200 --argv --failed        # only what did not exit 0
code-monkey file log --last 500 --stats                # usage summary
```

Every invocation appends one metadata-only JSONL event: timestamp, command, project path,
the full argv it was dispatched with, `status` (`ok` or `exit <n>`), `ms`, and the tier and
target the command reported. SQL text and source bodies are not logged.

The record is written from the single dispatch point both the CLI and the REPL go through,
after `normalized()` — so `-L2` is stored as `-L 2` and a recorded line re-parses as written.
`--argv` prints those lines back, oldest first, shell-quoted.

`query`'s positional is replaced with `<sql>` before writing, so the promise that SQL never
reaches the log survives argv recording.

`--stats` summarizes instead of listing. Every figure is derived by resolving the recorded argv
against the command tree that exists now, so an option a later build dropped is reported as a
line that no longer parses rather than silently miscounted. Sections: per-command counts,
failures, p50/p90; depth distribution for `code` and `get`; the argv the parser refused; and
targets read twice within two minutes by different reads.

Set root-level `audit` in `.code-monkey.toml` to choose destination. Without
configuration, fallback is `~/.code-monkey/audit.log`.

`file read`, `file write`, and `file append` also use fallback audit log because
they do not resolve project config. `file log` resolves project config and
supports `--project`.

Audit append uses an in-process Swift `Mutex`, cross-process `flock`, and
`O_APPEND`, so concurrent CLI processes cannot interleave JSON records.

### `index`

```bash
code-monkey index                                       # incremental by sha256
code-monkey index --full                                # rebuild from scratch
code-monkey index --check                               # detect stale state; no writes
```

There is no file watcher; you call `index` after edits made outside `clip
--paste-replacing`.

**Schema versions are rebuilds, not migrations.** Every table is derived from
source, so when the schema version moves, `index` drops the old tables and
rebuilds from the files — it reports `schema upgraded to N — index rebuilt from
source` when it does. Other writable commands (`clip`) refuse to run against an
index of the wrong version rather than discarding it behind your back:

```
Error: index schema is version 4, expected 5 — run `code-monkey index --full` to rebuild it from source
```

---

## `doctor`

```bash
code-monkey doctor
code-monkey doctor --json
```

Reports the provenance of the binary that is running, the project root, index
path, schema version, WAL mode, audit destination, freshness, and actionable
warnings.

Provenance is the part worth explaining. `doctor` prints, for the running
executable, the checkout it is being run against, and the `code-monkey-mcp`
peer beside it:

```
built_from=/path/to/checkout commit=abc1234 build=#20
```

and warns whenever those disagree. More than one repository can build a binary
of this name, and when the wrong one is on `PATH` the symptoms are indirect —
a schema mismatch, or an MCP tool list that does not match the CLI — so the
question "which checkout produced this?" is worth a direct answer.

Two things make that answer possible. `BuildInfo` is committed, so the commit
it names describes the source and not the working copy that ran the compiler;
`make install` therefore writes a manifest beside the binaries recording
`source_root`, `commit`, `build_seq` and `build_date`. And staleness is decided
by build sequence, never by modification time: `make install` copies, and a
copy always lands with a fresh mtime, so a date comparison would report every
stale install as current. The checkout's own identity is read out of
`BuildInfo.swift` rather than by executing `.build/debug/code-monkey` — a
diagnostic should not depend on the binary it is diagnosing being runnable.

`doctor` identifies the binary actually running. It does not scan `PATH`.

---

## Concurrency model

`Database` is a Swift actor. SQLite handle never leaves actor isolation.
Database results use `DatabaseRow` and `DatabaseValue`, both `Sendable`, rather
than `[String: Any?]`.

Read commands open existing index read-only, set SQLite query-only mode, and
never bootstrap or update schema metadata. Independent readers can run
concurrently without changing index file.

`index` and `clip --paste-replacing` open writable connection.
SQLite WAL mode permits readers during write transaction. Busy timeout waits
briefly for competing writer instead of failing immediately, then returns an
actionable writer-busy error. Write transactions start with `BEGIN IMMEDIATE`,
so writer contention resolves before index mutation begins.

Transaction closures receive `isolated Database` and contain no suspension
points. Entire multi-statement transaction remains one actor-isolated critical
section. Concurrent tasks can safely submit transactions to same actor.

---

## `//# ai:` directives

These live above a declaration (no blank line in between). They are parsed
into the `directives` table and surfaced by `get`, `get --tag`, and `weave`.

```swift
/// Create a user.
//# ai:invariant: returned User.id is unique
//# ai:prompt: never log the raw email
//# ai:why: domain operation — wraps repository write + audit
public func createUser(email: String, role: UserRole = .user) async throws -> User { ... }
```

| Tag | Purpose |
|---|---|
| `ai:section: "<name>"` | Literate chunk label. Groups decls in `weave`. |
| `ai:why` | Rationale prose. |
| `ai:spec` | Behavioral contract (pre/post). |
| `ai:invariant` | Guarantee the body must preserve. |
| `ai:prompt` | Instruction to an AI editing this decl. |
| `ai:example` | Usage example. |
| `ai:see: <name>` | Cross-reference. |
| `ai:depends: <name>` | Narrative dependency. |
| `ai:warn` | Intentional pattern — do not "fix". |
| `ai:requires` | Caller precondition. |

Anything else parses as `ai:<word>` and passes through to the index untouched.

---

## decl_id format

The stable handle every command uses.

```
[Container.]name[(label:Type,label:Type)]
```

Examples:

```
UserService                                         # type
FileCmd.Read                                        # nested type
UserService.createUser(email:String,role:UserRole)  # method
Database.init(path:URL)                             # initializer
Indexer.project                                     # property
relativePath(_:String,root:URL)                     # top-level free func
Int64.bind(stmt:OpaquePointer?,index:Int32)         # extension method
```

Parameter types are included so overloads disambiguate. For most lookups you
can pass just the name — the CLI promotes it to a name match. Drop down to
exact `decl_id` when you see "ambiguous".

---

## Schema (for `query`)

```sql
files(id, path UNIQUE, mtime, sha256, last_indexed)

declarations(
    id, decl_id, file_id,
    container, container_kind,             -- enclosing type name + kind, nullable
    kind, name, signature,
    access,                                -- the Swift modifier only; SPI is a separate axis
    spi,                                   -- comma-joined @_spi groups, effective; '' = not SPI
    modifiers,                             -- comma-joined: static,async,throws,override,...
    start_line, end_line,
    decl_offset, decl_length,              -- whole decl incl. attributes
    body_offset, body_length               -- nullable for stored properties / protocol reqs
)

imports(
    id, file_id,
    module, path,                          -- first path component; whole dotted path
    kind,                                  -- struct|func|... on a scoped import, else NULL
    spi,                                   -- comma-joined @_spi groups; '' for a plain import
    testable,                              -- 1 for @testable import
    line
)

doc_comments(decl_id, text)

directives(id, decl_id, tag, value, line)

call_sites(
    id, file_id,
    from_decl,                             -- innermost enclosing decl; NULL for file scope
    name, receiver,                        -- as written; receiver is text, not a resolved type
    kind,                                  -- call | ref
    line
)

bindings(                                  -- written only when call sites are
    id, file_id,
    from_decl,                             -- the decl the name is scoped to
    name, type,                            -- local/parameter/closure param, bare nominal type
    line
)

conformances(                              -- written only when call sites are
    id, file_id,
    type_name, protocol_name               -- one row per name in an inheritance clause
)

narrative(id, file_id, kind, path, text)   -- 'book' (BOOK.md) or 'sidecar' (<File>.md)
```

`bindings` and `conformances` exist to resolve `call_sites.receiver`, which is
raw text. A binding's `type` is desugared (`[String]` → `Array`, `any Saver` →
`Saver`) and tuples and function types get sentinels that match no container.
`conformances` does not distinguish a superclass from a protocol — syntax
can't — so a name that matches no indexed protocol simply never satisfies a
lookup.

`decl_id` is indexed but NOT unique — two decls in different files may share
one. Use `--file` (or join `files` in `query`) to disambiguate.

`kind` is one of `struct`, `class`, `enum`, `protocol`, `actor`, `extension`,
`typealias`, `associatedtype`, `operator`, `precedencegroup`, `func`, `init`,
`deinit`, `subscript`, `var`, `let`, `case`. Note that `var` and `let` are
*separate* kinds — `--kind var` will not match stored `let` properties.
`code --vars` covers both.

Operator *implementations* (`static func == `, `prefix func -`) are ordinary
`func` rows named after the operator; `operator` rows are the separate
`infix operator <>: SomePrecedence` declarations.

---

## SPI scopes

`@_spi(Group)` marks a declaration as public-to-the-compiler but private-to-you:
it is `public` in every sense the language cares about, and off-limits to anyone
who did not write `@_spi(Group) import` at the top of their file.

code-monkey tracks it as a **second axis**, never folded into `access`:

- `access` keeps recording the Swift modifier alone, so a `@_spi(X) public func`
  still reads as `public` and `--access public` keeps the meaning it always had.
  Swift's access levels are strictly ordered; SPI is not one of them, and
  inserting it would have made that order lie.
- `spi` is the group list, and `--spi` filters on it independently. Combine the
  two to ask the question people actually mean: `--access public --spi none` is
  the real API surface, `--access public --spi any` is everything that looks
  public but isn't.

`--spi` takes `any`, `none`, or a group name; names match whole, never as a
prefix, and it is accepted by `code`, `get`, `weave`, and `imports`.

**SPI is effective, not declared.** A member inherits every group its enclosing
type or extension carries, the way Swift resolves it:

```swift
@_spi(Testing) public extension Plain {
    func f() {}          // reported as @_spi(Testing) — nothing is written on it
}

@_spi(Internal) public struct Widget {
    @_spi(Testing) public func g() {}   // reported as @_spi(Internal,Testing)
}
```

Outer groups come first, a decl's own are appended, duplicates collapse.

The two sides of the contract are separate commands: `code --spi` / `get --spi`
show what this project **exposes** behind `@_spi`, and `imports --spi` shows
what it **consumes**. Renaming or retiring a group needs both.

Detection is syntactic and exact — `@_spi_available` is a different attribute
and never matches.

---

## What this is not

code-monkey is **syntactic and narrative**: it parses with SwiftSyntax, so it
needs no build, runs in well under a second on a large project, and works on
code that does not currently compile. Everything it knows comes from the shape
of the source.

A **semantic** index — one built on Apple's IndexStore — knows real USRs, and
answers "who calls this?" and "what conforms to X?" as fact rather than as a
graded guess. It also requires a successful `swift build` first. `calls` is the
syntactic approximation of that, and it grades every edge precisely because it
cannot be certain.

Pick accordingly: if an answer must be exact and you can afford a build, reach
for a semantic tool. If you want the shape of a codebase now — including one
that doesn't build yet — that's this.

---

## MCP server

`code-monkey-mcp` (`Sources/code-monkey-mcp/`) exposes the CLI's commands as MCP
tools over stdio — currently 18 (`code_monkey_init`, `_index`, `_doctor`, `_get`,
`_code`, `_calls`, `_clip`, `_move`, `_rename`, `_query`, `_stats`, `_weave`,
`_imports`, `_file_read`, `_file_write`, `_file_append`, `_file_log`, `_version`). This lets an agent use
`code-monkey` as a standing connection instead of invoking the CLI through a
shell each time.

The tools are not written down anywhere. At startup the server runs
`code-monkey --experimental-dump-help` — ArgumentParser's public JSON dump in the
versioned `ToolInfoV0` schema — and `ToolBridge` turns that tree into tool schemas
and, on the way back, into argv. Add an option to a command and it appears here;
nothing needs editing twice. `ToolPolicy` holds only what the dump cannot say:
which arguments are integers (the schema carries no value types), which value
lists are open rather than exhaustive, which payloads travel on stdin, and which
flags the server drives itself. No tool description is written here — each one is
the command's own `abstract` and `discussion`.

Which puts a requirement on that prose: everything above an `EXAMPLES` heading is
published to MCP clients, and everything from `EXAMPLES` down is dropped, because
it is literal `code-monkey …` invocations a client cannot run. Write the semantics
above the heading and the shell transcripts below it. Flag names are rewritten on
the way out — `--body-mode` on a help screen is `body_mode` to a client — so spell
options as the CLI does and wrap them in backticks, or the renamed form reads as an
ordinary word.

One asymmetry is worth knowing, because getting it wrong is silent: ArgumentParser's
`allValueStrings` is documentation and is explicitly allowed to be a partial list,
while a JSON Schema `enum` *validates*. Only sets confirmed exhaustive become an
`enum`; `--spi` (which takes a bare group name) and comma-separated lists like
`--fields` publish their values as prose instead.

It's a thin wrapper, not a reimplementation: each tool call shells out to the
`code-monkey` binary (built alongside it by `swift build`) and forwards
stdout. No index/database logic lives in this target.

```
swift build
.build/debug/code-monkey-mcp --project /path/to/swift/project
```

`--project` sets the default repo root; each tool call can override it with
a `project` argument. `--code-monkey-bin` overrides the binary path (default:
sibling of `code-monkey-mcp` in the same build output directory).

### `--profile` — narrow the advertised surface

Every tool schema is prompt context the client re-sends on **every turn**,
whether or not it calls the tool. A session that was only ever going to read
shouldn't be quoted the write tools.

| Profile | Tools | Use when |
|---|---|---|
| `all` *(default)* | 18 | open-ended sessions |
| `read` | 6 — `get`, `code` | lookups only |
| `nav` | 10 — `read` plus `calls`, `imports`, `query`, `stats` | reading and tracing, no edits |
| `write` | 13 — `read` plus `clip`, `move`, `rename` and the four `file` tools | an agent that reads, then applies changes |

`init`, `index`, `doctor` and `version` are in every profile: a client that
can't build or diagnose its own index is stranded by the first stale-index
error. `weave` is document generation rather than lookup, so it appears only
in `all`.

`write` builds on `read`, not on the essential four: an edit is a read followed
by a write, and a client that can `clip` a declaration but cannot `get` the one
it is replacing has to guess — or open the whole file, which is the cost this
tool exists to avoid.

```
code-monkey-mcp --profile nav
```

Also settable as `CODE_MONKEY_TOOL_PROFILE`. An unknown name is an error, not
a silent fallback to `all` — a profile that quietly doesn't apply is worse than
no profile.

---

## Known limitations

- No file watcher. Edits made outside `clip --paste-replacing` need `index`.
- Concurrent writers serialize through SQLite and may wait for busy timeout.
- Configured project audit path is not used by projectless `file read/write/append`.
- `get --fields callers,callees` and `calls` are syntactic guesses, graded high/medium/low. Locals, parameters and protocol conformances are now indexed, so most receivers resolve — but a receiver that is an expression, a tuple element or a `for` binding still doesn't, and conformances declared in a dependency are invisible. A semantic index (IndexStore-backed, build required) is the tool for exact answers here.
- `calls --tests` is bounded by `--depth`: a test that reaches the target in more hops than that is not found, and the empty result says "at confidence ≥ x" rather than claiming no coverage exists.
- Test classification is conventional (path component / container suffix), not attribute-based.
- `get`'s `dependencies` field is a heuristic (capitalized identifiers in the signature) — no stdlib/project resolution.
- `clip` only replaces; there's no `--pboard --cut` or `--paste-after`.
- `code` output is a readable outline, not compilable Swift — a stubbed
  non-`Void` function has no return statement.
- `macro` declarations aren't visited by the extractor, so they never appear.
- Changing the extractor requires `index --full`; incremental indexing keys off
  file content hashes and won't notice that the *parser* changed.
- Same-named decls across files share a `decl_id`. Disambiguate with `--file`.
- The parser doesn't visit code inside string literals — useful as a feature
  (escape hatch) but means decl-looking content in strings is invisible.

---

## Quick reference

```
init        bootstrap project (.code-monkey.toml + dir)
index       full or incremental build (--full to rebuild, --check for stale report, no writes)
            --no-call-sites to skip the call graph (~4x smaller index)
doctor      executable/index/schema/WAL/call-sites/audit/freshness diagnostics

calls       syntactic call tree (--callees, --both, --depth, --min low|medium|high,
            --include-refs, --limit); edges are graded guesses, not facts
code        readable Swift outlines at a chosen level of disclosure
            -L0 shell | -L1 +properties/cases | -L2 +signatures | -L3 +bodies
            selector: Name | Name:member | file | directory | . (whole project)
            --vars/--funcs/--types/--cases/--all   exact slice instead of a rung
            --body/--fold                          body depth
            --expand <substring>                   full bodies for matches only
            --access <level> --spi any|none|<group> --doc --numbers
            --no-header --limit
get         field-selectable read; bare positional resolves one record,
            any of --path/--kind/--container/--name-like/--tag/--spi enumerates
            --fields signature,summary,invariants,ownership,dependencies,
                     body,callers,callees
            --body-mode ref|full|fold   (fold: --keep <pat>, --deep)
            --format folded|markdown|json
            --limit/--offset            (enumerate mode)
clip        write-only: --paste-replacing <decl_id/name> (--file to disambiguate)
query       read-only SELECT/WITH/PRAGMA
stats       project shape (--section, --top, <path>)
weave       Markdown literate projection (--summary, --section, --access, --spi)
imports     import lines + their @_spi groups (--module, --spi, --testable)
file        sandbox-escape read/write/append/log
```

Run any command with `--help` for the full option list.
