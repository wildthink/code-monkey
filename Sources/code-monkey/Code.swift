import ArgumentParser
import Foundation

//# ai:section: "Code"

// MARK: - Vocabulary

/// Member kinds grouped the way people ask for them ("properties", "functions"),
/// not the way the index stores them (`var` and `let` are separate kinds).
enum MemberGroup: String, CaseIterable, Sendable {
    case vars, funcs, types, cases

    var kinds: Set<String> {
        switch self {
        case .vars:  ["var", "let"]
        case .funcs: ["func", "init", "deinit", "subscript"]
        // `typealias`, `associatedtype`, `operator` and `precedencegroup` are named declarations
        // rather than values or functions — they belong with the types for filtering purposes.
        case .types: ["struct", "class", "enum", "protocol", "actor", "extension",
                      "typealias", "associatedtype", "operator", "precedencegroup"]
        case .cases: ["case"]
        }
    }

    static var allKinds: Set<String> { allCases.reduce(into: Set()) { $0.formUnion($1.kinds) } }
}

/// How far a member's body is expanded.
enum BodyDepth: Sendable { case stub, fold, full }

/// The disclosure ladder. Each rung adds members or expands bodies; nothing else changes.
//# ai:why: one dial for "show me more" — the flags exist for when you want an exact slice instead
enum Ladder {
    static let max = 3

    static func rung(_ level: Int) -> (members: Set<String>, depth: BodyDepth) {
        switch level {
        case ..<1:  ([], .stub)
        case 1:     (MemberGroup.vars.kinds.union(MemberGroup.cases.kinds), .stub)
        case 2:     (MemberGroup.allKinds, .stub)
        default:    (MemberGroup.allKinds, .full)
        }
    }
}

/// Accessor blocks made only of these keywords are protocol/abstract requirements —
/// they carry meaning and are kept verbatim. Anything else is a real body and gets stubbed.
private let accessorRequirementKeywords: Set<String> =
    ["get", "set", "async", "throws", "nonmutating", "mutating"]

// MARK: - Selector

/// `Walker`, `Walk:enum`, `Sources/code-monkey/Walker.swift`, `.`, or nothing at all.
struct CodeSelector: Sendable {
    var path: String?      // file or directory, relative to project root
    var name: String?      // decl name / decl_id, exact or substring
    var member: String?    // `:member` — case-insensitive substring over descendants

    /// `:` splits target from member filter. The left side is a path when it looks like one
    /// (contains `/`, ends in `.swift`, is `.`, or names something on disk); otherwise a decl.
    static func parse(_ raw: String?, root: URL) -> CodeSelector {
        guard let raw, !raw.isEmpty else { return CodeSelector() }
        var lhs = raw
        var member: String?
        if let colon = raw.firstIndex(of: ":") {
            lhs = String(raw[raw.startIndex..<colon])
            let rest = String(raw[raw.index(after: colon)...])
            member = rest.isEmpty ? nil : rest
        }
        if lhs.isEmpty { return CodeSelector(member: member) }

        let looksLikePath = lhs.contains("/") || lhs.hasSuffix(".swift") || lhs == "."
            || FileManager.default.fileExists(atPath: root.appendingPathComponent(lhs).path)
        if looksLikePath {
            // `.` and the root itself relativize to "" — that means "no path filter", not "no match".
            let rel = relativePath(lhs, root: root)
            return CodeSelector(path: rel.isEmpty || rel == "." ? nil : rel, member: member)
        }
        return CodeSelector(name: lhs, member: member)
    }

    /// True when the user pointed at a specific decl by name — such a root is never
    /// filtered out by `--vars`/`--funcs`/`--access`, which describe its *members*.
    var namesARoot: Bool { name != nil }
}

// MARK: - Tree

/// One decl plus the decls nested inside it. Built from byte-offset containment rather
/// than the `container` name column, which cannot express same-named types in one file.
//# ai:invariant: only type kinds are ever given children — `case a, b` and `var a, b` share
//# ai:invariant: byte offsets, and a leaf must never adopt its own sibling
final class CodeNode {
    let rowId: Int64
    let id: String
    let kind: String
    let name: String
    let signature: String
    let access: String?
    /// Effective `@_spi(...)` groups — see `Extractor.Decl.spi`.
    let spi: [String]
    let file: String
    let startLine: Int
    let endLine: Int
    let declOffset: Int
    let declLength: Int
    let bodyOffset: Int?
    let bodyLength: Int?
    var children: [CodeNode] = []

