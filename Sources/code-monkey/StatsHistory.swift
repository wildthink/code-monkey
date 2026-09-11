import Foundation

//# ai:section: "Stats"

/// The two `stats` sections that need history, and the flat projection a dashboard wants.
///
/// Split from `Stats.swift` because everything here depends on `Git`, and the sections there
/// deliberately do not: a project with no repository, or a checkout too shallow to have one,
/// still gets every structural number.
//# ai:invariant: nothing in this file is reached unless `Git.discover` returned a repository
extension Stats {

    // MARK: - delta

    struct AsOf: Encodable {
        var generated_at: String
        var head: String
        var since_ref: String?
        var since_sha: String?
        var window_days: Int?
    }

    struct Delta: Encodable {
        var files_changed: Int
        var added: Int
        var removed: Int
        var signature_changed: Int
        var body_changed: Int
        /// Added and removed at `public` or `open`. The other counts are churn; this one is the
        /// only thing in the section a downstream package can break on.
        var api_added: Int
        var api_removed: Int
        /// Touched declarations carrying an `ai:invariant` or `ai:warn`. Somebody edited code the
        /// author fenced off on purpose, which is the one review signal this tool can give and a
        /// line-count diff cannot.
        //# ai:why: this is the on-brand number — structure plus intent, not volume
        var guarded_changed: Int
        var undocumented_changed: Int
        var changes: [DeclChange]
    }

    struct DeclChange: Encodable {
        var decl_id: String
        var kind: String
        var path: String
        var line: Int?
        var access: String
        /// `added`, `removed`, `signature`, or `body`.
        ///
        /// The split between the first two and `signature` follows `decl_id`, which carries
        /// parameter labels and types but not the return type or `throws`. So renaming a
        /// parameter retires one handle and introduces another, and is reported as a removal
        /// plus an addition — which is the truth a caller needs, because `get` can no longer
        /// reach the old handle. Changing only the return type keeps the handle and reports
        /// as `signature`.
        //# ai:invariant: classification follows the handle, not a judgement about severity
        var change: String
        var lines_touched: Int
        var documented: Bool
        /// The `ai:` tags on this declaration that mark it as deliberately constrained.
        var guards: [String]
    }

    // MARK: - volatility

    struct Volatility: Encodable {
        var window_days: Int
        var bucket: String
        var bucket_count: Int
        var files_changed: Int
        var commits: Int
        var authors: Int
        var files: [FileVolatility]
    }

    struct FileVolatility: Encodable {
        var path: String
        var commits: Int
        var authors: Int
        var insertions: Int
        var deletions: Int
        var churn: Int
        /// Days since the file's most recent commit, over all history rather than the window —
        /// a file untouched for two years reports 730 here and nothing at all in `commits`.
        var age_days: Int?
        var declarations: Int
        var doc_coverage: Double
        var directives: Int
        var series: [Int]
        var flags: [String]
    }

    /// Editorial labels, kept separate from the numbers that produced them.
    ///
    /// A single composite risk score would rank these files identically and tell a reader
    /// nothing about which signal fired, so the ranking stays churn and the judgement stays here.
    //# ai:why: a dashboard that says "risky" without saying why gives nobody an action
    static func flags(for file: FileVolatility, churnThreshold: Int) -> [String] {
        var flags: [String] = []
        if file.churn >= churnThreshold, file.churn > 0 { flags.append("hot") }
        if file.declarations > 0, file.doc_coverage < 0.25 { flags.append("thin-docs") }
        if file.directives == 0 { flags.append("unmapped") }
        if let age = file.age_days, age > 365 { flags.append("dormant") }
        if flags.contains("hot"), flags.contains("thin-docs") { flags.append("review") }
        return flags
    }
}

// MARK: - collection

extension Stats {

