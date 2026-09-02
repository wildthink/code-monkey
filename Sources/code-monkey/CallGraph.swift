import ArgumentParser
import Foundation

//# ai:section: "CallGraph"

// MARK: - Vocabulary

/// How much to trust an edge. The graph is built from names, not types, so every edge is a
/// guess — this says how good a guess it is.
//# ai:why: a ranked guess is useful; an unranked one just moves the ambiguity onto the reader
enum CallConfidence: String, CaseIterable, Comparable, Sendable, Encodable, ExpressibleByArgument {
    case low, medium, high

    /// Ordering is the whole point of this type, and the raw values no longer carry it —
    /// alphabetically `high` sorts below `low`. Rank restores the declaration order.
    //# ai:invariant: rank follows the case order above; every `>=` floor and `--min` depends on it
    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    var label: String { rawValue }

    /// Documents each value for `--help`, shell/REPL completion, and generated tool schemas.
    /// Deliberately not `defaultValueDescription`, which would rewrite the help screen's
    /// `(default: medium)` into the prose below.
    static var allValueDescriptions: [String: String] {
        [
            "low": "only the name matched — a lead, not a fact",
            "medium": "plausible receiver",
            "high": "receiver resolves to the declaration's container, or the name is unique project-wide",
        ]
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(label)
    }
}

/// A declaration at one end of an edge. `rowId == 0` marks file-scope code, which owns no decl.
struct CallTarget: Sendable, Hashable {
    var rowId: Int64
    var declId: String
    var name: String
    var kind: String
    var container: String?
    var file: String
    var startLine: Int

    /// Whether this declaration is test code, by the shared `TestConvention`.
    //# ai:why: deliberately not attribute-based; `@Test` marks the test *functions*, and the
    //# ai:why: caller of the code under test is as often a helper in the same file
    var isTest: Bool {
        TestConvention.isTestPath(file) || TestConvention.isTestContainer(container)
    }

    static func fileScope(file: String, line: Int) -> CallTarget {
        CallTarget(rowId: 0, declId: "<file-scope>", name: "<file-scope>", kind: "file",
                   container: nil, file: file, startLine: line)
    }
}

struct CallEdge: Sendable {
    var target: CallTarget
    var file: String            // where the reference is written
    var line: Int
    var siteKind: String        // call | ref
    var receiver: String?
    var confidence: CallConfidence
    var occurrences: Int
    /// Set when the edge was inferred across dynamic dispatch rather than matched at a call
    /// site: the decl_id of the protocol requirement (or overridden method) that bridges it.
    var via: String? = nil
}

// MARK: - Resolution

/// Resolves the syntactic `call_sites` table into declaration-to-declaration edges.
///
/// Nothing here is semantic. `foo.bar()` records the name `bar` and the text `foo`; matching it
/// to a declaration is a ranked guess, never a fact. See `grade` for how a guess earns its
/// confidence — the ranking is deliberately conservative, and a receiver that resolves to the
/// wrong type actively demotes an edge rather than being ignored.
//# ai:warn: a name shared by several declarations produces one edge per candidate
//# ai:warn: parameters and locals are not indexed, so receivers naming them never resolve
final class CallGraph {
    private let db: Database
    private var nameCounts: [String: Int] = [:]
    private var receiverTypes: [String: String?] = [:]
    private var protocolNames: [String: Bool] = [:]
    private var conformanceCache: [String: Bool] = [:]

    init(db: Database) { self.db = db }

    private static let targetColumns = """
        d.id, d.decl_id, d.name, d.kind, d.container, d.start_line, f.path AS decl_file
        """

    private static func target(_ row: DatabaseRow) -> CallTarget {
        CallTarget(rowId: row.int64("id") ?? 0,
                   declId: row.string("decl_id") ?? "",
                   name: row.string("name") ?? "",
                   kind: row.string("kind") ?? "",
                   container: row.string("container"),
                   file: row.string("decl_file") ?? "",
                   startLine: Int(row.int64("start_line") ?? 0))
    }

