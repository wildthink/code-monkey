import ArgumentParser
import CommandREPL
import Darwin
import Foundation
import Synchronization

// MARK: - init

struct InitCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init",
        abstract: "Create .code-monkey.toml and .code-monkey/ in current directory.")

    @Flag(name: .long, help: "Overwrite existing config.")
    var force: Bool = false

    mutating func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let tomlURL = cwd.appendingPathComponent(".code-monkey.toml")
        let dotURL = cwd.appendingPathComponent(".code-monkey")
        let fm = FileManager.default
        if fm.fileExists(atPath: tomlURL.path) && !force {
            FileHandle.standardError.write(Data("config exists: \(tomlURL.path) (use --force)\n".utf8))
            throw ExitCode(1)
        }
        try fm.createDirectory(at: dotURL, withIntermediateDirectories: true)
        try Config.defaultTOML.data(using: .utf8)?.write(to: tomlURL)
        print("wrote \(tomlURL.path)")
        print("wrote \(dotURL.path)/")
    }
}

// MARK: - index / refresh

struct IndexCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "index",
        abstract: "Build or refresh the SQLite index. Default: incremental.")
    @OptionGroup var opts: GlobalOptions
    @Flag(name: .long, help: "Reindex all files, ignoring content hashes.")
    var full: Bool = false
    @Flag(name: .long, help: "Report stale index state without writing.")
    var check: Bool = false
    /// Optional on purpose: nil means "not typed", which is what lets the config setting stand.
    //# ai:why: a defaulted Bool cannot say whether the user typed it, and the old workaround
    //# ai:why: — scanning `CommandLine.arguments` — reads the process argv, so it answers for
    //# ai:why: the wrong line the moment a command is dispatched from anywhere but main()
    @Flag(inversion: .prefixedNo, exclusivity: .chooseLast,
          help: "Index call sites, which power `calls` and `get --fields callers,callees`. Roughly quadruples the index. Defaults to `[parse] extract_call_sites`.")
    var callSites: Bool?

    mutating func run() async throws {
        if check && full {
            FileHandle.standardError.write(Data("--check and --full are mutually exclusive\n".utf8))
            throw ExitCode(1)
        }
        if check {
            let (project, db, _) = try await opts.openIndex(
                command: "index",
                tier: "T0",
                target: "check"
            )
            let result = try await Indexer.check(project: project, db: db)
            Printer.emit(
                result,
                json: opts.json,
                tier: "T0",
                freshness: result.needsRefresh ? "stale" : "fresh"
            ) {
                "fresh=\(result.fresh) modified=\(result.modified.count) missing=\(result.missing.count) unindexed=\(result.unindexed.count)"
            }
            if result.needsRefresh { throw ExitCode(2) }
            return
        }
        let (project, db, schemaWasReset) = try await opts.openIndex(
            command: "index",
            tier: "write",
            target: full ? "full" : "incremental",
            writable: true
        )
        // nil = not typed = leave the config setting alone.
        let r = try await Indexer(project: project, db: db).run(full: full || schemaWasReset,
                                                                callSites: callSites)
        Printer.emit(r, json: opts.json, warnings: schemaWasReset ? ["schema upgraded — index rebuilt from source"] : []) {
            "added=\(r.added) updated=\(r.updated) skipped=\(r.skipped) removed=\(r.removed)"
                + (schemaWasReset ? "\nschema upgraded to \(Schema.version) — index rebuilt from source" : "")
        }
    }
}

struct DoctorReport: Codable, Sendable {
    let executable: String
    let checkout_executable: String?
    let using_checkout_executable: Bool?
    let project_root: String
    let index_path: String
    let index_exists: Bool
    let schema_version: Int?
    let expected_schema_version: Int
    let journal_mode: String?
    let call_sites: String?
    let audit_path: String
    let freshness: IndexCheckResult?
    let warnings: [String]
}

