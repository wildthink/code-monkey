import ArgumentParser
import Foundation

//# ai:section: "Stats"

/// Project-shape metrics, read entirely off the index.
///
/// Not a line counter. `cloc` answers "how big", which the file system already knows. This
/// answers the three questions that decide what an agent reads next: where the mass is, what
/// reading it costs, and which of it carries no prose. Nothing here opens a source file, so the
/// whole report is a handful of aggregate queries against tables that are already built.
//# ai:invariant: read-only over the index — no source file is opened, no row is written
//# ai:why: the headline figure is `fold` — the byte share that `code -L0` never has to emit
enum Stats {

    /// The cuts a caller can ask for. Every one is independent, so `--section` narrows the work
    /// as well as the output: a section nobody asked for runs no query.
    enum Section: String, CaseIterable, Sendable, ExpressibleByArgument {
        case overview
        case kinds
        case mass
        case fold
        case docs
        case coupling
        case hotspots

        var summary: String {
            switch self {
            case .overview: "file, declaration and byte totals, split production vs test"
            case .kinds: "declarations per kind, with the line span each kind occupies"
            case .mass: "declarations per file — percentiles, concentration, densest files"
            case .fold: "what reading signatures instead of bodies saves, in bytes"
            case .docs: "doc-comment coverage by access, directive tags, unmapped files"
            case .coupling: "most-imported modules, most-conformed protocols"
            case .hotspots: "longest bodies, and undocumented names with the widest fan-in"
            }
        }

        static var allValueDescriptions: [String: String] {
            Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.summary) })
        }
    }

    // MARK: - path scoping

    /// A `WHERE` fragment restricting `files` (aliased `f`) to one file or subtree.
    ///
    /// Returned rather than applied so each section can splice it at its own binding position;
    /// a section using the filter twice appends the binds twice, in query order.
    //# ai:invariant: binds must be appended in the same order the fragments appear in the SQL
    struct Scope {
        var clause: String = "1=1"
        var binds: [any Bindable] = []

        init(path: String?, root: URL) {
            guard let path else { return }
            let rel = relativePath(path, root: root)
            guard !rel.isEmpty else { return }
            clause = "(f.path = ? OR f.path LIKE ?)"
            binds = [rel, rel + "/%"]
        }
    }

    // MARK: - aggregation primitives

    /// Nearest-rank percentile over an already-sorted-ascending array.
    ///
    /// Nearest-rank rather than interpolated: every value it reports is a file that exists, so
    /// "p90 is 128 declarations" names a real file rather than a point between two of them.
    static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(1, Int((Double(sorted.count) * fraction).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }

    /// The share of `values` held by its largest `fraction` of members.
    ///
    /// Reported instead of a standard deviation because it names an action: "the top tenth of
    /// the files hold two thirds of the declarations" tells a reader where to go, and a variance
    /// does not.
    static func concentration(_ values: [Int], topFraction: Double) -> Double {
        let total = values.reduce(0, +)
        guard total > 0 else { return 0 }
        let descending = values.sorted(by: >)
        let take = max(1, Int((Double(descending.count) * topFraction).rounded(.up)))
        return Double(descending.prefix(take).reduce(0, +)) / Double(total)
    }
}

// MARK: - the report

extension Stats {
    struct Report: Encodable {
        var scope: String
        var overview: Overview?
        var kinds: [KindStat]?
        var mass: Mass?
        var fold: Fold?
        var docs: Docs?
        var coupling: Coupling?
        var hotspots: Hotspots?
    }

    struct Overview: Encodable {
        var files: Int
        var declarations: Int
        /// Summed over top-level declarations only. Summing every row instead would count a
        /// type's members twice, once on their own and once inside their container's span.
        //# ai:invariant: byte totals restrict to `container IS NULL` — nesting double-counts
        var source_bytes: Int
        var production_files: Int
        var test_files: Int
        var imports: Int
        var call_sites: Int
        var directives: Int
    }