    var declEnd: Int { declOffset + declLength }
    /// Whether this decl is test code, by the shared `TestConvention`.
    ///
    /// A root here has no container to consult — it *is* one — so its own name stands in, which
    /// is what catches an `XCTestCase` or a `@Suite` parked outside a `Tests` directory.
    var isTest: Bool {
        TestConvention.isTestPath(file) || (isType && TestConvention.isTestContainer(name))
    }

    var isType: Bool { Fold.typeKinds.contains(kind) }

    init(row: DatabaseRow) {
        rowId = row.int64("id") ?? 0
        id = row.string("decl_id") ?? ""
        kind = row.string("kind") ?? ""
        name = row.string("name") ?? ""
        signature = row.string("signature") ?? ""
        access = row.string("access")
        spi = SPIFilter.groups(row.string("spi"))
        file = row.string("file_path") ?? ""
        startLine = Int(row.int64("start_line") ?? 0)
        endLine = Int(row.int64("end_line") ?? 0)
        declOffset = Int(row.int64("decl_offset") ?? 0)
        declLength = Int(row.int64("decl_length") ?? 0)
        bodyOffset = row.int64("body_offset").map(Int.init)
        bodyLength = row.int64("body_length").map(Int.init)
    }

    /// Rows must be for a single file, sorted by `decl_offset` ascending.
    static func buildForest(_ rows: [DatabaseRow]) -> [CodeNode] {
        var roots: [CodeNode] = []
        var stack: [CodeNode] = []
        for row in rows {
            let node = CodeNode(row: row)
            while let top = stack.last, !(node.declOffset >= top.declOffset && node.declEnd <= top.declEnd) {
                stack.removeLast()
            }
            if let top = stack.last { top.children.append(node) } else { roots.append(node) }
            if node.isType { stack.append(node) }
        }
        return roots
    }
}

// MARK: - Command