struct DoctorCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose executable, index, concurrency, audit, and freshness state."
    )
    @OptionGroup var opts: GlobalOptions

    mutating func run() async throws {
        let project = try opts.resolveProject()
        let executable = Bundle.main.executableURL?.standardizedFileURL.path
            ?? CommandLine.arguments[0]
        let checkoutURL = project.root.appendingPathComponent(".build/debug/code-monkey")
        let checkoutExists = FileManager.default.fileExists(atPath: checkoutURL.path)
        let checkoutExecutable = checkoutExists ? checkoutURL.standardizedFileURL.path : nil
        let usingCheckout = checkoutExecutable.map { $0 == executable }
        let executableDate = (try? FileManager.default.attributesOfItem(atPath: executable)[.modificationDate]) as? Date
        let checkoutDate = checkoutExecutable.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
        }
        let indexExists = FileManager.default.fileExists(atPath: project.dbPath.path)
        var schemaVersion: Int?
        var journalMode: String?
        var callSites: String?
        var freshness: IndexCheckResult?
        var warnings: [String] = []

        if let checkoutExecutable,
           checkoutExecutable != executable,
           let checkoutDate,
           checkoutDate > (executableDate ?? .distantPast) {
            warnings.append("checkout build differs from running executable; use \(checkoutExecutable)")
        }
        if indexExists {
            let db = try Database(path: project.dbPath, mode: .readOnly)
            schemaVersion = try await db.query(
                "SELECT value FROM meta WHERE key='schema_version'"
            ).first?.string("value").flatMap(Int.init)
            journalMode = try await db.query("PRAGMA journal_mode").first?.string("journal_mode")
            callSites = try await CallGraph(db: db).callSitesIndexed() ? "on" : "off"
            freshness = try await Indexer.check(project: project, db: db)
            if schemaVersion != Schema.version {
                warnings.append("schema version mismatch; run code-monkey index --full")
            }
            if freshness?.needsRefresh == true {
                warnings.append("index is stale; run code-monkey index")
            }
        } else {
            warnings.append("index missing; run code-monkey index")
        }

        let report = DoctorReport(
            executable: executable,
            checkout_executable: checkoutExecutable,
            using_checkout_executable: usingCheckout,
            project_root: project.root.path,
            index_path: project.dbPath.path,
            index_exists: indexExists,
            schema_version: schemaVersion,
            expected_schema_version: Schema.version,
            journal_mode: journalMode,
            call_sites: callSites,
            audit_path: AuditLog.url(project: project).path,
            freshness: freshness,
            warnings: warnings
        )
        Printer.emit(
            report,
            json: opts.json,
            tier: "T0",
            warnings: warnings,
            freshness: freshness?.needsRefresh == true ? "stale" : (indexExists ? "fresh" : "missing")
        ) {
            [
                "executable=\(report.executable)",
                "project=\(report.project_root)",
                "index=\(report.index_exists ? "present" : "missing") schema=\(report.schema_version.map(String.init) ?? "-")/\(report.expected_schema_version) journal=\(report.journal_mode ?? "-") call_sites=\(report.call_sites ?? "-")",
                "audit=\(report.audit_path)",
                warnings.isEmpty ? "status=ok" : "warnings=\(warnings.joined(separator: " | "))",
            ].joined(separator: "\n")
        }
    }
}

// MARK: - list/schema/info/body/fold/find — absorbed into `get` (see Get.swift)
// MARK: - query

/// A named query kept in the binary instead of on the tool surface.
///
/// A recipe costs one enum case in the published schema — a few tokens. The same convenience
/// as a subcommand would cost a whole tool description, in every request, in every session that
/// never calls it.
//# ai:why: this is the cheap extensibility axis — reach for a recipe before adding a command
//# ai:invariant: every recipe is read-only, so `run` can pass it through the SELECT/WITH guard
enum QueryRecipe: String, CaseIterable, Sendable, ExpressibleByArgument {
    case sections
    case mass
    case invariants
    case protocols

    var sql: String {
        switch self {
        case .sections:
            "SELECT DISTINCT value FROM directives WHERE tag='ai:section' ORDER BY value"
        case .mass:
            """
            SELECT f.path, COUNT(d.id) n FROM files f
            LEFT JOIN declarations d ON d.file_id = f.id
            GROUP BY f.path ORDER BY n DESC
            """
        case .invariants:
            """
            SELECT d.name, v.value FROM directives v
            JOIN declarations d ON d.id = v.decl_id
            WHERE v.tag = 'ai:invariant' ORDER BY d.name
            """
        case .protocols:
            """
            SELECT protocol_name, COUNT(*) n FROM conformances
            GROUP BY protocol_name ORDER BY n DESC
            """
        }
    }

    var summary: String {
        switch self {
        case .sections: "the sections the author declared — the cheapest map of a project"
        case .mass: "declarations per file, densest first — where the code actually is"
        case .invariants: "every ai:invariant, with the declaration it guards"
        case .protocols: "which protocols the project leans on, most-conformed first"
        }
    }

    /// Documents each recipe for `--help`, completion, and the generated tool schema.
    static var allValueDescriptions: [String: String] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.summary) })
    }
}

