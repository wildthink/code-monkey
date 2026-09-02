import ArgumentParserToolInfo
import CommandREPL
import Foundation
import MCP

// MARK: - bridge

/// Turns an ArgumentParser command tree into MCP tools, and a tool call back into argv.
///
/// Nothing in this type knows about code-monkey. The tree arrives as `ToolInfoV0` — the JSON
/// `--experimental-dump-help` prints — so a schema can only ever describe what the CLI actually
/// declares, and adding an option to a command is all it takes to expose it here.
///
/// What the schema does *not* carry bounds this: there are no value types (`defaultValue` is a
/// `String`), `@OptionGroup` is flattened, and cross-argument rules live in `validate()` bodies.
/// `ToolPolicy` supplies exactly those missing facts and nothing else.
//# ai:section: "Bridge"
struct ToolBridge: Sendable {
    let model: CommandModel
    let policy: ToolPolicy
    /// Walked once at startup: the tree cannot change while the server runs.
    let commands: [BoundCommand]

    init(root: CommandInfoV0, policy: ToolPolicy) {
        let model = CommandModel(root: root)
        self.model = model
        self.policy = policy
        self.commands = Self.leaves(of: model.root, policy: policy)
    }

    // MARK: leaves

    /// One MCP tool, and the subcommand path that runs it.
    ///
    /// - Note: `@unchecked` for the same reason `CommandModel` is: the `ToolInfoV0` family
    ///   predates `Sendable`, and its types are immutable trees of strings, arrays, and enums
    ///   with no reference storage. Nothing here ever mutates one.
    struct BoundCommand: @unchecked Sendable {
        let name: String
        let path: [String]
        let info: CommandInfoV0
    }

    /// Every runnable leaf of the tree, in declaration order.
    ///
    /// A command that only groups subcommands (`file`) is not itself runnable, so it yields its
    /// children instead of itself — `file read` becomes `code_monkey_file_read`.
    private static func leaves(of root: CommandInfoV0, policy: ToolPolicy) -> [BoundCommand] {
        var out: [BoundCommand] = []
        func walk(_ command: CommandInfoV0, path: [String]) {
            guard !policy.excludedCommands.contains(command.commandName) else { return }
            let path = path + [command.commandName]
            let children = command.visibleSubcommands
            if children.isEmpty {
                out.append(BoundCommand(name: policy.toolName(for: path), path: path, info: command))
            } else {
                for child in children { walk(child, path: path) }
            }
        }
        for command in root.visibleSubcommands { walk(command, path: []) }
        return out
    }

    // MARK: schemas

    func tools() -> [Tool] {
        commands.map { command in
            Tool(name: command.name,
                 description: description(of: command),
                 inputSchema: schema(of: command))
        }
    }

    private func description(of command: BoundCommand) -> String {
        let abstract = command.info.abstract ?? command.info.commandName
        let body = Self.semantics(of: command.info.discussion).map { "\(abstract)\n\n\($0)" } ?? abstract
        return renamingOptions(in: body, of: command)
    }

    /// The part of a `discussion` that is not a shell transcript.
    ///
    /// Everything from an `EXAMPLES` heading down is literal `code-monkey …` invocations, which
    /// are the right thing for a help screen and meaningless to a client that has no shell.
    //# ai:invariant: prose above `EXAMPLES` must read correctly for both audiences
    private static func semantics(of discussion: String?) -> String? {
        guard let discussion else { return nil }
        let kept = discussion
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { $0.trimmingCharacters(in: .whitespaces) != "EXAMPLES" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? nil : kept
    }

    /// Renames a command's own options from the spelling its help screen uses to the property
    /// names this server publishes — `--body-mode` on the terminal is `body_mode` here.
    ///
    /// Only spellings this tool actually exposes are touched, so a hidden flag, a flag belonging
    /// to another command, or a stray dash in prose survives exactly as written.
    private func renamingOptions(in text: String, of command: BoundCommand) -> String {
        var spellings: [String: String] = [:]
        for argument in exposed(of: command) {
            guard let key = Self.key(for: argument) else { continue }
            for name in argument.names ?? [] { spellings[name.token] = key }
        }
        guard !spellings.isEmpty, let pattern = Self.optionPattern else { return text }

        let ns = text as NSString
        var out = text
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let token = ns.substring(with: match.range)
            guard let key = spellings[token] else { continue }
            out = (out as NSString).replacingCharacters(in: match.range, with: key)
        }
        return out
    }

    private static let optionPattern = try? NSRegularExpression(pattern: "--?[A-Za-z][A-Za-z0-9-]*")

