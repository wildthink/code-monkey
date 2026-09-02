import Foundation
import SQLite3
import CryptoKit
import ArgumentParser

// MARK: - Errors

enum DBError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, String)
    case step(String, String)
    case bind(String)
    case busy(timeoutMilliseconds: Int)
    var description: String {
        switch self {
        case .open(let m): "open: \(m)"
        case .prepare(let s, let m): "prepare \(s): \(m)"
        case .step(let s, let m): "step \(s): \(m)"
        case .bind(let m): "bind: \(m)"
        case .busy(let timeout):
            "database writer busy after \(timeout)ms; wait for active index/refresh/clip operation and retry"
        }
    }
}

// Static destructors used with sqlite3_bind_*.
// SQLITE_TRANSIENT tells SQLite to copy the input. Standard incantation:
// see https://www.sqlite.org/c3ref/c_static.html
//# ai:warn: SQLITE_TRANSIENT = -1 cast to destructor — intentional, do not "fix" to nil/SQLITE_STATIC
//# ai:invariant: bound text/blob bytes are copied by SQLite; caller's buffer may be freed after bind
private let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
private let databaseBusyTimeoutMilliseconds = 5_000

enum DatabaseMode: Sendable, Equatable {
    case readOnly
    case readWrite
}

enum DatabaseValue: Sendable, Codable, Equatable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null

    var int64: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var string: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }
}

struct DatabaseRow: Sendable, Codable, Equatable {
    private var values: [String: DatabaseValue]
    let columns: [String]

    init(_ values: [String: DatabaseValue] = [:], columns: [String] = []) {
        self.values = values
        self.columns = columns
    }

    subscript(_ column: String) -> DatabaseValue? {
        values[column]
    }

    func string(_ column: String) -> String? {
        values[column]?.string
    }

    func int64(_ column: String) -> Int64? {
        values[column]?.int64
    }

    func displayValue(_ column: String) -> String {
        switch values[column] {
        case .integer(let value): String(value)
        case .real(let value): String(value)
        case .text(let value): value
        case .null, nil: ""
        }
    }
}

// MARK: - Thin SQLite wrapper