struct QueryCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "query",
        abstract: "Run a read-only SELECT/WITH/PRAGMA against the index.",
        discussion: """
        The escape hatch beneath `get` and `code`: counts, distributions, and cross-cutting \
        searches neither of those can express. Reach for it to decide *what* is worth reading, \
        then read that with `code`. Only SELECT/WITH/PRAGMA run; anything else is refused.

        `--recipe` runs a named query for the cases worth having by heart; `--help` \
        lists them with what each returns. Reach for one before writing SQL by hand.

        TABLES
          files          id, path, mtime, sha256, last_indexed
          declarations   id, decl_id, file_id, container, container_kind, kind, name,
                         signature, access, spi, modifiers, start_line, end_line,
                         decl_offset, decl_length, body_offset, body_length
          directives     decl_id, tag, value, line
          doc_comments   decl_id, text
          imports        file_id, module, path, kind, spi, testable, line
          call_sites     file_id, from_decl, name, receiver, kind, line
          bindings       file_id, from_decl, name, type, line
          conformances   file_id, type_name, protocol_name
          narrative      file_id, kind, path, text
        `PRAGMA table_info(<table>)` is the authoritative column list. A directive \
        `tag` is one of ai:why, ai:invariant, ai:warn, ai:section, ai:spec.

        Two joins bite. `declarations` carries no `path` — join `files` on `file_id`. And \
        `decl_id` names two different things: on `declarations` it is the stable TEXT handle \
        you hand to `get`, while on `directives` and `doc_comments` it is an INTEGER foreign \
        key to `declarations.id`. Equating the two matches nothing and reports no error.

        EXAMPLES
          code-monkey query --recipe sections    map a project you have not read
          code-monkey query --recipe mass        find the files worth reading
          code-monkey query --recipe invariants  the rules, before you edit
          code-monkey query --recipe protocols   what the project leans on

          hand-written SQL — note the join is on d.id, not d.decl_id
            code-monkey query "SELECT d.name, COUNT(*) n FROM directives v
              JOIN declarations d ON d.id = v.decl_id
              GROUP BY d.name ORDER BY n DESC LIMIT 10"
        """)
    @OptionGroup var opts: GlobalOptions
    @Argument(help: "SQL to run. Omit it when --recipe is given.") var sql: String?
    @Option(name: .long, help: "Run a named query instead of <sql>.") var recipe: QueryRecipe?

    func validate() throws {
        switch (sql, recipe) {
        case (nil, nil):
            throw ValidationError("pass <sql> or --recipe (\(QueryRecipe.allCases.map(\.rawValue).joined(separator: ", ")))")
        case (.some, .some):
            throw ValidationError("pass <sql> or --recipe, not both")
        default:
            break
        }
    }

    mutating func run() async throws {
        let (_, db, _) = try await opts.openIndex(command: "query", tier: "T0", target: "sql-redacted")
        let sql = recipe?.sql ?? sql ?? ""
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("select") || trimmed.hasPrefix("with") || trimmed.hasPrefix("pragma") else {
            FileHandle.standardError.write(Data("only SELECT/WITH/PRAGMA allowed\n".utf8))
            throw ExitCode(1)
        }
        let rows = try await db.query(sql)
        if opts.json {
            let payload: [[String: String]] = rows.map { row in
                var out: [String: String] = [:]
                for column in row.columns {
                    out[column] = row.displayValue(column)
                }
                return out
            }
            Printer.emit(payload, json: true) { "" }
        } else {
            if let first = rows.first {
                let cols = first.columns
                print(cols.joined(separator: "\t"))
                for r in rows {
                    print(cols.map { r.displayValue($0) }.joined(separator: "\t"))
                }
            }
        }
    }
}

// MARK: - weave

