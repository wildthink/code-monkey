import ArgumentParser
import Foundation

// MARK: - shared support for structural edits

enum EditOps {

    /// Resolve `pattern` to exactly one declaration, reporting ambiguity the way clip does.
    static func resolveOne(
        pattern: String,
        fileFilter: String?,
        db: Database,
        what: String
    ) async throws -> DatabaseRow {
        let rows = try await ClipCmd.resolveTarget(pattern: pattern, fileFilter: fileFilter, db: db)
        if rows.isEmpty {
            FileHandle.standardError.write(Data("no match for \(what) `\(pattern)` — try `code-monkey index`\n".utf8))
            throw ExitCode(1)
        }
        if rows.count > 1 {
            FileHandle.standardError.write(Data("ambiguous \(what) (\(rows.count) matches) — use exact decl_id or --file:\n".utf8))
            for r in rows {
                FileHandle.standardError.write(Data("  \(r.string("decl_id") ?? "")  \(r.string("file_path") ?? "")\n".utf8))
            }
            throw ExitCode(1)
        }
        return rows[0]
    }

    /// Read a file and refuse if its bytes differ from what the index recorded.
    //# ai:invariant: a structural edit never writes at offsets taken from a stale index
    static func verifiedContents(rel: String, expecting sha: String?, root: URL) throws -> Data {
        let url = root.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: url) else {
            FileHandle.standardError.write(Data("cannot read \(rel)\n".utf8))
            throw ExitCode(1)
        }
        if let sha, !sha.isEmpty, Indexer.sha256(data) != sha {
            let msg = "\(rel) changed since it was indexed — refusing to edit at stale "
                    + "offsets. Run `code-monkey index` and retry.\n"
            FileHandle.standardError.write(Data(msg.utf8))
            throw ExitCode(1)
        }
        return data
    }

    /// Apply byte edits to one buffer. Later ranges are applied first so earlier
    /// offsets stay valid.
    //# ai:invariant: edits must not overlap
    static func apply(_ edits: [(range: Range<Int>, bytes: Data)], to data: Data) -> Data {
        var out = data
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: edit.bytes)
        }
        return out
    }

    /// `true` for a bare Swift identifier — the only thing `rename --to` accepts.
    static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        guard first == "_" || first.isLetter else { return false }
        return s.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Offset of the declared name inside a decl's own bytes.
    //# ai:warn: this takes the first whole-word occurrence of the old name after the
    //#          decl's first byte. Attributes are part of those bytes, so a decl whose
    //#          attribute repeats its own name (`@objc(note) func note()`) renames the
    //#          attribute instead. Rare enough to accept, wrong enough to document.
    static func nameOffset(in data: Data, declRange: Range<Int>, name: String) -> Int? {
        let needle = Array(name.utf8)
        guard !needle.isEmpty, declRange.count >= needle.count else { return nil }
        func isWordByte(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
        }
        var i = declRange.lowerBound
        let limit = declRange.upperBound - needle.count
        while i <= limit {
            if data[data.startIndex + i] == needle[0] {
                var match = true
                for k in 1..<needle.count where data[data.startIndex + i + k] != needle[k] {
                    match = false
                    break
                }
                if match {
                    let beforeOK = i == 0 || !isWordByte(data[data.startIndex + i - 1])
                    let afterIdx = i + needle.count
                    let afterOK = afterIdx >= data.count || !isWordByte(data[data.startIndex + afterIdx])
                    if beforeOK && afterOK { return i }
                }
            }
            i += 1
        }
        return nil
    }

    /// Re-indent a moved block: strip the indentation it carried at its source depth
    /// and apply the destination's to every line.
    //# ai:why: a move usually changes nesting depth — that is the point of it — so the
    //#         paste rule of "indent the first line, leave the rest" misaligns the body.
    //#         Relative nesting inside the block is preserved by stripping only the
    //#         source's own prefix.
    static func reindent(_ payload: Data, from src: String, to dst: String) -> Data {
        let text = String(decoding: payload, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let out = lines.map { line -> String in
            var l = String(line)
            // Blank lines stay blank rather than collecting trailing indent.
            if l.allSatisfy({ $0 == " " || $0 == "\t" }) { return "" }
            // Strip only the source's own prefix. Dropping *all* leading whitespace
            // would flatten the block's internal nesting into the destination indent.
            if !src.isEmpty, l.hasPrefix(src) { l.removeFirst(src.count) }
            return dst + l
        }
        return Data(out.joined(separator: "\n").utf8)
    }

    /// Build a `CallTarget` for a resolved declaration row.
    static func callTarget(rowId: Int64, db: Database) async throws -> CallTarget? {
        let rows = try await db.query("""
            SELECT d.id, d.decl_id, d.name, d.kind, d.container, d.start_line, f.path AS file_path
              FROM declarations d JOIN files f ON f.id = d.file_id
             WHERE d.id = ?
            """, [rowId])
        guard let r = rows.first else { return nil }
        return CallTarget(
            rowId: r.int64("id") ?? rowId,
            declId: r.string("decl_id") ?? "",
            name: r.string("name") ?? "",
            kind: r.string("kind") ?? "",
            container: r.string("container"),
            file: r.string("file_path") ?? "",
            startLine: Int(r.int64("start_line") ?? 0)
        )
    }
}

