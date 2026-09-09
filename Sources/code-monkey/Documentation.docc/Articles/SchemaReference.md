# Schema reference

The tables `query` reads, and the traps in them.

## Overview

`PRAGMA table_info(<table>)` is always the authoritative column list. This is the
shape as designed.

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

## Resolving receivers

`bindings` and `conformances` exist to resolve the raw text in
`call_sites.receiver`. A binding's type is desugared, so `[String]` becomes
`Array` and `any Saver` becomes `Saver`, while tuples and function types get
sentinels that match no container.

`conformances` does not distinguish a superclass from a protocol, because syntax
cannot. A name that matches no indexed protocol simply never satisfies a lookup.

## Traps

`decl_id` is indexed but not unique. Two declarations in different files may
share one, so disambiguate with `--file`, or by joining `files` in a query.

`kind` is one of `struct`, `class`, `enum`, `protocol`, `actor`, `extension`,
`typealias`, `associatedtype`, `operator`, `precedencegroup`, `func`, `init`,
`deinit`, `subscript`, `var`, `let`, `case`. Note that `var` and `let` are
separate kinds, so `--kind var` will not match stored `let` properties. The
`--vars` flag on `code` covers both.

Operator implementations, written as a static or prefix function, are ordinary
`func` rows named after the operator. The `operator` rows are the separate
infix operator declarations.

The `narrative` table is often empty.

## See Also

- <doc:QueryingTheIndex>
- <doc:DeclarationIdentifiers>
