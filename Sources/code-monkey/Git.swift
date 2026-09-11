import Foundation

//# ai:section: "Git"

/// The only part of this tool that reads anything other than the index and the working tree.
///
/// Change history is the one question the index cannot answer at all: it records what the code
/// *is*, and a row carries no memory of what it displaced. Git already knows, going back years,
/// so `stats --since` asks git rather than growing a history table that would start empty and
/// stay useless for months.
//# ai:invariant: read-only — every invocation here is `log`, `diff`, `show` or `rev-parse`
//# ai:warn: the only subprocess use in the CLI; everything else runs in-process against SQLite
enum Git {

    struct Repository: Sendable {
        let root: URL
        let head: String
        let isShallow: Bool
        /// Where the project sits inside the repository, `""` when they are the same directory.
        ///
        /// Git reports paths from the repository top level and the index stores them from the
        /// project root. A project in a subdirectory of a monorepo makes those two disagree, and
        /// nothing in either string says so — the join simply matches nothing.
        //# ai:invariant: every path crossing this boundary goes through `gitPath`/`indexPath`
        let prefix: String

        func gitPath(fromIndex path: String) -> String {
            prefix.isEmpty ? path : prefix + "/" + path
        }

        /// Nil for a path outside the project, which a repository-wide `log` will return.
        func indexPath(fromGit path: String) -> String? {
            guard !prefix.isEmpty else { return path }
            guard path.hasPrefix(prefix + "/") else { return nil }
            return String(path.dropFirst(prefix.count + 1))
        }
    }

    struct Commit: Sendable {
        let sha: String
        let timestamp: Date
        let author: String
    }

    /// A contiguous run of lines on the *new* side of a diff, in the coordinates the working
    /// tree uses right now — which is what makes the join against `declarations.start_line`
    /// legal without re-indexing anything.
    //# ai:invariant: `start`/`end` are new-side line numbers, never the pre-image's
    struct Hunk: Sendable {
        let path: String
        let start: Int
        let end: Int
    }

    struct Change: Sendable {
        /// `A`, `M`, `D`, or `R` — added, modified, deleted, renamed.
        let status: String
        let path: String
        /// The pre-image path, which differs from `path` only across a rename.
        let oldPath: String
    }

    struct FileChurn: Sendable {
        var path: String
        var commits: Int = 0
        var authors: Set<String> = []
        var insertions: Int = 0
        var deletions: Int = 0
        var lastChange: Date?
        /// Commit counts per time bucket, oldest first, for a sparkline.
        var buckets: [Int] = []
    }

    // MARK: - running git

    enum Failure: Error, CustomStringConvertible {
        case notARepository(String)
        case unknownRef(String)
        case launchFailed(String)

        var description: String {
            switch self {
            case .notARepository(let path): "not a git repository: \(path)"
            case .unknownRef(let ref): "unknown git ref: \(ref)"
            case .launchFailed(let message): "could not run git: \(message)"
            }
        }
    }