//# ai:section: "Persistence"
//# ai:invariant: SQLite handle never leaves actor isolation
//# ai:invariant: transactions contain no suspension points
actor Database {
    private var db: OpaquePointer?
    let mode: DatabaseMode

    //# ai:invariant: writable opens create the db parent directory and enable WAL mode
    //# ai:invariant: read-only opens never mutate index state — enforced by PRAGMA query_only
    //# ai:warn: a WAL database cannot be opened with SQLITE_OPEN_READONLY unless its `-shm` sidecar
    //# ai:warn: already exists; SQLite must create it and a read-only handle cannot. A fresh clone or
    //# ai:warn: a reboot leaves index.db alone, so reads asked for READONLY and died at the first
    //# ai:warn: prepare() with "unable to open database file". Read-only mode therefore takes a
    //# ai:warn: read-write *handle* (SQLite manages -wal/-shm) and blocks writes with query_only.
    init(path: URL, mode: DatabaseMode) throws {
        self.mode = mode
        if mode == .readWrite {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let access = mode == .readOnly ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        var rc = sqlite3_open_v2(path.path, &handle, access | SQLITE_OPEN_FULLMUTEX, nil)
        if rc != SQLITE_OK, mode == .readOnly {
            // Immutable media or a file we lack write permission on — fall back to a true
            // read-only handle. Works when the `-shm` sidecar is already present.
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
            rc = sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard rc == SQLITE_OK, let handle else {
            throw DBError.open(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        func configure(_ sql: String) throws {
            var error: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(handle, sql, nil, nil, &error)
            if result != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "?"
                sqlite3_free(error)
                throw DBError.step(sql, message)
            }
        }
        if mode == .readOnly {
            try configure("PRAGMA query_only=ON")
        } else {
            try configure("PRAGMA journal_mode=WAL")
            try configure("PRAGMA synchronous=NORMAL")
        }
        try configure("PRAGMA foreign_keys=ON")
        try configure("PRAGMA busy_timeout=\(databaseBusyTimeoutMilliseconds)")
    }

    /// Truncating checkpoint on close keeps the committed `index.db` self-contained, so a
    /// clone that carries only `index.db` still holds every indexed row.
    isolated deinit {
        if let db {
            if mode == .readWrite { sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) }
            sqlite3_close_v2(db)
        }
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                throw DBError.busy(timeoutMilliseconds: databaseBusyTimeoutMilliseconds)
            }
            throw DBError.step(sql, m)
        }
    }

    func transaction<T: Sendable>(
        _ body: @Sendable (isolated Database) throws -> T
    ) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let v = try body(self)
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    func run(_ sql: String, _ binds: [Bindable] = []) throws -> Int64 {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindAll(stmt, binds)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
            throw DBError.busy(timeoutMilliseconds: databaseBusyTimeoutMilliseconds)
        }
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.step(sql, String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    func query(_ sql: String, _ binds: [any Bindable] = []) throws -> [DatabaseRow] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindAll(stmt, binds)
        let cols = Int(sqlite3_column_count(stmt))
        var names = [String]()
        for i in 0..<cols { names.append(String(cString: sqlite3_column_name(stmt, Int32(i)))) }
        var rows: [DatabaseRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                throw DBError.busy(timeoutMilliseconds: databaseBusyTimeoutMilliseconds)
            }
            guard rc == SQLITE_ROW else {
                throw DBError.step(sql, String(cString: sqlite3_errmsg(db)))
            }
            var row: [String: DatabaseValue] = [:]
            for i in 0..<cols {
                let type = sqlite3_column_type(stmt, Int32(i))
                let n = names[i]
                switch type {
                case SQLITE_INTEGER: row[n] = .integer(sqlite3_column_int64(stmt, Int32(i)))
                case SQLITE_FLOAT: row[n] = .real(sqlite3_column_double(stmt, Int32(i)))
                case SQLITE_NULL: row[n] = .null
                default:
                    if let cs = sqlite3_column_text(stmt, Int32(i)) {
                        row[n] = .text(String(cString: cs))
                    } else {
                        row[n] = .null
                    }
                }
            }
            rows.append(DatabaseRow(row, columns: names))
        }
        return rows
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
            throw DBError.busy(timeoutMilliseconds: databaseBusyTimeoutMilliseconds)
        }
        if rc == SQLITE_CANTOPEN, mode == .readOnly {
            throw DBError.prepare(sql, """
                unable to open database file — the index is in WAL mode and its `-shm` sidecar is \
                missing on a filesystem this process cannot write to. Run `code-monkey index` \
                somewhere writable, or copy the index to a writable location.
                """)
        }
        guard rc == SQLITE_OK else {
            throw DBError.prepare(sql, String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func bindAll(_ stmt: OpaquePointer?, _ binds: [any Bindable]) throws {
        for (i, v) in binds.enumerated() {
            try v.bind(stmt: stmt, index: Int32(i + 1))
        }
    }
}

protocol Bindable: Sendable {
    func bind(stmt: OpaquePointer?, index: Int32) throws
}

extension Int64: Bindable {
    func bind(stmt: OpaquePointer?, index: Int32) throws {
        if sqlite3_bind_int64(stmt, index, self) != SQLITE_OK { throw DBError.bind("int64") }
    }
}
extension Int: Bindable {
    func bind(stmt: OpaquePointer?, index: Int32) throws { try Int64(self).bind(stmt: stmt, index: index) }
}
extension Double: Bindable {
    func bind(stmt: OpaquePointer?, index: Int32) throws {
        if sqlite3_bind_double(stmt, index, self) != SQLITE_OK { throw DBError.bind("double") }
    }
}
extension String: Bindable {
    func bind(stmt: OpaquePointer?, index: Int32) throws {
        if sqlite3_bind_text(stmt, index, self, -1, SQLITE_TRANSIENT_FN) != SQLITE_OK { throw DBError.bind("text") }
    }
}
extension Bool: Bindable {
    func bind(stmt: OpaquePointer?, index: Int32) throws {
        try Int64(self ? 1 : 0).bind(stmt: stmt, index: index)
    }
}
struct SQLNull: Bindable {
    func bind(stmt: OpaquePointer?, index: Int32) throws {
        if sqlite3_bind_null(stmt, index) != SQLITE_OK { throw DBError.bind("null") }
    }
}
extension Optional: Bindable where Wrapped: Bindable {
    func bind(stmt: OpaquePointer?, index: Int32) throws {
        switch self {
        case .none: try SQLNull().bind(stmt: stmt, index: index)
        case .some(let v): try v.bind(stmt: stmt, index: index)
        }
    }
}

// MARK: - Schema

//# ai:section: "Schema"
//# ai:invariant: schema is idempotent — bootstrap() can re-run safely
//# ai:warn: decl_id is NOT UNIQUE — same logical decl can live in multiple files
//# ai:warn: there is no migration path — a version bump means `index --full` rebuilds from source.
//# ai:warn: `doctor` reports schema=<found>/<expected> so the mismatch is visible before it bites.
enum Schema {
    /// 2 — added `call_sites`.
    /// 3 — added `bindings`, which type the receivers `call_sites` records as raw text.
    /// 4 — added `conformances`, which carry the call graph across protocol dispatch.
    /// 5 — added `declarations.spi` and `imports`: the two sides of `@_spi`.
    static let version = 5

    static let createSQL: String = """
    CREATE TABLE IF NOT EXISTS meta(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS files(
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        mtime REAL NOT NULL,
        sha256 TEXT NOT NULL,
        last_indexed REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS declarations(
        id INTEGER PRIMARY KEY,
        decl_id TEXT NOT NULL,           -- stable handle: container.name(arglabels). NOT globally unique.
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        container TEXT,                  -- enclosing type/extension name (nullable for top-level)
        container_kind TEXT,             -- struct | class | enum | extension | protocol
        kind TEXT NOT NULL,              -- func | var | init | struct | class | enum | protocol | extension | typealias
        name TEXT NOT NULL,
        signature TEXT NOT NULL,
        access TEXT,                     -- public | internal | fileprivate | private | open
        -- Comma-joined @_spi group names, effective (a member inherits its container's).
        -- Empty string means "not SPI"; a second axis, never folded into `access`.
        spi TEXT NOT NULL DEFAULT '',
        modifiers TEXT,                  -- comma-joined: static,async,throws,override,...
        start_line INTEGER NOT NULL,
        end_line INTEGER NOT NULL,
        decl_offset INTEGER NOT NULL,
        decl_length INTEGER NOT NULL,
        body_offset INTEGER,
        body_length INTEGER
    );
    CREATE INDEX IF NOT EXISTS declarations_name ON declarations(name);
    CREATE INDEX IF NOT EXISTS declarations_file ON declarations(file_id);
    CREATE INDEX IF NOT EXISTS declarations_container ON declarations(container);
    CREATE INDEX IF NOT EXISTS declarations_decl_id ON declarations(decl_id);
    CREATE INDEX IF NOT EXISTS declarations_spi ON declarations(spi);

    -- The consuming side of `@_spi`: one row per `import` line. `spi` is comma-joined group
    -- names, empty for a plain import. Imports own no decl_id, so they hang off the file.
    CREATE TABLE IF NOT EXISTS imports(
        id INTEGER PRIMARY KEY,
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        module TEXT NOT NULL,            -- first path component
        path TEXT NOT NULL,              -- whole dotted path as written
        kind TEXT,                       -- struct | func | ... on a scoped import; NULL otherwise
        spi TEXT NOT NULL DEFAULT '',
        testable INTEGER NOT NULL DEFAULT 0,
        line INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS imports_module ON imports(module);
    CREATE INDEX IF NOT EXISTS imports_file ON imports(file_id);
    CREATE INDEX IF NOT EXISTS imports_spi ON imports(spi);

    CREATE TABLE IF NOT EXISTS doc_comments(
        decl_id INTEGER PRIMARY KEY REFERENCES declarations(id) ON DELETE CASCADE,
        text TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS directives(
        id INTEGER PRIMARY KEY,
        decl_id INTEGER NOT NULL REFERENCES declarations(id) ON DELETE CASCADE,
        tag TEXT NOT NULL,               -- e.g. "ai:invariant", "ai:why", "ai:see"
        value TEXT NOT NULL,
        line INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS directives_decl ON directives(decl_id);
    CREATE INDEX IF NOT EXISTS directives_tag  ON directives(tag);

    -- Syntactic name uses. `from_decl` is the innermost declaration containing the site;
    -- NULL for top-level code. Nothing here is resolved — resolution happens at query time.
    CREATE TABLE IF NOT EXISTS call_sites(
        id INTEGER PRIMARY KEY,
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        from_decl INTEGER REFERENCES declarations(id) ON DELETE CASCADE,
        name TEXT NOT NULL,              -- callee or member name as written
        receiver TEXT,                   -- base expression text, when there was one
        kind TEXT NOT NULL,              -- call | ref
        line INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS call_sites_name ON call_sites(name);
    CREATE INDEX IF NOT EXISTS call_sites_from ON call_sites(from_decl);
    CREATE INDEX IF NOT EXISTS call_sites_file ON call_sites(file_id);

    -- Names bound to a stated type inside a declaration: locals, parameters, closure params.
    -- Exists solely so `call_sites.receiver` can be resolved to a type; written only when
    -- call sites are.
    CREATE TABLE IF NOT EXISTS bindings(
        id INTEGER PRIMARY KEY,
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        from_decl INTEGER REFERENCES declarations(id) ON DELETE CASCADE,
        name TEXT NOT NULL,              -- the bound identifier as written
        type TEXT NOT NULL,              -- bare nominal type name
        line INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS bindings_lookup ON bindings(from_decl, name);
    CREATE INDEX IF NOT EXISTS bindings_file ON bindings(file_id);

    -- `type_name` declares or extends a type that names `protocol_name` in its inheritance
    -- clause. Superclasses land here too; a name that matches no indexed protocol simply
    -- never satisfies a lookup.
    CREATE TABLE IF NOT EXISTS conformances(
        id INTEGER PRIMARY KEY,
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        type_name TEXT NOT NULL,
        protocol_name TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS conformances_type ON conformances(type_name);
    CREATE INDEX IF NOT EXISTS conformances_protocol ON conformances(protocol_name);

    CREATE TABLE IF NOT EXISTS narrative(
        id INTEGER PRIMARY KEY,
        file_id INTEGER REFERENCES files(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,              -- 'sidecar' | 'book'
        path TEXT NOT NULL,
        text TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS narrative_file ON narrative(file_id);
    """

    /// Prepares an index for writing. On a fresh database this just creates the schema.
    ///
    /// On an index built by an *older* schema there is nothing to migrate: every table here is
    /// derived from source. `allowReset` (only `index` passes it) drops and rebuilds them, which
    /// is what `doctor`'s "run code-monkey index --full" has always promised; every other
    /// writable command refuses instead, so a `clip` can never quietly wipe the index.
    //# ai:warn: the drop must precede `createSQL` — `CREATE TABLE IF NOT EXISTS` cannot widen a
    //# ai:warn: table that already exists, and a new index on a new column fails outright
    //# ai:invariant: returns true only when rows were discarded — the caller must reindex in full
    @discardableResult
    static func bootstrap(_ db: Database, allowReset: Bool = false) async throws -> Bool {
        let stale = try await isStale(db)
        if stale, !allowReset {
            throw SchemaError.stale(found: try await storedVersion(db), expected: version)
        }
        try await db.transaction { db in
            if stale {
                for table in derivedTables { try db.exec("DROP TABLE IF EXISTS \(table)") }
            }
            try db.exec(createSQL)
            // OR REPLACE: after a reset the stored version must move; on a fresh index there is
            // nothing to replace. Either way the stamp now describes the shape actually on disk.
            try db.run(
                "INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)",
                ["schema_version", String(version)]
            )
        }
        return stale
    }

    /// Derived tables, dropped dependents-first.
    private static let derivedTables = [
        "imports", "conformances", "bindings", "call_sites",
        "directives", "doc_comments", "declarations", "narrative", "files",
    ]

    private static func storedVersion(_ db: Database) async throws -> Int? {
        guard try await tableExists("meta", db) else { return nil }
        return try await db.query("SELECT value FROM meta WHERE key='schema_version'")
            .first?.string("value").flatMap(Int.init)
    }

    /// An index carrying rows under a different (or unrecorded) schema version. A database with
    /// no `declarations` table at all is empty, not stale — nothing to lose, nothing to refuse.
    private static func isStale(_ db: Database) async throws -> Bool {
        guard try await tableExists("declarations", db) else { return false }
        return try await storedVersion(db) != version
    }

    private static func tableExists(_ name: String, _ db: Database) async throws -> Bool {
        try await !db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [name]).isEmpty
    }
}