struct CodeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "code",
        abstract: """
        Readable Swift outlines at a chosen level of disclosure — the cheapest way to see a \
        type's shape before reading it.
        """,
        discussion: """
        With no selector at all, `code` maps the whole project at level 0 — one call, and \
        the right first read in a repo you have not seen.

        `--level` is a ladder: 0 is the bare shell (`struct Walker {}`), 1 adds properties and \
        enum cases, 2 adds member signatures, 3 expands bodies. It defaults to 0, or to 2 when \
        the selector carries a `:member` filter or `--expand` is given. The kind flags — \
        `--vars`, `--funcs`, `--types`, `--cases`, `--all` — take an exact slice instead of a rung.

        Cost climbs steeply with the rung: level 1 carries every property, and with `--doc` \
        every leading doc comment and directive besides. Stay at 0 until you know which type \
        you want, then descend on that one alone.

        `--expand` lifts one member above the rung: matches get full bodies, everything else \
        stays where `--level` put it. That is the read a `:member` filter cannot express, \
        because `:member` also hides the siblings it filters past.

        A selector is a decl name, a `Name:member` pair, a file, or a directory; the selector `.` with `--types` lists every type in it. \
        The output is a readable outline, not compilable Swift.

        EXAMPLES
          code-monkey code Walk                    struct Walker {}
          code-monkey code Walk -L1                ...with its properties
          code-monkey code Walk:enum --funcs       just the funcs matching "enum"
          code-monkey code Walk:enum --funcs --body    ...with bodies expanded
          code-monkey code Walker --expand isEx    one body, its siblings as signatures
          code-monkey code Walker -L0 --expand isEx    ...without the siblings
          code-monkey code Sources/foo.swift -L2   outline every decl in one file
          code-monkey code . --types               every type in the project, one shell each
          code-monkey code Walker --funcs --access public    the public call surface
          code-monkey code . --access public --spi none     ...minus everything behind @_spi
        """)

    @OptionGroup var opts: GlobalOptions

    @Argument(help: "Decl name, `Name:member`, file, or directory. Omit for the whole project.")
    var selector: String?

    @Option(name: [.customShort("L"), .long],
            help: "Disclosure rung 0-\(Ladder.max): shell | +properties | +signatures | +bodies. Defaults to 0, or 2 when a `:member` filter is given.")
    var level: Int?

    @Flag(name: .long, help: "Include properties (`var` and `let`).") var vars: Bool = false
    @Flag(name: .long, help: "Include functions, initializers, subscripts.") var funcs: Bool = false
    @Flag(name: .long, help: "Include nested types and typealiases.") var types: Bool = false
    @Flag(name: .long, help: "Include enum cases.") var cases: Bool = false
    @Flag(name: .long, help: "Include every member kind.") var all: Bool = false

    @Flag(name: .long, help: "Expand the bodies of shown members.") var body: Bool = false
    @Flag(name: .long, help: "Render bodies as `{ ... }` instead of `{}`.") var fold: Bool = false
    @Option(name: .long, help: "Expand only the members whose name contains this, leaving the rest at --level. Case-insensitive.")
    var expand: String?

    @Option(name: .long, help: "Minimum access level. Decls with no modifier count as internal.")
    var access: AccessLevel?
    @Option(name: .long, help: "Filter by @_spi scope: \(SPIFilter.help). Independent of --access.")
    var spi: SPIFilter?
    @Flag(name: .long, help: "Include `///` docs and `//# ai:` directives.") var doc: Bool = false
    @Flag(name: .long, help: "After an expanded body, outline the project types its signature names.")
    var peek: Bool = false
    @Flag(name: .long, help: "Annotate each decl with its line range.") var numbers: Bool = false
    @Flag(name: .long, help: "Omit the `// path` provenance comments.") var noHeader: Bool = false
    @Option(name: .long, help: "Cap the number of top-level decls rendered.") var limit: Int = 200

    // MARK: run

    mutating func run() async throws {
        guard level == nil || (0...Ladder.max).contains(level!) else {
            FileHandle.standardError.write(Data("--level out of range: expected 0...\(Ladder.max)\n".utf8))
            throw ExitCode(1)
        }
        let allowedAccess = access.map { Set(AccessLevel.atOrAbove($0)) }

        let (project, db, _) = try await opts.openIndex(command: "code", tier: "code", target: selector ?? "all")
        let sel = CodeSelector.parse(selector, root: project.root)

        // A `:member` filter with no explicit rung means "show me those members" — rung 0 would
        // hide the very thing being filtered for. `--expand` gets the same bump for a different
        // reason: its whole purpose is a body *among its siblings*, and rung 0 has no siblings.
        // `--body` bumps for the plainest reason of the three: rung 0 shows no members, so
        // `code Renderer --body` answered `struct Renderer {}` — a request for bodies, granted
        // with none. Whoever types it has asked for the cost.
        let effectiveLevel = level ?? (sel.member != nil || expand != nil || body ? 2 : 0)
        let rung = Ladder.rung(effectiveLevel)

        let explicitKinds = kindFilter()
        let memberKinds = explicitKinds ?? rung.members
        let depth: BodyDepth = body ? .full : (fold ? .fold : (explicitKinds != nil ? .stub : rung.depth))

        let rootRows = try await resolveRoots(sel: sel, db: db, project: project)
        guard !rootRows.isEmpty else {
            FileHandle.standardError.write(Data("no decl matches: \(selector ?? "(project)")\n".utf8))
            throw ExitCode(1)
        }

        var renderer = Renderer(project: project, memberKinds: memberKinds, rootKinds: explicitKinds,
                                depth: depth, expand: expand, nameFilter: sel.member,
                                allowedAccess: allowedAccess,
                                spiFilter: spi, annotations: [:], numbers: numbers)

        var forest = try await assemble(roots: rootRows, db: db)
        // A root the user named is always shown — the filters describe its *members*. A root that
        // merely turned up in a path or project sweep is filtered too, which is what makes
        // `code . --types` a type listing and `code src:fold` a name search. Note this uses
        // `includeRoot`, not `include`: a rung's member set says what to show *inside* a
        // declaration and must never decide whether the declaration itself is listed.
        if !sel.namesARoot { forest = forest.filter(renderer.includeRoot) }

        // Test code sinks to the end, with the seam labelled. Across a package it is a fifth
        // to a quarter of the declarations and, in a map of the whole project, almost never
        // what the reader came for — but almost never is not never, so this orders and labels
        // rather than omits. Ordering also decides who spends the `--limit` budget: production
        // first. A path selector is left alone; pointing at `Tests/` already said what you want.
        //# ai:invariant: reorders only — every decl that passed the filters still renders
        let testCount = sel.path == nil ? CodeCmd.sinkTests(&forest) : 0

        let matched = forest.count
        let truncated = matched > limit
        forest = Array(forest.prefix(limit))
        guard !forest.isEmpty else {
            FileHandle.standardError.write(Data("no decl matches those filters\n".utf8))
            throw ExitCode(1)
        }
        if doc { renderer.annotations = try await loadAnnotations(forest: forest, db: db) }

        // Only the leaves that render in full are sliced from disk, so only their files need to
        // still match the index. A shell-level outline reads entirely from the index and stays
        // available even when the working tree has moved on.
        let sliced = forest.flatMap { renderer.expandedLeaves($0) }.map(\.file)
        try await SourceFreshness.require(sliced, project: project, db: db)

        // Resolved before either output path branches, so `--json` and the outline agree.
        let peeked = peek ? try await peekTypes(forest: forest, renderer: renderer, db: db) : []
        // The peek is a shape, never a body: rung 1 is the whole point of it.
        let peekRenderer = Renderer(project: project, memberKinds: Ladder.rung(1).members,
                                    rootKinds: nil, depth: .stub, expand: nil, nameFilter: nil,
                                    allowedAccess: nil, spiFilter: nil, annotations: [:],
                                    numbers: numbers)

        if opts.json {
            var payload = forest.map { node in
                CodeView(id: node.id, kind: node.kind, file: node.file,
                         start_line: node.startLine, end_line: node.endLine,
                         is_test: node.isTest,
                         code: renderer.render(node, indent: 0).joined(separator: "\n"))
            }
            payload += peeked.map { node in
                CodeView(id: node.id, kind: node.kind, file: node.file,
                         start_line: node.startLine, end_line: node.endLine,
                         is_test: node.isTest, peeked: true,
                         code: peekRenderer.render(node, indent: 0).joined(separator: "\n"))
            }
            Printer.emit(payload, json: true, tier: "code", resultCount: payload.count) { "" }
            return
        }

        // A seam is worth drawing only with production on one side and tests still on the
        // other. `--limit` can cut into the test block after they sank, so the label counts
        // what survived the truncation rather than what moved.
        // `--no-header` is decoration off, so the seam goes with the provenance comments. The
        // truncation note below stays: that one warns that output is incomplete, which is not
        // decoration and is never the thing a caller meant to silence.
        let firstTest = matched - testCount
        let seam = (!noHeader && testCount > 0 && firstTest > 0 && firstTest < forest.count)
            ? firstTest : nil
        let shownTests = seam.map { forest.count - $0 } ?? 0

        var out: [String] = []
        var lastFile = ""
        for (i, node) in forest.enumerated() {
            if let seam, i == seam {
                out.append("")
                out.append("// ── production map ends here — \(shownTests) test "
                           + "decl\(shownTests == 1 ? "" : "s") follow")
                lastFile = ""   // re-print the file header on the far side of the seam
            }
            if !noHeader, node.file != lastFile {
                if !out.isEmpty { out.append("") }
                out.append("// ── \(node.file)")
                lastFile = node.file
            } else if !out.isEmpty {
                out.append("")
            }
            out.append(contentsOf: renderer.render(node, indent: 0))
        }
        if !peeked.isEmpty {
            out.append("")
            if !noHeader { out.append("// ── types named above, shape only") }
            for node in peeked {
                out.append("")
                out.append(contentsOf: peekRenderer.render(node, indent: 0))
            }
        }
        if truncated { out.append("\n// +\(matched - limit) more — raise --limit or narrow the selector") }
        print(out.joined(separator: "\n"))
    }

    /// Moves test decls to the end, preserving the order within each group, and returns how
    /// many moved. Stable so the file grouping the renderer relies on survives the shuffle.
    static func sinkTests(_ forest: inout [CodeNode]) -> Int {
        var production: [CodeNode] = [], tests: [CodeNode] = []
        for node in forest { node.isTest ? tests.append(node) : production.append(node) }
        guard !tests.isEmpty, !production.isEmpty else { return tests.count }
        forest = production + tests
        return tests.count
    }

    /// Type kinds worth peeking at. `extension` is absent on purpose: it shares its name with
    /// the type it extends, so including it would render the same shell twice.
    private static let peekableKinds = ["struct", "class", "enum", "protocol", "actor", "typealias"]

    /// Every capitalised identifier in a signature — the type names, plus some noise.
    ///
    /// Deliberately lexical rather than parsed. The index is the filter that matters: `String`,
    /// `Int` and `@MainActor` fall out on their own by not being declared in this project, and
    /// what survives is exactly the set the reader would otherwise have to look up.
    //# ai:why: a signature is text in the index, not syntax — parsing it back would need SwiftSyntax
    static func typeNames(in signature: String) -> Set<String> {
        var names: Set<String> = []
        var current = ""
        for ch in signature {
            if ch.isLetter || ch.isNumber || ch == "_" {
                current.append(ch)
            } else {
                if let first = current.first, first.isUppercase { names.insert(current) }
                current = ""
            }
        }
        if let first = current.first, first.isUppercase { names.insert(current) }
        return names
    }

    /// The types named by the signatures of everything rendered in full, minus the ones already
    /// on screen. One query, capped — a peek that outgrows the body it explains is not a peek.
    private func peekTypes(forest: [CodeNode], renderer: Renderer, db: Database) async throws -> [CodeNode] {
        var wanted: Set<String> = []
        for root in forest {
            for leaf in renderer.expandedLeaves(root) {
                wanted.formUnion(Self.typeNames(in: leaf.signature))
            }
        }
        var onScreen: Set<String> = []
        func note(_ nodes: [CodeNode]) {
            for n in nodes { onScreen.insert(n.name); note(n.children) }
        }
        note(forest)
        wanted.subtract(onScreen)
        guard !wanted.isEmpty else { return [] }

        let names = wanted.sorted()
        let holes = Array(repeating: "?", count: names.count).joined(separator: ",")
        let kinds = Self.peekableKinds.map { "'\($0)'" }.joined(separator: ",")
        let rows = try await db.query("""
            SELECT \(Self.selectColumns) FROM declarations d JOIN files f ON f.id = d.file_id
             WHERE d.name IN (\(holes)) AND d.kind IN (\(kinds))
             ORDER BY f.path, d.start_line
            """, names.map { $0 as Bindable })
        return try await assemble(roots: Array(rows.prefix(peekLimit)), db: db)
    }

    /// A peek that outgrows the body it explains has stopped being a peek.
    private var peekLimit: Int { 12 }

    private func kindFilter() -> Set<String>? {
        if all { return MemberGroup.allKinds }
        var set: Set<String> = []
        if vars { set.formUnion(MemberGroup.vars.kinds) }
        if funcs { set.formUnion(MemberGroup.funcs.kinds) }
        if types { set.formUnion(MemberGroup.types.kinds) }
        if cases { set.formUnion(MemberGroup.cases.kinds) }
        return set.isEmpty ? nil : set
    }

    // MARK: resolve

    private static let selectColumns = """
        d.id, d.decl_id, d.kind, d.name, d.signature, d.access, d.spi, d.start_line, d.end_line,
        d.decl_offset, d.decl_length, d.body_offset, d.body_length, d.file_id, f.path AS file_path
        """

    /// Unlike `get`, an ambiguous name is not an error — rendering every match at a low rung
    /// *is* the discovery mode. Exact `decl_id` wins outright; then name substring; then decl_id
    /// substring. Matches nested inside another match are dropped so nothing renders twice.
    private func resolveRoots(sel: CodeSelector, db: Database, project: Project) async throws -> [DatabaseRow] {
        let order = " ORDER BY f.path, d.start_line"
        let base = "SELECT \(Self.selectColumns) FROM declarations d JOIN files f ON f.id = d.file_id"

        var pathClause = ""
        var pathBinds: [Bindable] = []
        if let p = sel.path {
            // Exact path, subtree, or a bare basename — `code Walker.swift` should just work.
            pathClause = " AND (f.path = ? OR f.path LIKE ? OR f.path LIKE ?)"
            pathBinds = [p, p + "/%", "%/" + p]
        }

        guard let name = sel.name else {
            // Path or whole-project listing: top-level decls only, nesting comes from the tree.
            let sql = base + " WHERE d.container IS NULL" + pathClause + order
            return try await db.query(sql, pathBinds)
        }

        for clause in ["d.decl_id = ?", "LOWER(d.name) LIKE LOWER(?)", "d.decl_id LIKE ?"] {
            let bind: Bindable = clause == "d.decl_id = ?" ? name : "%\(name)%"
            let rows = try await db.query(base + " WHERE \(clause)" + pathClause + order, [bind] + pathBinds)
            if !rows.isEmpty { return dropNested(rows) }
        }
        return []
    }

    /// `Walk` matches `Walker` and every decl inside it; only the outermost should render.
    private func dropNested(_ rows: [DatabaseRow]) -> [DatabaseRow] {
        rows.filter { row in
            let file = row.int64("file_id")
            let start = row.int64("decl_offset") ?? 0
            let end = start + (row.int64("decl_length") ?? 0)
            return !rows.contains { other in
                guard other.int64("id") != row.int64("id"), other.int64("file_id") == file else { return false }
                let oStart = other.int64("decl_offset") ?? 0
                let oEnd = oStart + (other.int64("decl_length") ?? 0)
                return oStart <= start && oEnd >= end && (oEnd - oStart) > (end - start)
            }
        }
    }

    /// Loads every decl in each touched file once, builds that file's tree, then plucks out
    /// the roots we resolved. One query per file regardless of how many roots it holds.
    private func assemble(roots: [DatabaseRow], db: Database) async throws -> [CodeNode] {
        var byFile: [Int64: [Int64]] = [:]          // file_id -> wanted decl rowids, in order
        var fileOrder: [Int64] = []
        for r in roots {
            guard let fid = r.int64("file_id"), let rid = r.int64("id") else { continue }
            if byFile[fid] == nil { fileOrder.append(fid) }
            byFile[fid, default: []].append(rid)
        }
        var found: [Int64: CodeNode] = [:]
        for fid in fileOrder {
            let rows = try await db.query("""
                SELECT \(Self.selectColumns) FROM declarations d JOIN files f ON f.id = d.file_id
                 WHERE d.file_id = ? ORDER BY d.decl_offset ASC, d.decl_length DESC
                """, [fid])
            collect(CodeNode.buildForest(rows), wanted: Set(byFile[fid] ?? []), into: &found)
        }
        return roots.compactMap { $0.int64("id").flatMap { found[$0] } }
    }

    private func collect(_ nodes: [CodeNode], wanted: Set<Int64>, into found: inout [Int64: CodeNode]) {
        for n in nodes {
            if wanted.contains(n.rowId) { found[n.rowId] = n }
            collect(n.children, wanted: wanted, into: &found)
        }
    }

    private func loadAnnotations(forest: [CodeNode], db: Database) async throws -> [Int64: Annotation] {
        var ids: [Int64] = []
        func walk(_ nodes: [CodeNode]) { for n in nodes { ids.append(n.rowId); walk(n.children) } }
        walk(forest)
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let binds = ids.map { $0 as Bindable }
        var out: [Int64: Annotation] = [:]
        for r in try await db.query("SELECT decl_id, text FROM doc_comments WHERE decl_id IN (\(placeholders))", binds) {
            guard let k = r.int64("decl_id") else { continue }
            out[k, default: Annotation()].doc = r.string("text")
        }
        for r in try await db.query("SELECT decl_id, tag, value FROM directives WHERE decl_id IN (\(placeholders)) ORDER BY line", binds) {
            guard let k = r.int64("decl_id") else { continue }
            out[k, default: Annotation()].directives.append((r.string("tag") ?? "", r.string("value") ?? ""))
        }
        return out
    }
}