    /// Same matching ladder as `get`: exact decl_id, then name, then decl_id substring.
    func resolve(query: String, file: String?) async throws -> [CallTarget] {
        let base = "SELECT \(Self.targetColumns) FROM declarations d JOIN files f ON f.id = d.file_id"
        var fileClause = ""
        var fileBinds: [Bindable] = []
        if let file {
            fileClause = " AND f.path = ?"
            fileBinds = [file]
        }
        for clause in ["d.decl_id = ?", "LOWER(d.name) = LOWER(?)", "d.decl_id LIKE ?"] {
            let bind: Bindable = clause == "d.decl_id LIKE ?" ? "%\(query)%" : query
            let rows = try await db.query(base + " WHERE \(clause)" + fileClause
                                          + " ORDER BY f.path, d.start_line", [bind] + fileBinds)
            if !rows.isEmpty { return rows.map(Self.target) }
        }
        return []
    }

    /// Whether this index carries call sites at all. Indexes built before the setting existed
    /// have no `meta` row, so fall back to asking the table.
    //# ai:why: an empty call graph must be distinguishable from a disabled one — otherwise
    //# ai:why: "no callers" reads as a fact about the code rather than about the index
    func callSitesIndexed() async throws -> Bool {
        if let value = try await db.query("SELECT value FROM meta WHERE key='call_sites'")
            .first?.string("value") {
            return value == "on"
        }
        let rows = try await db.query("SELECT COUNT(*) AS c FROM call_sites")
        return (rows.first?.int64("c") ?? 0) > 0
    }

    static let disabledMessage = """
        call sites are not indexed — set `[parse] extract_call_sites = true` in .code-monkey.toml \
        (or pass `index --call-sites`) and run `code-monkey index --full`
        """

    private func declarationCount(named name: String) async throws -> Int {
        if let cached = nameCounts[name] { return cached }
        let rows = try await db.query("SELECT COUNT(*) AS c FROM declarations WHERE name = ?", [name])
        let count = Int(rows.first?.int64("c") ?? 0)
        nameCounts[name] = count
        return count
    }

    /// A receiver written as a plain identifier is resolved to a type in two steps, nearest
    /// scope first: a local or parameter bound inside the *calling* declaration, then a property
    /// of the calling type read out of its stored signature. That turns `graph.resolve(...)`
    /// and `db.query(...)` from "some name matched" into "the receiver is a `CallGraph`"
    /// without any type checking.
    ///
    /// Returns nil when the receiver is an expression, or a type nothing states plainly — all
    /// of which are simply unknown, not negative.
    //# ai:why: bindings come first because a local shadows a property of the same name, and
    //# ai:why: answering with the property would be confidently wrong rather than unknown
    //# ai:warn: collections and tuples are deliberately unresolved; `[String: Foo]` would
    //# ai:warn: otherwise yield `String` and manufacture confident nonsense
    private func receiverType(_ receiver: String, in origin: CallTarget?) async throws -> String? {
        let container = origin?.container
        let key = "\(origin?.rowId ?? -1)\u{0}\(container ?? "-")\u{0}\(receiver)"
        if let cached = receiverTypes[key] { return cached }
        var resolved: String?
        if receiver.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            if let rowId = origin?.rowId, rowId != 0 {
                resolved = try await db.query(
                    "SELECT type FROM bindings WHERE from_decl = ? AND name = ? ORDER BY line LIMIT 1",
                    [rowId, receiver]).first?.string("type")
            }
            if resolved == nil {
                let rows = try await db.query("""
                    SELECT signature FROM declarations
                     WHERE name = ? AND kind IN ('var','let')
                     ORDER BY CASE WHEN container = ? THEN 0 ELSE 1 END
                     LIMIT 1
                    """, [receiver, container ?? ""])
                if let signature = rows.first?.string("signature"),
                   let colon = signature.firstIndex(of: ":") {
                    let rest = signature[signature.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                    if let first = rest.first, first.isLetter || first == "_" {
                        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                        if !name.isEmpty { resolved = String(name) }
                    }
                }
            }
        }
        receiverTypes[key] = resolved
        return resolved
    }

