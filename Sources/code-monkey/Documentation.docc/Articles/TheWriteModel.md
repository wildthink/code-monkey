# The write model

`clip`, `move`, and `rename` write at byte offsets taken from the index.

## Overview

Everything below follows from that one fact, and is worth reading once before
using any of the three.

## Where a declaration begins

The stored `decl_offset` points at the declaration's first token onward.
Attributes are tokens of the node, so `@MainActor` and its kind are part of the
declaration. Comments never are. Their text is stored in `doc_comments` and
`directives` instead, and the bytes above a declaration belong to no declaration
at all.

```swift
/// Doc for note.              <- doc_comments
//# ai:invariant: returns one  <- directives
@MainActor                     <- decl_offset starts here
func note() -> Int { 1 }       <- ...through here
```

That single rule explains what each write addresses.

| Operation | Byte range it writes |
|---|---|
| `clip --paste-replacing` | the declaration only |
| `clip --paste-replacing --with-doc` | comment block plus declaration |
| `clip --paste-after` | inserts at the declaration's last byte |
| `clip --paste-before` | inserts above the comment block |
| `clip --cut`, `move` | comment block plus declaration, separators collapsed |

`--paste-before` and `--cut` need the commentary, which `decl_offset` cannot give
them, so they re-derive it from the source by climbing contiguous comment lines
upward from the declaration's own line. This is deliberate rather than a
workaround, because it stays correct regardless of what the extractor decides a
declaration's bytes are.

The scan is textual. A blank line between a doc comment and its declaration
breaks the association, and the comment is then left behind.

## Indentation

A declaration's stored bytes begin at the declaration, not at the start of its
line, so the whitespace positioning it is not part of what these commands see.
That is why `--paste-replacing` never has to think about indentation, and why
inserting does.

The paste modes re-indent the first line of stdin to match the neighbouring
declaration and leave its interior alone, which matches same-depth insertion.

`move` re-indents the whole block, stripping the source's indent prefix per line
and applying the destination's. A move usually changes nesting depth, which is
the point of it, so first-line-only would misalign the body. Nesting inside the
block is preserved.

## Round trips

Two contracts hold exactly, and both are covered by tests.

```bash
code-monkey clip Box.note --cut > removed.swift
code-monkey clip Box.tail --paste-before < removed.swift   # byte-identical
```

`--cut` echoes the block from its first content byte rather than the line start,
because the paste modes supply the indent themselves. A payload carrying its own
indentation would come back double-indented. Moving a declaration out of a type
and back likewise returns the original text.

## Three write guards

Writing at index-derived offsets has three failure modes worth refusing outright.

**Stale index.** An edit made outside these commands, whether a stream editor, an
editor save, or a checkout, shifts every later offset while the index still
points at the old ones. A shifted offset that happens to stay in range passes a
bounds check and splices into the middle of a token, corrupting the file
silently. So the file is compared against the SHA-256 recorded at index time.

```
Sources/App/Box.swift changed since it was indexed — refusing to write at stale
offsets. Run `code-monkey index` and retry.
```

There is no override. Reindexing is the remedy and it is incremental. This does
not make outside edits safe, it makes them loud.

**Empty payload.** A paste mode given empty or whitespace-only stdin refuses. An
empty payload is never a real edit. It is a failed read, a closed pipe, or a
mistyped heredoc, and writing it silently deletes the declaration. Pass `--cut`
to delete deliberately.

**Duplicated doc.** Because a declaration's bytes stop below its comment block, a
`--paste-replacing` payload carrying its own doc comment lands underneath the
existing one rather than overwriting it. `clip` refuses when stdin starts with a
comment and the declaration already has a block. `--with-doc` is the explicit
path, and is also the only way to edit a doc comment through `clip`. A
doc-carrying payload for a declaration with no block is allowed, because that
legitimately adds one.

## What is not checked

These are positional writes at stable addresses, not AST operations.