struct WeaveCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "weave",
        abstract: "Knuth-style literate projection: prose + signatures (+ bodies unless --summary).")
    @OptionGroup var opts: GlobalOptions
    @Argument(help: "Path filter (file or directory).") var path: String?
    @Option(name: .long, help: "Write to file instead of stdout.") var output: String?
    @Flag(name: .long, help: "Strip bodies — keep prose + signatures.") var summary: Bool = false
    @Option(name: .long, help: "Only decls under this ai:section value.") var section: String?
    @Option(name: .long, help: "Minimum access level to include. Includes higher levels too. Decls with no modifier count as `internal`.")
    var access: AccessLevel?
    @Option(name: .long, help: "Filter by @_spi scope: \(SPIFilter.help). Independent of --access.")
    var spi: SPIFilter?

    mutating func run() async throws {
        let (project, db, _) = try await opts.openIndex(
            command: "weave",
            tier: summary ? "T1" : "T3",
            target: path
        )
        var lines: [String] = []
        // BOOK.md preamble
        if let book = try await db.query("SELECT text FROM narrative WHERE kind='book' LIMIT 1").first,
           let txt = book.string("text") {
            lines.append(txt)
            lines.append("")
        }
        let pathFilter = path.map { relativePath($0, root: project.root) }
        var clauses: [String] = []
        var binds: [Bindable] = []
        if let pathFilter {
            clauses.append("(f.path = ? OR f.path LIKE ?)")
            binds.append(pathFilter); binds.append(pathFilter + "/%")
        }
        if section != nil {
            clauses.append("d.id IN (SELECT decl_id FROM directives WHERE tag='ai:section' AND value=?)")
            binds.append(section!)
        }
        if let access {
            let allowed = AccessLevel.atOrAbove(access)
            // Decls without an explicit modifier default to `internal`; treat "" / NULL as internal for filter purposes.
            let quoted = allowed.map { "'\($0)'" }.joined(separator: ",")
            if allowed.contains("internal") {
                clauses.append("(d.access IN (\(quoted)) OR d.access IS NULL OR d.access = '')")
            } else {
                clauses.append("d.access IN (\(quoted))")
            }
        }
        if let spi {
            let (sql, spiBinds) = spi.clause(column: "d.spi")
            clauses.append(sql)
            binds.append(contentsOf: spiBinds)
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let rows = try await db.query("""
            SELECT d.id, d.decl_id, d.name, d.kind, d.container, d.container_kind,
                   d.signature, d.start_line, d.body_offset, d.body_length,
                   f.path AS file_path
              FROM declarations d JOIN files f ON f.id = d.file_id
              \(whereSQL)
              ORDER BY f.path, d.start_line
            """, binds)
        // `--summary` prints signatures straight from the index and never touches disk; without
        // it every body here is a slice, so every file behind them has to still match.
        if !summary {
            try await SourceFreshness.require(rows.compactMap { $0.string("file_path") },
                                              project: project, db: db)
        }

        var lastFile = ""
        for r in rows {
            let file = r.string("file_path") ?? ""
            if file != lastFile {
                lines.append("## \(file)")
                if let nar = try await db.query("SELECT text FROM narrative WHERE file_id=(SELECT id FROM files WHERE path=?) AND kind='sidecar'", [file]).first,
                   let txt = nar.string("text") {
                    lines.append(txt); lines.append("")
                }
                lastFile = file
            }
            let id = r.string("decl_id") ?? ""
            lines.append("### `\(id)`")
            let declRowId = r.int64("id") ?? 0
            if let dr = try await db.query("SELECT text FROM doc_comments WHERE decl_id=?", [declRowId]).first,
               let txt = dr.string("text"), !txt.isEmpty {
                lines.append(txt)
            }
            let dirs = try await db.query("SELECT tag, value FROM directives WHERE decl_id=? ORDER BY line", [declRowId])
            for d in dirs {
                let t = d.string("tag") ?? ""
                let v = d.string("value") ?? ""
                if t == "ai:section" { lines.append("> **Section:** \(v)") }
                else { lines.append("> **\(t):** \(v)") }
            }
            lines.append("")
            lines.append("```swift")
            lines.append(r.string("signature") ?? "")
            if !summary, let off = r.int64("body_offset"), let len = r.int64("body_length"),
               let body = sliceFile(project.root, file, offset: Int(off), length: Int(len)) {
                lines.append(body)
            }
            lines.append("```")
            lines.append("")
        }
        let text = lines.joined(separator: "\n")
        if let out = output {
            try text.data(using: .utf8)?.write(to: URL(fileURLWithPath: out))
        } else {
            print(text)
        }
    }
}

// MARK: - imports