    /// The one place a guess is graded.
    ///
    /// - `high`   — corroborated. The receiver names the declaration's own container
    ///              (`Fold.apply`), or resolves to it by declared type (`db.query` where
    ///              `db` is a `Database`), or there is no receiver at all and the name belongs
    ///              to exactly one declaration in the project.
    /// - `medium` — plausible. A unique name reached through a receiver we could not resolve,
    ///              or a sibling in the same container or file.
    /// - `low`    — the name matched and nothing corroborates it — including the case where the
    ///              receiver *did* resolve, to something else entirely. That last one is why
    ///              `out.append(x)` stops claiming to call `AuditLog.append`.
    private func grade(target: CallTarget, from origin: CallTarget?, receiver rawReceiver: String?,
                       globallyUnique: Bool) async throws -> CallConfidence {
        // `self.foo()` carries no more information than `foo()`.
        let receiver = (rawReceiver == "self" || rawReceiver == "Self") ? nil : rawReceiver

        guard let receiver else {
            if globallyUnique { return .high }
            if let origin {
                if let c = origin.container, c == target.container { return .medium }
                if origin.file == target.file { return .medium }
            }
            return .low
        }
        if receiver == target.container { return .high }
        if let type = try await receiverType(receiver, in: origin) {
            if type == target.container { return .high }
            // The receiver names a protocol or superclass the target's container conforms to,
            // so dispatch could land here. Plausible — one implementation of several runs.
            if let container = target.container,
               try await conforms(container, to: type) { return .medium }
            // A protocol-typed receiver whose conformances are not indexed — the protocol comes
            // from a dependency, say. Unknown, which is not the same as refuted.
            if !(try await isProtocol(type)) { return .low }
        }
        return globallyUnique ? .medium : .low
    }

    /// Whether `type` names `parent` in its inheritance clause, directly or through one
    /// intermediate protocol. Two hops covers refinement (`Codable: Encodable`) without
    /// paying for a transitive closure the call graph would barely use.
    private func conforms(_ type: String, to parent: String) async throws -> Bool {
        let key = "\(type)\u{0}\(parent)"
        if let cached = conformanceCache[key] { return cached }
        let hit = try await !db.query("""
            SELECT 1 FROM conformances c
             WHERE c.type_name = ?
               AND (c.protocol_name = ?
                    OR EXISTS (SELECT 1 FROM conformances p
                                WHERE p.type_name = c.protocol_name AND p.protocol_name = ?))
             LIMIT 1
            """, [type, parent, parent]).isEmpty
        conformanceCache[key] = hit
        return hit
    }

    /// Whether a resolved receiver type is a protocol declared in this project.
    private func isProtocol(_ name: String) async throws -> Bool {
        if let cached = protocolNames[name] { return cached }
        let hit = try await !db.query(
            "SELECT 1 FROM declarations WHERE name = ? AND kind = 'protocol' LIMIT 1", [name]
        ).isEmpty
        protocolNames[name] = hit
        return hit
    }

    // MARK: Dispatch

    /// Implementations of a protocol requirement: same name, declared in a type that names the
    /// protocol in its inheritance clause — including through an `extension`.
    private func implementations(ofRequirement requirement: CallTarget) async throws -> [CallTarget] {
        guard let proto = requirement.container else { return [] }
        return try await db.query("""
            SELECT \(Self.targetColumns) FROM declarations d
              JOIN files f ON f.id = d.file_id
              JOIN conformances c ON c.type_name = d.container
             WHERE d.name = ? AND c.protocol_name = ? AND d.container <> ?
             GROUP BY d.id ORDER BY f.path, d.start_line
            """, [requirement.name, proto, proto]).map(Self.target)
    }

    /// The inverse: requirements (or superclass methods) a declaration stands in for.
    //# ai:why: "who calls FileSaver.persist" is nearly always answered by "whoever calls
    //# ai:why: Saver.persist" — without this, protocol-oriented code reads as uncalled
    private func requirements(implementedBy target: CallTarget) async throws -> [CallTarget] {
        guard let container = target.container else { return [] }
        return try await db.query("""
            SELECT \(Self.targetColumns) FROM declarations d
              JOIN files f ON f.id = d.file_id
              JOIN conformances c ON c.protocol_name = d.container
             WHERE d.name = ? AND c.type_name = ? AND d.container <> ?
             GROUP BY d.id ORDER BY f.path, d.start_line
            """, [target.name, container, container]).map(Self.target)
    }