struct Annotation {
    var doc: String?
    var directives: [(tag: String, value: String)] = []
}

struct CodeView: Encodable {
    var id: String
    var kind: String
    var file: String
    var start_line: Int
    var end_line: Int
    var is_test: Bool
    /// Set on the shells `--peek` added for context; they were not selected by the query.
    var peeked: Bool = false
    var code: String
}

// MARK: - Renderer

/// Reconstructs Swift from the index rather than slicing the file, so filtering, nesting and
/// indentation stay uniform across files. Only `--body` reaches back into the source.
//# ai:why: `get --body-mode fold` already covers the faithful-excerpt case; this is the synthetic view
//# ai:warn: output is a readable outline, not compilable Swift — a stubbed non-Void func has no return
struct Renderer {
    let project: Project
    let memberKinds: Set<String>
    /// Kinds a *root* must have to be listed, or nil for no constraint. Only an explicit
    /// `--vars`/`--funcs`/`--types`/`--cases`/`--all` sets this — never a ladder rung.
    let rootKinds: Set<String>?
    let depth: BodyDepth
    /// Members whose name contains this render at `.full` regardless of `depth` — the one way
    /// to get sibling signatures and one real body out of a single call.
    //# ai:why: `:member` prunes as well as selects, so it cannot express "expand this, keep the rest"
    let expand: String?
    let nameFilter: String?
    let allowedAccess: Set<String>?
    /// Orthogonal to `allowedAccess`: a decl must clear both to be shown.
    let spiFilter: SPIFilter?
    var annotations: [Int64: Annotation]
    let numbers: Bool

