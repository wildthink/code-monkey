import Foundation
import MCP

// MARK: - policy

/// The code-monkey-specific half of the bridge: everything `ToolInfoV0` cannot say.
///
/// Each table exists because the dump is silent on something, not because the CLI shape was
/// disliked. Keep it that way — anything derivable belongs in `ToolBridge`.
//# ai:section: "Bridge"
struct ToolPolicy: Sendable {
    /// A property the CLI does not declare as an argument.
    struct ExtraArgument: Sendable {
        let key: String
        let schema: Value
        let isRequired: Bool
    }

    /// Not commands: `repl` is an interactive shell, which an MCP client can never drive, and
    /// `help` is ArgumentParser's own.
    let excludedCommands: Set<String> = ["repl", "help"]

    /// `--json` is the server's business, not the client's — every tool that emits structured
    /// output gets it injected below, and offering it as a parameter only invites turning it off.
    private let alwaysHidden: Set<String> = ["json"]

    /// Integers. The tool info schema carries no value types at all, so this is the one gap that
    /// cannot be closed by reading harder.
    //# ai:invariant: every `Int`/`Int?` option in the CLI appears here, or it types as a string
    let integerArguments: Set<String> = ["limit", "offset", "depth", "level", "last"]

    /// Options whose single string holds a comma-separated list. Such a value can never satisfy
    /// a JSON Schema `enum` over its members, so these are treated as open sets too.
    let commaSplitArguments: Set<String> = ["keep", "fields"]

    /// Arguments whose advertised values are examples rather than the whole set.
    ///
    /// ArgumentParser's `allValueStrings` is documentation — its own guidance is that the list
    /// "does not need to be exhaustive" — but a JSON Schema `enum` is a hard constraint. Naming
    /// the open ones here is what keeps a partial list from becoming a validating one.
    //# ai:invariant: any `ExpressibleByArgument` that accepts values outside `allValueStrings`
    //# ai:invariant: must appear here, or clients will be told a legal value is invalid
    let openValueArguments: Set<String> = ["spi"]

    func toolName(for path: [String]) -> String {
        (["code", "monkey"] + path.map(ToolBridge.snakeCased)).joined(separator: "_")
    }

    func hiddenArguments(for tool: String) -> Set<String> {
        switch tool {
        // The config setting is the right default and the flag pair is a two-property way to
        // say one thing; a client that wants call sites off should edit `.code-monkey.toml`.
        case "code_monkey_index": alwaysHidden.union(["call_sites", "no_call_sites"])
        // This tool's contract is the JSON envelope, and `--format json` is injected to get it.
        // Advertising `format` would offer a choice the injected flag then overrides.
        case "code_monkey_get": alwaysHidden.union(["format"])
        default: alwaysHidden
        }
    }

    /// Argv appended after the client's own arguments.
    ///
    /// `get` needs both spellings: `Get.swift` gates resolve-mode JSON on `--format json` and
    /// enumerate-mode JSON on the global `--json`, and a call can land in either mode.
    let injectedArguments: [String: [String]] = [
        "code_monkey_index": ["--json"],
        "code_monkey_doctor": ["--json"],
        "code_monkey_get": ["--json", "--format", "json"],
        "code_monkey_code": ["--json"],
        "code_monkey_calls": ["--json"],
        "code_monkey_query": ["--json"],
        "code_monkey_imports": ["--json"],
        "code_monkey_stats": ["--json"],
    ]

    /// Payload delivered on standard input rather than as an argument, because it is a file's
    /// or a declaration's whole text and has no business on a command line.
    func stdinArgument(for tool: String) -> ExtraArgument? {
        switch tool {
        // Not required: `cut` removes a declaration and reads nothing. Which modes need a
        // payload is a rule between arguments, and the schema has no way to say it — the CLI
        // refuses an empty payload itself, with a better message than a schema could give.
        case "code_monkey_clip":
            ExtraArgument(
                key: "new_body",
                schema: .object([
                    "type": .string("string"),
                    "description": .string(
                        "Declaration text (attributes, signature, body). Required by "
                            + "paste_replacing, paste_after and paste_before; ignored by cut."),
                ]),
                isRequired: false)
        case "code_monkey_file_write", "code_monkey_file_append":
            ExtraArgument(
                key: "content",
                schema: .object([
                    "type": .string("string"),
                    "description": .string("Bytes to write."),
                ]),
                isRequired: true)
        default:
            nil
        }
    }

    /// Properties beyond what the command declares. `project` lands here only for commands with
    /// no `--project` of their own — it still picks the working directory the CLI runs in, which
    /// is how `init` and `file` reach a project at all.
    func extraArguments(for tool: String) -> [ExtraArgument] {
        [stdinArgument(for: tool)].compactMap { $0 } + [
            ExtraArgument(
                key: "project",
                schema: .object([
                    "type": .string("string"),
                    "description": .string("Project root. Omit to use the server's default --project."),
                ]),
                isRequired: false),
        ]
    }

    // MARK: profiles

    /// Named slices of the tool surface.
    ///
    /// A tool the client can't call still costs its full JSON schema in every request. The whole
    /// surface is right for an open-ended session and wrong for an agent that was only ever
    /// going to read.
    //# ai:why: `init`/`index`/`doctor` ride along in every profile — a tool that cannot build
    //# ai:why: or diagnose its own index strands the client on the first stale-index error
    enum Profile {
        static let essential: Set<String> = [
            "code_monkey_init", "code_monkey_index", "code_monkey_doctor", "code_monkey_version",
        ]
        static let read: Set<String> = essential.union(["code_monkey_get", "code_monkey_code"])
        static let nav: Set<String> = read.union([
            "code_monkey_calls", "code_monkey_imports", "code_monkey_query",
            "code_monkey_stats",
        ])
        /// Builds on `read`, not on `essential`: an edit is a read followed by a write, and a
        /// client that can `clip` a declaration but cannot `get` one first has to guess at what
        /// it is replacing — or fall back to reading the whole file, which is the thing this
        /// tool exists to avoid.
        //# ai:invariant: write is a superset of read
        //# ai:invariant: every command that writes source belongs here, or the profile lies
        static let write: Set<String> = read.union([
            "code_monkey_clip", "code_monkey_move", "code_monkey_rename",
            "code_monkey_file_read", "code_monkey_file_write",
            "code_monkey_file_append", "code_monkey_file_log",
        ])

        static let allNames = ["all", "read", "nav", "write"]

        static func names(_ profile: String, all: Set<String>) -> Set<String>? {
            switch profile {
            case "all": all
            case "read": read
            case "nav": nav
            case "write": write
            default: nil
            }
        }
    }

    /// The advertised tools for a profile, in declaration order. Nil means the name is unknown.
    func tools(_ all: [Tool], profile: String) -> [Tool]? {
        guard let wanted = Profile.names(profile, all: Set(all.map(\.name))) else { return nil }
        return all.filter { wanted.contains($0.name) }
    }

    /// Names a profile claims that no generated tool answers to.
    ///
    /// Tool names are derived from the command tree now, so a renamed subcommand silently
    /// empties a profile unless something checks. This is that check.
    //# ai:invariant: every profile is a subset of the generated tool list
    func danglingProfileNames(against all: [Tool]) -> [String] {
        let existing = Set(all.map(\.name))
        let claimed = Profile.essential
            .union(Profile.read).union(Profile.nav).union(Profile.write)
        return claimed.subtracting(existing).sorted()
    }
}
