import ArgumentParser
import Foundation

// MARK: - get (field-selectable read; absorbs list/find/schema/info/body/fold)

//# ai:section: "Get"
/// Attributes selectable via `--fields`. Each is independently cheap/expensive and
/// independently available — orthogonal to the old T0-T3 tier model.
enum GetField: String, CaseIterable, Sendable {
    case signature, summary, invariants, ownership, dependencies, body, callers, callees

    static func parse(_ raw: String) throws -> [GetField] {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var fields: [GetField] = []
        for p in parts {
            guard let f = GetField(rawValue: p) else {
                throw FieldParseError(
                    message: "unknown field: \(p) — expected one of: \(allCases.map(\.rawValue).joined(separator: ","))"
                )
            }
            fields.append(f)
        }
        return fields
    }
}

/// The value of `--fields`: a comma-separated list carried in a single token.
///
/// A wrapper rather than a repeating `[GetField]` option, because a repeating option would
/// spell the same request `--fields a --fields b` and change the CLI surface. Conforming here
/// is what puts the field names into `--help`, completion, and generated tool schemas.
struct GetFieldList: ExpressibleByArgument, Sendable {
    var fields: [GetField]

    init?(argument: String) {
        guard let parsed = try? GetField.parse(argument) else { return nil }
        fields = parsed
    }

    static var allValueStrings: [String] { GetField.allCases.map(\.rawValue) }

    var defaultValueDescription: String { fields.map(\.rawValue).joined(separator: ",") }
}

/// How a single `get` result renders.
enum GetFormat: String, CaseIterable, Sendable, ExpressibleByArgument {
    case folded, markdown, json

    static var allValueDescriptions: [String: String] {
        [
            "folded": "line-oriented text, one `//` comment per field",
            "markdown": "prose-friendly, for pasting into a document",
            "json": "the full result object",
        ]
    }
}

/// How the `body` field renders when `--fields` asks for it.
enum BodyMode: String, CaseIterable, Sendable, ExpressibleByArgument {
    case ref, full, fold

    static var allValueDescriptions: [String: String] {
        [
            "ref": "a {file, start_line, end_line} pointer only — no source text",
            "full": "the whole declaration text",
            "fold": "members and bodies elided — see --keep and --deep",
        ]
    }
}

/// The `kind` vocabulary stored on a declaration, as `--kind` accepts it.
///
/// A filter vocabulary, not a storage type: rows keep `kind` as a `String`, and this only
/// constrains what a caller may type. It has to stay in step with the kinds `Extractor`
/// emits, or a real declaration becomes unreachable by kind.
//# ai:invariant: one case per `kind:` literal emitted in Extractor.swift, plus var/let from
//# ai:invariant: the binding specifier
enum DeclKind: String, CaseIterable, Sendable, ExpressibleByArgument {
    case `struct`, `class`, `enum`, `protocol`, actor, `extension`
    case `func`, `init`, `subscript`, `deinit`
    case `var`, `let`, `case`, `typealias`, `associatedtype`
    case `operator`, `precedencegroup`

    // No `allValueStrings` override: the list has to stay exhaustive. It is the only statement
    // anywhere that this set is closed, and a generated JSON Schema `enum` validates against it
    // — trimming it to the common kinds would reject `actor`, `init`, and `typealias` outright.
}

struct FieldParseError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// `summary` carries narrative directives; `invariants` carries contract directives.
/// Same `directives` table, disjoint tag sets.
enum DirectiveClass {
    static let invariantTags: Set<String> = ["ai:invariant", "ai:requires", "ai:warn", "ai:spec"]
    static let summaryTags: Set<String> = ["ai:why", "ai:example", "ai:see", "ai:depends", "ai:prompt", "ai:section"]
}

