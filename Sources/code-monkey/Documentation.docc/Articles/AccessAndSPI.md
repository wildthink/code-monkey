# Access and SPI

Two independent axes, never folded into one.

## Overview

The `@_spi(Group)` attribute marks a declaration as public to the compiler but
private to you. It is public in every sense the language cares about, and
off-limits to anyone who did not write a matching `@_spi(Group) import` at the top
of their file.

code-monkey tracks it as a second axis.

- `access` records the Swift modifier alone, so a declaration marked both public
  and SPI still reads as public, and `--access public` keeps the meaning it always
  had. Swift's access levels are strictly ordered. SPI is not one of them, and
  inserting it would have made that order lie.
- `spi` is the group list, and `--spi` filters on it independently.

Combine the two to ask the question people actually mean. Asking for public with
no SPI is the real API surface. Asking for public with any SPI is everything that
looks public but is not.

`--spi` takes `any`, `none`, or a group name. Names match whole, never as a
prefix. It is accepted by `code`, `get`, `weave`, and `imports`.

## SPI is effective, not declared

A member inherits every group its enclosing type or extension carries, the way
Swift resolves it.

```swift
@_spi(Testing) public extension Plain {
    func f() {}          // reported as @_spi(Testing) — nothing is written on it
}

@_spi(Internal) public struct Widget {
    @_spi(Testing) public func g() {}   // reported as @_spi(Internal,Testing)
}
```

Outer groups come first, a declaration's own groups are appended, and duplicates
collapse.

## Both sides of the contract

The two sides are separate commands. `code --spi` and `get --spi` show what this
project exposes behind SPI. `imports --spi` shows what it consumes. Renaming or
retiring a group needs both.

Detection is syntactic and exact. The `@_spi_available` attribute is a different
attribute and never matches.

## Access levels

| Level | Meaning |
|---|---|
| `open` | subclassable and overridable outside the defining module |
| `public` | visible outside the module |
| `package` | visible across the package |
| `internal` | module-wide, and what a declaration with no modifier gets |
| `fileprivate` | visible within the file |
| `private` | visible within the enclosing scope |

## See Also

- <doc:ReadableOutlines>
- <doc:LiterateProjection>