- **The payload is never parsed.** A replacement that redeclares a sibling
  surfaces as a compiler error, not a `clip` error. Replace the narrowest
  declaration that covers what you are changing.
- **`move` does not check the destination is legal.** Moving a private member out
  of its type, or a method that uses `self`, produces code that does not compile.
  It relocates bytes. Whether they belong there is your call.
- **`rename` changes the declaration only.** References are reported with
  confidence grades and never rewritten.

## `clip`

Write-only. Exactly one of `--paste-replacing`, `--paste-after`,
`--paste-before`, or `--cut` is required. To read a declaration first, use `get
--fields body`.

```bash
code-monkey clip "UserService.createUser(email:String)" --paste-replacing < new.swift
code-monkey clip createUser --file Sources/UserService.swift --paste-replacing < new.swift
code-monkey clip createUser --paste-after < sibling.swift
code-monkey clip createUser --paste-before < sibling.swift
code-monkey clip createUser --cut > removed.swift
```

It resolves the same way `get` does: exact `decl_id` first, then name or
signature substring, with `--file` narrowing when a name matches in more than one
file. Every mode auto-refreshes the index for the touched file.

Because the exact tier wins, a container name resolves to the type itself rather
than to its members. Replacing `Box` replaces the whole of `Box`, bodies
included, so stdin must carry the entire declaration.

`--paste-after` inserts stdin as a new declaration immediately following the
matched one, in the same scope. After a member it lands inside the container,
after a top-level declaration it lands at top level. It supplies its own blank
line separator and trims trailing newlines from stdin so they do not stack.

`--paste-before` is the mirror, with one difference that matters: it inserts
above the declaration's comment block, not between a declaration and the doc
comment describing it.

`--cut` deletes the declaration together with the comment block introducing it,
and echoes the removed source to stdout so the deletion is recoverable. It
collapses the blank line separators around the hole, so cutting the first or last
declaration in a file does not leave the file opening or ending on a blank line.

```bash
# add a sibling method inside Box, indented to match
printf 'func added() -> Int { 2 }' | code-monkey clip "Box.note()" --paste-after

# delete it again, keeping the source
code-monkey clip "Box.note()" --cut > removed.swift

# put it back exactly as it was
code-monkey clip "Box.tail()" --paste-before < removed.swift
```

All four modes write their confirmation to stderr, leaving stdout for payload.
Only `--cut` produces payload, so redirecting stdout captures exactly the removed
source.

## `move`

```bash
code-monkey move "Box.note()" --to Sources/Other.swift
code-monkey move "Box.note()" --to Sources/Other.swift --after "Crate.tag"
code-monkey move helper --to Sources/Same.swift --after other
```

`move` relocates the declaration and its comment block, so the docs and
directives that introduce it travel with it. The source is closed up the way
`--cut` closes it. Separators collapse, and a declaration that was the last
member of its type does not leave a blank line dangling before the closing brace.

Both files are hash-checked before either is written, the same guard `clip` uses.
`--after` is resolved in the destination file, and naming the declaration being
moved is refused.

## `rename`

```bash
code-monkey rename "Box.note()" --to observe
```

```
renamed Box.note() to `observe` in Sources/A.swift
2 sites may reference `note` — none were changed:
  [medium] Sources/B.swift:3  usesIt(b:Box) via b
  [medium] Sources/B.swift:4  alsoUses(b:Box) via b
```

`--to` must be a bare Swift identifier. The rename touches the declared name and
nothing else. The status line goes to stderr and the reference report to stdout.

References are reported, never rewritten, for two concrete reasons. Call sites
record a line number and no byte offset, so there is nothing to patch precisely.
And every edge is a graded syntactic guess, so rewriting a `medium` or `low` one
renames unrelated code that merely shares a name. A correct automatic update
needs a semantic index.

The workflow is therefore: rename, read the graded list, fix each site with
`clip`.

## See Also

- <doc:TheCallGraph>
- <doc:DeclarationIdentifiers>
- <doc:KnownLimitations>
