import Foundation
import TOMLKit

//# ai:section: "Project"
/// Resolved project context: root, config, paths.
//# ai:invariant: root walk-up stops at the nearest `.code-monkey.toml` or `.code-monkey/` directory
//# ai:invariant: a project with no config files falls back to the start dir + defaults
struct Project: Sendable {
    let root: URL
    let config: Config

    var dbPath: URL { root.appendingPathComponent(config.index.path) }
    var dbDir: URL { dbPath.deletingLastPathComponent() }

    /// Walks up from `explicitRoot` (or cwd) to find the project root.
    /// Root marker: `.code-monkey.toml` or `.code-monkey/` directory.
    /// If neither found, the walk-up start dir is used and default config is returned.
    static func load(explicitRoot: String?) throws -> Project {
        let start: URL = if let p = explicitRoot {
            URL(fileURLWithPath: p, isDirectory: true)
        } else {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }
        let root = findRoot(from: start) ?? start
        let cfg = try Config.load(at: root)
        return Project(root: root, config: cfg)
    }

    private static func findRoot(from start: URL) -> URL? {
        var dir = start.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<32 {
            let toml = dir.appendingPathComponent(".code-monkey.toml")
            let dot = dir.appendingPathComponent(".code-monkey")
            if fm.fileExists(atPath: toml.path) { return dir }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dot.path, isDirectory: &isDir), isDir.boolValue { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }
}

/// Persistent project config. Loaded from `.code-monkey.toml`. Defaults applied for missing keys.
struct Config: Sendable {
    /// Matches `defaultTOML`. These two disagreed: `init` wrote `["Sources", "Tests"]` while a
    /// project without a config file silently indexed `Sources` alone — so "no test exercises
    /// this" was sometimes a fact about the config rather than about the code.
    //# ai:why: anything that reasons about test coverage has to be able to trust that absence
    var sources: [String] = ["Sources", "Tests"]
    var exclude: [String] = ["**/.build/**", "**/.git/**", "**/DerivedData/**"]
    var index: IndexConfig = IndexConfig()
    var parse: ParseConfig = ParseConfig()
    var audit: String? = nil

    struct IndexConfig: Sendable {
        var path: String = ".code-monkey/index.db"
        var followGitignore: Bool = true
    }

    struct ParseConfig: Sendable {
        var includePrivate: Bool = true
        var extractDocComments: Bool = true
        var extractAIDirectives: Bool = true
        /// Call sites are by far the bulkiest thing indexed — roughly four rows per declaration,
        /// which on a mid-size project is most of the database file. Turning this off costs you
        /// `calls` and `get --fields callers,callees` and nothing else.
        var extractCallSites: Bool = true
    }

    static func load(at root: URL) throws -> Config {
        let url = root.appendingPathComponent(".code-monkey.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let text = try String(contentsOf: url, encoding: .utf8)
        let table = try TOMLTable(string: text)
        var cfg = Config()
        if let arr = table["sources"]?.array {
            cfg.sources = arr.compactMap { $0.string }
        }
        if let arr = table["exclude"]?.array {
            cfg.exclude = arr.compactMap { $0.string }
        }
        if let idx = table["index"]?.table {
            if let p = idx["path"]?.string { cfg.index.path = p }
            if let g = idx["follow_gitignore"]?.bool { cfg.index.followGitignore = g }
        }
        if let p = table["parse"]?.table {
            if let v = p["include_private"]?.bool { cfg.parse.includePrivate = v }
            if let v = p["extract_doc_comments"]?.bool { cfg.parse.extractDocComments = v }
            if let v = p["extract_ai_directives"]?.bool { cfg.parse.extractAIDirectives = v }
            if let v = p["extract_call_sites"]?.bool { cfg.parse.extractCallSites = v }
        }
        cfg.audit = table["audit"]?.string

        return cfg
    }

    static let defaultTOML: String = """
    # code-monkey project config. Run `code-monkey --help` for the full reference.
    sources = ["Sources", "Tests"]
    exclude = ["**/.build/**", "**/.git/**", "**/DerivedData/**", "**/Generated/**"]
    audit = ".code-monkey/audit.log"

    [index]
    path = ".code-monkey/index.db"
    follow_gitignore = true

    [parse]
    include_private = true
    extract_doc_comments = true
    extract_ai_directives = true

    # Powers `calls` and `get --fields callers,callees`. Roughly quadruples the
    # index file; set false if you don't need the call graph.
    extract_call_sites = true
    """
}

// MARK: - Test convention

/// Where the project's test code lives, by convention alone.
///
/// Shared so `code` and `calls` cannot drift apart on what counts as a test. It is a
/// convention, never a fact: nothing in the index records intent, and `@Test` marks the test
/// *functions* rather than the helpers and fixtures beside them.
//# ai:warn: purely conventional — a test named outside the convention reads as production
//# ai:why: used only to order and label output, never to omit it, so a miss costs attention
//# ai:why: rather than correctness — do not promote this to a filter
enum TestConvention {
    /// A `Tests` directory component is how SPM says it, and it covers the helpers and
    /// fixtures that carry no test attribute at all.
    static func isTestPath(_ file: String) -> Bool {
        file.split(separator: "/").contains { $0 == "Tests" || $0.hasSuffix("Tests") }
    }

    /// Catches an XCTest case or a swift-testing suite living outside such a directory.
    static func isTestContainer(_ container: String?) -> Bool {
        guard let container else { return false }
        return container.hasSuffix("Tests") || container.hasSuffix("TestCase")
    }
}