    /// Declarations that mention `target`'s name, plus those that reach it through a protocol
    /// requirement or an overridden superclass method.
    func callers(of target: CallTarget, includeRefs: Bool) async throws -> [CallEdge] {
        var edges = try await directCallers(of: target, includeRefs: includeRefs)
        var byRow = Dictionary(edges.enumerated().map { ($0.element.target.rowId, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        for requirement in try await requirements(implementedBy: target) {
            for var edge in try await directCallers(of: requirement, includeRefs: includeRefs) {
                guard edge.target.rowId != target.rowId else { continue }
                // Dispatch is dynamic. This caller reaches the requirement; `target` is one of
                // possibly several implementations, so the edge is plausible, never corroborated.
                edge.confidence = Swift.min(edge.confidence, .medium)
                edge.via = requirement.declId
                // The same caller often also matches by bare name, and that match will have
                // been graded on the receiver's declared type — the protocol, not this type.
                // Reaching it through the requirement is the better explanation, so it wins.
                if let existing = byRow[edge.target.rowId] {
                    if edge.confidence > edges[existing].confidence {
                        edge.occurrences = edges[existing].occurrences
                        edges[existing] = edge
                    }
                } else {
                    byRow[edge.target.rowId] = edges.count
                    edges.append(edge)
                }
            }
        }
        return edges.sorted { $0.confidence > $1.confidence }
    }

    /// Declarations that mention `target`'s name at a call site — syntax only, no dispatch.
    private func directCallers(of target: CallTarget, includeRefs: Bool) async throws -> [CallEdge] {
        let unique = try await declarationCount(named: target.name) == 1
        var sql = """
            SELECT cs.line, cs.receiver, cs.kind AS site_kind, sf.path AS site_file,
                   \(Self.targetColumns)
              FROM call_sites cs
              JOIN files sf ON sf.id = cs.file_id
              LEFT JOIN declarations d ON d.id = cs.from_decl
              LEFT JOIN files f ON f.id = d.file_id
             WHERE cs.name = ?
            """
        if !includeRefs { sql += " AND cs.kind = 'call'" }
        sql += " ORDER BY sf.path, cs.line"

        var edges: [CallTarget: CallEdge] = [:]
        var order: [CallTarget] = []
        for row in try await db.query(sql, [target.name]) {
            let siteFile = row.string("site_file") ?? ""
            let line = Int(row.int64("line") ?? 0)
            let origin = row.int64("id") != nil ? Self.target(row) : CallTarget.fileScope(file: siteFile, line: line)
            // A declaration referring to itself is recursion, not a caller worth charting.
            if origin.rowId == target.rowId { continue }
            let receiver = row.string("receiver")
            let confidence = try await grade(target: target, from: origin, receiver: receiver,
                                             globallyUnique: unique)
            if var existing = edges[origin] {
                existing.occurrences += 1
                if confidence > existing.confidence {
                    existing.confidence = confidence
                    existing.line = line
                    existing.receiver = receiver
                }
                edges[origin] = existing
            } else {
                order.append(origin)
                edges[origin] = CallEdge(target: origin, file: siteFile, line: line,
                                         siteKind: row.string("site_kind") ?? "call",
                                         receiver: receiver, confidence: confidence, occurrences: 1)
            }
        }
        return order.compactMap { edges[$0] }.sorted { $0.confidence > $1.confidence }
    }

    /// Declarations that `target` mentions.
    func callees(of target: CallTarget, includeRefs: Bool) async throws -> [CallEdge] {
        guard target.rowId != 0 else { return [] }
        var sql = """
            SELECT cs.name, cs.receiver, cs.line, cs.kind AS site_kind, f.path AS site_file
              FROM call_sites cs JOIN files f ON f.id = cs.file_id
             WHERE cs.from_decl = ?
            """
        if !includeRefs { sql += " AND cs.kind = 'call'" }
        sql += " ORDER BY cs.line"

        var edges: [CallTarget: CallEdge] = [:]
        var order: [CallTarget] = []
        var candidateCache: [String: [CallTarget]] = [:]

        for row in try await db.query(sql, [target.rowId]) {
            guard let name = row.string("name") else { continue }
            let candidates: [CallTarget]
            if let cached = candidateCache[name] {
                candidates = cached
            } else {
                candidates = try await db.query("""
                    SELECT \(Self.targetColumns) FROM declarations d JOIN files f ON f.id = d.file_id
                     WHERE d.name = ? ORDER BY f.path, d.start_line
                    """, [name]).map(Self.target)
                candidateCache[name] = candidates
            }
            // An extension is not callable, so `String(...)` must not resolve to the project's
            // `extension String` — with nothing else named String indexed, that would otherwise
            // score `high` off global uniqueness and assert a call that never happens.
            let usable = row.string("site_kind") == "call"
                ? candidates.filter { $0.kind != "extension" }
                : candidates
            // Nothing by that name: the standard library, a dependency, or a local binding.
            guard !usable.isEmpty else { continue }

            let receiver = row.string("receiver")
            // A receiver naming one candidate's container settles it; otherwise every candidate
            // is a live possibility and they all get charted.
            let narrowed = receiver.map { r in usable.filter { $0.container == r } } ?? []
            let resolved = narrowed.isEmpty ? usable : narrowed
            let unique = usable.count == 1

            var graded: [(target: CallTarget, confidence: CallConfidence)] = []
            for candidate in resolved where candidate.rowId != target.rowId {
                graded.append((candidate, try await grade(target: candidate, from: target,
                                                          receiver: receiver, globallyUnique: unique)))
            }
            // One corroborated candidate refutes the rest: if `db.run(...)` resolves to
            // `Database.run` by receiver type, the eight other declarations named `run` are
            // not also being called here.
            if graded.contains(where: { $0.confidence == .high }) {
                graded = graded.filter { $0.confidence == .high }
            }

            for (candidate, confidence) in graded {
                let line = Int(row.int64("line") ?? 0)
                if var existing = edges[candidate] {
                    existing.occurrences += 1
                    if confidence > existing.confidence { existing.confidence = confidence }
                    edges[candidate] = existing
                } else {
                    order.append(candidate)
                    edges[candidate] = CallEdge(target: candidate,
                                                file: row.string("site_file") ?? "", line: line,
                                                siteKind: row.string("site_kind") ?? "call",
                                                receiver: receiver, confidence: confidence,
                                                occurrences: 1)
                }
            }
        }

        var result = order.compactMap { edges[$0] }
        // A call dispatched through a protocol lands on the requirement, where no work happens.
        // Chart the conforming implementations too — as possibilities, since only one runs.
        var charted = Set(result.map(\.target.rowId))
        var viaProtocol: [CallEdge] = []
        for edge in result {
            guard let container = edge.target.container,
                  try await isProtocol(container) else { continue }
            for implementation in try await implementations(ofRequirement: edge.target) {
                guard implementation.rowId != target.rowId,
                      !charted.contains(implementation.rowId) else { continue }
                charted.insert(implementation.rowId)
                viaProtocol.append(CallEdge(target: implementation, file: edge.file, line: edge.line,
                                            siteKind: edge.siteKind, receiver: edge.receiver,
                                            confidence: Swift.min(edge.confidence, .medium),
                                            occurrences: edge.occurrences,
                                            via: edge.target.declId))
            }
        }
        result.append(contentsOf: viaProtocol)
        return result.sorted { $0.confidence > $1.confidence }
    }
}

// MARK: - Command

struct CallsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "calls",
        abstract: """
        Syntactic call tree: what reaches a declaration, or what it reaches.
        """,
        discussion: """
        Reach for this before changing something, to see how far the change can travel, and \
        when getting oriented in unfamiliar code. Callers are followed by default; \
        `--callees` follows the other direction, and `--both` shows each in turn.

        Edges are matched by NAME, not by type, so every edge is a graded guess rather than a \
        fact. `--min` sets the confidence floor and documents what each grade means; edges \
        below it are counted but not shown, so an empty result still tells you something. \
        Treat the weakest grade as a lead to check, not an answer. Only calls are followed \
        unless `--include-refs` adds property and type mentions. None of this is a substitute \
        for a semantic index.

        EXAMPLES
          code-monkey calls Fold.apply                  who reaches it, two levels up
          code-monkey calls Fold.apply --callees        what it reaches
          code-monkey calls sliceFile --depth 3         further out
          code-monkey calls query --min high            only unambiguous edges
          code-monkey calls Walker --both --include-refs    add non-call references
        """)

    @OptionGroup var opts: GlobalOptions

    @Argument(help: "decl_id, name, or substring.") var query: String
    @Flag(name: .long, help: "Follow what this declaration reaches instead of what reaches it.")
    var callees: Bool = false
    @Flag(name: .long, help: "Show both directions.") var both: Bool = false
    @Option(name: [.customShort("d"), .long], help: "How many levels to follow.") var depth: Int = 2
    @Option(name: .long, help: "Drop edges below this confidence. Pass low to see every name match.")
    var min: CallConfidence = .medium
    @Flag(name: .long, help: "Include plain references (property and type mentions), not just calls.")
    var includeRefs: Bool = false
    @Option(name: .long, help: "Restrict the starting declaration to this file.") var file: String?
    @Option(name: .long, help: "Cap edges shown per node.") var limit: Int = 25
    @Flag(name: .long, help: "Keep only branches that reach a test. Answers \"what covers this?\"")
    var tests: Bool = false
    @Flag(name: .long, help: "One-block blast-radius summary instead of the tree.")
    var summary: Bool = false

    mutating func run() async throws {
        let floor = min
        guard depth >= 1 else {
            FileHandle.standardError.write(Data("--depth must be at least 1\n".utf8))
            throw ExitCode(1)
        }

        let (project, db, _) = try await opts.openIndex(command: "calls", tier: "calls", target: query)
        let graph = CallGraph(db: db)
        guard try await graph.callSitesIndexed() else {
            FileHandle.standardError.write(Data("\(CallGraph.disabledMessage)\n".utf8))
            throw ExitCode(1)
        }
        let roots = try await graph.resolve(query: query, file: file.map { relativePath($0, root: project.root) })
        guard let root = roots.first else {
            FileHandle.standardError.write(Data("no decl: \(query)\n".utf8))
            throw ExitCode(1)
        }
        if roots.count > 1 {
            FileHandle.standardError.write(Data(
                "note: \(roots.count) decls match — charting \(root.declId) at \(root.file):\(root.startLine). Use an exact decl_id or --file.\n".utf8))
        }

        let directions: [Bool] = both ? [false, true] : [callees]
        var out: [String] = []
        var payload: [TreeView] = []
        var summaries: [BlastRadiusView] = []

        for wantCallees in directions {
            let full = try await build(node: root, graph: graph, callees: wantCallees,
                                       floor: floor, remaining: depth, seen: [root.rowId])
            // `--tests` prunes rather than re-queries: coverage is "does any path from here end
            // at a test", which is a property of the tree, not of the direct edges.
            let tree = self.tests ? (Self.pruneToTests(full) ?? Self.leaf(full)) : full
            if summary {
                let block = Self.summarise(tree, root: root, callees: wantCallees,
                                           floor: floor, depth: depth)
                if opts.json {
                    summaries.append(block)
                } else {
                    if !out.isEmpty { out.append("") }
                    out.append(contentsOf: block.lines)
                }
                continue
            }
            if opts.json {
                payload.append(TreeView(direction: wantCallees ? "callees" : "callers", root: tree))
            } else {
                if !out.isEmpty { out.append("") }
                out.append("// \(wantCallees ? "what \(root.declId) reaches" : "what reaches \(root.declId)")"
                           + " — depth \(depth), \(includeRefs ? "calls + refs" : "calls only")"
                           + ", confidence ≥ \(floor.label)")
                out.append("\(root.declId)  \(root.file):\(root.startLine)")
                render(tree.children, prefix: "", floorLabel: floor.label, into: &out)
                if tree.children.isEmpty {
                    let weaker = tree.suppressed ?? 0
                    // Three different empties, and conflating them is how a tool starts lying:
                    // nothing is covered, nothing is *clearly* covered, and nothing calls this.
                    out.append(
                        self.tests
                        ? "(no test reaches this at confidence ≥ \(floor.label)"
                          + (weaker > 0 ? "; \(weaker) weaker edge\(weaker == 1 ? "" : "s") not followed)" : ")")
                        : weaker > 0
                        ? "(none at this confidence — \(weaker) weaker edge\(weaker == 1 ? "" : "s"); rerun with --min low)"
                        : "(none)")
                }
            }
        }

        if opts.json {
            if summary {
                Printer.emit(summaries, json: true, tier: "calls", resultCount: summaries.count) { "" }
            } else {
                Printer.emit(payload, json: true, tier: "calls", resultCount: payload.count) { "" }
            }
        } else {
            print(out.joined(separator: "\n"))
        }
    }

    /// Depth-first expansion. `seen` carries the path's declarations so a cycle terminates
    /// instead of recursing — mutual recursion is common and must not hang the command.
    private func build(node: CallTarget, graph: CallGraph, callees: Bool,
                       floor: CallConfidence, remaining: Int, seen: Set<Int64>) async throws -> NodeView {
        var view = NodeView(id: node.declId, kind: node.kind, file: node.file,
                            line: node.startLine, confidence: nil, occurrences: nil,
                            site: nil, via: nil, is_test: node.isTest, truncated: false,
                            suppressed: nil, children: [])
        guard remaining > 0 else { return view }

        let all = try await (callees ? graph.callees(of: node, includeRefs: includeRefs)
                                     : graph.callers(of: node, includeRefs: includeRefs))
        let edges = all.filter { $0.confidence >= floor }
        // An edge the floor removed is not an edge that doesn't exist. Counting them is what
        // lets the output distinguish "nothing calls this" from "nothing calls this *clearly*".
        //# ai:why: a bare `(none)` reads as a fact about the code; here it is a fact about
        //# ai:why: the threshold, and the reader has to be able to tell which
        view.suppressed = all.count - edges.count
        view.truncated = edges.count > limit

        for edge in edges.prefix(limit) {
            var child: NodeView
            if seen.contains(edge.target.rowId), edge.target.rowId != 0 {
                child = NodeView(id: edge.target.declId + "  (cycle)", kind: edge.target.kind,
                                 file: edge.target.file, line: edge.target.startLine,
                                 confidence: edge.confidence.label, occurrences: edge.occurrences,
                                 site: "\(edge.file):\(edge.line)", via: edge.via,
                                 is_test: edge.target.isTest, truncated: false,
                                 suppressed: nil, children: [])
            } else {
                child = try await build(node: edge.target, graph: graph, callees: callees,
                                        floor: floor, remaining: remaining - 1,
                                        seen: seen.union([edge.target.rowId]))
                child.confidence = edge.confidence.label
                child.occurrences = edge.occurrences
                child.site = "\(edge.file):\(edge.line)"
                child.via = edge.via
            }
            view.children.append(child)
        }
        return view
    }

    // MARK: Pruning and summary

    /// Keeps only the branches that end at a test. A node survives if it is itself a test or
    /// something beneath it is — which is what makes the answer "what covers this?" rather than
    /// "which of its direct callers happens to be a test".
    //# ai:invariant: returns nil when nothing in this subtree is a test, so callers can drop it
    private static func pruneToTests(_ node: NodeView) -> NodeView? {
        var kept = node
        kept.children = node.children.compactMap(pruneToTests)
        if kept.children.isEmpty && !node.is_test { return nil }
        return kept
    }

    /// The root with no children — what `--tests` shows when nothing reaches a test. The
    /// distinction matters: an empty tree here is a coverage finding, not a lookup failure.
    private static func leaf(_ node: NodeView) -> NodeView {
        var bare = node
        bare.children = []
        return bare
    }

    /// Flattens a tree into a blast-radius report.
    ///
    /// The tree answers "which declarations", which is the wrong shape for the question people
    /// actually ask before a change — how much of the project moves, how sure are we, and is any
    /// of it covered. Counting is not new information; presenting it as a count is the point.
    private static func summarise(_ tree: NodeView, root: CallTarget, callees: Bool,
                                  floor: CallConfidence, depth: Int) -> BlastRadiusView {
        var everyNode: [NodeView] = []
        func collect(_ nodes: [NodeView]) {
            for node in nodes { everyNode.append(node); collect(node.children) }
        }
        collect(tree.children)

        let direct = tree.children
        let byConfidence = Dictionary(grouping: direct, by: { $0.confidence ?? "-" })
            .mapValues(\.count)
        let files = Set(everyNode.map(\.file))
        let tests = everyNode.filter(\.is_test)
        let viaDispatch = everyNode.filter { $0.via != nil }

        let noun = callees ? "callee" : "caller"
        var lines = ["// \(callees ? "reach" : "blast radius") of \(root.declId)"
                     + "  —  confidence ≥ \(floor.label), depth \(depth)"]
        func row(_ label: String, _ value: String) {
            lines.append("\(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(value)")
        }
        let grades = ["high", "medium", "low"]
            .compactMap { grade in byConfidence[grade].map { "\($0) \(grade)" } }
            .joined(separator: ", ")
        row("direct \(noun)s", "\(direct.count)" + (grades.isEmpty ? "" : "  (\(grades))"))
        if depth > 1 {
            row("transitive", "\(everyNode.count) across \(files.count) file\(files.count == 1 ? "" : "s")")
        } else {
            row("files", "\(files.count)")
        }
        // Coverage is a callers-direction question. In the callees direction "tests reached"
        // would be counting the test code this declaration calls into, which is either nothing
        // or a sign of something wrong — not a number worth reporting as coverage.
        if !callees {
            let testFiles = Set(tests.map(\.file)).count
            row("tests", tests.isEmpty
                ? "none — this change is not covered from here"
                : "\(tests.count) (\(testFiles) file\(testFiles == 1 ? "" : "s"))")
        }
        if !viaDispatch.isEmpty {
            row("via dispatch", "\(viaDispatch.count) reached through a protocol requirement")
        }
        let suppressed = tree.suppressed ?? 0
        if suppressed > 0 {
            row("below --min", "\(suppressed) weaker edge\(suppressed == 1 ? "" : "s") not counted")
        }
        if tree.truncated {
            lines.append("// capped at --limit \(direct.count) — raise it before trusting the totals")
        }

        return BlastRadiusView(direction: callees ? "callees" : "callers", root: root.declId,
                           direct: direct.count, transitive: everyNode.count, files: files.count,
                           tests: tests.count, via_dispatch: viaDispatch.count,
                           below_floor: suppressed, truncated: tree.truncated, lines: lines)
    }

    private func render(_ nodes: [NodeView], prefix: String, floorLabel: String,
                        into out: inout [String]) {
        for (i, node) in nodes.enumerated() {
            let last = i == nodes.count - 1
            let times = (node.occurrences ?? 1) > 1 ? " ×\(node.occurrences!)" : ""
            let via = node.via.map { "  via \($0)" } ?? ""
            let test = node.is_test ? "  [test]" : ""
            out.append("\(prefix)\(last ? "└─ " : "├─ ")\(node.id)  \(node.site ?? "")"
                       + "  [\(node.confidence ?? "-")]\(times)\(test)\(via)")
            render(node.children, prefix: prefix + (last ? "   " : "│  "),
                   floorLabel: floorLabel, into: &out)
            let indent = prefix + (last ? "   " : "│  ")
            if node.truncated {
                out.append("\(indent)… more edges — raise --limit")
            }
            if let suppressed = node.suppressed, suppressed > 0, !node.children.isEmpty {
                out.append("\(indent)… \(suppressed) below --min \(floorLabel)")
            }
        }
    }
}

struct NodeView: Encodable {
    var id: String
    var kind: String
    var file: String
    var line: Int
    var confidence: String?
    var occurrences: Int?
    var site: String?
    /// Present when the edge crossed dynamic dispatch: the requirement that bridges it.
    var via: String?
    var is_test: Bool
    var truncated: Bool
    /// Edges this node has that the confidence floor removed. Present so an empty result can
    /// say which kind of empty it is.
    var suppressed: Int?
    var children: [NodeView]
}

struct BlastRadiusView: Encodable {
    var direction: String
    var root: String
    var direct: Int
    var transitive: Int
    var files: Int
    var tests: Int
    var via_dispatch: Int
    var below_floor: Int
    var truncated: Bool
    /// The rendered text block, so the JSON and the terminal agree on the wording.
    var lines: [String]
}

struct TreeView: Encodable {
    var direction: String
    var root: NodeView
}