// MARK: - move

struct MoveCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a declaration, with its comment block, to another file or position.")

    @OptionGroup var opts: GlobalOptions
    @Argument var pattern: String
    @Option(name: .long, help: "Destination file.") var to: String
    @Option(name: .long, help: "Place it after this decl in the destination. Default: end of file.")
    var after: String?
    @Option(name: .long, help: "Restrict the source match to this file.") var file: String?

    mutating func run() async throws {
        let (project, db, _) = try await opts.openIndex(
            command: "move", tier: "write", target: pattern, writable: true)

        let src = try await EditOps.resolveOne(
            pattern: pattern, fileFilter: file.map { relativePath($0, root: project.root) },
            db: db, what: "decl")
        let srcRel = src.string("file_path") ?? ""
        let declId = src.string("decl_id") ?? ""
        let offset = Int(src.int64("decl_offset") ?? 0)
        let length = Int(src.int64("decl_length") ?? 0)

        let destRel = relativePath(to, root: project.root)
        let destURL = project.root.appendingPathComponent(destRel)
        guard FileManager.default.fileExists(atPath: destURL.path) else {
            FileHandle.standardError.write(Data("no such file: \(destRel)\n".utf8))
            throw ExitCode(1)
        }

        var srcData = try EditOps.verifiedContents(
            rel: srcRel, expecting: src.string("file_sha256"), root: project.root)
        guard offset >= 0, length >= 0, offset + length <= srcData.count else {
            FileHandle.standardError.write(Data("stale offsets for \(declId) — run `code-monkey index`\n".utf8))
            throw ExitCode(1)
        }

        let payload = srcData.subdata(in: ClipCmd.cutPayloadRange(
            in: srcData, declOffset: offset, declLength: length))
        let removal = ClipCmd.cutRange(in: srcData, declOffset: offset, declLength: length)

        // Where it lands.
        let sameFile = destRel == srcRel
        var destData = sameFile
            ? srcData
            : try EditOps.verifiedContents(rel: destRel, expecting: nil, root: project.root)

        let srcIndent = ClipCmd.lineIndent(
            of: srcData, at: ClipCmd.cutPayloadRange(
                in: srcData, declOffset: offset, declLength: length).lowerBound)

        var insertRange: Range<Int>
        var indent: String
        var trailer = ""
        if let after {
            let anchor = try await EditOps.resolveOne(
                pattern: after, fileFilter: destRel, db: db, what: "--after anchor")
            let anchorOffset = Int(anchor.int64("decl_offset") ?? 0)
            let anchorLength = Int(anchor.int64("decl_length") ?? 0)
            guard !(sameFile && anchorOffset == offset) else {
                FileHandle.standardError.write(Data("--after names the decl being moved\n".utf8))
                throw ExitCode(1)
            }
            guard anchorOffset + anchorLength <= destData.count else {
                FileHandle.standardError.write(Data("stale offsets in \(destRel) — run `code-monkey index`\n".utf8))
                throw ExitCode(1)
            }
            let at = anchorOffset + anchorLength
            insertRange = at..<at
            indent = ClipCmd.lineIndent(of: destData, at: anchorOffset)
        } else {
            // Append at end of file, absorbing whatever trailing newlines are there so
            // the result is exactly one blank line and one terminating newline.
            var end = destData.count
            while end > 0, destData[destData.startIndex + end - 1] == 0x0A
                        || destData[destData.startIndex + end - 1] == 0x0D { end -= 1 }
            insertRange = end..<destData.count
            indent = ""
            trailer = "\n"
        }

        // Nothing precedes an insertion at offset 0, so it takes no separator.
        var insert = Data(insertRange.lowerBound == 0 ? "".utf8 : "\n\n".utf8)
        insert.append(EditOps.reindent(
            ClipCmd.trimmingTrailingNewlines(payload), from: srcIndent, to: indent))
        insert.append(Data(trailer.utf8))

        if sameFile {
            guard !removal.contains(insertRange.lowerBound) else {
                FileHandle.standardError.write(Data("destination lies inside the decl being moved\n".utf8))
                throw ExitCode(1)
            }
            srcData = EditOps.apply([(insertRange, insert), (removal, Data())], to: srcData)
            try srcData.write(to: project.root.appendingPathComponent(srcRel))
        } else {
            destData = EditOps.apply([(insertRange, insert)], to: destData)
            srcData = EditOps.apply([(removal, Data())], to: srcData)
            try destData.write(to: destURL)
            try srcData.write(to: project.root.appendingPathComponent(srcRel))
        }

        _ = try await Indexer(project: project, db: db).run(full: false)
        let where_ = after.map { " after \($0)" } ?? ""
        FileHandle.standardError.write(Data("moved \(declId) to \(destRel)\(where_)\n".utf8))
    }
}

