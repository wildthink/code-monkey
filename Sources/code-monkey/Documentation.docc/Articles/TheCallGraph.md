# The call graph

What reaches a declaration, or what it reaches, with every edge graded.

## Overview

Use `calls` for blast radius before a change, and for orientation in code you do
not know.

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

## Every edge is a guess

The index records names, not types. A call written `foo.bar()` stores the name
`bar` and the text `foo`, and nothing resolves `foo`. Each edge is therefore
graded, and the grade is the point.

| Grade | Earned by |
|---|---|
| `high` | The receiver names the declaration's container, or resolves to it by declared type, or there is no receiver and the name is unique project-wide |
| `medium` | A unique name reached through a receiver that could not be resolved, a sibling in the same container or file, or an edge that crossed dynamic dispatch |
| `low` | The name matched and nothing corroborates it, including when the receiver resolved to something else entirely |

Three rules do most of the work.

**Receivers are typed, nearest scope first.** A receiver is looked up as a local
or parameter bound inside the calling declaration, then as a property of the
calling type, and its declared type is read off. That is what separates a
database query from an array append, and, because locals count, what lets a
freshly constructed value be charted as a fact rather than a name collision.
Sugared types are desugared rather than abandoned, so a receiver known to be an
`Array` actively refutes a project declaration named `append` instead of merely
failing to explain it.

**A corroborated match refutes its rivals.** Once one call resolves to a specific
declaration, the other declarations sharing that name are dropped from that site
rather than listed.

**Dispatch is followed across protocols.** A call on an existential lands on the
protocol requirement, where no work happens. The conforming implementations are
charted behind it at `medium`, tagged with the requirement they came through, and
the reverse question is answered by whoever reaches the requirement. Only one
implementation actually runs, so these are possibilities, never facts.
Conformances written on an extension count, and one level of protocol refinement
is followed.

```
├─ Saver.persist()        Sources/Client.swift:4  [high]
├─ FileSaver.persist()    Sources/Client.swift:4  [medium]  via Saver.persist()
└─ MemorySaver.persist()  Sources/Client.swift:4  [medium]  via Saver.persist()
```

## Coverage

`--tests` keeps only the branches that end at a test, which answers "what covers
this?" rather than "which of its direct callers happens to be a test".

A test is recognised by convention: a path component named `Tests` or ending in
`Tests`, or a container ending in `Tests` or `TestCase`. A suite that follows
neither reads as production code. An empty result is phrased as a coverage
finding, not a lookup failure.

## Summary

`--summary` gives one block instead of the tree, for the question people actually
ask before a change.

```
// blast radius of Extractor.extractAll(source:String,file:String,callSites:Bool)  —  confidence ≥ medium, depth 2
direct callers    4  (4 high)
transitive        15 across 3 files
tests             13 (1 file)
```

The tests line reads `none — this change is not covered from here` when nothing
does. A `via dispatch` note appears when edges crossed a protocol requirement,
and `below --min` reports what the floor excluded from the totals. If the tree
hit `--limit`, the summary says so rather than reporting a total it knows is
short. These are the same edges the tree shows; the summary is presentation, not
a second analysis.

## Thresholds and shape

The default floor is `--min medium`. Pass `--min low` to see every name match and
treat those as leads. When the floor removes edges, the output says so rather
than printing a bare `(none)`, because an empty result must be a fact about the
threshold and not a claim about the code.

`--include-refs` adds property and type mentions to the calls. `--limit` caps
edges per node and `--depth` the levels followed. Cycles are detected and marked
rather than followed.

## What it will still get wrong

A receiver that is an expression, a tuple element, or a `for` binding never
resolves, so correct edges through them land at `medium` or `low`. A project
declaration sharing a name with a standard library member can attract a false
edge. Conformances declared in a dependency are invisible, so dispatch through
them stops at the receiver's type.

The grades exist so these stay legible as leads. Treat `high` as a fact, `medium`
as likely, and `low` as a name that matched and nothing more. A tool built on a
semantic index, one that consumes Apple's IndexStore and so requires a build, can
answer these outright. code-monkey trades that for needing no build at all.

`get --fields callers,callees` gives the same edges for a single declaration,
without the tree.

## See Also

- <doc:Configuration>
- <doc:TheReadModel>
- <doc:KnownLimitations>