    struct KindStat: Encodable {
        var kind: String
        var count: Int
        /// Declared span in lines, nesting included: a struct's span covers its members. Named
        /// `span` rather than `lines` so nobody sums the column and expects the file total.
        var span: Int
    }

    struct Mass: Encodable {
        var p50: Int
        var p90: Int
        var max: Int
        var empty_files: Int
        /// Share of all declarations living in the densest tenth of the files.
        var top_decile_share: Double
        var densest: [FileStat]
    }

    struct FileStat: Encodable {
        var path: String
        var declarations: Int
        var bytes: Int
    }

    struct Fold: Encodable {
        var source_bytes: Int
        var body_bytes: Int
        var doc_bytes: Int
        /// `body_bytes` as a share of `source_bytes` — what a signature-only read never emits.
        var body_share: Double
    }

    struct Docs: Encodable {
        var by_access: [AccessStat]
        var directives: [TagStat]
        var files_without_directives: Int
        var files_without_section: Int
    }

    struct AccessStat: Encodable {
        var access: String
        var declarations: Int
        var documented: Int
        var coverage: Double
    }

    struct TagStat: Encodable {
        var tag: String
        var count: Int
    }

    struct Coupling: Encodable {
        var modules: [NameCount]
        var protocols: [NameCount]
    }

    struct NameCount: Encodable {
        var name: String
        var count: Int
    }

    struct Hotspots: Encodable {
        var longest_bodies: [Longest]
        var undocumented_fan_in: [FanIn]
    }

    struct Longest: Encodable {
        var decl_id: String
        var kind: String
        var path: String
        var start_line: Int
        var span: Int
    }

    /// A widely-called declaration carrying no doc comment.
    ///
    /// `callers` counts only corroborated edges — the `high` rung of `CallGraph`'s confidence
    /// ladder, restated in SQL so the whole section stays one query. Matching on the callee name
    /// alone instead would rank `append` and `String` at the top of every project, because those
    /// names collide with the standard library and `call_sites.name` is the callee as written.
    //# ai:invariant: mirrors CallGraph's `high` grade — receiver absent, or resolving to the container
    //# ai:warn: a lower bound: closure and parameter receivers are not indexed, so their calls are dropped
    //# ai:see: CallGraph.grade(target:from:receiver:)
    struct FanIn: Encodable {
        var decl_id: String
        var path: String
        var callers: Int
    }
}

// MARK: - collection