// MARK: - rename

struct RenameCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a declaration and report the call sites that may refer to it.")

    @OptionGroup var opts: GlobalOptions
    @Argument var pattern: String
    @Option(name: .long, help: "New name. Must be a bare Swift identifier.") var to: String
    @Option(name: .long, help: "Restrict the match to this file.") var file: String?

    mutating func run() async throws {
        guard EditOps.isIdentifier(to) else {
            FileHandle.standardError.write(Data("`\(to)` is not a Swift identifier\n".utf8))
            throw ExitCode(1)
        }
        let (project, db, _) = try await opts.openIndex(
            command: "rename", tier: "write", target: pattern, writable: true)

        let row = try await EditOps.resolveOne(
            pattern: pattern, fileFilter: file.map { relativePath($0, root: project.root) },
            db: db, what: "decl")
        let rel = row.string("file_path") ?? ""
        let declId = row.string("decl_id") ?? ""
        let rowId = row.int64("id") ?? 0
        let offset = Int(row.int64("decl_offset") ?? 0)
        let length = Int(row.int64("decl_length") ?? 0)

        let target = try await EditOps.callTarget(rowId: rowId, db: db)
        let oldName = target?.name ?? ""
        guard !oldName.isEmpty else {
            FileHandle.standardError.write(Data("cannot determine current name of \(declId)\n".utf8))
            throw ExitCode(1)
        }
        guard oldName != to else {
            FileHandle.standardError.write(Data("\(declId) is already named `\(to)`\n".utf8))
            throw ExitCode(1)
        }

        var data = try EditOps.verifiedContents(
            rel: rel, expecting: row.string("file_sha256"), root: project.root)
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            FileHandle.standardError.write(Data("stale offsets for \(declId) — run `code-monkey index`\n".utf8))
            throw ExitCode(1)
        }
        guard let at = EditOps.nameOffset(
            in: data, declRange: offset..<(offset + length), name: oldName) else {
            FileHandle.standardError.write(Data("cannot locate `\(oldName)` inside \(declId)\n".utf8))
            throw ExitCode(1)
        }

        // Collect references *before* the edit — the call graph is keyed on the old name.
        let graph = CallGraph(db: db)
        let indexed = try await graph.callSitesIndexed()
        var edges: [CallEdge] = []
        if indexed, let target {
            edges = try await graph.callers(of: target, includeRefs: true)
        }

        data = EditOps.apply(
            [(at..<(at + oldName.utf8.count), Data(to.utf8))], to: data)
        try data.write(to: project.root.appendingPathComponent(rel))
        _ = try await Indexer(project: project, db: db).run(full: false)

        FileHandle.standardError.write(Data("renamed \(declId) to `\(to)` in \(rel)\n".utf8))
        report(edges: edges, indexed: indexed, oldName: oldName)
    }

    /// References are reported, never rewritten.
    //# ai:warn: do not "finish" this by editing the sites. call_sites stores a line
    //#          number and no byte offset, so there is nothing to patch precisely, and
    //#          every edge is a graded syntactic guess — rewriting a medium or low one
    //#          renames unrelated code. Reporting is the honest surface; a semantic
    //#          index (swiftmind) is what an automatic update would need.
    private func report(edges: [CallEdge], indexed: Bool, oldName: String) {
        guard indexed else {
            print("call sites are not indexed — cannot list references. See `code-monkey calls --help`.")
            return
        }
        guard !edges.isEmpty else {
            print("no call sites reference `\(oldName)`.")
            return
        }
        print("\(edges.count) site\(edges.count == 1 ? "" : "s") may reference `\(oldName)` — none were changed:")
        for e in edges {
            let times = e.occurrences > 1 ? " ×\(e.occurrences)" : ""
            let via = e.receiver.map { " via \($0)" } ?? ""
            print("  [\(e.confidence.label)] \(e.file):\(e.line)  \(e.target.declId)\(via)\(times)")
        }
        print("Each is a syntactic guess. Fix them with `clip`, or use `swiftmind` for semantic answers.")
    }
}
