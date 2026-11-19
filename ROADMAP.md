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

## 6. Directives as contracts — the surface around `//# ai:`

Written 2026-09-11, after reading [code-contracts](https://github.com/spolu/code-contracts)
(`code-contracts.cc`) and asking what of it this project should take.

**The overlap is near-total on the core and empty everywhere else.** Their
`@cc` directive in a doc comment *is* `//# ai:invariant` — prose concrete
enough to find a violation, colocated with what it governs, discoverable by a
grep. This repo already carries 75 invariants, 34 warns and 2 specs, so the
idea needs no adoption. What they have and this doesn't is everything *around*
the directive: an identity, a scope wider than one declaration, a lookup keyed
by source location, and a linter.

Four tiers, cheapest first. They are independent — 6a is worth doing whether or
not the rest ever lands — but 6b is the one that composes with what already
shipped, and 6c is the one an agent would actually call.

### 6a. `lint` — a tag that doesn't exist should not index silently

**This is a defect, not an enhancement.** `parseDirective`
(`Extractor.swift:738`) takes everything after `ai:` up to the first
non-identifier character and stores it as the tag. Nothing anywhere validates
it. `DirectiveClass` (`Get.swift:96`) then partitions directives into `summary`
and `invariants` by two hardcoded sets — so `//# ai:invarinat: ...` parses
cleanly, lands in the `directives` table, matches neither set, and **vanishes
from `get` output with no warning at any layer**. The failure mode is the worst
kind this tool can have: a constraint the author believed they wrote, which no
reader will ever be shown.

Their `cc-check format` exists for exactly this, and reports duplicate ids
besides.

**LOE: 3–4 hours.** A tag whitelist derived from `DirectiveClass` (make it the
single source rather than a second copy), a pass over the `directives` table,
and a command that exits non-zero. No parsing work — the rows are already
indexed, so this is a query and a renderer.

**Worth noting while in there.** `DirectiveClass` declares ten tags; six appear
in this repo. `ai:requires`, `ai:example`, `ai:depends` and `ai:prompt` have
zero rows and may never have been used. A linter that rejects unknown tags
forces that vocabulary to be decided rather than accumulated.

### 6b. Stable ids on directives

**What.** An optional id in the directive: `//# ai:invariant(no-global-store):
...`. Unique within the declaration it attaches to, reusable across
declarations — their scoping rule, which is the right one.

**Why it earns its keep, and it is not documentation.** Every directive today
is keyed by declaration, tag, value and line. None of those survive an edit, so
nothing can refer to a specific invariant across two versions of the tree. An
id buys three things that already have homes here:

- `stats --section delta` can say *"invariant `no-global-store` was removed"*.
  It currently classifies declarations; this is the same join one column over,
  and removal of an invariant is a far louder signal than modification of a
  body.
- A review comment, a commit message or a test can cite one.
- The `--argv` log and the audit trail become greppable by constraint rather
  than by file.

**LOE: 1 day.** ~15 LOC in the parser, a nullable column, the `delta`
crossing, and tests. It is a schema bump, so it inherits the migration problem
noted at the end of this file — price it as one, not as a parser change.

**The trap.** Ids are a naming surface, and naming surfaces attract
bureaucracy. Keep them optional forever. The moment `lint` requires one on
every invariant, 75 existing directives need names nobody wants to invent, and
the tool starts refusing to index a repo over a matter of taste.

### 6c. Rules applicable at a source location

**What.** `cc-check list path/to/file.ts:42` returns every contract governing
that line, walking up through ancestor scopes. There is no equivalent here:
`get` is keyed by `decl_id`, which is the wrong key for the question *"what am
I not allowed to break in the code I am about to edit?"*

**Why this is the one an agent calls.** It is the read that belongs immediately
before the write primitive, and it is the only tier here that changes agent
behaviour rather than author behaviour. `SKILL.md` can say "check the
invariants first" as many times as it likes; a location-keyed lookup makes it
one call instead of a judgement.

**LOE: 4–6 hours** on its own, near zero as a flag. The query is `file_id`,
`line BETWEEN start_line AND end_line`, then the `container` chain upward —
all indexed. Do **not** ship it as a new MCP tool: item 1 settled that a tool
costs its whole description on every request, and this is a cut of `get`. It is
`get --at Sources/x.swift:42`, or a `query --recipe`.

### 6d. Directory-scoped rules

**What.** Their `CONTRACTS` file holds unattached contracts covering a
directory and everything beneath it — architectural boundaries, dependency
constraints, security practice. Rules with no host declaration currently have
nowhere to live here. `ai:section` labels a region; it does not carry anything
downward.

**Why it is last despite being the most interesting.** The `narrative` table
already exists with a `sidecar` kind (`Index.swift:659`) and is **empty in this
repo** — the mechanism shipped and nobody fed it. Adding a second unattached-
prose mechanism before understanding why the first went unused is how a tool
grows two half-used surfaces instead of one working one. Feed `sidecar` first,
or delete it.

**LOE: 1–1.5 days** if built, most of it inheritance semantics and the
`--no-global` equivalent, not parsing.

### What of theirs is explicitly not worth taking

- **`owner` / `notify` GitHub handles in source.** `stats --section volatility`
  already derives authors from git, which cannot go stale. Handles written into
  comments rot silently the first time someone leaves, and they only pay off if
  something is sending notifications — which is the next bullet.
- **The PR review bot.** A hosted service that reads diffs and posts comments.
  It would give up the no-subprocess, no-network property priced in item 1, and
  it is a different product. The *useful half* survives without it: `delta`
  already classifies changed declarations, so crossing that with the invariants
  guarding them — "you touched 3 declarations carrying 5 invariants, here they
  are" — is mostly built and runs locally.
- **Adopting `@cc` as a second directive syntax.** Their format is
  language-agnostic and lives in doc comments; `//# ai:` is a line-comment
  sigil parsed by a Swift extractor. Teaching the extractor to also recognise
  `@cc` and map it onto `directives` with a `ai:contract` tag is maybe 2 hours,
  but nobody has asked, and two spellings of one concept is a documentation
  cost paid on every read forever. Revisit only if this index ever needs to be
  consumed by their toolchain, or a second language lands.

---

## 7. MCP server `instructions` — the reading rules ride the handshake — **done** (2026-11-19)

Written 2026-11-19, after a review found three copies of the agent rules — the
repo `SKILL.md`, a claude.ai account skill, and a `~/.claude/CLAUDE.md` recipe —
had drifted. The account skill was two months stale: it advertised `clip`,
`weave` and `file` as MCP tools and had never heard of `code`, `calls`,
`imports` or `stats`. Its local copy cannot be fixed in place either; the
account sync overwrites it.

**What.** Pass `instructions:` to `Server(...)` in `CodeMonkeyMCP.swift:54`. The
swift-sdk already carries the field (`Server.swift:191`) and returns it in the
`initialize` result; clients that honour it put it in the agent's context with
no install step. Content is the short form of `SKILL.md`, ~300 tokens: name the
project on every call; `doctor` first, `index` only when stale; the orientation
order (`ai:section` query → `stats --section mass` → `code -L0 --doc` →
`--expand`); `decl_id` is the handle; directives are guarantees; the table names
for `query`. It should also name the active `--profile`, so an agent told about
`clip` doesn't go looking for it on a `nav` server.

**LOE: 2–3 hours**, nearly all of it the text. One golden test on the
`initialize` response.

**Why it rates above 4b.** 4b ships rules beside the index and still produces a
second copy. This ships them inside the binary that the rules describe, so they
cannot be older than the tools they talk about, and they reach every MCP client
— including ones that read neither `AGENTS.md` nor skills — at the one moment
the agent is learning the tool surface. It also makes the "which binary am I
talking to" failure visible: stale rules now mean a stale binary, which
`doctor` already diagnoses.

**The trap.** Same as 4b's: a hand-written short form drifts from `SKILL.md`.
Either generate both from one source, or embed the text as a resource the
build stamps and have a test assert every command it names exists in the
command tree. The second is cheaper and catches the exact failure that
prompted this item.

**As built.** `ServerInstructions.swift` holds the steps as data (tool, argument
keys, text) and assembles the text per profile, dropping any step whose tool the
profile doesn't advertise. Tests hold every named tool and argument to the
generated tool list, check no profile's text names a tool outside it, and cap
the size (~1.6 KB for `nav`). The test-asserted-resource route was taken over
generating from `SKILL.md`; the long form still has to be kept in step by hand.

**Follow-ons, now unblocked.** `code-monkey skill [--write <dir>]` prints or
places the full `SKILL.md` from the same embedded resource with a version
stamp, and `doctor` warns when a skill it can find (`~/.claude/skills`,
`.claude/skills`) carries an older stamp than the binary. Account-synced skills
(claude.ai, Desktop) can't be written locally; `skill --zip` produces the upload
bundle instead. Without the `doctor` check this is just a faster way to make
stale copies.

---

## 8. `code --budget` — price the rung before paying for it — **done** (2026-11-19)

Written 2026-11-19, from `file log --stats` over 347 invocations. `code` is the
most-read command after `index`, and the **re-reads** section is almost
entirely `code` changing rungs on one target — `CodeMonkey` alone accounts for
five, moving up and down through all four rungs. That is an agent that cannot see what a rung
costs until it has paid for it, overshooting and backing off. The help text
says the cost "climbs steeply"; measured here, whole-project `code` is 6 KB at
L0, 19 KB with `--doc`, 26 KB for `. --types --doc`.

**What.** Two pieces, cheapest first.

- **8a. A cost trailer.** After the outline, one line:
  `// next: -L1 ≈ 2.1 KB, -L2 ≈ 5.8 KB, -L3 ≈ 31 KB`, and `next_rungs` in the
  JSON envelope. `get` already does the equivalent for a single target
  (`doc_lines`, `body_lines`); this extends it to the ladder. L0–L2 are
  in-memory renders over the forest `run()` has already assembled — `code`'s
  p50 is 9 ms, so rendering three rungs to count bytes is affordable. L3 slices
  from disk, so estimate it from `sum(body_length)` instead of rendering.
- **8b. `--budget <bytes>`.** Pick the deepest rung whose render fits, and say
  which was chosen and what the next one would have cost. An explicit `-L`
  still wins. `--expand` matches are paid first and the remainder sets the
  rung, because the expanded body is the thing that was asked for.

**LOE: 8a half a day, 8b another half.** The renderer is pure and already
parameterised by rung (`Ladder.rung`), so this is a loop and a byte count, plus
golden files.

**Why it's worth it.** Every re-read in the log is a whole extra response. A
trailer that costs one line turns the ladder from trial-and-error into a choice,
and `--budget` lets the skill say "spend at most N" instead of teaching rung
semantics an agent then misjudges. It is also measurable after the fact: the
re-reads section of `--stats` should shrink, and if it doesn't, the trailer
isn't being read.

**As built.** Both halves. `Shaper` now owns forest shaping and text so every
rung is measured by the code path that prints the chosen one. L0–L2 render in
memory; L3 is L2 plus each newly-sliced leaf's `decl_length` less the stub it
replaces — within 1% on this repo's types and on the whole project (479.2 KB
estimated, 478.9 KB actual). Whole-project `code` with the trailer runs in
~70 ms debug. One deviation from the plan above: `--expand` isn't paid first
as a separate step — its matches render in full on every rung, so they are in
every rung's price already. `-L` given with `--budget` wins and the trailer
says the budget was ignored; kind flags, `--body`, `--fold` reject it.

**The trap.** Estimates that lie. Byte counts must come from the same renderer
with the same flags (`--doc`, `--access`, `--spi`, `--limit`), or the trailer
teaches agents to distrust it. And `--budget` must never silently drop
declarations to fit — truncation is `--limit`'s job, and it already says when
it truncates. If L0 alone exceeds the budget, render L0 and say so.

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

- **The `query` tool description omits `ai:see`.** It names five directive tags
  as the authoritative set; the table carries six, and `DirectiveClass` knows
  ten. The description is what an agent reads before writing SQL, so the
  omission costs a real query. One line, and it stops mattering the moment 6a
  derives the list from one place.


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