    /// Declarations as they were at `ref`, extracted in-process from `git show`.
    ///
    /// The alternative is checking the ref out into a worktree and indexing it, which costs a
    /// full index run and a temporary directory. Extracting only the files the diff already
    /// named costs one `git show` each, and gives the same answer: a declaration set to
    /// difference against the current one.
    //# ai:invariant: only files the diff reports as changed are extracted — never the whole tree
    static func priorDeclarations(
        changes: [Git.Change],
        ref: String,
        repo: Git.Repository
    ) throws -> [String: [String: Extractor.Decl]] {
        var result: [String: [String: Extractor.Decl]] = [:]
        for change in changes where change.status != "A" {
            guard let source = try Git.show(change.oldPath, at: ref, in: repo) else { continue }
            let decls = Extractor.extract(source: source, file: change.path)
            result[change.path] = Dictionary(decls.map { ($0.declId, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return result
    }

    static func delta(
        db: Database,
        repo: Git.Repository,
        ref: String,
        scope: Scope,
        top: Int
    ) async throws -> Delta {
        let allChanges = try Git.changes(since: ref, in: repo)
        let allHunks = try Git.hunks(since: ref, in: repo)

        // Scope is a path prefix on the index side, so it filters git's answer rather than
        // git's question: the diff is one process either way and narrowing it would not pay.
        let inScope: (String) -> Bool = { path in
            guard let prefix = scope.pathPrefix else { return true }
            return path == prefix || path.hasPrefix(prefix + "/")
        }
        let changes = allChanges.filter { inScope($0.path) }
        let hunks = allHunks.filter { inScope($0.path) }

        var touchedLines: [String: [(Int, Int)]] = [:]
        for hunk in hunks { touchedLines[hunk.path, default: []].append((hunk.start, hunk.end)) }

        let prior = try priorDeclarations(changes: changes, ref: ref, repo: repo)

        // Current state, for the changed files only. `guards` and `documented` come from the
        // index rather than from a re-extraction so they agree with every other section.
        var current: [String: [String: (row: DatabaseRow, guards: [String], documented: Bool)]] = [:]
        for change in changes where change.status != "D" {
            let rows = try await db.query("""
                SELECT d.decl_id AS decl_id, d.kind AS kind, d.signature AS signature,
                       d.access AS access, d.start_line AS start_line, d.end_line AS end_line,
                       (SELECT COUNT(*) FROM doc_comments dc WHERE dc.decl_id = d.id) AS documented,
                       (SELECT GROUP_CONCAT(v.tag) FROM directives v
                         WHERE v.decl_id = d.id AND v.tag IN ('ai:invariant', 'ai:warn')) AS guards
                  FROM declarations d JOIN files f ON f.id = d.file_id
                 WHERE f.path = ?
                """, [change.path])
            var byId: [String: (DatabaseRow, [String], Bool)] = [:]
            for row in rows {
                let guards = (row.string("guards") ?? "").split(separator: ",").map(String.init)
                byId[row.string("decl_id") ?? ""] = (row, Array(Set(guards)).sorted(),
                                                     (row.int64("documented") ?? 0) > 0)
            }
            current[change.path] = byId
        }

        func access(_ raw: String?) -> String {
            let value = raw ?? ""
            return value.isEmpty ? "internal" : value
        }
        func overlap(_ path: String, _ start: Int, _ end: Int) -> Int {
            (touchedLines[path] ?? []).reduce(0) { total, range in
                total + max(0, min(end, range.1) - max(start, range.0) + 1)
            }
        }

        var entries: [DeclChange] = []
        for change in changes {
            let old = prior[change.path] ?? [:]
            let new = current[change.path] ?? [:]

            for (declId, entry) in new where old[declId] == nil {
                let start = Int(entry.row.int64("start_line") ?? 0)
                entries.append(DeclChange(
                    decl_id: declId, kind: entry.row.string("kind") ?? "", path: change.path,
                    line: start, access: access(entry.row.string("access")),
                    change: "added",
                    lines_touched: overlap(change.path, start, Int(entry.row.int64("end_line") ?? 0)),
                    documented: entry.documented, guards: entry.guards))
            }
            for (declId, decl) in old where new[declId] == nil {
                entries.append(DeclChange(
                    decl_id: declId, kind: decl.kind, path: change.path, line: nil,
                    access: access(decl.access), change: "removed",
                    lines_touched: 0, documented: !decl.doc.isEmpty,
                    guards: Array(Set(decl.directives.map(\.tag)
                        .filter { $0 == "ai:invariant" || $0 == "ai:warn" })).sorted()))
            }
            for (declId, entry) in new {
                guard let was = old[declId] else { continue }
                let start = Int(entry.row.int64("start_line") ?? 0)
                let end = Int(entry.row.int64("end_line") ?? 0)
                let touched = overlap(change.path, start, end)
                let signatureChanged = was.signature != (entry.row.string("signature") ?? "")
                // A declaration whose text no hunk reaches did not change; it only moved,
                // because something above it grew.
                guard signatureChanged || touched > 0 else { continue }
                entries.append(DeclChange(
                    decl_id: declId, kind: entry.row.string("kind") ?? "", path: change.path,
                    line: start, access: access(entry.row.string("access")),
                    change: signatureChanged ? "signature" : "body",
                    lines_touched: touched, documented: entry.documented, guards: entry.guards))
            }
        }

        func count(_ predicate: (DeclChange) -> Bool) -> Int { entries.filter(predicate).count }
        let api: Set<String> = ["public", "open"]
        return Delta(
            files_changed: Set(changes.map(\.path)).count,
            added: count { $0.change == "added" },
            removed: count { $0.change == "removed" },
            signature_changed: count { $0.change == "signature" },
            body_changed: count { $0.change == "body" },
            api_added: count { $0.change == "added" && api.contains($0.access) },
            api_removed: count { $0.change == "removed" && api.contains($0.access) },
            guarded_changed: count { !$0.guards.isEmpty },
            undocumented_changed: count { !$0.documented && $0.change != "removed" },
            changes: entries
                .sorted {
                    ($0.lines_touched, $0.decl_id) > ($1.lines_touched, $1.decl_id)
                }
                .prefix(top)
                .map { $0 }
        )
    }

    static func volatility(
        db: Database,
        repo: Git.Repository,
        scope: Scope,
        days: Int,
        buckets: Int,
        top: Int,
        now: Date = Date()
    ) async throws -> Volatility {
        let churn = try Git.churn(in: repo, days: days, buckets: buckets, now: now)
        let touched = try Git.lastTouched(in: repo)

        // The structural half. Only indexed files appear: a file git knows about but the index
        // does not is excluded by config or gitignore, and reporting it would invite a drill-down
        // into declarations that were never extracted.
        //# ai:invariant: the index is the spine — git contributes columns, never rows
        let rows = try await db.query("""
            SELECT f.path AS path,
                   COUNT(d.id) AS decls,
                   SUM(CASE WHEN dc.decl_id IS NOT NULL THEN 1 ELSE 0 END) AS documented,
                   (SELECT COUNT(*) FROM directives v
                      JOIN declarations dd ON dd.id = v.decl_id
                     WHERE dd.file_id = f.id) AS directives
              FROM files f
              LEFT JOIN declarations d ON d.file_id = f.id
              LEFT JOIN doc_comments dc ON dc.decl_id = d.id
             WHERE \(scope.clause)
             GROUP BY f.id
            """, scope.binds)

        var files: [FileVolatility] = rows.map { row in
            let path = row.string("path") ?? ""
            let entry = churn[path]
            let decls = Int(row.int64("decls") ?? 0)
            let documented = Int(row.int64("documented") ?? 0)
            let age = touched[path].map { Int(now.timeIntervalSince($0) / 86_400) }
            return FileVolatility(
                path: path,
                commits: entry?.commits ?? 0,
                authors: entry?.authors.count ?? 0,
                insertions: entry?.insertions ?? 0,
                deletions: entry?.deletions ?? 0,
                churn: (entry?.insertions ?? 0) + (entry?.deletions ?? 0),
                age_days: age,
                declarations: decls,
                doc_coverage: decls > 0 ? Double(documented) / Double(decls) : 0,
                directives: Int(row.int64("directives") ?? 0),
                series: entry?.buckets ?? Array(repeating: 0, count: buckets),
                flags: [])
        }

        // "Hot" is relative to this project, not to an absolute line count: a threshold that
        // means something in a busy service means nothing in a library nobody has touched.
        let churned = files.map(\.churn).filter { $0 > 0 }.sorted()
        let threshold = percentile(churned, 0.75)
        files = files.map { file in
            var copy = file
            copy.flags = flags(for: file, churnThreshold: max(threshold, 1))
            return copy
        }
        files.sort { ($0.churn, $1.path) > ($1.churn, $0.path) }

        let scoped = Set(files.map(\.path))
        let relevant = churn.filter { scoped.contains($0.key) }
        return Volatility(
            window_days: days,
            bucket: buckets > 0 ? "\(max(1, days / buckets))d" : "none",
            bucket_count: buckets,
            files_changed: relevant.count,
            commits: relevant.values.reduce(0) { $0 + $1.commits },
            authors: Set(relevant.values.flatMap(\.authors)).count,
            files: Array(files.prefix(top))
        )
    }
}

// MARK: - dashboard projection

extension Stats {

    /// The report flattened into one entity list, which is the shape a table or a card grid can
    /// render without walking a tree.
    ///
    /// Sections are how a person reads the report and the wrong axis for a UI: a dashboard wants
    /// every file in one array so it can sort, filter and drill down, and it wants the *numbers*
    /// rather than the strings the text renderer produces.
    //# ai:invariant: every `values` entry is a number or a short enum string — never preformatted text
    struct Dashboard: Encodable {
        var schema_version: Int = 2
        var as_of: AsOf
        var metrics: [String: MetricDescriptor]
        var series_axis: SeriesAxis?
        var entities: [Entity]
    }

    /// What a metric means, so the UI colours and formats without hardcoding a column list.
    struct MetricDescriptor: Encodable {
        var unit: String
        /// `riskier` or `safer` — which end of the range wants the reader's attention.
        var higher_is: String
        var format: String
    }

    struct SeriesAxis: Encodable {
        var bucket: String
        var count: Int
        var window_days: Int
    }

    struct Entity: Encodable {
        var id: String
        var kind: String
        var label: String
        var path: String
        var line: Int?
        /// The file entity a declaration belongs to, so drill-down is a filter rather than a join.
        var parent: String?
        var values: [String: Value]
        var flags: [String]
        var series: [String: [Int]]?

        /// Numbers stay numbers and short enums stay strings. Encoding everything as text would
        /// make the UI parse its own data back out, and sorting would go lexicographic.
        enum Value: Encodable {
            case int(Int)
            case double(Double)
            case text(String)

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .int(let value): try container.encode(value)
                case .double(let value): try container.encode(value)
                case .text(let value): try container.encode(value)
                }
            }
        }
    }

    static let metricDescriptors: [String: MetricDescriptor] = [
        "churn": .init(unit: "lines", higher_is: "riskier", format: "int"),
        "commits": .init(unit: "commits", higher_is: "riskier", format: "int"),
        "authors": .init(unit: "people", higher_is: "riskier", format: "int"),
        "age_days": .init(unit: "days", higher_is: "safer", format: "int"),
        "declarations": .init(unit: "declarations", higher_is: "riskier", format: "int"),
        "doc_coverage": .init(unit: "ratio", higher_is: "safer", format: "percent"),
        "directives": .init(unit: "directives", higher_is: "safer", format: "int"),
        "bytes": .init(unit: "bytes", higher_is: "riskier", format: "bytes"),
        "lines_touched": .init(unit: "lines", higher_is: "riskier", format: "int"),
        "documented": .init(unit: "boolean", higher_is: "safer", format: "bool"),
        "guards": .init(unit: "directives", higher_is: "riskier", format: "int"),
    ]

    static func fileEntityId(_ path: String) -> String { "file:" + path }

    static func dashboard(from report: Report, asOf: AsOf) -> Dashboard {
        var files: [String: Entity] = [:]
        var order: [String] = []

        func file(_ path: String) -> Entity {
            if let existing = files[path] { return existing }
            order.append(path)
            let label = path.split(separator: "/").last.map(String.init) ?? path
            return Entity(id: fileEntityId(path), kind: "file", label: label, path: path,
                          line: nil, parent: nil, values: [:], flags: [], series: nil)
        }

        for entry in report.mass?.densest ?? [] {
            var entity = file(entry.path)
            entity.values["declarations"] = .int(entry.declarations)
            entity.values["bytes"] = .int(entry.bytes)
            files[entry.path] = entity
        }
        for entry in report.volatility?.files ?? [] {
            var entity = file(entry.path)
            entity.values["churn"] = .int(entry.churn)
            entity.values["commits"] = .int(entry.commits)
            entity.values["authors"] = .int(entry.authors)
            entity.values["declarations"] = .int(entry.declarations)
            entity.values["doc_coverage"] = .double(entry.doc_coverage)
            entity.values["directives"] = .int(entry.directives)
            if let age = entry.age_days { entity.values["age_days"] = .int(age) }
            entity.flags = entry.flags
            entity.series = ["commits": entry.series]
            files[entry.path] = entity
        }

        var entities = order.compactMap { files[$0] }
        for change in report.delta?.changes ?? [] {
            let label = change.decl_id.split(separator: "(").first.map(String.init) ?? change.decl_id
            entities.append(Entity(
                id: "decl:" + change.decl_id,
                kind: "declaration",
                label: label,
                path: change.path,
                line: change.line,
                parent: fileEntityId(change.path),
                values: [
                    "change": .text(change.change),
                    "lines_touched": .int(change.lines_touched),
                    "access": .text(change.access),
                    "kind": .text(change.kind),
                    "documented": .int(change.documented ? 1 : 0),
                    "guards": .int(change.guards.count),
                ],
                flags: [change.change]
                    + (change.guards.isEmpty ? [] : ["guarded"])
                    + (change.documented ? [] : ["undocumented"]),
                series: nil))
        }

        let axis = report.volatility.map {
            SeriesAxis(bucket: $0.bucket, count: $0.bucket_count, window_days: $0.window_days)
        }
        return Dashboard(as_of: asOf, metrics: metricDescriptors, series_axis: axis, entities: entities)
    }
}