extension Stats {
    /// One section, one query batch. Split out from the command so the report is testable
    /// without going through ArgumentParser.
    static func report(
        db: Database,
        root: URL,
        path: String?,
        sections: Set<Section>,
        top: Int
    ) async throws -> Report {
        let scope = Scope(path: path, root: root)
        var report = Report(scope: path ?? ".")

        // `overview` and `mass` share this: both are folds over the same per-file row set, and
        // running it once keeps the two sections from disagreeing about the file count.
        var perFile: [FileStat] = []
        if sections.contains(.overview) || sections.contains(.mass) {
            let rows = try await db.query("""
                SELECT f.path AS path,
                       COUNT(d.id) AS decls,
                       COALESCE(SUM(CASE WHEN d.container IS NULL THEN d.decl_length ELSE 0 END), 0) AS bytes
                  FROM files f
                  LEFT JOIN declarations d ON d.file_id = f.id
                 WHERE \(scope.clause)
                 GROUP BY f.id
                 ORDER BY decls DESC, f.path
                """, scope.binds)
            perFile = rows.map {
                FileStat(path: $0.string("path") ?? "",
                         declarations: Int($0.int64("decls") ?? 0),
                         bytes: Int($0.int64("bytes") ?? 0))
            }
        }

        if sections.contains(.overview) {
            func count(_ table: String, _ join: String) async throws -> Int {
                let rows = try await db.query(
                    "SELECT COUNT(*) AS n FROM \(table) JOIN files f ON \(join) WHERE \(scope.clause)",
                    scope.binds)
                return Int(rows.first?.int64("n") ?? 0)
            }
            let directiveRows = try await db.query("""
                SELECT COUNT(*) AS n FROM directives v
                  JOIN declarations d ON d.id = v.decl_id
                  JOIN files f ON f.id = d.file_id
                 WHERE \(scope.clause)
                """, scope.binds)
            let tests = perFile.filter { TestConvention.isTestPath($0.path) }
            report.overview = Overview(
                files: perFile.count,
                declarations: perFile.reduce(0) { $0 + $1.declarations },
                source_bytes: perFile.reduce(0) { $0 + $1.bytes },
                production_files: perFile.count - tests.count,
                test_files: tests.count,
                imports: try await count("imports i", "f.id = i.file_id"),
                call_sites: try await count("call_sites cs", "f.id = cs.file_id"),
                directives: Int(directiveRows.first?.int64("n") ?? 0)
            )
        }

        if sections.contains(.mass) {
            let counts = perFile.map(\.declarations)
            let ascending = counts.sorted()
            report.mass = Mass(
                p50: percentile(ascending, 0.5),
                p90: percentile(ascending, 0.9),
                max: ascending.last ?? 0,
                empty_files: counts.filter { $0 == 0 }.count,
                top_decile_share: concentration(counts, topFraction: 0.1),
                densest: Array(perFile.prefix(top))
            )
        }

        if sections.contains(.kinds) {
            let rows = try await db.query("""
                SELECT d.kind AS kind,
                       COUNT(*) AS n,
                       SUM(d.end_line - d.start_line + 1) AS span
                  FROM declarations d JOIN files f ON f.id = d.file_id
                 WHERE \(scope.clause)
                 GROUP BY d.kind
                 ORDER BY n DESC
                """, scope.binds)
            report.kinds = rows.map {
                KindStat(kind: $0.string("kind") ?? "",
                         count: Int($0.int64("n") ?? 0),
                         span: Int($0.int64("span") ?? 0))
            }
        }

        if sections.contains(.fold) {
            // Summing `body_length` over every row is safe here and only here: the extractor
            // records a body for functions and computed properties but never for a type, and no
            // declaration has a function as its container — so no body nests inside another.
            //# ai:invariant: body spans do not overlap; if the extractor ever nests one, this over-counts
            let rows = try await db.query("""
                SELECT COALESCE(SUM(CASE WHEN d.container IS NULL THEN d.decl_length ELSE 0 END), 0) AS source_bytes,
                       COALESCE(SUM(COALESCE(d.body_length, 0)), 0) AS body_bytes
                  FROM declarations d JOIN files f ON f.id = d.file_id
                 WHERE \(scope.clause)
                """, scope.binds)
            let docRows = try await db.query("""
                SELECT COALESCE(SUM(LENGTH(dc.text)), 0) AS doc_bytes
                  FROM doc_comments dc
                  JOIN declarations d ON d.id = dc.decl_id
                  JOIN files f ON f.id = d.file_id
                 WHERE \(scope.clause)
                """, scope.binds)
            let source = Int(rows.first?.int64("source_bytes") ?? 0)
            let body = Int(rows.first?.int64("body_bytes") ?? 0)
            report.fold = Fold(
                source_bytes: source,
                body_bytes: body,
                doc_bytes: Int(docRows.first?.int64("doc_bytes") ?? 0),
                body_share: source > 0 ? Double(body) / Double(source) : 0
            )
        }

        if sections.contains(.docs) {
            // Swift writes `internal` by omitting it, and the extractor records what was
            // written — so the majority of rows carry an empty string. Normalizing here rather
            // than in every caller's SQL is the difference between a coverage number and a
            // coverage number with a silent hole in it.
            //# ai:invariant: empty or NULL access means `internal` — never report it as blank
            let accessRows = try await db.query("""
                SELECT CASE WHEN d.access IS NULL OR d.access = '' THEN 'internal' ELSE d.access END AS access,
                       COUNT(*) AS n,
                       SUM(CASE WHEN dc.decl_id IS NOT NULL THEN 1 ELSE 0 END) AS documented
                  FROM declarations d
                  JOIN files f ON f.id = d.file_id
                  LEFT JOIN doc_comments dc ON dc.decl_id = d.id
                 WHERE \(scope.clause)
                 GROUP BY access
                """, scope.binds)
            let order = ["open", "public", "package", "internal", "fileprivate", "private"]
            let byAccess = accessRows.map { row -> AccessStat in
                let n = Int(row.int64("n") ?? 0)
                let documented = Int(row.int64("documented") ?? 0)
                return AccessStat(access: row.string("access") ?? "internal",
                                  declarations: n,
                                  documented: documented,
                                  coverage: n > 0 ? Double(documented) / Double(n) : 0)
            }.sorted { a, b in
                (order.firstIndex(of: a.access) ?? order.count) < (order.firstIndex(of: b.access) ?? order.count)
            }

            let tagRows = try await db.query("""
                SELECT v.tag AS tag, COUNT(*) AS n
                  FROM directives v
                  JOIN declarations d ON d.id = v.decl_id
                  JOIN files f ON f.id = d.file_id
                 WHERE \(scope.clause)
                 GROUP BY v.tag
                 ORDER BY n DESC
                """, scope.binds)

            /// Files holding no directive at all, and files no `ai:section` claims. Both are
            /// "territory the author never mapped", and the second is the one that matters for
            /// orientation, since `query --recipe sections` is how a cold reader starts.
            func filesMissing(_ tagClause: String) async throws -> Int {
                let rows = try await db.query("""
                    SELECT COUNT(*) AS n FROM files f
                     WHERE \(scope.clause)
                       AND f.id NOT IN (
                           SELECT d.file_id FROM declarations d
                             JOIN directives v ON v.decl_id = d.id
                            WHERE \(tagClause))
                    """, scope.binds)
                return Int(rows.first?.int64("n") ?? 0)
            }

            report.docs = Docs(
                by_access: byAccess,
                directives: tagRows.map {
                    TagStat(tag: $0.string("tag") ?? "", count: Int($0.int64("n") ?? 0))
                },
                files_without_directives: try await filesMissing("1=1"),
                files_without_section: try await filesMissing("v.tag = 'ai:section'")
            )
        }

        if sections.contains(.coupling) {
            let moduleRows = try await db.query("""
                SELECT i.module AS name, COUNT(DISTINCT i.file_id) AS n
                  FROM imports i JOIN files f ON f.id = i.file_id
                 WHERE \(scope.clause)
                 GROUP BY i.module
                 ORDER BY n DESC, name
                 LIMIT \(top)
                """, scope.binds)
            let protocolRows = try await db.query("""
                SELECT c.protocol_name AS name, COUNT(*) AS n
                  FROM conformances c JOIN files f ON f.id = c.file_id
                 WHERE \(scope.clause)
                 GROUP BY c.protocol_name
                 ORDER BY n DESC, name
                 LIMIT \(top)
                """, scope.binds)
            func counts(_ rows: [DatabaseRow]) -> [NameCount] {
                rows.map { NameCount(name: $0.string("name") ?? "", count: Int($0.int64("n") ?? 0)) }
            }
            report.coupling = Coupling(modules: counts(moduleRows), protocols: counts(protocolRows))
        }

        if sections.contains(.hotspots) {
            let longestRows = try await db.query("""
                SELECT d.decl_id AS decl_id, d.kind AS kind, f.path AS path,
                       d.start_line AS start_line,
                       (d.end_line - d.start_line + 1) AS span
                  FROM declarations d JOIN files f ON f.id = d.file_id
                 WHERE \(scope.clause) AND d.body_length IS NOT NULL
                 ORDER BY span DESC, d.decl_id
                 LIMIT \(top)
                """, scope.binds)

            // Every edge here is corroborated by its receiver. The cheap alternative — joining
            // declarations to call sites on name alone — ranks `append`, `String` and `map` at
            // the top of any project, because those names belong to the standard library and
            // nothing in `call_sites` says which `append` was meant.
            //# ai:invariant: the three OR branches are CallGraph's `high` grade and nothing weaker
            let fanInRows = try await db.query("""
                WITH callable AS (
                    SELECT d.id AS id, d.name AS name, d.container AS container,
                           d.decl_id AS decl_id, f.path AS path
                      FROM declarations d
                      JOIN files f ON f.id = d.file_id
                      LEFT JOIN doc_comments dc ON dc.decl_id = d.id
                     WHERE \(scope.clause)
                       AND dc.decl_id IS NULL
                       AND d.kind IN ('func', 'init', 'subscript')
                ),
                edges AS (
                    SELECT DISTINCT c.id AS target, cs.from_decl AS caller
                      FROM call_sites cs
                      JOIN files f ON f.id = cs.file_id
                      JOIN callable c ON c.name = cs.name
                      LEFT JOIN declarations origin ON origin.id = cs.from_decl
                     WHERE cs.kind = 'call' AND \(scope.clause)
                       AND (
                              ((cs.receiver IS NULL OR cs.receiver IN ('self', 'Self'))
                                  AND (c.container IS NULL OR c.container = origin.container))
                           OR cs.receiver = c.container
                           OR EXISTS (SELECT 1 FROM bindings b
                                       WHERE b.from_decl = cs.from_decl
                                         AND b.name = cs.receiver
                                         AND b.type = c.container)
                           )
                )
                SELECT c.decl_id AS decl_id, c.path AS path, COUNT(DISTINCT e.caller) AS callers
                  FROM callable c JOIN edges e ON e.target = c.id
                 GROUP BY c.id
                 ORDER BY callers DESC, c.decl_id
                 LIMIT \(top)
                """, scope.binds + scope.binds)

            report.hotspots = Hotspots(
                longest_bodies: longestRows.map {
                    Longest(decl_id: $0.string("decl_id") ?? "",
                            kind: $0.string("kind") ?? "",
                            path: $0.string("path") ?? "",
                            start_line: Int($0.int64("start_line") ?? 0),
                            span: Int($0.int64("span") ?? 0))
                },
                undocumented_fan_in: fanInRows.map {
                    FanIn(decl_id: $0.string("decl_id") ?? "",
                          path: $0.string("path") ?? "",
                          callers: Int($0.int64("callers") ?? 0))
                }
            )
        }

        return report
    }
}