    private static let unit = "    "

    /// `expanded` is inherited: once a declaration matches `--expand`, everything nested inside
    /// it is expanded too, so naming a type expands the type rather than silently doing nothing.
    func render(_ node: CodeNode, indent: Int, expanded: Bool = false) -> [String] {
        let pad = String(repeating: Self.unit, count: indent)
        let expanded = expanded || matchesExpand(node)
        let depth = expanded ? .full : self.depth
        var lines: [String] = []

        if let a = annotations[node.rowId] {
            for line in (a.doc ?? "").split(whereSeparator: \.isNewline) { lines.append("\(pad)/// \(line)") }
            for d in a.directives { lines.append("\(pad)//# \(d.tag): \(d.value)") }
        }

        let header = pad + collapse(headerSignature(node))
        // The line range trails the *finished* line, so it never lands between a header and its brace.
        func tagged(_ line: String) -> String {
            numbers ? "\(line)  // \(node.startLine)-\(node.endLine)" : line
        }

        if node.isType {
            let kids = node.children.filter { expanded || include($0) }
            guard !kids.isEmpty else { return lines + [tagged("\(header) {}")] }
            lines.append(tagged("\(header) {"))
            var previousWasMultiline = false
            for (i, kid) in kids.enumerated() {
                let rendered = render(kid, indent: indent + 1, expanded: expanded)
                // Breathing room around anything that spans lines; one-line members pack together.
                if i > 0, previousWasMultiline || rendered.count > 1 { lines.append("") }
                lines.append(contentsOf: rendered)
                previousWasMultiline = rendered.count > 1
            }
            lines.append("\(pad)}")
            return lines
        }

        // Leaf.
        if depth == .full,
           let text = sliceFile(project.root, node.file, offset: node.declOffset, length: node.declLength) {
            var slice = reindent(text, to: pad)
            if numbers, !slice.isEmpty { slice[0] = tagged(slice[0]) }
            return lines + slice
        }
        guard node.bodyOffset != nil else { return lines + [tagged(header)] }  // requirement, `case`, stored `let`
        if let requirement = accessorRequirement(node) { return lines + [tagged("\(header) \(requirement)")] }
        return lines + [tagged("\(header) \(depth == .fold ? "{ ... }" : "{}")")]
    }

