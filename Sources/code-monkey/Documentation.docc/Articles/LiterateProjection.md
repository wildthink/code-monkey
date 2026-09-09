# Literate projection

`weave` renders the index back as a Markdown book of the codebase.

## Overview

```bash
code-monkey weave Sources                              # everything, Markdown to stdout
code-monkey weave Sources --summary                    # prose + signatures, no bodies
code-monkey weave --section "Authentication"           # one ai:section chunk
code-monkey weave Sources --access public              # only open + public
code-monkey weave Sources --access internal            # adds internal + package
code-monkey weave Sources --access public --spi none   # ...minus anything behind @_spi
code-monkey weave Sources -o BOOK.draft.md
```

`--access` takes a minimum level. Passing `public` keeps open and public.
Passing `internal` also keeps internal and package. Passing `private` keeps
everything. Declarations without an explicit access modifier count as internal,
which is Swift's own default.

## Prose sidecars

`weave` pulls `BOOK.md` from the project root as a preamble, and a `<File>.md`
sidecar beside any source file as per-file prose. Declarations interleave in
source order, and `//# ai:` directives render as block quotes.

## See Also

- <doc:Directives>
- <doc:AccessAndSPI>
