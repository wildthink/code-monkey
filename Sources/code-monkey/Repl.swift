import ArgumentParser
import CommandREPL
import LineEditor

//# ai:section: "Repl"

// MARK: - repl

/// An interactive shell over the same command tree the CLI exposes.
///
/// Built on `CommandREPL`, which derives completion from `_dumpHelp()` — the same
/// `ToolInfoV0` dump `--experimental-dump-help` prints. Nothing here declares a command,
/// an option, or a value: every one of them is read back off the definitions in
/// `Commands.swift`, `Get.swift`, `Code.swift`, and `CallGraph.swift`.
///
/// This does not use `CommandREPLRunner.run()`, which owns its own loop. Dispatch has to be
/// wrapped — for argv normalization, envelope labelling, and stdin-reading commands — so the
/// loop lives here and the package's pieces are composed by hand.
struct ReplCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repl",
        abstract: "Interactive shell. Tab completes commands, options, and their values.",
        discussion: """
        EXAMPLES
          code get --ki<Tab>                  option-name completion
          calls Walker --min <Tab>            value completion, with descriptions
          .form get                           fill a command in field by field
          .help                               the command tree
          .exit                               leave (or Ctrl-D)
        """)

    @Option(name: .long, help: "History file. Default: ~/.code-monkey_history")
    var history: String?

    func run() async throws {
        try await Session(historyPath: history).run()
    }
}

/// The read/dispatch loop. `@MainActor` because the line editor owns terminal state and must
/// not be driven from two places at once.
@MainActor
private struct Session {
    let historyPath: String?
    let model: CommandModel

    /// Handled here rather than by the command tree.
    static let metaCommands = [".exit", ".quit", ".help", ".form"]

    init(historyPath: String?) throws {
        self.historyPath = historyPath
        self.model = try CommandModel(CodeMonkey.self)
    }

    func run() async {
        let editor = LineEditor(
            historyFile: historyPath ?? LineEditor.homeHistoryFile(prefix: CodeMonkey._commandName))
        install(on: editor)

        if !editor.isDumb {
            print("\(CodeMonkey._commandName) \(BuildInfo.version) — Tab completes, "
                  + "`.form <cmd>` fills a command in, `.help` lists commands, Ctrl-D quits.")
        }

        await editor.readEvaluateLoop(prompt: "\(CodeMonkey._commandName) > ") { line in
            await evaluate(line: line, editor: editor)
        }
    }

    private func install(on editor: LineEditor) {
        editor.setCompletionProvider(
            CommandCompletionProvider(
                root: CodeMonkey.self, model: model, metaCommands: Self.metaCommands))
    }

    // MARK: one line

    private func evaluate(line: String, editor: LineEditor) async -> LineEditor.Action {
        let words = Tokenizer.tokens(in: line).map(\.text)
        guard let first = words.first else { return .step }

        switch first {
        case ".exit", ".quit":
            return .exit
        case ".help":
            // The root help screen, exactly as `code-monkey --help` renders it. For one
            // command, `<name> --help` already works and goes through `report`.
            print(CodeMonkey.helpMessage())
        case ".form":
            await runForm(path: Array(words.dropFirst()), editor: editor)
        default:
            await dispatch(argv: words)
        }
        return .step
    }

    /// Parses and runs one line against the real command tree.
    ///
    /// The wrapping is the reason this loop exists: `-L2` has to be split apart the same way
    /// `main()` splits it, the JSON envelope has to be told which command is running, and a
    /// command that would read stdin has to be turned away before it eats the session.
    private func dispatch(argv: [String]) async {
        if argv.first == ReplCmd.configuration.commandName {
            print("Already in the shell.")
            return
        }
        if let blocked = ReplGuards.stdinCommand(matching: argv) {
            let name = blocked.joined(separator: " ")
            print("`\(name)` reads its payload from standard input, which this shell is reading.")
            print("Run it from your own shell: \(CodeMonkey._commandName) \(argv.joined(separator: " ")) < file")
            return
        }

        let normalized = CodeMonkey.normalized(argv)
        CommandContext.set(normalized.first)
        defer { CommandContext.set(nil) }

        // `CodeMonkey.dispatch` runs and records; `report` prints what escapes, mirroring
        // `exit(withError:)` minus the exiting — which is why the shell cannot just call
        // `evaluateAsRoot`, whose do/catch has no seam to record the outcome in.
        do {
            try await CodeMonkey.dispatch(argv: normalized)
        } catch {
            CodeMonkey.report(error: error)
        }
    }

    /// Fills a command out field by field, then runs the argv it produces.
    private func runForm(path: [String], editor: LineEditor) async {
        let (command, consumed) = model.resolve(path: path)
        guard consumed.count == path.count else {
            print("Unknown command: \(path.joined(separator: " "))")
            return
        }
        guard command.visibleSubcommands.isEmpty else {
            let names = command.visibleSubcommands.map(\.commandName).joined(separator: ", ")
            print("`\(command.commandName)` has subcommands: \(names)")
            print("Use `.form \(path.joined(separator: " ")) <subcommand>`.")
            return
        }

        let form = CommandForm(root: CodeMonkey.self, model: model, path: consumed, command: command)
        guard let argv = form.run(editor: editor) else {
            print("Cancelled.")
            return
        }
        print("> \(argv.map(Tokenizer.quoteIfNeeded).joined(separator: " "))")
        await dispatch(argv: argv)

        // The form swapped in its own per-field provider; put the line-level one back.
        install(on: editor)
    }
}

/// Line-level guards, kept out of `Session` so they can be tested without a terminal.
enum ReplGuards {
    /// Commands that read their payload from standard input. In a shell, standard input is the
    /// terminal the line editor is reading, so running one consumes the session and hangs.
    //# ai:invariant: one entry per command whose `run()` calls `readDataToEndOfFile`
    static let stdinCommands: [[String]] = [["clip"], ["file", "write"], ["file", "append"]]

    /// The matched command, or nil when `argv` is safe to run in-process.
    static func stdinCommand(matching argv: [String]) -> [String]? {
        stdinCommands.first { argv.starts(with: $0) }
    }
}