    /// The leaves this render will print in full, in render order.
    ///
    /// Mirrors `render`'s own expansion rule instead of re-deriving it, so `--peek` can never
    /// disagree with what actually reached the screen.
    //# ai:invariant: must track `render`'s leaf branch — both keys off `expanded || depth == .full`
    func expandedLeaves(_ node: CodeNode, expanded: Bool = false) -> [CodeNode] {
        let expanded = expanded || matchesExpand(node)
        if node.isType {
            return node.children
                .filter { expanded || include($0) }
                .flatMap { expandedLeaves($0, expanded: expanded) }
        }
        return expanded || depth == .full ? [node] : []
    }

    /// A member survives if its kind was asked for, if its name matches the `:member` filter,
    /// or — for a type — if anything inside it survived. That last clause is what keeps
    /// `--funcs` from hiding functions that happen to live in a nested type.
    /// Whether a top-level declaration is listed at all.
    ///
    /// Deliberately not `include`. A rung sets `memberKinds` to describe what to show *inside*
    /// a declaration — `-L0` sets it empty ("no members"), `-L1` to properties. Judging roots by
    /// that set made `-L0` on a file match nothing, and made `-L1` silently drop any declaration
    /// that happened to have no properties. Roots are constrained only by things the user asked
    /// for directly: an explicit kind flag, a `:member` filter, an access floor.
    //# ai:invariant: with no explicit kind flag, no name filter and no access floor, every root passes
    func includeRoot(_ node: CodeNode) -> Bool {
        if let allowedAccess, !allowedAccess.contains(node.access ?? "internal"),
           !(node.isType && node.children.contains(where: include)) {
            return false
        }
        if let spiFilter, !spiFilter.matches(node.spi),
           !(node.isType && node.children.contains(where: include)) {
            return false
        }
        if let rootKinds, !rootKinds.contains(node.kind) {
            // A type that isn't the requested kind still earns its place by what it contains.
            return node.isType && node.children.contains(where: include)
        }
        guard let nameFilter else { return true }
        if node.name.range(of: nameFilter, options: .caseInsensitive) != nil { return true }
        return node.children.contains(where: include)
    }

