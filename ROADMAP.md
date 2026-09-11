# Deferred work

Standing decisions about work that was scoped, costed, and deliberately not
done. These outlive any one working session, and should be edited when the
reasoning changes, not when the calendar does.

Written 2026-08-24, after the call-graph precision work (bindings, conformances,
dispatch bridging) and the `--profile` / `--tests` / `--summary` additions.

---

## 1. `pr_context` — one-call change analysis — **mostly done** (2026-09-11)

**Shipped as `stats --section delta` / `--section volatility`**, plus
`--format dashboard`. Not a separate command: a new MCP tool costs its whole
description in every request, and these are cuts of the same report.

**Actual LOE: ~1 day** for both sections, the git layer, the dashboard
projection, and 15 tests. The estimate below was close on effort and right
about every risk, so the reasoning is left intact.

Four things landed differently than the entry anticipated:

- **No worktree, no re-index.** `git diff -U0` reports hunks in *current-file*
  coordinates, so they join straight onto `declarations.start_line`. Prior state
  comes from `git show` piped through `Extractor` in-process, for the changed
  files only. The obvious approach — check the ref out and index it — was never
  needed.
- **The staleness trap is a warning, not a hard error.** The entry called for a
  hard error. In practice `delta` is most useful on a tree you are still
  editing, and refusing to run would make it useless exactly then. It says so
  loudly instead, alongside two other cases that would otherwise read as a
  confident zero: no repository, and a shallow clone.
- **Blast radius stayed out.** `hotspots` already reports corroborated fan-in;
  crossing it with the delta is Tier B below.
- **Classification follows `decl_id`**, which carries parameter labels and types
  but not the return type. So renaming a parameter reads as a removal plus an
  addition rather than a signature change, because `get` can no longer reach the
  old handle.

The subprocess question below was the real decision, and it went the way the
entry framed it: deliberately, in one file, with the three failure modes
enumerated. Standard error goes to the null device on purpose — draining one
pipe while git fills another deadlocks once the unread one fills.

**Still open:** the commit-message scope suggestion, and test coverage per
changed declaration. Neither has been asked for.

<details>
<summary>Original entry, 2026-08-24</summary>


**What.** `git diff` against a base branch → changed declarations → their blast
radius, which of them are covered by tests, which are public API, a suggested
commit-message scope. CodeGraph exposes this as a single tool and it is the
highest-value ergonomic idea in that project.

**LOE: 1.5–2.5 days.** ~350–450 LOC plus tests and docs.

**Why it isn't small.** The `code-monkey` CLI target has **no subprocess use at
all** — the only `Process` in the repo lives in `code-monkey-mcp`, which shells
out to the CLI. Today the CLI touches nothing but the filesystem and SQLite,
and that is a property worth pricing before giving it up: it is what makes the
tool trivially sandboxable and its failure modes enumerable. Adding git means a
subprocess layer, error paths for not-a-repo / missing base branch / detached
HEAD / shallow clone, and git-repo fixtures in the test suite. Call it 40% of
the work.

The other 60% is cheap because the pieces exist: diff hunks map to declarations
through `decl_offset` / `start_line` / `end_line`, blast radius is
`CallGraph.callers`, coverage is `CallTarget.isTest`, and `--summary` already
renders the block.

**The trap.** Blast radius is computed from the *index*, and a PR diff is by
definition about a working tree that has moved. If the index is stale relative
to HEAD, the answer is confidently wrong in a way nobody checks. Any
implementation must gate on freshness first — `Indexer.check` already returns
the stale/modified/unindexed split, so wire it as a hard error, not a warning.

**Decide it separately** from the rest of this list. It is the only item that
changes what kind of program `code-monkey` is.

</details>

---

## 1b. Declaration-level history — deferred (2026-09-11)

**What.** Per-declaration volatility rather than per-file: how many commits have
touched *this* function, by how many authors, and when last. The drill-down
`stats --section volatility` currently stops one level short of.

**LOE: 1–1.5 days.** The mechanism is `git log -L <start>,<end>:<file>`, which
follows a line range backwards through history and is the only thing that gets
this right — hunk line numbers from an old commit do not map onto today's
declarations, and pretending they do silently attributes edits to whichever
declaration happens to occupy those lines now.

**Why it is a separate tier.** Measured at **42ms per declaration**. This
project has 1263 of them, so a whole-project pass is roughly 50 seconds against
the ~80ms one `git log --numstat` costs for every file at once. It can only ever
run over a shortlist — and the shortlist already comes from the file-level
sections that shipped, which is why those came first.

**What it needs beyond the git call.** A cache, or it will feel broken. Key it
on the declaration plus the file blob sha plus HEAD, so an unchanged declaration
is computed once and a rebased branch invalidates cleanly. That is a schema
bump, and there is no migration path — a version bump means `index --full`.