/// The consuming side of the SPI contract. `code --spi` answers "what do we *expose* behind
/// `@_spi`"; this answers "what do we *reach for*" — the question that decides whether an
/// upstream group can be renamed, and the one nothing else in the index can answer.
struct ImportsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "imports",
        abstract: "List `import` lines, with their @_spi groups and @testable marks.",
        discussion: """
        The consuming side of SPI — what this project reaches for. For the other side, what \
        it exposes behind @_spi, filter declarations by their spi scope with `code`. Use this \
        before renaming or retiring an SPI group, and to find which files are wired to a \
        module.

        EXAMPLES
          code-monkey imports                      every import in the project
          code-monkey imports --spi any            only SPI imports — the SPI we consume
          code-monkey imports --spi Internal       only imports of that group
          code-monkey imports --module Foundation  every file that imports Foundation
          code-monkey imports Sources/code-monkey  narrow to a subtree
        """)

    struct ImportView: Encodable {
        var file: String
        var line: Int
        var module: String
        var path: String
        var kind: String?
        var spi: [String]
        var testable: Bool
    }

    @OptionGroup var opts: GlobalOptions
    @Argument(help: "Path filter (file or directory).") var path: String?
    @Option(name: .long, help: "Only imports of this module (first path component).") var module: String?
    @Option(name: .long, help: "Filter by @_spi scope: \(SPIFilter.help).") var spi: SPIFilter?
    @Flag(name: .long, help: "Only `@testable` imports.") var testable: Bool = false

    mutating func run() async throws {
        let (project, db, _) = try await opts.openIndex(
            command: "imports", tier: "T0", target: module ?? spi?.description ?? path ?? "all")
        var clauses: [String] = []
        var binds: [Bindable] = []
        if let path {
            let rel = relativePath(path, root: project.root)
            clauses.append("(f.path = ? OR f.path LIKE ?)")
            binds.append(rel); binds.append(rel + "/%")
        }
        if let module { clauses.append("i.module = ?"); binds.append(module) }
        if let spi {
            let (sql, spiBinds) = spi.clause(column: "i.spi")
            clauses.append(sql)
            binds.append(contentsOf: spiBinds)
        }
        if testable { clauses.append("i.testable = 1") }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let rows = try await db.query("""
            SELECT i.module, i.path, i.kind, i.spi, i.testable, i.line, f.path AS file_path
              FROM imports i JOIN files f ON f.id = i.file_id
              \(whereSQL)
              ORDER BY f.path, i.line
            """, binds)

        let views = rows.map { r in
            ImportView(file: r.string("file_path") ?? "",
                       line: Int(r.int64("line") ?? 0),
                       module: r.string("module") ?? "",
                       path: r.string("path") ?? "",
                       kind: r.string("kind"),
                       spi: SPIFilter.groups(r.string("spi")),
                       testable: (r.int64("testable") ?? 0) == 1)
        }
        Printer.emit(views, json: opts.json, tier: "T0", resultCount: views.count) {
            views.map { v in
                var attrs = v.spi.map { "@_spi(\($0))" }
                if v.testable { attrs.append("@testable") }
                let prefix = attrs.isEmpty ? "" : attrs.joined(separator: " ") + " "
                let kind = v.kind.map { $0 + " " } ?? ""
                return "\(v.file):\(v.line)\t\(prefix)import \(kind)\(v.path)"
            }.joined(separator: "\n")
        }
    }
}

// MARK: - clip (file-scoped: read or paste-replace one decl in one file)

struct ClipCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clip",
        abstract: """
        Replace a declaration's full text by decl_id/name. Write-only — reading is what \
        `get` is for.
        """,
        discussion: """
        The replacement is the declaration's entire text, attributes and signature included, \
        and it overwrites the matched declaration outright. An ambiguous name is refused \
        rather than guessed; narrow it with `--file`, or name the decl_id exactly. The file is \
        re-indexed on the way out, so the index never lags the write.
        """)
    @OptionGroup var opts: GlobalOptions
    @Argument var pattern: String
    @Option(name: .long, help: "Restrict to this file (disambiguates same-named decls).")
    var file: String?
    @Flag(name: .long, help: "Required. Replace the matched decl with stdin.") var pasteReplacing: Bool = false

    mutating func run() async throws {
        guard pasteReplacing else {
            FileHandle.standardError.write(Data("clip is write-only — pass --paste-replacing, or use `get --fields body` to read\n".utf8))
            throw ExitCode(1)
        }
        let (project, db, _) = try await opts.openIndex(
            command: "clip",
            tier: "write",
            target: pattern,
            writable: true
        )
        var sql = """
            SELECT d.id, d.decl_id, d.signature, d.decl_offset, d.decl_length, f.path AS file_path
              FROM declarations d JOIN files f ON f.id=d.file_id
             WHERE (d.decl_id = ? OR d.name = ? OR d.decl_id LIKE ? OR d.signature LIKE ?)
            """
        var binds: [Bindable] = [pattern, pattern, "%" + pattern + "%", "%" + pattern + "%"]
        if let file {
            sql += " AND f.path = ?"
            binds.append(relativePath(file, root: project.root))
        }
        sql += " ORDER BY f.path, d.start_line"
        let rows = try await db.query(sql, binds)
        if rows.isEmpty {
            FileHandle.standardError.write(Data("no match for `\(pattern)` — try `code-monkey index`\n".utf8))
            throw ExitCode(1)
        }
        if rows.count > 1 {
            FileHandle.standardError.write(Data("ambiguous (\(rows.count) matches) — use exact decl_id or --file:\n".utf8))
            for r in rows {
                FileHandle.standardError.write(Data("  \(r.string("decl_id") ?? "")  \(r.string("file_path") ?? "")\n".utf8))
            }
            throw ExitCode(1)
        }
        let row = rows[0]
        let rel = row.string("file_path") ?? ""
        let offset = Int(row.int64("decl_offset") ?? 0)
        let length = Int(row.int64("decl_length") ?? 0)
        let url = project.root.appendingPathComponent(rel)
        let newBody = FileHandle.standardInput.readDataToEndOfFile()
        guard var data = try? Data(contentsOf: url) else {
            FileHandle.standardError.write(Data("cannot read \(rel)\n".utf8))
            throw ExitCode(1)
        }
        data.replaceSubrange(offset..<offset+length, with: newBody)
        try data.write(to: url)
        // Re-index this single file.
        _ = try await Indexer(project: project, db: db).run(full: false)
        print("replaced \(row.string("decl_id") ?? "") in \(rel)")
    }
}

