import ArgumentParser
import Foundation

@main
struct CodeMonkey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "code-monkey",
        abstract: "Swift code index with literate metadata. Tiered reads for AI agents.",
        subcommands: [
            InitCmd.self,
            IndexCmd.self,
            DoctorCmd.self,
            GetCmd.self,
            CodeCmd.self,
            CallsCmd.self,
            ClipCmd.self,
            QueryCmd.self,
            WeaveCmd.self,
            ImportsCmd.self,
            FileCmd.self,
            ReplCmd.self,
            VersionCmd.self,
        ],
        defaultSubcommand: nil
    )

    /// ArgumentParser does not join a short option to its value, but `-L2` is what anyone
    /// dialling a disclosure rung actually types. Split it back apart before parsing.
    ///
    /// Every dispatch path has to go through here, not just `main()` — the REPL parses lines
    /// the process argv never sees.
    //# ai:invariant: only `-L` followed by digits is rewritten; every other argument passes through
    static func normalized(_ argv: some Sequence<String>) -> [String] {
        argv.flatMap { arg -> [String] in
            guard arg.count > 2, arg.hasPrefix("-L"), arg.dropFirst(2).allSatisfy(\.isNumber) else { return [arg] }
            return ["-L", String(arg.dropFirst(2))]
        }
    }

    static func main() async {
        let argv = normalized(CommandLine.arguments.dropFirst())
        do {
            try await dispatch(argv: argv)
        } catch {
            exit(withError: error)
        }
    }

    /// Parse, run, and record. This is the expansion of `AsyncParsableCommand.main(_:)` with
    /// one line added — and the expansion exists only so that line has somewhere to live: argv,
    /// the working directory, and the outcome are all visible here and nowhere inside `run()`.
    ///
    /// Errors are rethrown rather than reported, because the two callers end differently: the
    /// process exits, the REPL prints and reads another line.
    //# ai:invariant: every dispatch path writes exactly one invocation entry, success or not
    static func dispatch(argv: [String]) async throws {
        let started = ContinuousClock.now
        func record(_ status: String) {
            let elapsed = started.duration(to: .now).components
            AuditLog.record(argv: argv,
                            cwd: FileManager.default.currentDirectoryPath,
                            status: status,
                            ms: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000))
        }
        do {
            var command = try await asyncParseAsRoot(argv)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            record("ok")
        } catch {
            // `--help` and the completion scripts leave through this path too, and they exit 0.
            // Calling those failures would put every help request in `--failed`.
            let code = exitCode(for: error).rawValue
            record(code == 0 ? "ok" : "exit \(code)")
            throw error
        }
    }
}

// MARK: Version command
struct VersionCmd: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "version"
      )

      func run() async throws {
        print("code-monkey VERSION \(BuildInfo.version)")
        print("BUILD \(BuildInfo.buildDate) #\(BuildInfo.buildSeq)")
      }
}

/// Shared options every command honors.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Project root override. Default: walk up to find .code-monkey.toml or .code-monkey/.")
    var project: String?

    @Flag(name: .long, help: "Emit JSON instead of text.")
    var json: Bool = false

    func resolveProject() throws -> Project {
        try Project.load(explicitRoot: project)
    }

    /// `schemaWasReset` is true when an index built by an older schema was discarded to make
    /// room for the current one — only `index` allows that, and only it needs to know.
    func openIndex(
        command: String,
        tier: String,
        target: String? = nil,
        writable: Bool = false
    ) async throws -> (project: Project, db: Database, schemaWasReset: Bool) {
        let project = try resolveProject()
        CommandContext.note(["tier=\(tier)", target.map { "target=\($0)" }]
            .compactMap { $0 }
            .joined(separator: " "))
        let db = try Database(path: project.dbPath, mode: writable ? .readWrite : .readOnly)
        var reset = false
        if writable {
            reset = try await Schema.bootstrap(db, allowReset: command == "index")
        }
        return (project, db, reset)
    }
}