// MARK: - text rendering

extension Stats {
    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    static func render(_ report: Report) -> String {
        var out: [String] = []
        func section(_ title: String, _ body: [String]) {
            guard !body.isEmpty else { return }
            if !out.isEmpty { out.append("") }
            out.append("## \(title)")
            out.append(contentsOf: body)
        }

        if let o = report.overview {
            section("overview", [
                "files=\(o.files) (production=\(o.production_files) test=\(o.test_files))",
                "declarations=\(o.declarations) source_bytes=\(o.source_bytes)",
                "imports=\(o.imports) call_sites=\(o.call_sites) directives=\(o.directives)",
            ])
        }
        if let kinds = report.kinds {
            section("kinds", ["kind\tcount\tspan"] + kinds.map { "\($0.kind)\t\($0.count)\t\($0.span)" })
        }
        if let m = report.mass {
            section("mass", [
                "decls_per_file p50=\(m.p50) p90=\(m.p90) max=\(m.max) empty=\(m.empty_files)",
                "top decile holds \(percent(m.top_decile_share)) of all declarations",
                "path\tdecls\tbytes",
            ] + m.densest.map { "\($0.path)\t\($0.declarations)\t\($0.bytes)" })
        }
        if let f = report.fold {
            section("fold", [
                "source_bytes=\(f.source_bytes) body_bytes=\(f.body_bytes) doc_bytes=\(f.doc_bytes)",
                "bodies are \(percent(f.body_share)) of source — what a signature-only read skips",
            ])
        }
        if let d = report.docs {
            section("docs", ["access\tdecls\tdocumented\tcoverage"]
                + d.by_access.map { "\($0.access)\t\($0.declarations)\t\($0.documented)\t\(percent($0.coverage))" }
                + [""]
                + ["tag\tcount"]
                + d.directives.map { "\($0.tag)\t\($0.count)" }
                + ["", "files with no directive=\(d.files_without_directives) "
                    + "files outside any ai:section=\(d.files_without_section)"])
        }
        if let c = report.coupling {
            section("coupling", ["module\tfiles"]
                + c.modules.map { "\($0.name)\t\($0.count)" }
                + [""]
                + ["protocol\tconformances"]
                + c.protocols.map { "\($0.name)\t\($0.count)" })
        }
        if let h = report.hotspots {
            section("hotspots", ["decl_id\tkind\tspan\tlocation"]
                + h.longest_bodies.map { "\($0.decl_id)\t\($0.kind)\t\($0.span)\t\($0.path):\($0.start_line)" }
                + [""]
                + ["callers\tundocumented decl_id\tfile"]
                + h.undocumented_fan_in.map { "\($0.callers)\t\($0.decl_id)\t\($0.path)" })
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - command

struct StatsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats",
        abstract: "Project shape: where the mass is, what reading it costs, what is undocumented.",
        discussion: """
        A sizing pass to run before the first read. `doctor` says whether the index is usable \
        and `query` answers one question at a time; this answers the standing ones at once, \
        off the index alone, without opening a source file.

        SECTIONS
          overview   file, declaration and byte totals, production vs test
          kinds      declarations per kind, with the line span each occupies
          mass       declarations per file: p50/p90/max, concentration, densest files
          fold       body bytes against source bytes — what `code -L0` never emits
          docs       doc coverage by access, directive tags, files no section claims
          coupling   most-imported modules, most-conformed protocols
          hotspots   longest bodies, and undocumented names with the widest fan-in

        Three figures carry caveats worth knowing before you quote them. `span` nests, so a \
        struct's span covers its members and the column does not sum to a file total. Byte \
        totals count top-level declarations only, for the same reason. And `hotspots` fan-in \
        counts corroborated call edges only, which makes it a lower bound: a call reached \
        through a closure parameter has no indexed receiver and is dropped rather than guessed.

        EXAMPLES
          code-monkey stats                            every section
          code-monkey stats --section mass --top 20    the files worth reading first
          code-monkey stats --section fold             the case for reading at level 0
          code-monkey stats --section docs             where the prose is missing
          code-monkey stats Sources/code-monkey        narrow to a subtree
        """)

    @OptionGroup var opts: GlobalOptions
    @Argument(help: "Path filter (file or directory). Default: the whole project.") var path: String?

    @Option(name: .long, help: "Limit to these sections. Repeatable. Default: all of them.")
    var section: [Stats.Section] = []

    @Option(name: .long, help: "Rows per ranked list.") var top: Int = 10

    func validate() throws {
        guard top > 0 else { throw ValidationError("--top must be at least 1") }
    }

    mutating func run() async throws {
        let requested = section.isEmpty ? Set(Stats.Section.allCases) : Set(section)
        let (project, db, _) = try await opts.openIndex(
            command: "stats", tier: "T0",
            target: path ?? (section.isEmpty ? "all" : section.map(\.rawValue).joined(separator: ",")))
        let freshness = try await Indexer.check(project: project, db: db)
        let report = try await Stats.report(
            db: db, root: project.root, path: path, sections: requested, top: top)
        Printer.emit(
            report,
            json: opts.json,
            tier: "T0",
            resultCount: requested.count,
            freshness: freshness.needsRefresh ? "stale" : "fresh"
        ) {
            Stats.render(report)
        }
    }
}