    /// Runs git and returns stdout, or nil when git exits non-zero.
    ///
    /// Standard error goes to the null device rather than a second pipe. Draining one pipe while
    /// a subprocess fills another deadlocks once the unread one hits its buffer, and `git log`
    /// over a large history produces megabytes. Callers that need a *reason* for a failure ask
    /// `rev-parse` first, whose output is one line.
    //# ai:warn: never attach a stderr Pipe here without draining it concurrently — that deadlocks
    static func run(_ arguments: [String], in directory: URL) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(String(describing: error))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func line(_ arguments: [String], in directory: URL) throws -> String? {
        try run(arguments, in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when `root` is not inside a git repository, which is a fact to report rather than an
    /// error to throw: the rest of `stats` works fine without one.
    static func discover(root: URL) throws -> Repository? {
        guard let top = try line(["rev-parse", "--show-toplevel"], in: root), !top.isEmpty,
              let head = try line(["rev-parse", "HEAD"], in: root)
        else { return nil }
        let shallow = try line(["rev-parse", "--is-shallow-repository"], in: root) == "true"
        let topPath = URL(fileURLWithPath: top).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasPrefix(topPath + "/")
            ? String(rootPath.dropFirst(topPath.count + 1))
            : ""
        return Repository(root: URL(fileURLWithPath: topPath),
                          head: head,
                          isShallow: shallow,
                          prefix: prefix)
    }

    static func resolve(ref: String, in repo: Repository) throws -> String? {
        try line(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: repo.root)
    }

    // MARK: - history

    /// Git's numstat spelling of a rename, reduced to the post-image path.
    ///
    /// Two forms reach here: `old => new`, and the factored `dir/{old => new}/file` that git
    /// emits when only part of the path moved. Both mean the same file, and treating either as
    /// a literal path invents a file that never existed and loses the one that did.
    //# ai:why: without this, a renamed file reads as brand new and its whole history disappears
    static func postImagePath(_ raw: String) -> String {
        guard raw.contains(" => ") else { return raw }
        if let open = raw.firstIndex(of: "{"), let close = raw.firstIndex(of: "}"), open < close {
            let inner = raw[raw.index(after: open)..<close]
            let newPart = inner.components(separatedBy: " => ").last ?? ""
            let result = String(raw[raw.startIndex..<open]) + newPart + String(raw[raw.index(after: close)...])
            return result.replacingOccurrences(of: "//", with: "/")
        }
        return raw.components(separatedBy: " => ").last ?? raw
    }

    /// Per-file churn over the last `days`, bucketed for a sparkline.
    ///
    /// `-M` is not optional. This repository has nine renames in its history, and without rename
    /// detection each one reads as a file created on the day it moved, which understates the
    /// volatility of exactly the files that have been moved around the most.
    //# ai:invariant: `-M` stays, or renamed files report a falsely short history
    static func churn(
        in repo: Repository,
        days: Int,
        buckets bucketCount: Int,
        now: Date = Date()
    ) throws -> [String: FileChurn] {
        // A leading \u{1} marks a commit header, so a numstat line can never be mistaken for one:
        // a path may contain tabs and a two-field split alone would misread it.
        let marker = "\u{1}"
        guard let output = try run([
            "log", "--no-merges", "-M",
            "--format=\(marker)%H%x09%at%x09%an",
            "--numstat",
            "--since=\(days) days ago",
            "--", "*.swift",
        ], in: repo.root) else { return [:] }

        let windowStart = now.addingTimeInterval(-Double(days) * 86_400)
        let span = max(now.timeIntervalSince(windowStart), 1)
        var result: [String: FileChurn] = [:]
        var commit: Commit?
        var seenThisCommit: Set<String> = []

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix(marker) {
                let fields = raw.dropFirst().split(separator: "\t", maxSplits: 2)
                guard fields.count == 3, let seconds = TimeInterval(fields[1]) else { commit = nil; continue }
                commit = Commit(sha: String(fields[0]),
                                timestamp: Date(timeIntervalSince1970: seconds),
                                author: String(fields[2]))
                seenThisCommit = []
                continue
            }
            guard let commit, !raw.isEmpty else { continue }
            let fields = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            // "-" in place of a count is git's marker for a binary file.
            let insertions = Int(fields[0]) ?? 0
            let deletions = Int(fields[1]) ?? 0
            guard let path = repo.indexPath(fromGit: postImagePath(String(fields[2]))) else { continue }

            var entry = result[path] ?? FileChurn(path: path, buckets: Array(repeating: 0, count: bucketCount))
            entry.insertions += insertions
            entry.deletions += deletions
            entry.authors.insert(commit.author)
            // A commit that touches one file twice (a rename plus an edit) is still one commit.
            if !seenThisCommit.contains(path) {
                seenThisCommit.insert(path)
                entry.commits += 1
                let offset = commit.timestamp.timeIntervalSince(windowStart) / span
                let bucket = min(bucketCount - 1, max(0, Int(offset * Double(bucketCount))))
                entry.buckets[bucket] += 1
            }
            if entry.lastChange == nil || commit.timestamp > entry.lastChange! {
                entry.lastChange = commit.timestamp
            }
            result[path] = entry
        }
        return result
    }

    /// The most recent commit date per file, over all history rather than a window.
    ///
    /// Separate from `churn` because "untouched for two years" is the interesting answer and a
    /// windowed log cannot give it: a file with no commits inside the window is indistinguishable
    /// from a file with no commits at all.
    //# ai:why: age and churn need different windows, so they are different queries
    static func lastTouched(in repo: Repository) throws -> [String: Date] {
        let marker = "\u{1}"
        guard let output = try run([
            "log", "--no-merges", "-M", "--format=\(marker)%at", "--name-only", "--", "*.swift",
        ], in: repo.root) else { return [:] }
        var result: [String: Date] = [:]
        var stamp: Date?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix(marker) {
                stamp = TimeInterval(raw.dropFirst()).map { Date(timeIntervalSince1970: $0) }
                continue
            }
            guard let stamp, !raw.isEmpty,
                  let path = repo.indexPath(fromGit: postImagePath(String(raw)))
            else { continue }
            // The log walks newest first, so the first sighting of a path is its latest commit.
            if result[path] == nil { result[path] = stamp }
        }
        return result
    }