enum SchemaError: Error, CustomStringConvertible {
    case stale(found: Int?, expected: Int)

    var description: String {
        switch self {
        case .stale(let found, let expected):
            "index schema is version \(found.map(String.init) ?? "unknown"), expected \(expected) — "
                + "run `code-monkey index --full` to rebuild it from source"
        }
    }
}

// MARK: - Indexer

struct IndexResult: Sendable, Codable, Equatable {
    var added: Int
    var updated: Int
    var skipped: Int
    var removed: Int
}

struct IndexCheckResult: Sendable, Codable, Equatable {
    var fresh: Int
    var modified: [String]
    var missing: [String]
    var unindexed: [String]

    var needsRefresh: Bool {
        !modified.isEmpty || !missing.isEmpty || !unindexed.isEmpty
    }
}

/// Guards source slicing against an index that has drifted from disk.
///
/// A byte offset only means anything against the exact bytes it was recorded from. Once a file
/// is edited the recorded ranges still *resolve* — they just land in the wrong place, and the
/// command prints shredded text that reads like a corrupt database rather than a stale one.
/// Refusing is the only honest answer: there is no partial credit in a wrong slice.
//# ai:why: `doctor` and `index --check` answer this for the whole project; a read command needs
//# ai:why: it for the two or three files it is about to touch, cheaply enough to do every time
//# ai:invariant: hashes only the files about to be sliced, never the whole project
enum SourceFreshness {
    /// The subset of `paths` whose bytes on disk no longer match what the index recorded.
    /// A path the index has never heard of is stale too — nothing recorded, nothing to trust.
    static func stale(_ paths: some Collection<String>, project: Project,
                      db: Database) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        let unique = Set(paths).sorted()
        let holes = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let rows = try await db.query(
            "SELECT path, sha256 FROM files WHERE path IN (\(holes))", unique.map { $0 as Bindable })
        var recorded: [String: String] = [:]
        for row in rows {
            if let path = row.string("path"), let sha = row.string("sha256") { recorded[path] = sha }
        }
        return unique.filter { path in
            guard let expected = recorded[path],
                  let data = try? Data(contentsOf: project.root.appendingPathComponent(path))
            else { return true }
            return Indexer.sha256(data) != expected
        }
    }

    /// Refuses the command when any file it is about to read source text from has drifted.
    /// Exit code 2 matches `index --check`, so a script can treat staleness the same way
    /// wherever it surfaces.
    static func require(_ paths: some Collection<String>, project: Project, db: Database) async throws {
        let drifted = try await stale(paths, project: project, db: db)
        guard !drifted.isEmpty else { return }
        let list = drifted.prefix(5).map { "  \($0)" }.joined(separator: "\n")
        let more = drifted.count > 5 ? "\n  … and \(drifted.count - 5) more" : ""
        FileHandle.standardError.write(Data("""
            index is stale for the file\(drifted.count == 1 ? "" : "s") this read would slice:
            \(list)\(more)
            The recorded byte offsets no longer match what is on disk, so the source text would
            come out shredded. Run `code-monkey index` and retry.

            """.utf8))
        throw ExitCode(2)
    }
}

