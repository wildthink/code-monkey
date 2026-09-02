import Foundation

/// Enumerates Swift sources under the configured roots, respecting
/// `exclude` globs and (optionally) `.gitignore`.
struct Walker {
    let project: Project

    func enumerateSwiftFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var ignore = GitIgnore()
        if project.config.index.followGitignore {
            ignore.load(rootedAt: project.root)
        }
        for sub in project.config.sources {
            let base = project.root.appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: base.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if base.pathExtension == "swift", !isExcluded(base) { out.append(base) }
                continue
            }
            guard let it = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in it {
                let rel = relPath(url)
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if isExcluded(url) || ignore.matches(path: rel, isDir: true) {
                        it.skipDescendants()
                    }
                    continue
                }
                guard url.pathExtension == "swift" else { continue }
                if isExcluded(url) { continue }
                if ignore.matches(path: rel, isDir: false) { continue }
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    private func relPath(_ url: URL) -> String {
        let r = project.root.standardizedFileURL.path
        let u = url.standardizedFileURL.path
        if u.hasPrefix(r + "/") { return String(u.dropFirst(r.count + 1)) }
        return u
    }

    private func isExcluded(_ url: URL) -> Bool {
        let rel = relPath(url)
        for pat in project.config.exclude {
            if Glob.match(pattern: pat, path: rel) { return true }
        }
        return false
    }
}

//# ai:section: "Globbing"
/// Minimal glob: supports `*`, `?`, `**`, character classes `[...]`.
/// Patterns are matched against forward-slash paths.
//# ai:spec: `*` matches anything except `/`; `**` matches zero or more path segments; `?` matches one non-`/` char; `[abc]` and `[!abc]` are character classes; `[a-z]` is a range
//# ai:warn: do not extend to full POSIX glob — minimal-on-purpose; reach for a library if needed
enum Glob {
    static func match(pattern: String, path: String) -> Bool {
        matchImpl(Array(pattern), 0, Array(path), 0)
    }

    private static func matchImpl(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> Bool {
        var pi = pi, si = si
        while pi < p.count {
            let c = p[pi]
            if c == "*" {
                let isDouble = pi + 1 < p.count && p[pi + 1] == "*"
                if isDouble {
                    // `**` matches any number of path segments (including zero).
                    // `**/` consumes trailing slash too.
                    var skip = 2
                    if pi + 2 < p.count && p[pi + 2] == "/" { skip = 3 }
                    let next = pi + skip
                    if next >= p.count { return true }
                    for k in si...s.count {
                        if matchImpl(p, next, s, k) { return true }
                    }
                    return false
                } else {
                    // single * matches anything except '/'
                    if pi + 1 == p.count {
                        return !s[si...].contains("/")
                    }
                    for k in si...s.count {
                        if k > si, s[si..<k].contains("/") { break }
                        if matchImpl(p, pi + 1, s, k) { return true }
                    }
                    return false
                }
            } else if c == "?" {
                if si >= s.count || s[si] == "/" { return false }
                pi += 1; si += 1
            } else if c == "[" {
                guard si < s.count else { return false }
                // find closing ]
                var j = pi + 1
                var negate = false
                if j < p.count && p[j] == "!" { negate = true; j += 1 }
                var matched = false
                while j < p.count && p[j] != "]" {
                    if j + 2 < p.count && p[j + 1] == "-" {
                        if s[si] >= p[j] && s[si] <= p[j + 2] { matched = true }
                        j += 3
                    } else {
                        if s[si] == p[j] { matched = true }
                        j += 1
                    }
                }
                if negate { matched = !matched }
                if !matched { return false }
                pi = j + 1; si += 1
            } else {
                if si >= s.count || s[si] != c { return false }
                pi += 1; si += 1
            }
        }
        return si == s.count
    }
}

/// Minimal .gitignore: line-based, supports negation (`!`), trailing `/` (dir-only),
/// leading `/` (anchored to root), and glob syntax via `Glob`.
/// Only loads the project-root `.gitignore`; nested gitignores ignored for simplicity.
struct GitIgnore {
    private struct Rule {
        let pattern: String
        let negate: Bool
        let dirOnly: Bool
        let anchored: Bool
    }
    private var rules: [Rule] = []

    mutating func load(rootedAt root: URL) {
        let url = root.appendingPathComponent(".gitignore")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var negate = false
            if line.hasPrefix("!") { negate = true; line.removeFirst() }
            var anchored = false
            if line.hasPrefix("/") { anchored = true; line.removeFirst() }
            var dirOnly = false
            if line.hasSuffix("/") { dirOnly = true; line.removeLast() }
            rules.append(Rule(pattern: line, negate: negate, dirOnly: dirOnly, anchored: anchored))
        }
    }

    func matches(path: String, isDir: Bool) -> Bool {
        var ignored = false
        for r in rules {
            if r.dirOnly && !isDir { continue }
            let pat = r.anchored ? r.pattern : "**/" + r.pattern
            if Glob.match(pattern: pat, path: path) || Glob.match(pattern: r.pattern, path: path) {
                ignored = !r.negate
            }
        }
        return ignored
    }
}