    // MARK: - diff against a ref

    /// Changed line ranges since `ref`, on the new side.
    ///
    /// `-U0` is what makes these ranges usable: with context lines git would widen every hunk by
    /// three lines in each direction and the join would claim neighbouring declarations that
    /// nobody touched.
    //# ai:invariant: -U0, or the hunk ranges overstate what changed
    static func hunks(since ref: String, in repo: Repository) throws -> [Hunk] {
        guard let output = try run([
            "diff", "-U0", "--no-color", "-M", ref, "--", "*.swift",
        ], in: repo.root) else { return [] }

        var hunks: [Hunk] = []
        var path: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("+++ ") {
                let target = String(raw.dropFirst(4))
                // `/dev/null` is a deletion: there is no new side to point at.
                path = target == "/dev/null" ? nil
                    : repo.indexPath(fromGit: target.hasPrefix("b/") ? String(target.dropFirst(2)) : target)
                continue
            }
            guard raw.hasPrefix("@@"), let path else { continue }
            // @@ -old,count +new,count @@ optional trailing context
            guard let plus = raw.range(of: " +") else { continue }
            let tail = raw[plus.upperBound...]
            let spec = tail.prefix(while: { $0 != " " && $0 != "@" })
            let parts = spec.split(separator: ",")
            guard let start = Int(parts[0]) else { continue }
            let count = parts.count > 1 ? (Int(parts[1]) ?? 0) : 1
            // A zero-length new side is a pure deletion; it has no lines to attribute.
            guard count > 0 else { continue }
            hunks.append(Hunk(path: path, start: start, end: start + count - 1))
        }
        return hunks
    }

    static func changes(since ref: String, in repo: Repository) throws -> [Change] {
        guard let output = try run([
            "diff", "--name-status", "-M", ref, "--", "*.swift",
        ], in: repo.root) else { return [] }
        var changes: [Change] = []
        for raw in output.split(separator: "\n") {
            let fields = raw.split(separator: "\t")
            guard fields.count >= 2, let code = fields.first?.prefix(1) else { continue }
            // A rename carries both paths; every other status carries one. `oldPath` stays in
            // git's coordinates because it is only ever handed back to `git show`.
            let isRename = code == "R" && fields.count >= 3
            let newField = String(isRename ? fields[2] : fields[1])
            guard let path = repo.indexPath(fromGit: newField) else { continue }
            changes.append(Change(status: isRename ? "R" : String(code),
                                  path: path,
                                  oldPath: String(fields[1])))
        }
        return changes
    }

    /// A file's contents at `ref`. Nil when the path did not exist there.
    static func show(_ gitPath: String, at ref: String, in repo: Repository) throws -> String? {
        try run(["show", "\(ref):\(gitPath)"], in: repo.root)
    }
}