// MARK: - file ops

struct FileCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "file",
        abstract: "Read/write/append/log for paths outside the project sandbox.",
        subcommands: [Read.self, WriteSub.self, AppendSub.self, LogSub.self])

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "read")
        @Argument var path: String
        @Option(name: .long, help: "Line range: \"1-30\" or \"-50\" (last 50).") var lines: String?
        mutating func run() async throws {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let text = try String(contentsOf: url, encoding: .utf8)
            let split = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let chosen: ArraySlice<Substring> = {
                guard let lines else { return ArraySlice(split) }
                if lines.hasPrefix("-"), let n = Int(lines.dropFirst()) {
                    return split.suffix(n)[...]
                }
                let parts = lines.split(separator: "-").map(String.init)
                if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) {
                    let lo = max(0, a - 1), hi = min(split.count, b)
                    if lo < hi { return split[lo..<hi] }
                }
                return ArraySlice(split)
            }()
            print(chosen.joined(separator: "\n"))
            AuditLog.append("read", path: url.path, note: lines)
        }
    }

    struct WriteSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "write")
        @Argument var path: String
        @Option(name: .long, help: "Reason — logged for audit.") var context: String?
        mutating func run() async throws {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let data = FileHandle.standardInput.readDataToEndOfFile()
            try data.write(to: url)
            AuditLog.append("write", path: url.path, note: context)
        }
    }

    struct AppendSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "append")
        @Argument var path: String
        @Option(name: .long) var context: String?
        mutating func run() async throws {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let h = try? FileHandle(forWritingTo: url) {
                try h.seekToEnd()
                try h.write(contentsOf: data)
                try h.close()
            } else {
                try data.write(to: url)
            }
            AuditLog.append("append", path: url.path, note: context)
        }
    }

    struct LogSub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "log",
            abstract: "Tail the audit log.",
            discussion: """
            Raw JSONL by default. `--argv` renders the invocation entries as the command \
            lines that produced them, oldest first — a session history you can read, grep, \
            or pipe to a shell.

            `--stats` summarizes them instead: which commands were reached for, how deep the \
            reads went, which argv the parser refused, and which targets were read twice in \
            quick succession. The last two are the ones worth acting on — a refused argv is a \
            command whose help failed to teach its own spelling, and a re-read is the cheaper \
            tier failing to answer.

            EXAMPLES
              code-monkey file log --last 200 --argv
              code-monkey file log --last 200 --argv --failed
              code-monkey file log --last 500 --stats
            """)
        @OptionGroup var opts: GlobalOptions
        @Option(name: .long, help: "How many entries to read back.") var last: Int = 20
        @Flag(name: .long, help: "Render invocation entries as command lines instead of JSON.")
        var argv: Bool = false
        @Flag(name: .long, help: "With --argv, keep only invocations that did not exit 0.")
        var failed: Bool = false
        @Flag(name: .long, help: "Summarize the log instead of listing it.")
        var stats: Bool = false

        mutating func run() async throws {
            let project = try opts.resolveProject()
            let lines = AuditLog.tail(last, project: project)
            if stats {
                let report = AuditStats.build(from: AuditLog.decode(lines),
                                              model: try CommandModel(CodeMonkey.self))
                Printer.emit(report, json: opts.json, tier: "T0",
                             resultCount: report.invocations) { AuditStats.render(report) }
                return
            }
            guard argv else {
                for line in lines { print(line) }
                return
            }
            for event in AuditLog.decode(lines) {
                guard let words = event.argv else { continue }
                guard !failed || event.status != "ok" else { continue }
                let rendered = words.map(Tokenizer.quoteIfNeeded).joined(separator: " ")
                let status = event.status == "ok" ? "" : "  # \(event.status ?? "?")"
                print("\(CodeMonkey._commandName) \(rendered)\(status)")
            }
        }
    }
}

