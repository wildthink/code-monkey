import CommandREPL
import Foundation

//# ai:section: "Audit stats"

/// Reads the audit log back as evidence about how the tool is used.
///
/// This tool's whole argument is token economy, and until the log carried argv there was no
/// measurement of its own use — which commands get reached for, how deep the reads go, which
/// invocations a caller could not spell. Every number here comes from recorded argv resolved
/// against the *live* command tree, so a renamed option shows up as a parse miss rather than
/// as a silently wrong count.
//# ai:invariant: read-only over `AuditLog.Event` — nothing here opens the index or the source
enum AuditStats {

    // MARK: - parsing a recorded argv

    /// A recorded invocation, resolved against the command tree that exists now.
    struct Invocation {
        var path: [String]
        var positionals: [String]
        var values: [String: String]
        var flags: Set<String>

        var command: String { path.joined(separator: " ") }
        func value(_ token: String) -> String? { values[token] }
        func has(_ token: String) -> Bool { flags.contains(token) || values[token] != nil }
    }

    /// Splits argv the way ArgumentParser would, using the tree to know which options consume
    /// the token after them. Guessing that from the leading dash alone gets `--project /tmp/x`
    /// wrong, which is exactly the case that would corrupt target counts.
    static func parse(_ argv: [String], model: CommandModel) -> Invocation? {
        let (command, consumed) = model.resolve(path: argv)
        guard !consumed.isEmpty else { return nil }
        var out = Invocation(path: consumed, positionals: [], values: [:], flags: [])
        var index = consumed.count
        while index < argv.count {
            let token = argv[index]
            defer { index += 1 }
            guard token.hasPrefix("-"), token != "-" else {
                out.positionals.append(token)
                continue
            }
            if let split = token.firstIndex(of: "=") {
                out.values[String(token[token.startIndex..<split])] = String(token[split...].dropFirst())
                continue
            }
            guard let argument = command.argument(matchingToken: token) else {
                out.flags.insert(token)          // an option this build no longer declares
                continue
            }
            if argument.takesValue, index + 1 < argv.count {
                out.values[token] = argv[index + 1]
                index += 1
            } else {
                out.flags.insert(token)
            }
        }
        return out
    }

    /// How deep a read asked to go.
    ///
    /// Deliberately *not* the `tier` the command reports about itself: half of those are the
    /// command's own name (`tier=code`), which answers nothing argv does not already say. Only
    /// `code` and `get` are classified, because only those two are the disclosure ladder.
    static func depth(of invocation: Invocation) -> String? {
        switch invocation.path.first {
        case "code":
            let rung = invocation.value("-L") ?? invocation.value("--level")
            var parts = [rung.map { "L\($0)" } ?? "L default"]
            if invocation.has("--body") { parts.append("body") }
            if invocation.has("--expand") { parts.append("expand") }
            if invocation.has("--doc") { parts.append("doc") }
            return parts.joined(separator: "+")
        case "get":
            let fields = invocation.value("--fields") ?? ""
            if fields.contains("body") || invocation.value("--body-mode") != nil {
                return "body:\(invocation.value("--body-mode") ?? "ref")"
            }
            return fields.isEmpty ? "shell" : "fields"
        default:
            return nil
        }
    }

    /// What a read was aimed at, for spotting the same thing read twice.
    ///
    /// `query` is excluded on purpose — its positional is redacted before it ever reaches the
    /// log, and a redaction marker is not a target.
    static func target(of invocation: Invocation) -> String? {
        guard invocation.path.first != "query" else { return nil }
        return invocation.positionals.first
    }
}

// MARK: - the report

extension AuditStats {
    struct Report: Encodable {
        var invocations: Int
        var parsed: Int
        var failed: Int
        var first: String?
        var last: String?
        var commands: [CommandStat]
        var usage_errors: [ErrorStat]
        var repeated_targets: [Repeat]
    }

    struct CommandStat: Encodable {
        var command: String
        var count: Int
        var failed: Int
        var p50_ms: Int?
        var p90_ms: Int?
        /// Only `code` and `get` populate this — see `depth(of:)`. Absent rather than empty
        /// for the rest, so a reader is not invited to interpret a zero.
        var depth: [String: Int]?
    }

    /// An argv the parser rejected, kept verbatim. On a tool whose primary caller is an agent
    /// filling in a generated schema, this is the most actionable section in the report: each
    /// line is a description that failed to teach someone how to spell the command.
    struct ErrorStat: Encodable {
        var count: Int
        var status: String
        var argv: String
    }

    /// The same target read twice in quick succession by different reads — the signal that the
    /// cheaper one did not answer, and therefore that the ladder is cut in the wrong place.
    struct Repeat: Encodable {
        var count: Int
        var target: String
        var first: String
        var then: String

        struct Key: Hashable {
            var target: String
            var first: String
            var then: String
        }
    }

    /// Long tails are noise here: both lists are ranked, and what matters is the head.
    static let listCap = 10

    /// Two reads of one target further apart than this are a coincidence, not a re-read.
    ///
    /// Pairs are counted rather than listed: one target re-read forty times is one finding.
    static let repeatWindow: TimeInterval = 120

