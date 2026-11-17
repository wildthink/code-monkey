import ArgumentParser
import Foundation
import SwiftIDEUtils
import SwiftParser
import SwiftSyntax

//# ai:section: "Code"

/// When `code` paints its outline. `auto` paints only for a person at a terminal.
enum ColorMode: String, ExpressibleByArgument, CaseIterable, Sendable {
    case auto, always, never

    //# ai:invariant: `auto` never paints into a pipe — the MCP bridge reads `code` through one,
    //# ai:invariant: and an escape code in an agent's context is pure cost
    func enabled(isTTY: Bool = isatty(STDOUT_FILENO) != 0,
                 environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch self {
        case .always: return true
        case .never: return false
        case .auto:
            // https://no-color.org: present and non-empty disables color.
            if let value = environment["NO_COLOR"], !value.isEmpty { return false }
            if environment["TERM"] == "dumb" { return false }
            return isTTY
        }
    }
}

/// ANSI syntax coloring for `code`'s outline, driven by swift-syntax's own classifier.
//# ai:why: the outline is not compilable Swift, but the parser recovers and classification is
//# ai:why: per token — a stubbed body or a `{ ... }` fold costs at most a few plain tokens
enum Highlighter {
    enum Style: String {
        case keyword   = "\u{1B}[35m"       // magenta
        case type      = "\u{1B}[36m"       // cyan
        case string    = "\u{1B}[31m"       // red
        case number    = "\u{1B}[33m"       // yellow
        case attribute = "\u{1B}[34m"       // blue
        case comment   = "\u{1B}[2;32m"     // dim green
        case doc       = "\u{1B}[32m"       // green
        case directive = "\u{1B}[1;33m"     // bold yellow — `//# ai:` is a contract, not a remark
        case header    = "\u{1B}[1;2m"      // bold dim — the tool's own provenance lines
        static let reset = "\u{1B}[0m"
    }

    static func colorize(_ text: String) -> String {
        let bytes = Array(text.utf8)
        let tree = Parser.parse(source: text)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 2)
        var cursor = 0

        for span in tree.classifications {
            let start = span.range.lowerBound.utf8Offset
            let end = min(span.range.upperBound.utf8Offset, bytes.count)
            guard start >= cursor, start < end else { continue }
            out.append(contentsOf: bytes[cursor..<start])
            let slice = bytes[start..<end]
            if let style = style(for: span.kind, slice) {
                // A style never spans a newline, so a pager or `head` that cuts mid-output
                // leaves no line painted by the one above it.
                var first = true
                for line in slice.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
                    if !first { out.append(UInt8(ascii: "\n")) }
                    first = false
                    guard !line.isEmpty else { continue }
                    out.append(contentsOf: style.rawValue.utf8)
                    out.append(contentsOf: line)
                    out.append(contentsOf: Style.reset.utf8)
                }
            } else {
                out.append(contentsOf: slice)
            }
            cursor = end
        }
        out.append(contentsOf: bytes[min(cursor, bytes.count)...])
        return String(decoding: out, as: UTF8.self)
    }

    private static func style(for kind: SyntaxClassification, _ slice: ArraySlice<UInt8>) -> Style? {
        switch kind {
        case .keyword, .ifConfigDirective: return .keyword
        case .type: return .type
        case .stringLiteral, .regexLiteral: return .string
        case .integerLiteral, .floatLiteral: return .number
        case .attribute: return .attribute
        case .docLineComment, .docBlockComment: return .doc
        case .lineComment:
            if slice.starts(with: "//# ai:".utf8) { return .directive }
            if slice.starts(with: "// ──".utf8) || slice.starts(with: "// +".utf8) { return .header }
            return .comment
        case .blockComment: return .comment
        default: return nil
        }
    }
}