    func include(_ node: CodeNode) -> Bool {
        if let allowedAccess, !allowedAccess.contains(node.access ?? "internal") {
            if !(node.isType && node.children.contains(where: include)) { return false }
        }
        if let spiFilter, !spiFilter.matches(node.spi) {
            if !(node.isType && node.children.contains(where: include)) { return false }
        }
        // Without this, `--expand` is a silent no-op below the rung that would have shown the
        // member anyway — and "shell plus one body" is the case it exists for.
        if matchesExpand(node) { return true }
        if node.isType, node.children.contains(where: include) { return true }
        guard memberKinds.contains(node.kind) else { return false }
        guard let nameFilter else { return true }
        return node.name.range(of: nameFilter, options: .caseInsensitive) != nil
    }

    /// Types store their signature without the member block; funcs store theirs without the body.
    /// Properties are the exception — `VariableDeclSyntax.trimmedDescription` swallows the whole
    /// accessor block *and* any initializer, so a computed property is cut at the opening brace
    /// and a stored one with a multi-line initializer (a `"""` literal, a big array) at the `=`.
    private func headerSignature(_ node: CodeNode) -> String {
        // Anything that can carry an accessor block keeps it in its stored signature; the brace
        // is cut here so `accessorRequirement` can re-attach `{ get set }` without doubling it.
        if ["var", "let", "subscript"].contains(node.kind), node.bodyOffset != nil,
           let brace = node.signature.firstIndex(of: "{") {
            return String(node.signature[..<brace]).trimmingCharacters(in: .whitespaces)
        }
        guard ["var", "let"].contains(node.kind), node.signature.contains(where: \.isNewline) else {
            return node.signature
        }
        if let equals = node.signature.firstIndex(of: "=") {
            return String(node.signature[..<equals]).trimmingCharacters(in: .whitespaces) + " = ..."
        }
        return (node.signature.split(whereSeparator: \.isNewline).first.map(String.init) ?? node.signature) + " ..."
    }

    /// `{ get set }` and friends are the declaration, not an implementation — keep them.
    private func accessorRequirement(_ node: CodeNode) -> String? {
        guard ["var", "let", "subscript"].contains(node.kind),
              let open = node.signature.firstIndex(of: "{"),
              let close = node.signature.lastIndex(of: "}") , close > open else { return nil }
        let inner = node.signature[node.signature.index(after: open)..<close]
        let tokens = inner.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard !tokens.isEmpty, tokens.allSatisfy({ accessorRequirementKeywords.contains(String($0)) }) else { return nil }
        return "{ \(tokens.joined(separator: " ")) }"
    }

    private func matchesExpand(_ node: CodeNode) -> Bool {
        guard let expand, !expand.isEmpty else { return false }
        return node.name.range(of: expand, options: .caseInsensitive) != nil
    }

    private func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Source slices keep their original indentation on every line but the first (which begins
    /// at `decl_offset`). Strip the common indent, then re-apply the target one.
    private func reindent(_ text: String, to pad: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }
        lines[0] = lines[0].trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let common = rest.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.enumerated().map { i, line in
            if i == 0 { return pad + line }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
            return pad + String(line.dropFirst(min(common, line.prefix { $0 == " " }.count)))
        }
    }
}