/// Heuristic syntactic dependency extraction: capitalized identifiers found in a stored
/// signature string. Not semantic — no stdlib/project resolution, no generic-vs-concrete
/// distinction. Swift has no capitalized keywords, so this stays clean without an exclusion list.
enum DependencyExtractor {
    private static let pattern = try! NSRegularExpression(pattern: "\\b[A-Z][A-Za-z0-9_]*\\b")

    static func extract(signature: String) -> [String] {
        let ns = signature as NSString
        var seen = Set<String>()
        var ordered: [String] = []
        for match in pattern.matches(in: signature, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            if seen.insert(token).inserted { ordered.append(token) }
        }
        return ordered
    }
}

/// Module = first path segment under a configured source root (e.g. "Sources/code-monkey/x.swift" -> "code-monkey").
enum Ownership {
    static func module(forFile path: String, sources: [String]) -> String {
        for src in sources {
            let prefix = src.hasSuffix("/") ? src : src + "/"
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { return String(rest[..<slash]) }
            return String(rest)
        }
        return "-"
    }
}

struct SummaryView: Encodable {
    var doc: String?
    var directives: [DirectiveView]?
}

struct OwnershipView: Encodable {
    var file: String
    var container: String?
    var module: String
}

struct BodyRefView: Encodable {
    var file: String
    var start_line: Int
    var end_line: Int
}

/// Field-selectable result. `id`/`kind`/`container`/`file`/`start_line`/`end_line` are the
/// always-present locate fields (cheap — already on the resolved row). Elision counts
/// (`doc_lines`/`body_lines`/`directive_count`) are populated only when resolving a single
/// target — computing them per-row across an enumerated match set would multiply query cost.
/// Everything else stays `nil` and is omitted entirely from JSON unless its field was requested
/// (Swift's synthesized Encodable uses encodeIfPresent for Optional properties).
struct GetResult: Encodable {
    var id: String
    var kind: String
    var container: String?
    var file: String
    var start_line: Int
    var end_line: Int
    var doc_lines: Int?
    var body_lines: Int?
    var directive_count: Int?
    /// `@_spi(...)` groups this decl stands behind, effective (inherited from its container).
    /// Omitted entirely when the decl is not SPI — always reported, never field-selected,
    /// because a reader who does not know a symbol is SPI has been told the wrong thing.
    var spi: [String]?
    var signature: String?
    var summary: SummaryView?
    var invariants: [DirectiveView]?
    var ownership: OwnershipView?
    var dependencies: [String]?
    var body_ref: BodyRefView?
    var body_text: String?
    var callers: [CallEdgeView]?
    var callees: [CallEdgeView]?
    /// Edges the medium floor removed. Distinguishes "nothing calls this" from
    /// "nothing calls this unambiguously" — see `code-monkey calls --min low`.
    var callers_below_floor: Int?
    var callees_below_floor: Int?
}

/// One resolved end of a syntactic call edge. `confidence` is not decoration — see `CallGraph.grade`.
struct CallEdgeView: Encodable {
    var id: String
    var file: String
    var line: Int
    var confidence: String
    var occurrences: Int
    /// Set when the edge crossed dynamic dispatch — see `CallEdge.via`.
    var via: String?

    init(_ edge: CallEdge) {
        id = edge.target.declId
        file = edge.file
        line = edge.line
        confidence = edge.confidence.label
        occurrences = edge.occurrences
        via = edge.via
    }
}

