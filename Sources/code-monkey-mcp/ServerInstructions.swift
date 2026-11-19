import Foundation

// MARK: - instructions

/// The reading rules, sent in the `initialize` result's `instructions`.
///
/// Clients that honour the field put it in the agent's context before the first tool call, which
/// is the one moment an agent is learning this tool surface — and it ships inside the binary the
/// rules describe, so it cannot fall behind the tools the way a separately installed skill did.
///
/// Steps are data rather than prose so a test can hold every tool and argument they name to the
/// generated tool list. Text is assembled per profile: a step whose tool the profile does not
/// advertise is left out rather than taught.
//# ai:section: "Bridge"
//# ai:invariant: every tool and argument a step names exists in the generated tool list
//# ai:invariant: the text never names a tool the active profile does not advertise
//# ai:see: SKILL.md — the long form; keep the orientation order in step with it
enum ServerInstructions {
    struct Step: Sendable {
        let tool: String
        /// Argument keys the text tells the agent to pass, as the tool schema spells them.
        let arguments: [String]
        let text: String
    }

    static let orientation: [Step] = [
        Step(tool: "code_monkey_doctor", arguments: [],
             text: "index freshness, project root, which binary is running. Call "
                + "code_monkey_index only when it reports stale files."),
        Step(tool: "code_monkey_query", arguments: ["recipe"],
             text: "recipe \"sections\" — the author's own architecture map. Recipe "
                + "\"invariants\" lists the constraints that must hold, before you edit."),
        Step(tool: "code_monkey_stats", arguments: ["section"],
             text: "section [\"mass\"] — which files hold the declarations. Ask for sections; "
                + "the full report is several KB."),
        Step(tool: "code_monkey_code", arguments: ["selector", "level", "doc", "budget"],
             text: "level 0 with doc, aimed at what the steps above surfaced. The result's "
                + "ladder field prices the next levels in bytes; or pass budget (bytes) and get "
                + "the deepest level that fits."),
        Step(tool: "code_monkey_code", arguments: ["expand"],
             text: "expand <member> — one body in full, its siblings as signatures, one call."),
        Step(tool: "code_monkey_calls", arguments: ["summary"],
             text: "summary before an edit — the blast radius. Edges are graded guesses by name."),
    ]

    static let editing = Step(
        tool: "code_monkey_clip", arguments: [],
        text: "is the write. Read the target's //# ai: directives first (code_monkey_get) and "
            + "honour ai:invariant, ai:requires and ai:warn — they are guarantees, not advice.")

    static let schema = "Tables for code_monkey_query: meta, files, declarations (not decls; no path "
        + "column — join files on file_id), imports, doc_comments, directives, call_sites, "
        + "bindings, conformances, narrative (often empty)."

    /// The text for one profile. `tools` is the advertised set, so the profile decides content.
    static func text(profile: String, tools: Set<String>) -> String {
        var out = [
            "code-monkey indexes this Swift project's declarations. Read Swift through these "
                + "tools rather than opening .swift files: they return the shape you ask for, and "
                + "body text only on request. Use rg for text inside bodies and for non-Swift files.",
            "Pass project (the project root) on every call — the server's default root is "
                + "wherever the client launched it, not necessarily the user's project.",
        ]

        let steps = orientation.filter { tools.contains($0.tool) }
        if !steps.isEmpty {
            out.append("Orient cheapest first:\n" + steps.enumerated()
                .map { "\($0.offset + 1). \($0.element.tool): \($0.element.text)" }
                .joined(separator: "\n"))
        }
        if tools.contains(editing.tool) { out.append("\(editing.tool) \(editing.text)") }
        if tools.contains("code_monkey_query") { out.append(schema) }
        out.append("Tool profile: \(profile). A tool you expect but don't see is outside this "
                   + "profile — say so rather than falling back to reading files.")
        return out.joined(separator: "\n\n")
    }

    /// Every tool name the text for `tools` mentions, for the test that keeps it honest.
    static func mentionedTools(in text: String) -> Set<String> {
        guard let pattern = try? NSRegularExpression(pattern: "code_monkey_[a-z_]+") else { return [] }
        let ns = text as NSString
        return Set(pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) })
    }
}