//# ai:section: "Indexing"
struct Indexer: Sendable {
    let project: Project
    let db: Database

    /// Index all files. When `full` is true, ignore content hashes and reindex everything.
    /// Returns (added, updated, skipped, removed).
    //# ai:invariant: runs inside one transaction — partial failure rolls back
    //# ai:invariant: skipped means file existed in index with matching sha256
    //# ai:invariant: removed counts files in index that no longer exist on disk
    //# ai:spec: idempotent — repeated calls without source changes return (0, 0, N, 0)
    /// `callSites` overrides `[parse] extract_call_sites`; nil honours the config.
    @discardableResult
    func run(full: Bool = false, callSites: Bool? = nil) async throws -> IndexResult {
        let walker = Walker(project: project)
        let urls = walker.enumerateSwiftFiles()
        let root = project.root
        let wantCallSites = callSites ?? project.config.parse.extractCallSites

        return try await db.transaction { db in
            var added = 0, updated = 0, skipped = 0, removed = 0
            // 1. Index swift files.
            for url in urls {
                let rel = Self.relPath(url, root: root)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                      let data = try? Data(contentsOf: url),
                      let source = String(data: data, encoding: .utf8) else {
                    continue
                }
                let sha = Self.sha256(data)
                let existing = try db.query("SELECT id, sha256 FROM files WHERE path = ?", [rel]).first
                if !full, let existing, existing["sha256"]?.string == sha {
                    skipped += 1
                    continue
                }
                let fileId: Int64
                if let existing, let id = existing["id"]?.int64 {
                    try db.run("UPDATE files SET mtime=?, sha256=?, last_indexed=? WHERE id=?",
                               [mtime, sha, Date().timeIntervalSince1970, id])
                    try db.run("DELETE FROM declarations WHERE file_id=?", [id])
                    // Sites owned by top-level code have from_decl NULL, so the cascade from
                    // declarations does not reach them — clear by file.
                    try db.run("DELETE FROM call_sites WHERE file_id=?", [id])
                    try db.run("DELETE FROM bindings WHERE file_id=?", [id])
                    try db.run("DELETE FROM conformances WHERE file_id=?", [id])
                    try db.run("DELETE FROM imports WHERE file_id=?", [id])
                    fileId = id
                    updated += 1
                } else {
                    fileId = try db.run("INSERT INTO files(path, mtime, sha256, last_indexed) VALUES(?,?,?,?)",
                                        [rel, mtime, sha, Date().timeIntervalSince1970])
                    added += 1
                }
                let extraction = Extractor.extractAll(source: source, file: rel, callSites: wantCallSites)
                let declIds = try Self.insert(decls: extraction.decls, fileId: fileId, db: db)
                let owners = Self.owners(decls: extraction.decls, declIds: declIds)
                try Self.insert(callSites: extraction.callSites, owners: owners,
                                fileId: fileId, db: db)
                try Self.insert(bindings: extraction.bindings, owners: owners,
                                fileId: fileId, db: db)
                try Self.insert(conformances: extraction.decls, fileId: fileId, db: db)
                try Self.insert(imports: extraction.imports, fileId: fileId, db: db)
            }
            // 2. Remove files that no longer exist.
            let known = try db.query("SELECT id, path FROM files")
            let urlSet = Set(urls.map { Self.relPath($0, root: root) })
            for row in known {
                guard let p = row["path"]?.string, let id = row["id"]?.int64 else { continue }
                if !urlSet.contains(p) {
                    try db.run("DELETE FROM files WHERE id=?", [id])
                    removed += 1
                }
            }
            // 3. Narrative: BOOK.md + <File>.md sidecars.
            try db.run("DELETE FROM narrative")
            let book = project.root.appendingPathComponent("BOOK.md")
            if let txt = try? String(contentsOf: book, encoding: .utf8) {
                try db.run("INSERT INTO narrative(file_id, kind, path, text) VALUES(NULL, 'book', ?, ?)",
                           ["BOOK.md", txt])
            }
            for swiftURL in urls {
                let mdURL = swiftURL.deletingPathExtension().appendingPathExtension("md")
                guard let txt = try? String(contentsOf: mdURL, encoding: .utf8) else { continue }
                let rel = Self.relPath(swiftURL, root: root)
                let mdRel = Self.relPath(mdURL, root: root)
                if let row = try db.query("SELECT id FROM files WHERE path=?", [rel]).first,
                   let fid = row["id"]?.int64 {
                    try db.run("INSERT INTO narrative(file_id, kind, path, text) VALUES(?, 'sidecar', ?, ?)",
                               [fid, mdRel, txt])
                }
            }
            // Recorded so `calls` can say "turned off" rather than "nothing found" — a silently
            // empty call graph reads as a fact about the code, which would be a lie.
            if !wantCallSites {
                try db.run("DELETE FROM call_sites")
                try db.run("DELETE FROM bindings")
                try db.run("DELETE FROM conformances")
            }
            try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('call_sites',?)",
                       [wantCallSites ? "on" : "off"])
            return IndexResult(added: added, updated: updated, skipped: skipped, removed: removed)
        }
    }

    static func check(project: Project, db: Database) async throws -> IndexCheckResult {
        let urls = Walker(project: project).enumerateSwiftFiles()
        let rows = try await db.query("SELECT path, sha256 FROM files")
        var indexed = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
                guard let path = row.string("path"), let sha = row.string("sha256") else { return nil }
                return (path, sha)
            }
        )
        var fresh = 0
        var modified: [String] = []
        var unindexed: [String] = []

        for url in urls {
            let path = relPath(url, root: project.root)
            guard let expected = indexed.removeValue(forKey: path) else {
                unindexed.append(path)
                continue
            }
            guard let data = try? Data(contentsOf: url), sha256(data) == expected else {
                modified.append(path)
                continue
            }
            fresh += 1
        }
        return IndexCheckResult(
            fresh: fresh,
            modified: modified.sorted(),
            missing: indexed.keys.sorted(),
            unindexed: unindexed.sorted()
        )
    }

    /// Returns each decl's row id, positionally aligned with `decls`.
    @discardableResult
    private static func insert(
        decls: [Extractor.Decl],
        fileId: Int64,
        db: isolated Database
    ) throws -> [Int64] {
        var ids: [Int64] = []
        ids.reserveCapacity(decls.count)
        for d in decls {
            let modifiers = d.modifiers.joined(separator: ",")
            let id = try db.run("""
                INSERT INTO declarations
                  (decl_id, file_id, container, container_kind, kind, name, signature,
                   access, spi, modifiers, start_line, end_line, decl_offset, decl_length,
                   body_offset, body_length)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [
                    d.declId, fileId, d.container, d.containerKind, d.kind, d.name, d.signature,
                    d.access, d.spi.joined(separator: ","),
                    modifiers, d.startLine, d.endLine, d.declOffset, d.declLength,
                    d.bodyOffset.map { Int64($0) }, d.bodyLength.map { Int64($0) },
                ])
            if !d.doc.isEmpty {
                try db.run("INSERT INTO doc_comments(decl_id, text) VALUES(?,?)", [id, d.doc])
            }
            for dir in d.directives {
                try db.run("INSERT INTO directives(decl_id, tag, value, line) VALUES(?,?,?,?)",
                           [id, dir.tag, dir.value, dir.line])
            }
            ids.append(id)
        }
        return ids
    }

    /// Declaration byte ranges, narrowest first. Ranges nest (a method sits inside its type),
    /// so the first range containing an offset is the innermost declaration that owns it.
    //# ai:invariant: sorted by span ascending — `owner(of:)` depends on it
    private typealias Owner = (start: Int, end: Int, id: Int64)

    private static func owners(decls: [Extractor.Decl], declIds: [Int64]) -> [Owner] {
        zip(decls, declIds)
            .map { (start: $0.0.declOffset, end: $0.0.declOffset + $0.0.declLength, id: $0.1) }
            .sorted { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    private static func owner(of offset: Int, in owners: [Owner]) -> Int64? {
        owners.first { offset >= $0.start && offset < $0.end }?.id
    }

    /// Attributes each site to the innermost declaration containing it; NULL means top-level code.
    private static func insert(
        callSites: [Extractor.CallSite],
        owners: [Owner],
        fileId: Int64,
        db: isolated Database
    ) throws {
        for site in callSites {
            try db.run("""
                INSERT INTO call_sites(file_id, from_decl, name, receiver, kind, line)
                VALUES (?,?,?,?,?,?)
                """, [fileId, owner(of: site.offset, in: owners), site.name, site.receiver,
                        site.kind, site.line])
        }
    }

    /// Same attribution as call sites. A binding owned by no declaration is file-scope and
    /// scoped to nothing a caller can name, so it is dropped rather than stored with a NULL owner.
    private static func insert(
        bindings: [Extractor.Binding],
        owners: [Owner],
        fileId: Int64,
        db: isolated Database
    ) throws {
        for binding in bindings {
            guard let owner = owner(of: binding.offset, in: owners) else { continue }
            try db.run("""
                INSERT INTO bindings(file_id, from_decl, name, type, line)
                VALUES (?,?,?,?,?)
                """, [fileId, owner, binding.name, binding.type, binding.line])
        }
    }

    /// One row per name in a type's or extension's inheritance clause. Extensions matter as
    /// much as the declaration — `extension FileSaver: Saver` is how most Swift conformances
    /// are written, and dropping them would leave the protocol edge unbuilt.
    private static func insert(
        conformances decls: [Extractor.Decl],
        fileId: Int64,
        db: isolated Database
    ) throws {
        for decl in decls where !decl.inherits.isEmpty {
            for parent in decl.inherits {
                try db.run("INSERT INTO conformances(file_id, type_name, protocol_name) VALUES (?,?,?)",
                           [fileId, decl.name, parent])
            }
        }
    }

    /// One row per `import` line, in source order. Nothing is deduped — two files importing the
    /// same module are two facts, and "which files import this SPI group" is the question asked.
    private static func insert(
        imports: [Extractor.Import],
        fileId: Int64,
        db: isolated Database
    ) throws {
        for imp in imports {
            try db.run("""
                INSERT INTO imports(file_id, module, path, kind, spi, testable, line)
                VALUES (?,?,?,?,?,?,?)
                """, [fileId, imp.module, imp.path, imp.kind, imp.spi.joined(separator: ","),
                        imp.testable ? 1 : 0, imp.line])
        }
    }

    static func relPath(_ url: URL, root: URL) -> String {
        let r = root.standardizedFileURL.path
        let u = url.standardizedFileURL.path
        if u.hasPrefix(r + "/") { return String(u.dropFirst(r.count + 1)) }
        return u
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