    static func build(from events: [AuditLog.Event], model: CommandModel) -> Report {
        let invocations = events.filter { $0.argv != nil }
        var byCommand: [String: (count: Int, failed: Int, ms: [Int], depth: [String: Int])] = [:]
        var errors: [String: (count: Int, status: String)] = [:]
        var repeats: [Repeat.Key: Int] = [:]
        var lastRead: [String: (command: String, at: Date)] = [:]
        var parsed = 0

        for event in invocations {
            guard let argv = event.argv, let invocation = parse(argv, model: model) else { continue }
            parsed += 1
            let key = invocation.command
            var stat = byCommand[key] ?? (0, 0, [], [:])
            stat.count += 1
            if let ms = event.ms { stat.ms.append(ms) }
            if let label = depth(of: invocation) { stat.depth[label, default: 0] += 1 }

            let ok = event.status == "ok" || event.status == nil
            if !ok {
                stat.failed += 1
                // Exit 64 is ArgumentParser refusing the argv — a spelling failure, not a
                // command that ran and disagreed. Only those are worth showing verbatim.
                if event.status == "exit 64" {
                    let rendered = argv.joined(separator: " ")
                    errors[rendered] = ((errors[rendered]?.count ?? 0) + 1, event.status ?? "?")
                }
            }
            byCommand[key] = stat

            guard ok, let target = target(of: invocation), let at = date(event.timestamp) else { continue }
            let label = [key, depth(of: invocation)].compactMap { $0 }.joined(separator: " ")
            if let previous = lastRead[target],
               previous.command != label,
               at.timeIntervalSince(previous.at) <= repeatWindow {
                repeats[Repeat.Key(target: target, first: previous.command, then: label),
                        default: 0] += 1
            }
            lastRead[target] = (label, at)
        }

        let commands = byCommand
            .map { name, stat in
                CommandStat(command: name, count: stat.count, failed: stat.failed,
                            p50_ms: percentile(stat.ms, 50), p90_ms: percentile(stat.ms, 90),
                            depth: stat.depth.isEmpty ? nil : stat.depth)
            }
            .sorted { ($0.count, $1.command) > ($1.count, $0.command) }

        return Report(
            invocations: invocations.count,
            parsed: parsed,
            failed: invocations.count { $0.status != nil && $0.status != "ok" },
            first: invocations.first?.timestamp,
            last: invocations.last?.timestamp,
            commands: commands,
            usage_errors: errors
                .map { ErrorStat(count: $0.value.count, status: $0.value.status, argv: $0.key) }
                .sorted { ($0.count, $1.argv) > ($1.count, $0.argv) }
                .prefix(listCap)
                .map { $0 },
            repeated_targets: repeats
                .map { Repeat(count: $0.value, target: $0.key.target,
                              first: $0.key.first, then: $0.key.then) }
                .sorted { ($0.count, $1.target) > ($1.count, $0.target) }
                .prefix(listCap)
                .map { $0 })
    }

    /// Nearest-rank, which needs no interpolation and is right for the small samples a session
    /// produces. Nil rather than 0 when nothing carried a duration.
    static func percentile(_ values: [Int], _ p: Int) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, Int((Double(p) / 100 * Double(sorted.count)).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }

    private static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    // MARK: - text

    static func render(_ report: Report) -> String {
        var out: [String] = []
        let span = [report.first, report.last].compactMap { $0 }
        out.append("\(report.invocations) invocations"
                   + (span.count == 2 ? "  \(span[0]) → \(span[1])" : "")
                   + "  \(report.failed) failed"
                   + (report.parsed < report.invocations
                      ? "  (\(report.invocations - report.parsed) no longer parse)" : ""))
        out.append("")

        let width = max(7, report.commands.map(\.command.count).max() ?? 7)
        out.append("COMMAND".padding(toLength: width, withPad: " ", startingAt: 0)
                   + "     n   fail    p50    p90   depth")
        for stat in report.commands {
            let depth = (stat.depth ?? [:])
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: " ")
            out.append(stat.command.padding(toLength: width, withPad: " ", startingAt: 0)
                       + column(stat.count, 6)
                       + column(stat.failed, 7)
                       + column(stat.p50_ms.map { "\($0)ms" }, 7)
                       + column(stat.p90_ms.map { "\($0)ms" }, 7)
                       + (depth.isEmpty ? "" : "   \(depth)"))
        }

        if !report.usage_errors.isEmpty {
            out.append("")
            out.append("USAGE ERRORS — argv the parser refused")
            for error in report.usage_errors {
                out.append("  \(error.count)×  \(CodeMonkey._commandName) \(error.argv)")
            }
        }

        if !report.repeated_targets.isEmpty {
            out.append("")
            out.append("RE-READS — same target, two reads inside \(Int(repeatWindow))s")
            for repeated in report.repeated_targets {
                out.append("  \(repeated.count)×  \(repeated.target)"
                           + "  \(repeated.first) → \(repeated.then)")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func column(_ value: Int, _ width: Int) -> String { column("\(value)", width) }

    private static func column(_ value: String?, _ width: Int) -> String {
        let text = value ?? "-"
        return String(repeating: " ", count: max(1, width - text.count)) + text
    }
}