    private func schema(of command: BoundCommand) -> Value {
        var properties: [String: Value] = [:]
        var required: [Value] = []

        for argument in exposed(of: command) {
            guard let key = Self.key(for: argument) else { continue }
            properties[key] = property(for: argument, of: command, key: key)
            if !argument.isOptional { required.append(.string(key)) }
        }
        // Declared arguments win: a command that takes `--project` already described it.
        for extra in policy.extraArguments(for: command.name) where properties[extra.key] == nil {
            properties[extra.key] = extra.schema
            if extra.isRequired { required.append(.string(extra.key)) }
        }

        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    private func property(for argument: ArgumentInfoV0, of command: BoundCommand, key: String) -> Value {
        var property: [String: Value] = ["type": .string(jsonType(for: argument, key: key))]

        var text = argument.abstract ?? ""
        if argument.isRepeating, policy.commaSplitArguments.contains(key) {
            text += text.isEmpty ? "Comma-separated." : " Comma-separated."
        }
        if let fallback = argument.defaultValue {
            text += text.isEmpty ? "Default: \(fallback)." : " Default: \(fallback)."
        }
        if !text.isEmpty { property["description"] = .string(text) }

        // `allValues` is the payoff of declaring options as enums rather than as `String`.
        //
        // Emitting it as a schema `enum` is only safe when the list is the whole set: a JSON
        // Schema `enum` rejects anything outside it, while ArgumentParser's `allValueStrings`
        // is allowed to be a sample. Open sets get the same values as prose instead.
        if let values = argument.allValues, !values.isEmpty {
            let isClosed = !policy.openValueArguments.contains(key)
                && !policy.commaSplitArguments.contains(key)
            if isClosed {
                property["enum"] = .array(values.map { .string($0) })
            }
            let glosses = argument.allValueDescriptions ?? [:]
            let listed = values.map { value in
                glosses[value].map { "\(value): \($0)" } ?? value
            }
            var note = (isClosed ? "Values" : "Values include") + " — " + listed.joined(separator: "; ")
            if !isClosed { note += ". Other values are accepted." }
            let existing = property["description"]?.stringValue
            property["description"] = .string(existing.map { "\($0) \(note)" } ?? note)
        }
        return .object(property)
    }

    /// The schema has no value types, so integers are the one thing policy has to name.
    //# ai:why: `defaultValue` is a String and there is no type field; inferring from a
    //# ai:why: digit-shaped default would still miss `--level`, which declares no default
    private func jsonType(for argument: ArgumentInfoV0, key: String) -> String {
        if argument.kind == .flag { return "boolean" }
        return policy.integerArguments.contains(key) ? "integer" : "string"
    }

    // MARK: argv

    /// Builds the argv for a tool call, plus anything that should arrive on standard input.
    func invocation(for name: String, arguments: [String: Value]) throws -> (argv: [String], stdin: String?) {
        guard let command = commands.first(where: { $0.name == name }) else {
            throw ServerError(message: "unknown tool \(name)")
        }
        var argv = command.path
        var options: [String] = []

        for argument in exposed(of: command) {
            guard let key = Self.key(for: argument) else { continue }
            guard let value = arguments[key] else {
                guard argument.isOptional else {
                    throw ServerError(message: "\(name) requires '\(key)'")
                }
                continue
            }
            switch argument.kind {
            case .positional:
                guard let token = Self.token(for: value) else { continue }
                argv.append(token)
            case .flag:
                if value.boolValue == true, let flag = argument.preferredName?.token {
                    options.append(flag)
                }
            default:
                guard let flag = argument.preferredName?.token else { continue }
                for token in values(of: value, key: key) { options += [flag, token] }
            }
        }

        argv += options
        argv += policy.injectedArguments[name] ?? []

        var stdin: String?
        if let key = policy.stdinArgument(for: name) {
            guard let text = arguments[key.key]?.stringValue else {
                throw ServerError(message: "\(name) requires '\(key.key)'")
            }
            stdin = text
        }
        return (argv, stdin)
    }

    /// One token per value, so a repeating option can be spelled either way by the client.
    private func values(of value: Value, key: String) -> [String] {
        if let list = value.arrayValue { return list.compactMap(Self.token) }
        guard let token = Self.token(for: value) else { return [] }
        guard policy.commaSplitArguments.contains(key) else { return [token] }
        return token.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Arguments a client may set: everything the command declares, minus what the parser
    /// injects (`--help`) and what policy drives itself (`--json`, `--paste-replacing`).
    private func exposed(of command: BoundCommand) -> [ArgumentInfoV0] {
        let hidden = policy.hiddenArguments(for: command.name)
        return command.info.formArguments.filter { argument in
            guard let key = Self.key(for: argument) else { return false }
            return !hidden.contains(key)
        }
    }

    // MARK: naming

    /// The property name for an argument: its long spelling, in snake_case.
    static func key(for argument: ArgumentInfoV0) -> String? {
        switch argument.kind {
        case .positional: argument.valueName.map(snakeCased)
        default: argument.preferredName.map { snakeCased($0.name) }
        }
    }

    static func snakeCased(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: "_")
    }

    /// Renders a JSON value as a single argv token.
    ///
    /// Deliberately wider than the value's declared type: a client that sends `2` for a string
    /// option, or `2.0` for an integer one, means the same thing the CLI would read from a
    /// shell, and refusing it would be pedantry.
    static func token(for value: Value) -> String? {
        switch value {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let flag): String(flag)
        case .null, .data, .array, .object: nil
        }
    }
}
