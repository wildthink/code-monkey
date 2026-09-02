// code-monkey MCP server (`code-monkey-mcp`).
//
// Exposes the CLI's commands as MCP tools over stdio. Every tool shells out to the
// `code-monkey` binary (same process model as the CLI: open index, answer, exit) and forwards
// its stdout as the tool result. No logic is duplicated here, and — since this file stopped
// transcribing them — no argument schemas either: `ToolBridge` reads the command tree out of
// `code-monkey --experimental-dump-help` at startup, so the tools are whatever the CLI declares.
//
// What is left in this file is process plumbing: run the dump, wire the server, run a tool.

import ArgumentParser
import ArgumentParserToolInfo
import Foundation
import MCP

@main
struct CodeMonkeyMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "code-monkey-mcp",
        abstract: "code-monkey MCP server — one tool per CLI command, over stdio.")

    @Option(name: .long, help: "Default project root when a tool call omits `project`.")
    var project: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Path to the code-monkey executable. Default: sibling of this binary.")
    var codeMonkeyBin: String?

    @Option(name: .long, help: """
        Narrow the advertised tool surface: all | read | nav | write. Every tool schema is \
        prompt context the client pays for on every turn, so a session that only reads should \
        not be quoted the write tools. Unknown names fail rather than silently serving `all`.
        """)
    var profile: String = ProcessInfo.processInfo.environment["CODE_MONKEY_TOOL_PROFILE"] ?? "all"

    func run() async throws {
        let runner = CLIRunner(defaultRoot: project, binPath: codeMonkeyBin)
        let bridge = ToolBridge(root: try Self.commandTree(runner: runner), policy: ToolPolicy())
        let allTools = bridge.tools()

        // Profiles name tools by hand, and the names are derived now — so a renamed subcommand
        // would quietly empty a profile rather than fail. Refuse to start instead.
        let dangling = bridge.policy.danglingProfileNames(against: allTools)
        guard dangling.isEmpty else {
            throw ValidationError("""
                profile lists \(dangling.count) tool(s) the command tree no longer has: \
                \(dangling.joined(separator: ", ")). Update ToolPolicy.Profile.
                """)
        }
        guard let tools = bridge.policy.tools(allTools, profile: profile) else {
            throw ValidationError("unknown --profile: \(profile) — expected "
                                  + ToolPolicy.Profile.allNames.joined(separator: " | "))
        }

        let server = Server(
            name: "code-monkey",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                let text = try Self.run(tool: params.name, arguments: params.arguments ?? [:],
                                        bridge: bridge, runner: runner)
                return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
            } catch {
                return .init(content: [.text(text: "\(error)", annotations: nil, _meta: nil)], isError: true)
            }
        }

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// Reads the CLI's own description of itself.
    ///
    /// `--experimental-dump-help` is ArgumentParser's public JSON dump in the versioned
    /// `ToolInfoV0` schema, and it already recurses the whole subcommand tree.
    //# ai:why: shelling out keeps this target from linking `code-monkey`, so the server still
    //# ai:why: knows nothing about the CLI beyond the binary's path and its output
    static func commandTree(runner: CLIRunner) throws -> CommandInfoV0 {
        let result = try runner.run(["--experimental-dump-help"], cwd: runner.defaultRoot, stdin: nil)
        guard result.code == 0 else {
            let message = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerError(message: "could not read the command tree from \(runner.binURL.path): "
                              + (message.isEmpty ? "exited \(result.code)" : message))
        }
        do {
            return try JSONDecoder().decode(ToolInfoV0.self, from: Data(result.out.utf8)).command
        } catch {
            throw ServerError(message: "could not decode \(runner.binURL.path) "
                              + "--experimental-dump-help: \(error)")
        }
    }

    /// `project` selects the working directory for every tool, which is how commands that
    /// declare no `--project` of their own (`init`, `file`) still reach a project.
    static func run(tool: String, arguments: [String: Value],
                    bridge: ToolBridge, runner: CLIRunner) throws -> String {
        let (argv, stdin) = try bridge.invocation(for: tool, arguments: arguments)
        let cwd = arguments["project"]?.stringValue ?? runner.defaultRoot
        let result = try runner.run(argv, cwd: cwd, stdin: stdin)
        guard result.code == 0 else {
            let message = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerError(message: message.isEmpty ? "code-monkey exited \(result.code)" : message)
        }
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ServerError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Runs `code-monkey` as a subprocess and captures its output. Stateless —
/// each call opens and closes its own SQLite handle, exactly like running the
/// CLI directly, so there is nothing here to cache between calls.
struct CLIRunner: Sendable {
    let defaultRoot: String
    let binURL: URL

    init(defaultRoot: String, binPath: String?) {
        self.defaultRoot = defaultRoot
        if let binPath {
            binURL = URL(fileURLWithPath: binPath)
        } else {
            let selfURL = URL(fileURLWithPath: CommandLine.arguments[0])
            binURL = selfURL.deletingLastPathComponent().appendingPathComponent("code-monkey")
        }
    }

    func run(_ args: [String], cwd: String, stdin: String?) throws -> (out: String, err: String, code: Int32) {
        guard FileManager.default.isExecutableFile(atPath: binURL.path) else {
            throw ServerError(message: "code-monkey binary not found/executable at \(binURL.path) — pass --code-monkey-bin")
        }
        let process = Process()
        process.executableURL = binURL
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try inPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }
}
