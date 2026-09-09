# Known limitations

What this tool is not, and where it is known to be wrong.

## Syntactic, not semantic

code-monkey parses with SwiftSyntax. It needs no build, runs in well under a
second on a large project, and works on code that does not currently compile.
Everything it knows comes from the shape of the source.

A semantic index, one built on Apple's IndexStore, knows real unified symbol
references and answers "who calls this?" and "what conforms to X?" as fact rather
than as a graded guess. It also requires a successful build first. The call graph
here is the syntactic approximation of that, and it grades every edge precisely
because it cannot be certain.

Pick accordingly. If an answer must be exact and you can afford a build, reach
for a semantic tool. If you want the shape of a codebase now, including one that
does not build yet, this is that.

## The list

- No file watcher. Edits made outside the write commands need a reindex.
- Concurrent writers serialize through SQLite and may wait for the busy timeout.
- The configured project audit path is not used by the projectless `file` read,
  write, and append operations.
- Call edges are syntactic guesses, graded high, medium, and low. Locals,
  parameters, and protocol conformances are indexed, so most receivers resolve,
  but a receiver that is an expression, a tuple element, or a `for` binding still
  does not, and conformances declared in a dependency are invisible.
- Test coverage answers are bounded by the depth limit. A test that reaches the
  target in more hops is not found, and the empty result says so at the
  confidence floor rather than claiming no coverage exists.
- Test classification is conventional, by path component or container suffix,
  not attribute-based.
- The `dependencies` field is a heuristic, being the capitalized identifiers in a
  signature, with no standard library or project resolution.
- The `code` output is a readable outline, not compilable Swift. A stubbed
  function with a non-`Void` return type has no return statement.
- Macro declarations are not visited by the extractor, so they never appear.
- Changing the extractor requires a full reindex. Incremental indexing keys off
  file content hashes and will not notice that the parser changed.
- Declarations sharing a name across files share an identifier. Disambiguate with
  `--file`.
- The parser does not visit code inside string literals. That is useful as an
  escape hatch, but it means declaration-shaped content in strings is invisible.

## See Also

- <doc:TheCallGraph>
- <doc:TheWriteModel>
