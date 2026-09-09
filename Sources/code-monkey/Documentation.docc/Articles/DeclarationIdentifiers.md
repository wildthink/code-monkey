# Declaration identifiers

The stable handle every command uses.

## Overview

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

Parameter types are included so overloads disambiguate.

For most lookups you can pass just the name, because the CLI promotes it to a
name match. Drop down to the exact identifier when a command reports an ambiguous
match.

Two declarations in different files may share an identifier. Use `--file` to
disambiguate.

## See Also

- <doc:TheReadModel>
- <doc:SchemaReference>