**Worth building when** someone asks *why* a file is hot and the answer needs to
name a function. Until then the file-level answer is the one people act on, and
it is free.

**Not worth pairing with** a tool-owned snapshot table that records declaration
hashes on every `index`. That was costed at ~2 days and rejected: it duplicates
what git already knows, and it starts empty, so it delivers nothing for months.

---

## 2. Entry points and dead-code candidates

**What.** "Which declarations have no callers?" and "what are the roots of this
project?" — `find_entry_points` / `find_dead_code` in CodeGraph terms.

**LOE: 1 day** for a defensible version. **3 hours** for one that lies.

**Why it isn't a SQL query.** The obvious implementation — `SELECT` decls with
no matching `call_sites` row — is wrong, because confidence grading lives in
`CallGraph.grade` (Swift), not in the schema. "No callers" and "no callers we
believe" are different questions and only the second is useful. Answering it
properly means iterating declarations and grading each one's callers, which is
O(decls × query) unless the caller lookup is batched into a single pass.

**Why the naive version lies.** Everything below is genuinely uncalled *from
indexed source* and genuinely alive:

- `public` / `open` API consumed by another module
- `@main`, `main.swift` top level
- protocol witnesses satisfied structurally (now partly handled — see
  `conformances` — but not for protocols declared in dependencies)
- `#selector` / `@objc` / KVO targets
- `Codable`, `CaseIterable`, result-builder and macro-synthesised members
- anything reached only from a target that `sources` doesn't cover

A list that doesn't classify *why* something looks unreferenced is a list
nobody will act on twice. The day of effort is mostly that classification.

**Cheap alternative that already works:** `calls <decl> --min high` plus
`query` answers this ad hoc for anyone who wants it, without a command
promising more certainty than the data carries.

---

## 3. Code context — **done, cheaply** (2026-08-25)

**Shipped:** `code --expand <substring>`. Matches render at full body depth;
everything else stays where `--level` put it. `code Walker --expand isEx` is
the output the original entry asked for, and `code --fold --expand X` is the
outline-view twin of `get X --body-mode fold --keep X`.

**Actual LOE: ~2 hours.** ~20 LOC in `Code.swift` plus three tests.

**The original proposal was `code -L2 Walker -L3 .is`** — ordered
selector/level pairs, later selectors scoped by earlier ones. Rejected at
1.5–2 days for three reasons, kept here because the syntax will be proposed
again:

1. **It cannot cross MCP.** `ToolBridge.invocation` builds `argv = path +
   positionals` and then appends *every* option at the end. Order-dependent
   pairing is unreachable from the server without a bespoke policy escape
   hatch — in a tool whose primary consumer is an agent over MCP.
2. **ArgumentParser doesn't preserve interleaving** between `@Option var level`
   and `@Argument var selector`. Recovering the pairing means zipping parallel
   arrays (breaks the moment a pair omits `-L`) or hand-parsing argv, which
   costs the generated help and, through it, the generated MCP schema.
3. **`.` is taken.** `CodeSelector.parse` reads bare `.` as the project root,
   so a `.member` sigil needs a special case sitting next to a token that means
   the opposite thing.

**The diagnosis in the original entry was wrong** in a way worth remembering.
It said `code` "only returns one level of detail". It never did — `-L` was
already a ladder, and `code Walker:isEx --body` already mixed rungs (shell at
0, body at 3) in one render. The actual defect was that `:member` was
**overloaded**: the same `nameFilter` served as both the pruning predicate and
the expansion target, so selecting a body necessarily hid its siblings. One
coupled axis, not a missing dimension — and separating the two was one flag.

**The general lesson.** The desired *output* cost two hours; the desired
*syntax* would have cost two days. Price those separately. A roadmap entry that
specifies a grammar has already chosen an implementation; make it state the
output it wants and let the grammar be the cheapest thing that produces it.

**What was deliberately not built.** Arbitrary per-node rungs. `-L<n> --expand
<x>` covers every read anyone has actually wanted; the multi-pair grammar's
marginal value over it is close to zero, and it would be a permanent surface.

---

## 4. Getting installed — MCP config and agent instructions

Written 2026-08-25, after pricing "should there be a command that registers
`code-monkey-mcp` into other projects and harnesses — Claude, Codex, Gemini,
Cursor, VS Code".

Two items, deliberately paired: registering the server ships the capability,
and shipping the reading rules is what makes an agent use it. Either one alone
delivers less than half of the pair.

### 4a. `code-monkey mcp config` — print the snippet, write only what's local