// MARK: - helpers

func relativePath(_ p: String, root: URL) -> String {
    let url = URL(fileURLWithPath: p, relativeTo: root).standardizedFileURL
    let r = root.standardizedFileURL.path
    if url.path.hasPrefix(r + "/") { return String(url.path.dropFirst(r.count + 1)) }
    if url.path == r { return "" }
    return p
}

/// Swift access levels, most-visible to least. `atOrAbove(.public)` returns the levels
/// at least as visible as `public` (i.e., open + public).
//# ai:invariant: case order matches Swift's strict ordering, and `atOrAbove` reads it; do not reorder
enum AccessLevel: String, CaseIterable, Sendable, ExpressibleByArgument {
    case open, `public`, package, `internal`, `fileprivate`, `private`

    /// Documents each value for `--help`, completion, and generated tool schemas. Not
    /// `defaultValueDescription`, which would rewrite how a default value prints.
    static var allValueDescriptions: [String: String] {
        [
            "open": "subclassable/overridable outside the defining module",
            "public": "visible outside the module",
            "package": "visible across the package",
            "internal": "module-wide — what a decl with no modifier gets",
            "fileprivate": "visible within the file",
            "private": "visible within the enclosing scope",
        ]
    }

    /// The raw values at least as visible as `floor`, ready to bind into SQL.
    static func atOrAbove(_ floor: AccessLevel) -> [String] {
        // Unreachable for a `CaseIterable` value, but total beats a force-unwrap.
        guard let i = allCases.firstIndex(of: floor) else { return [floor.rawValue] }
        return allCases[...i].map(\.rawValue)
    }
}

/// The `--spi` filter. SPI is a second axis, orthogonal to `access`: `any` selects every decl
/// standing behind some `@_spi(...)`, `none` selects everything that is not, and a bare name
/// selects one group. There is no ordering here — SPI is not an access *level*.
//# ai:why: folding SPI into `AccessLevel` would have made `--access public` finally mean
//# ai:why: "real API surface", but SPI is not a Swift access level and the order must not lie
//# ai:invariant: group names match whole — the column is comma-joined, so a prefix must not hit
enum SPIFilter: Sendable, CustomStringConvertible, ExpressibleByArgument {
    case any
    case none
    case group(String)

    static let help = "any (behind some @_spi), none, or a bare group name"

    static func parse(_ raw: String) -> SPIFilter {
        switch raw.lowercased() {
        case "any": return .any
        case "none": return .none
        default: return .group(raw)
        }
    }

    /// Never fails — an unrecognized word is a group name, not an error.
    init?(argument: String) { self = Self.parse(argument) }

    /// Only the two magic words. The group-name case is an open set, and `allValueStrings` is
    /// display and completion only — ArgumentParser never validates against it — so listing
    /// the words here documents them without closing the set.
    //# ai:invariant: this list must stay non-exhaustive; a bare group name has to keep parsing
    static var allValueStrings: [String] { ["any", "none"] }

    static var allValueDescriptions: [String: String] {
        [
            "any": "every decl standing behind some @_spi(...)",
            "none": "every decl not behind any @_spi",
        ]
    }

    var description: String {
        switch self {
        case .any: "any"
        case .none: "none"
        case .group(let g): g
        }
    }

    /// A predicate over a comma-joined `spi` column. Padding both sides with commas turns
    /// substring matching into whole-token matching.
    func clause(column: String) -> (sql: String, binds: [Bindable]) {
        switch self {
        case .any: return ("\(column) <> ''", [])
        case .none: return ("\(column) = ''", [])
        case .group(let g):
            // `_` is a LIKE wildcard and leads SPI group names by convention (`@_spi(_Foo)`).
            return ("(',' || \(column) || ',') LIKE ? ESCAPE '\\'", ["%,\(Self.escaped(g)),%"])
        }
    }

    func matches(_ groups: [String]) -> Bool {
        switch self {
        case .any: return !groups.isEmpty
        case .none: return groups.isEmpty
        case .group(let g): return groups.contains(g)
        }
    }

    /// Splits a stored `spi` column back into group names. Empty column -> no groups.
    static func groups(_ column: String?) -> [String] {
        (column ?? "").split(separator: ",").map(String.init)
    }

