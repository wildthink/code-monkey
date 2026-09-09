# Readable outlines

`code` renders declarations themselves, at whatever level of detail you want.

## Overview

Where `get` answers facts about declarations, `code` renders the declarations, as
Swift you can read. Disclosure is a ladder. Start at the bottom and turn the
dial.

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

Cost climbs steeply with the rung. Level 1 carries every property, and with
`--doc` every leading doc comment and directive besides. Stay at level 0 until
you know which type you want, then descend on that one alone.

## Selectors

A name, a `Name:member` pair, a file, a directory, or nothing at all.

```bash
code-monkey code Walker                      # by name; substring matches are not an error
code-monkey code Walk:enum                   # only members whose name contains "enum"
code-monkey code Sources/App/Walker.swift    # every decl in one file
code-monkey code Sources/App:fold            # decls named *fold* under a directory
code-monkey code .                           # the whole project
```

A `:member` filter with no explicit level starts at rung 2, because rung 0 would
hide the very thing you filtered for.

## Kind flags

These take an exact slice instead of a rung, and they compose.

```bash
code-monkey code Walker --vars
code-monkey code Walk:enum --funcs
code-monkey code Walk:enum --funcs --body
code-monkey code Walker --funcs --access public
code-monkey code . --types
code-monkey code . --all --access public --spi none
```

`--vars` covers `var` and `let` together. `--funcs` covers `func`, `init`,
`deinit`, and `subscript`. `--types` covers nested types plus the other named
declarations: `typealias`, `associatedtype`, `operator`, `precedencegroup`.
`--cases` covers enum cases, and `--all` is everything.

A nested type survives a kind filter it does not match if something inside it
does. `--funcs` shows methods living in a nested type, wrapped in that type's
shell, rather than dropping them.

## Body depth

Independent of which members are shown. `--body` expands them, `--fold` renders
`{ ... }`, and the default `{}` keeps one member per line.

## Lifting one member with `--expand`

Everything named by `--expand` renders in full. Everything else stays where
`--level` put it. This is the read a `:member` filter cannot express, because
`:member` also hides the siblings it filters past.

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

Three rules make it predictable.

- Like `:member`, it defaults the level to 2. A body among its siblings is the
  point, and rung 0 has no siblings. Say `-L0` for the shell alone.
- It forces the match in even below the rung that would have listed it, so `-L0
  --expand` is never a silent no-op. An explicit `--access` or `--spi` floor
  still outranks it.
- Expansion is inherited. Naming a type expands what is nested inside it, rather
  than doing nothing because the match was not a leaf.

`code --fold --expand X` is the outline-view twin of `get X --fields body
--body-mode fold --keep X`. Reach for `code` when you want the synthetic,
uniformly indented view, and `get` when you need byte-accurate source.

## Other options

`--doc` interleaves doc comments and directives. `--numbers` annotates each
declaration with its line range. `--no-header` drops the path comments.
`--limit` caps top-level declarations, defaulting to 200. `--json` emits `{id,
kind, file, start_line, end_line, code}` per declaration.

> Important: `code` output is a readable outline, not compilable Swift. A stubbed
> function with a non-`Void` return type has no return statement. For a faithful
> excerpt of real source, use `get --fields body --body-mode fold`, which does
> byte-accurate elision on the file itself.

## See Also

- <doc:TheReadModel>
- <doc:AccessAndSPI>