**What.** `code-monkey mcp config --client codex --profile nav` prints the MCP
server entry for that client with the binary path resolved and the profile
chosen. `--write` merges it, but only into project-local files — `.mcp.json`,
`.cursor/mcp.json`, `.vscode/mcp.json`, `.gemini/settings.json`. Home-directory
targets are refused with "paste this into `~/.codex/config.toml`".

**LOE: 4–6 hours.** ~150 LOC plus one golden file per output shape.

**Why it's cheap.** There are four shapes, not N clients: JSON `mcpServers`
(Claude Code and Desktop, Cursor, Windsurf, Gemini CLI, Cline), JSON `servers`
with an explicit `type` (VS Code / Copilot, and it's jsonc), TOML
`[mcp_servers.x]` (Codex), and bespoke (Zed, JetBrains — not supported).
TOMLKit is already a CLI dependency. The output is a string, so the tests are
golden files and nothing else.

**Why it's worth anything at all.** Not keystrokes. Registration happens once
per project per client, and the minutes saved never repay a day of work. It is
`--profile`. Nobody hand-editing `mcpServers` JSON chooses between `read` /
`nav` / `write` (`ToolPolicy.Profile`) — they paste `all` and pay for every
advertised tool schema on every turn, in a tool whose entire argument is token
economy. The prompt is the only moment that decision is ever made. Second: the
absolute binary path and the `--project` root are the two things people get
wrong, and the failure is silent — the server simply doesn't appear.

**The trap.** `--write` into a global config. `~/.claude.json` carries session
state, and `.vscode/mcp.json` is jsonc with the user's own comments in it. A
merge bug there is a destructive failure in a file this tool didn't create and
can't validate. Project-local writes, printed snippets for everything else.

**Note.** This preserves the no-subprocess property priced in item 1 — it
writes files, it does not shell out to `claude mcp add`.

### 4b. `init --agent` — ship the reading rules with the index

**What.** `init` also writes an `AGENTS.md` (plus a `CLAUDE.md` pointing at it)
carrying the short form of `SKILL.md`: never `cat` a `.swift` file, index
before the first read, read at the lowest tier that answers the question,
`decl_id` is the handle.

**LOE: half a day**, nearly all of it deciding what the short form says.

**Why it rates above 4a.** The MCP entry gives an agent the *ability* to do
tiered reads; nothing makes it prefer them to opening the file. Markdown is
also the only cross-harness surface that doesn't drift — Codex, Gemini, Cursor
and Claude Code all read it, there's no schema, no path matrix, no merge, and
it works for clients that don't exist yet. Hours spent here keep working;
hours spent tracking config shapes decay.

**The trap.** Two copies of the rules — `SKILL.md` and a generated `AGENTS.md`
— drift, and the generated one is the copy nobody re-reads. Either generate it
from `SKILL.md` or state in the file itself that it is a summary and name the
source.

---

## 5. Command playback — **partly done** (2026-08-25)

Written after pricing "record and playback of Commands, generic given the
ability to introspect Commands".

**Shipped:** the recording half, and the two readers that make it useful.
Every invocation appends one line carrying its argv, cwd, `status`, and `ms`,
written from `CodeMonkey.dispatch(argv:)` — a single choke point both the CLI
and the REPL go through, and which the MCP server reaches by shelling out.
`file log --argv` renders those back as command lines; `--stats` summarizes
them. **Actual LOE: ~3 hours** across both commits.

**The pricing that mattered.** The original ask was record/playback *for
testing*, at 1–1.5 days. Almost all of that was the cost of making a replayed
run byte-comparable: path scrubbing, timestamp and build-version masking, a
checked-in fixture project, an `--accept` path. None of it is about commands —
it is the price of asserting equality. Relaxing the goal from *testing* to
*insight* deleted the entire day, because a summary needs no determinism at
all.

**The generic-ness claim was right about a narrower thing than it sounds.**
`CommandModel` / `ToolInfoV0` buys exactly two things: resolving a recorded
argv correctly (`takesValue` is what separates an option's value from a
positional — the leading-dash heuristic reads `get --project /tmp/x Walker` as
targeting `/tmp/x`), and detecting an argv that no longer parses instead of
miscounting it. It buys nothing for capture, normalization, or fixtures — the
three things that cost. **Introspection makes the corpus self-maintaining; it
does not make the harness.**

**Deferred: transcripts as tests.** Still the right call to wait, for the same
reason as before — golden output on formats that moved twice in two days
produces churn nobody reads, and `--accept` turns rubber-stamping into a habit.
But the price dropped: `dispatch(argv:)` is now an in-process seam a test
target can call directly, so this is a loop over argv plus an fd-level stdout
capture. No subprocess in the CLI, no `CLIRunner`. **Revised LOE: ~half a day**,
and the fixture project is the only hard part left. Revisit when the render
formats settle, and keep the corpus to ~15–25 transcripts pinned to stable
shapes (envelope keys, exit codes, error text, `-L` rungs) rather than one per
command.

---

## Smaller things noticed in passing

- **`--argv` does not emit `--project`.** A recorded line replays against
  whichever project the cwd resolves to, not the one it ran in — `cwd` is in the
  entry but not in the rendered line. Fine for the case that matters (replaying
  in the directory you were in), wrong the moment anyone pipes a log from
  elsewhere. A `--with-project` flag, ~10 LOC, worth adding the first time it
  bites.

- **The `tier` a command reports about itself is not a tier.** The values passed
  to `openIndex` are `T0`, `T1`, `T3`, `write` — and `code`, `get`, `calls`,
  `imports`, four commands that pass their own name. The field feeds the JSON
  envelope's `tier`, so it is a published inconsistency, not just an internal
  one. `--stats` sidesteps it by reading depth off argv instead. Normalizing the
  strings is an hour; it is an envelope change, so price it as a schema bump
  rather than a cleanup.

- **`AuditLog.redacting` is hardcoded to `query`.** It is the only command whose
  argument carries content rather than a name, and deriving the set from the
  command tree means building a `CommandModel` on every invocation to protect
  one command. The `ai:invariant` on it names the condition for adding a case —
  a new command with a payload-carrying argument. That condition is easy to miss
  at review time; if a second such command ever lands, derive it instead.

- **`weave` sits only in the `all` MCP profile.** Defensible — it is document
  generation, not lookup, and its output is large — but it is the one tool with
  no profile home. Revisit if a "generate" profile ever earns its keep.

- **Test classification is conventional, not attribute-based.** Path component
  named `Tests` / ending in `Tests`, or a container ending in `Tests` /
  `TestCase`. A suite following neither reads as production code. Now that
  `conformances` exists, `XCTestCase` subclass detection is available cheaply,
  and swift-testing's `@Test` could be picked up if the extractor recorded
  attributes (it records modifiers, not attributes). Worth ~2 hours if
  false-negative coverage reports ever bite.

- **`--summary` totals are bounded by `--limit` and `--depth`.** The block says
  so when it hits the cap, but the counts come from the already-truncated tree
  rather than from a separate uncapped pass. Fine for orientation, wrong for
  anything that wants a real total.

- **`calls --tests` prunes the built tree**, so coverage more hops away than
  `--depth` is invisible. The empty message is phrased to admit this ("at
  confidence ≥ x") rather than asserting no coverage exists.

- **Changing the `Config.sources` default to `["Sources", "Tests"]`** aligned it
  with what `init` has always written, but it is an index-size change for any
  existing project that never ran `init`. Those projects will index more files
  on their next `index --full`.

- **The schema still has no migration path.** Three separate bumps landed in
  quick succession (call sites → bindings → conformances, and a concurrent SPI
  change). `doctor` surfaces the mismatch and `index` can reset, which is the
  right trade for a derived artifact — but the churn rate is worth watching.


---

## Explicitly not doing

- **A `replay` command.** `code-monkey file log --last 50 --argv | sh` already
  replays a session, and the shell is a better runner than anything worth
  writing here: an in-process `replay` would re-enter `dispatch` and record the
  commands it replayed into the log it just read, and an out-of-process one
  gives up the no-subprocess property priced in item 1. The only version that
  earns its keep is one that rewrites `--project` to run a recorded sequence
  against a *different* repo, which nobody has asked for.

- **Embeddings / semantic search.** A 1.5 GB ONNX gate for roughly what BM25
  already gives on a single-language index. If this is ever revisited, the
  interesting prior art is model2vec-style static embeddings (~100× faster
  indexing, no runtime), not a transformer.

- **A global cross-project store.** CodeGraph persists every indexed project
  into one `~/.codegraph/graph.db`. Per-project indexes are the better default
  for a tool that reads source: they are reproducible, disposable, and don't
  accumulate a copy of everything you've ever opened.

- **Bare-name symbol keying.** CodeGraph resolves Swift calls by unqualified
  function name with one global winner per name. On this repo that would
  collapse 18 `run` and 19 `visit` declarations into one node each. The whole
  point of `decl_id` and the confidence grading is to not do this.

- **A multi-client MCP registration writer.** The full version of item 4a —
  merging into every harness's global config, with backups, uninstall, and a
  per-client doctor — costs 2–3 days, which is more than `pr_context` (item 1),
  the highest-value idea on this list. It also carries a permanent tail: config
  paths and schemas move per client per release, and a wrong entry fails
  silently. Claude Code already ships `claude mcp add-json`, so for the largest
  client the writer's marginal value over printing the right arguments is zero.
  Revisit when someone other than the author is installing this.