    private static func escaped(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// Type-erased Encodable so we can hand `Printer.emit` either a single view or a list.
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ v: T) { _encode = { try v.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

/// Append-only JSONL record of what this tool was asked to do.
///
/// Two kinds of line live here. `file read/write/append` write a *semantic* entry naming the
/// path they touched — that is the audit trail proper. Every dispatched invocation also writes
/// an *invocation* entry carrying the whole argv, which is strictly more information and is
/// what a reader replays. They are told apart by `argv` being present.
//# ai:invariant: `argv` is the post-`normalized()` vector, so a recorded line re-parses as written
enum AuditLog {
    struct Event: Codable, Sendable {
        let timestamp: String
        let operation: String
        let path: String
        let note: String?
        /// The invocation exactly as it was dispatched. Nil on the older per-operation entries.
        var argv: [String]? = nil
        /// `ok`, or `exit <n>` — the code `exit(withError:)` would have used.
        var status: String? = nil
        var ms: Int? = nil

        // `encode(to:)` is explicit so that nil fields are omitted rather than written as
        // null. It does not control field order — `JSONEncoder`'s keyed container is
        // unordered, so `.sortedKeys` in `write` is what makes a line diffable.
        enum CodingKeys: String, CodingKey {
            case timestamp, operation, path, note, argv, status, ms
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(timestamp, forKey: .timestamp)
            try c.encode(operation, forKey: .operation)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(note, forKey: .note)
            try c.encodeIfPresent(argv, forKey: .argv)
            try c.encodeIfPresent(status, forKey: .status)
            try c.encodeIfPresent(ms, forKey: .ms)
        }
    }

    private static let lock = Mutex<Void>(())

    static func url(project: Project? = nil) -> URL {
        if let project, let configured = project.config.audit, !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded)
            }
            return project.root.appendingPathComponent(expanded)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".code-monkey/audit.log")
    }
    static func append(_ op: String, path: String, note: String?, project: Project? = nil) {
        write(Event(timestamp: now(), operation: op, path: path, note: note), project: project)
    }

    /// The invocation entry: one line per dispatched argv, written from the only place that
    /// still has the whole vector. `operation` stays the top-level command name so the older
    /// entries and these still group the same way; the subcommand is in `argv`.
    ///
    /// `project` is resolved from argv rather than from the parsed command, because parsing may
    /// be what failed. A project that cannot be loaded logs to the home-directory default.
    static func record(argv: [String], cwd: String, status: String, ms: Int) {
        guard let op = argv.first else { return }
        let project = try? Project.load(explicitRoot: optionValue("--project", in: argv))
        write(Event(timestamp: now(), operation: op, path: cwd, note: CommandContext.drainNote(),
                    argv: redacting(argv), status: status, ms: ms),
              project: project)
    }

    /// `query`'s positional is a SQL statement, and this log has always promised not to carry
    /// SQL. Recording argv would have quietly broken that promise.
    ///
    /// The value-taking options are named here rather than read off the command tree, because
    /// deriving them means building a `CommandModel` on every invocation to protect one command.
    //# ai:invariant: no command's payload text reaches the log — add a case here if another
    //# ai:invariant: command grows an argument that carries content rather than a name
    static func redacting(_ argv: [String]) -> [String] {
        guard argv.first == "query" else { return argv }
        let valueOptions: Set<String> = ["--recipe", "--project"]
        var out = [argv[0]]
        var index = 1
        while index < argv.count {
            let token = argv[index]
            if token.hasPrefix("-") {
                out.append(token)
                if valueOptions.contains(token), index + 1 < argv.count {
                    out.append(argv[index + 1])
                    index += 1
                }
            } else {
                out.append("<sql>")
            }
            index += 1
        }
        return out
    }

    /// argv is scanned rather than parsed — `--project` is a plain long option with a separate
    /// value on every path that reaches here, including the REPL's.
    static func optionValue(_ name: String, in argv: [String]) -> String? {
        if let i = argv.firstIndex(of: name), i + 1 < argv.count { return argv[i + 1] }
        return argv.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    private static func write(_ event: Event, project: Project?) {
        let url = url(project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(event) else { return }
        lock.withLock { _ in
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { return }
            defer { flock(descriptor, LOCK_UN) }
            var line = encoded
            line.append(0x0A)
            line.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: written),
                        bytes.count - written
                    )
                    if count <= 0 { return }
                    written += count
                }
            }
        }
    }
    /// Lines that do not decode are skipped rather than reported: the log is append-only and
    /// shared, so a truncated final write must not take the reader down with it.
    static func decode(_ lines: [String]) -> [Event] {
        let decoder = JSONDecoder()
        return lines.compactMap { try? decoder.decode(Event.self, from: Data($0.utf8)) }
    }

    static func tail(_ n: Int, project: Project? = nil) -> [String] {
        let url = url(project: project)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).suffix(n).map(String.init)
    }
}