struct GetCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get",
        abstract: """
        The one read command: resolve a single declaration, or enumerate every match.
        """,
        discussion: """
        A bare decl_id, name, or substring resolves to one record — an ambiguous match lists \
        the candidates instead, so rerun with an exact decl_id. Supplying any of `--path`, \
        `--kind`, `--container`, `--name-like` or `--tag`, or giving no query at all, \
        enumerates every match rather than resolving one.

        `--fields` chooses what each record carries. Left out, a single target defaults to \
        signature, summary and invariants, while an enumeration shows only enough to locate \
        each decl. `--body-mode` chooses how the body field renders, and `--keep` and \
        `--deep` narrow what stays inline once it is folded.

        EXAMPLES
          code-monkey get Walker                          one record, default fields
          code-monkey get Walker --fields body            ...plus a source pointer
          code-monkey get --kind protocol                 every protocol in the project
          code-monkey get --path Sources/foo.swift        every decl in one file
          code-monkey get Walker --body-mode fold --keep relPath
        """)
    @OptionGroup var opts: GlobalOptions
    @Argument(help: "decl_id (stable handle), name, or substring. Omit to enumerate by filter alone.")
    var query: String?
    @Option(name: .long, help: "Comma-separated attributes to include.")
    var fields: GetFieldList?
    @Option(name: .long, help: "How a single result renders.")
    var format: GetFormat = .folded
    @Option(name: .long, help: "Restrict to this file (disambiguates same-named decls; narrows enumeration too).")
    var file: String?
    @Option(name: .long, help: "Subtree filter: file or directory, relative to project root. Enumerates.")
    var path: String?
    @Option(name: .long, help: "Restrict to a kind. Enumerates.")
    var kind: DeclKind?
    @Option(name: .long, help: "Restrict to decls inside this container. Enumerates.")
    var container: String?
    @Option(name: .long, help: "Name substring, case-insensitive. Enumerates.")
    var nameLike: String?
    @Option(name: .long, help: "Has directive tag, e.g. ai:invariant. Enumerates.")
    var tag: String?
    @Option(name: .long, help: "Filter by @_spi scope: \(SPIFilter.help). Enumerates.")
    var spi: SPIFilter?
    @Option(name: .long, help: "Cap rows when enumerating.") var limit: Int = 500
    @Option(name: .long, help: "Skip rows when enumerating.") var offset: Int = 0
    @Option(name: .long, help: "How the `body` field renders.")
    var bodyMode: BodyMode = .ref
    @Option(name: .long, parsing: .singleValue,
            help: "With --body-mode fold: decl_id/name/glob whose body stays inline. Repeatable.")
    var keep: [String] = []
    @Flag(name: .long, help: "With --body-mode fold: type targets keep nested-type members; leaf targets fold the enclosing type instead, keeping this leaf inline.")
    var deep: Bool = false

    private static var typeKinds: Set<String> { Fold.typeKinds }

    /// Set once in `run`. Distinguishes "this decl has no callers" from "nobody looked".
    private var callSitesOff = false

    mutating func run() async throws {
        let requested = fields?.fields ?? []

        let (project, db, _) = try await opts.openIndex(
            command: "get",
            tier: "get",
            target: query ?? path ?? container ?? nameLike ?? tag ?? kind?.rawValue ?? spi?.description ?? "all"
        )
        let keepIds = try await resolveKeepIds(db: db)
        let graph = CallGraph(db: db)
        if requested.contains(.callers) || requested.contains(.callees),
           try await !graph.callSitesIndexed() {
            callSitesOff = true
            FileHandle.standardError.write(Data("warning: \(CallGraph.disabledMessage)\n".utf8))
        }

        let isEnumerating = query == nil || path != nil || kind != nil || container != nil
            || nameLike != nil || tag != nil || spi != nil
        if isEnumerating {
            let rows = try await enumerate(project: project, db: db)
            try await requireFreshSource(for: rows, fields: requested, project: project, db: db)
            try await emitEnumerated(rows: rows, fields: requested, project: project, db: db,
                                     keepIds: keepIds, graph: graph)
            return
        }

        let row = try await resolve(query: query!, file: file, project: project, db: db)
        try await requireFreshSource(for: [row], fields: requested, project: project, db: db)
        let effective = requested.isEmpty ? [.signature, .summary, .invariants] : requested
        let result = try await buildResult(row: row, fields: effective, project: project, db: db,
                                            computeElision: true, keepIds: keepIds, graph: graph)
        switch format {
        case .json:
            Printer.emit(result, json: true, tier: "get", resultCount: 1, fields: effective.map(\.rawValue)) { "" }
        case .markdown:
            print(renderMarkdown(result))
        case .folded:
            print(renderFolded(result))
        }
    }

    // MARK: resolve (single target — exact decl_id, then name/decl_id substring)

    private func resolve(query: String, file: String?, project: Project, db: Database) async throws -> DatabaseRow {
        var rows = try await db.query("""
            SELECT d.*, f.path AS file_path FROM declarations d
              JOIN files f ON f.id = d.file_id
             WHERE d.decl_id = ?
            """, [query])
        if let file {
            let rel = relativePath(file, root: project.root)
            rows = rows.filter { $0.string("file_path") == rel }
        }
        if rows.isEmpty {
            var sql = """
                SELECT d.*, f.path AS file_path FROM declarations d
                  JOIN files f ON f.id = d.file_id
                 WHERE (d.name = ? OR d.decl_id LIKE ?)
                """
            var binds: [Bindable] = [query, "%" + query + "%"]
            if let file {
                sql += " AND f.path = ?"
                binds.append(relativePath(file, root: project.root))
            }
            sql += " ORDER BY f.path, d.start_line"
            rows = try await db.query(sql, binds)
        }
        guard !rows.isEmpty else {
            FileHandle.standardError.write(Data("no decl: \(query)\n".utf8))
            throw ExitCode(1)
        }
        if rows.count > 1 {
            FileHandle.standardError.write(Data("ambiguous (\(rows.count) matches) — use exact decl_id or --file:\n".utf8))
            for r in rows {
                FileHandle.standardError.write(Data("  \(r.string("decl_id") ?? "")  \(r.string("file_path") ?? ""):\(Int(r.int64("start_line") ?? 0))\n".utf8))
            }
            throw ExitCode(1)
        }
        return rows[0]
    }

    // MARK: enumerate (any filter present, or no query at all)

    private func enumerate(project: Project, db: Database) async throws -> [DatabaseRow] {
        var clauses: [String] = []
        var binds: [Bindable] = []
        if let path {
            let rel = relativePath(path, root: project.root)
            clauses.append("(f.path = ? OR f.path LIKE ?)")
            binds.append(rel); binds.append(rel + "/%")
        }
        if let kind { clauses.append("d.kind = ?"); binds.append(kind.rawValue) }
        if let container { clauses.append("d.container = ?"); binds.append(container) }
        if let nameLike { clauses.append("LOWER(d.name) LIKE LOWER(?)"); binds.append("%" + nameLike + "%") }
        if let query {
            clauses.append("(d.decl_id LIKE ? OR d.name LIKE ?)")
            binds.append("%" + query + "%"); binds.append("%" + query + "%")
        }
        if let file {
            clauses.append("f.path = ?")
            binds.append(relativePath(file, root: project.root))
        }
        if let spi {
            let (sql, spiBinds) = spi.clause(column: "d.spi")
            clauses.append(sql)
            binds.append(contentsOf: spiBinds)
        }
        var sql = "SELECT DISTINCT d.*, f.path AS file_path FROM declarations d JOIN files f ON f.id = d.file_id"
        if let tag {
            sql += " JOIN directives x ON x.decl_id = d.id"
            clauses.append("x.tag = ?"); binds.append(tag)
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY f.path, d.start_line LIMIT \(limit) OFFSET \(offset)"
        return try await db.query(sql, binds)
    }

    private func emitEnumerated(rows: [DatabaseRow], fields: [GetField], project: Project, db: Database,
                                keepIds: Set<String>, graph: CallGraph) async throws {
        if fields.isEmpty {
            // Cheapest path — no per-row queries, same shape as the old list/find.
            if opts.json {
                let payload = rows.map { r -> [String: String] in
                    [
                        "id": r.string("decl_id") ?? "",
                        "kind": r.string("kind") ?? "",
                        "container": r.string("container") ?? "",
                        "file": r.string("file_path") ?? "",
                        "line": String(Int(r.int64("start_line") ?? 0)),
                        "spi": r.string("spi") ?? "",
                    ]
                }
                Printer.emit(payload, json: true, resultCount: rows.count) { "" }
            } else {
                for r in rows { print(t0Line(r)) }
            }
            return
        }
        var results: [GetResult] = []
        for row in rows {
            results.append(try await buildResult(row: row, fields: fields, project: project, db: db,
                                                  computeElision: false, keepIds: keepIds, graph: graph))
        }
        if opts.json {
            Printer.emit(results, json: true, tier: "get", resultCount: results.count, fields: fields.map(\.rawValue)) { "" }
        } else {
            for (i, r) in results.enumerated() {
                if i > 0 { print("") }
                print(format == .markdown ? renderMarkdown(r) : renderFolded(r))
            }
        }
    }

    /// The SPI marker is appended rather than given a column of its own: most rows have none,
    /// and a trailing tag keeps the four-column shape every existing reader parses.
    private func t0Line(_ r: DatabaseRow) -> String {
        let ctn = r.string("container") ?? "-"
        let groups = SPIFilter.groups(r.string("spi"))
        let mark = groups.isEmpty ? "" : "\t@_spi(\(groups.joined(separator: ",")))"
        return "\(r.string("decl_id") ?? "")\t\(r.string("kind") ?? "")\t\(ctn)\t\(r.string("file_path") ?? ""):\(Int(r.int64("start_line") ?? 0))" + mark
    }

    // MARK: build

    /// Refuses to slice a file the index no longer describes.
    ///
    /// Scoped to the case that actually emits source text. `--body-mode ref` hands back a
    /// pointer and opens nothing, and the default field set is index-only metadata — refusing
    /// those over staleness would cost far more than the drift does. What must never happen is
    /// printing body text cut at offsets that have moved.
    //# ai:why: a stale line *count* is a small wrong number; a stale slice is unreadable garbage
    private func requireFreshSource(for rows: [DatabaseRow], fields: [GetField],
                                    project: Project, db: Database) async throws {
        guard fields.contains(.body), bodyMode != .ref else { return }
        try await SourceFreshness.require(rows.compactMap { $0.string("file_path") },
                                          project: project, db: db)
    }

    private func buildResult(row: DatabaseRow, fields: [GetField], project: Project, db: Database,
                              computeElision: Bool, keepIds: Set<String>,
                              graph: CallGraph) async throws -> GetResult {
        let id = row.string("decl_id") ?? ""
        let kind = row.string("kind") ?? ""
        let file = row.string("file_path") ?? ""
        let container = row.string("container")
        let startLine = Int(row.int64("start_line") ?? 0)
        let endLine = Int(row.int64("end_line") ?? 0)
        let declRowId = row.int64("id") ?? 0

        var result = GetResult(id: id, kind: kind, container: container, file: file,
                                start_line: startLine, end_line: endLine)
        let spiGroups = SPIFilter.groups(row.string("spi"))
        if !spiGroups.isEmpty { result.spi = spiGroups }

        if computeElision {
            if let docRow = try await db.query("SELECT text FROM doc_comments WHERE decl_id=?", [declRowId]).first,
               let txt = docRow.string("text") {
                result.doc_lines = txt.split(whereSeparator: \.isNewline).count
            }
            let dirCount = try await db.query("SELECT COUNT(*) AS c FROM directives WHERE decl_id=?", [declRowId])
            result.directive_count = Int(dirCount.first?.int64("c") ?? 0)
            if let bo = row.int64("body_offset"), let bl = row.int64("body_length"),
               let s = sliceFile(project.root, file, offset: Int(bo), length: Int(bl)) {
                result.body_lines = s.split(whereSeparator: \.isNewline).count
            }
        }

        if fields.contains(.signature) {
            result.signature = row.string("signature")
        }
        if fields.contains(.summary) {
            let doc = try await db.query("SELECT text FROM doc_comments WHERE decl_id=?", [declRowId])
                .first?.string("text")
            let dirRows = try await db.query(
                "SELECT tag, value, line FROM directives WHERE decl_id=? ORDER BY line", [declRowId])
            let narrative = dirRows
                .filter { DirectiveClass.summaryTags.contains($0.string("tag") ?? "") }
                .map { DirectiveView(tag: $0.string("tag") ?? "", value: $0.string("value") ?? "", line: Int($0.int64("line") ?? 0)) }
            result.summary = SummaryView(doc: doc, directives: narrative.isEmpty ? nil : narrative)
        }
        if fields.contains(.invariants) {
            let dirRows = try await db.query(
                "SELECT tag, value, line FROM directives WHERE decl_id=? ORDER BY line", [declRowId])
            result.invariants = dirRows
                .filter { DirectiveClass.invariantTags.contains($0.string("tag") ?? "") }
                .map { DirectiveView(tag: $0.string("tag") ?? "", value: $0.string("value") ?? "", line: Int($0.int64("line") ?? 0)) }
        }
        if fields.contains(.ownership) {
            result.ownership = OwnershipView(
                file: file,
                container: container,
                module: Ownership.module(forFile: file, sources: project.config.sources)
            )
        }
        if fields.contains(.dependencies) {
            result.dependencies = DependencyExtractor.extract(signature: row.string("signature") ?? "")
        }
        if fields.contains(.body) {
            switch bodyMode {
            case .full:
                if let s = sliceFile(project.root, file,
                                      offset: Int(row.int64("decl_offset") ?? 0),
                                      length: Int(row.int64("decl_length") ?? 0)) {
                    result.body_text = s
                }
            case .fold:
                result.body_text = try await foldText(row: row, db: db, project: project, keepIds: keepIds, deep: deep)
            case .ref:
                result.body_ref = BodyRefView(file: file, start_line: startLine, end_line: endLine)
            }
        }
        if fields.contains(.callers) || fields.contains(.callees) {
            let target = CallTarget(rowId: declRowId, declId: id, name: row.string("name") ?? "",
                                    kind: kind, container: container, file: file, startLine: startLine)
            // Same floor as `calls` defaults to — a wall of unrefuted name matches is worse
            // than a short list, and `calls --min low` is there when you want everything.
            if fields.contains(.callers) {
                let all = try await graph.callers(of: target, includeRefs: false)
                let kept = all.filter { $0.confidence >= .medium }
                result.callers = kept.map(CallEdgeView.init)
                result.callers_below_floor = all.count - kept.count
            }
            if fields.contains(.callees) {
                let all = try await graph.callees(of: target, includeRefs: false)
                let kept = all.filter { $0.confidence >= .medium }
                result.callees = kept.map(CallEdgeView.init)
                result.callees_below_floor = all.count - kept.count
            }
        }
        return result
    }

    /// Resolves each `--keep` pattern to a set of decl_ids (same matching rules as the main query).
    private func resolveKeepIds(db: Database) async throws -> Set<String> {
        var ids: Set<String> = []
        for p in keep {
            let isGlob = p.contains("*") || p.contains("?")
            let rows: [DatabaseRow]
            if isGlob {
                let like = p.replacingOccurrences(of: "*", with: "%").replacingOccurrences(of: "?", with: "_")
                rows = try await db.query("SELECT decl_id FROM declarations WHERE decl_id LIKE ?", [like])
            } else {
                rows = try await db.query(
                    "SELECT decl_id FROM declarations WHERE decl_id = ? OR name = ? OR decl_id LIKE ?",
                    [p, p, p + "(%"])
            }
            for r in rows {
                if let id = r.string("decl_id") { ids.insert(id) }
            }
        }
        return ids
    }

    /// Slice the decl's source, replace inner bodies with `{ ... }`. Handles both type decls
    /// (descendant members folded) and leaf decls (just this body folded). If `deep` and the
    /// row is a leaf, swaps target to the enclosing type and keeps this leaf inline.
    //# ai:invariant: descendants are processed in DESC decl_offset order so replacements never invalidate later offsets
    //# ai:invariant: nested-type member-block replacement walks raw bytes for `{` ... `}` — works because type signatures contain no braces
    //# ai:warn: keepIds.contains(dId) skips replacement only — does not re-recurse into the kept decl
    private func foldText(row: DatabaseRow, db: Database, project: Project, keepIds: Set<String>, deep: Bool) async throws -> String {
        let kind = row.string("kind") ?? ""

        if deep && !Self.typeKinds.contains(kind), let fileId = row.int64("file_id") {
            let leafOff = Int(row.int64("decl_offset") ?? 0)
            let leafEnd = leafOff + Int(row.int64("decl_length") ?? 0)
            let leafId = row.string("decl_id") ?? ""
            let typeKinds = Self.typeKinds.map { "'\($0)'" }.joined(separator: ",")
            let containerRows = try await db.query("""
                SELECT d.id, d.decl_id, d.kind, d.decl_offset, d.decl_length, d.body_offset, d.body_length,
                       d.start_line, d.end_line, d.file_id, f.path AS file_path
                  FROM declarations d JOIN files f ON f.id = d.file_id
                 WHERE d.file_id = ?
                   AND d.kind IN (\(typeKinds))
                   AND d.decl_offset <= ?
                   AND d.decl_offset + d.decl_length >= ?
                 ORDER BY d.decl_length ASC
                 LIMIT 1
                """, [fileId, leafOff, leafEnd])
            if let cRow = containerRows.first {
                return try await foldText(row: cRow, db: db, project: project, keepIds: keepIds.union([leafId]), deep: deep)
            }
        }

        let filePath = row.string("file_path") ?? ""
        let targetOff = Int(row.int64("decl_offset") ?? 0)
        let targetLen = Int(row.int64("decl_length") ?? 0)
        guard let source = sliceFile(project.root, filePath, offset: targetOff, length: targetLen) else {
            return "// could not slice \(filePath)"
        }

        var descendants: [Fold.Descendant]
        if Self.typeKinds.contains(kind) {
            let fileId = row.int64("file_id") ?? 0
            let targetRowId = row.int64("id") ?? 0
            let rows = try await db.query("""
                SELECT id, decl_id, kind, decl_offset, decl_length, body_offset, body_length
                  FROM declarations
                 WHERE file_id = ?
                   AND id != ?
                   AND decl_offset > ?
                   AND decl_offset + decl_length <= ?
                 ORDER BY decl_offset DESC
                """, [fileId, targetRowId, targetOff, targetOff + targetLen])
            descendants = rows.map(Self.toDescendant)
        } else {
            descendants = [Self.toDescendant(row)]
        }
        return Fold.apply(source: source, sliceOffset: targetOff, descendants: descendants, keep: keepIds, deep: deep)
    }

    private static func toDescendant(_ r: DatabaseRow) -> Fold.Descendant {
        Fold.Descendant(
            declId: r.string("decl_id") ?? "",
            kind: r.string("kind") ?? "",
            declOffset: Int(r.int64("decl_offset") ?? 0),
            declLength: Int(r.int64("decl_length") ?? 0),
            bodyOffset: r.int64("body_offset").map(Int.init),
            bodyLength: r.int64("body_length").map(Int.init)
        )
    }

    // MARK: render

    private func renderFolded(_ r: GetResult) -> String {
        var lines: [String] = []
        lines.append("// \(r.kind)  \(r.file):\(r.start_line)-\(r.end_line)")
        if let groups = r.spi { lines.append("// @_spi: \(groups.joined(separator: ", "))") }
        if let dl = r.doc_lines { lines.append("// doc_lines: \(dl)") }
        if let bl = r.body_lines { lines.append("// body_lines: \(bl)") }
        if let dc = r.directive_count { lines.append("// directives: \(dc)") }
        if let doc = r.summary?.doc, !doc.isEmpty {
            for line in doc.split(whereSeparator: \.isNewline) { lines.append("// \(line)") }
        }
        for d in r.summary?.directives ?? [] { lines.append("// \(d.tag): \(d.value)") }
        for d in r.invariants ?? [] { lines.append("// \(d.tag): \(d.value)") }
        if let o = r.ownership { lines.append("// owner: \(o.module)/\(o.container ?? "-")") }
        if let deps = r.dependencies {
            lines.append(deps.isEmpty ? "// deps: none" : "// deps: \(capped(deps))")
        }
        for c in r.callers ?? [] { lines.append("// caller: \(c.id)  \(c.file):\(c.line)  [\(c.confidence)]"
                                       + (c.via.map { "  via \($0)" } ?? "")) }
        if r.callers?.isEmpty == true {
            let weaker = r.callers_below_floor ?? 0
            lines.append(callSitesOff ? "// callers: not indexed"
                         : weaker > 0 ? "// callers: none above medium confidence — \(weaker) weaker; see `calls --min low`"
                         : "// callers: none found")
        }
        for c in r.callees ?? [] { lines.append("// callee: \(c.id)  \(c.file):\(c.line)  [\(c.confidence)]"
                                       + (c.via.map { "  via \($0)" } ?? "")) }
        if r.callees?.isEmpty == true {
            let weaker = r.callees_below_floor ?? 0
            lines.append(callSitesOff ? "// callees: not indexed"
                         : weaker > 0 ? "// callees: none above medium confidence — \(weaker) weaker; see `calls --min low`"
                         : "// callees: none found")
        }
        if let sig = r.signature { lines.append(sig) }
        if let ref = r.body_ref { lines.append("// body: \(ref.file):\(ref.start_line)-\(ref.end_line)") }
        if let text = r.body_text { lines.append(text) }
        return lines.joined(separator: "\n")
    }

    private func renderMarkdown(_ r: GetResult) -> String {
        var lines: [String] = ["### `\(r.id)`"]
        lines.append("_\(r.kind) · \(r.file):\(r.start_line)-\(r.end_line)_")
        if let groups = r.spi { lines.append("**@_spi:** \(groups.joined(separator: ", "))") }
        if let sig = r.signature { lines.append("`\(sig)`") }
        if let doc = r.summary?.doc, !doc.isEmpty { lines.append(doc) }
        for d in r.summary?.directives ?? [] { lines.append("- **\(d.tag):** \(d.value)") }
        for d in r.invariants ?? [] { lines.append("- **\(d.tag):** \(d.value)") }
        if let o = r.ownership { lines.append("\(o.file) · \(o.container ?? "-") · \(o.module)") }
        if let deps = r.dependencies {
            lines.append(deps.isEmpty ? "_no dependencies_" : capped(deps))
        }
        if let ref = r.body_ref { lines.append("`\(ref.file):\(ref.start_line)–\(ref.end_line)`") }
        if let text = r.body_text { lines.append("```swift\n\(text)\n```") }
        for c in r.callers ?? [] { lines.append("- **caller:** `\(c.id)` \(c.file):\(c.line) _\(c.confidence)_"
                                       + (c.via.map { " via `\($0)`" } ?? "")) }
        for c in r.callees ?? [] { lines.append("- **callee:** `\(c.id)` \(c.file):\(c.line) _\(c.confidence)_"
                                       + (c.via.map { " via `\($0)`" } ?? "")) }
        return lines.joined(separator: "\n")
    }

    private func capped(_ items: [String], limit: Int = 8) -> String {
        let shown = items.prefix(limit).joined(separator: ", ")
        return items.count > limit ? "\(shown), +\(items.count - limit) more" : shown
    }
}
