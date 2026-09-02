import Foundation
import Synchronization

/// The command name that labels a JSON envelope and seeds `inferredTier`.
///
/// The process argv answers this correctly only while one process runs one command. The REPL
/// runs many from one process, so it sets this per line instead.
//# ai:why: reading `CommandLine.arguments` here labelled every REPL result `repl`
enum CommandContext {
    private static let override = Mutex<String?>(nil)

    /// Pass nil to hand the question back to the process argv.
    static func set(_ name: String?) { override.withLock { $0 = name } }

    static var name: String {
        override.withLock { $0 } ?? CommandLine.arguments.dropFirst().first ?? "unknown"
    }

    /// What the running command wants said about itself in the audit log — the tier it read at
    /// and what it was aimed at. argv carries neither: `tier` is a property of the command, not
    /// of its arguments.
    ///
    /// A slot rather than a return value because the dispatcher writes the entry and the
    /// dispatcher never sees the parsed command.
    private static let auditNote = Mutex<String?>(nil)

    static func note(_ text: String?) { auditNote.withLock { $0 = text } }

    /// Reads and clears, so a command that sets nothing cannot inherit the last one's note.
    static func drainNote() -> String? {
        auditNote.withLock { let note = $0; $0 = nil; return note }
    }
}

struct DirectiveView: Codable {
    var tag: String
    var value: String
    var line: Int
}

enum Printer {
    struct Envelope<T: Encodable>: Encodable {
        let schema_version = 1
        let command: String
        let tier: String?
        let result_count: Int
        let warnings: [String]
        let freshness: String?
        var fields: [String]? = nil
        let data: T
    }

    static func emit<T: Encodable>(
        _ value: T,
        json: Bool,
        tier: String? = nil,
        resultCount: Int? = nil,
        warnings: [String] = [],
        freshness: String? = nil,
        fields: [String]? = nil,
        text: () -> String
    ) {
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let command = CommandContext.name
            let envelope = Envelope(
                command: command,
                tier: tier ?? inferredTier(command: command),
                result_count: resultCount ?? reflectedCount(value),
                warnings: warnings,
                freshness: freshness,
                fields: fields,
                data: value
            )
            if let d = try? enc.encode(envelope), let s = String(data: d, encoding: .utf8) {
                print(s)
            }
        } else {
            print(text())
        }
    }

    private static func reflectedCount<T>(_ value: T) -> Int {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .collection ? mirror.children.count : 1
    }

    private static func inferredTier(command: String) -> String? {
        switch command {
        case "query": "T0"
        case "weave": "T3"
        case "clip", "index": "write"
        default: nil
        }
    }
}

/// Pure folding primitive — given a source slice and the descendants inside it,
/// returns the same slice with descendant bodies (or nested-type member blocks)
/// replaced by `{ ... }`. Caller decides what to keep.
//# ai:invariant: `descendants` must already be sorted DESC by `declOffset` so replacements never invalidate later byte ranges
//# ai:invariant: offsets in `descendants` are absolute file offsets — translated against `sliceOffset`
enum Fold {
    struct Descendant {
        var declId: String
        var kind: String                          // struct | class | enum | protocol | actor | extension | func | init | var | typealias
        var declOffset: Int
        var declLength: Int
        var bodyOffset: Int?
        var bodyLength: Int?
    }

    static let typeKinds: Set<String> = ["struct", "class", "enum", "protocol", "actor", "extension"]
    static let stub: [UInt8] = Array("{ ... }".utf8)

    /// `sliceOffset` is the absolute file offset where `source` begins.
    /// `keep` decl_ids stay un-folded.
    /// `deep` skips nested-type member-block replacement (so their children's bodies show).
    static func apply(source: String,
                      sliceOffset: Int,
                      descendants: [Descendant],
                      keep: Set<String>,
                      deep: Bool) -> String {
        var bytes = Array(source.utf8)
        for d in descendants {
            let keepThis = keep.contains(d.declId)
            if typeKinds.contains(d.kind) {
                if deep || keepThis { continue }
                let aOff = d.declOffset - sliceOffset
                let aEnd = aOff + d.declLength
                guard aOff >= 0, aEnd <= bytes.count else { continue }
                if let open = (aOff..<aEnd).first(where: { bytes[$0] == UInt8(ascii: "{") }),
                   let close = (aOff..<aEnd).reversed().first(where: { bytes[$0] == UInt8(ascii: "}") }),
                   close > open {
                    bytes.replaceSubrange(open...close, with: stub)
                }
            } else if let bOff = d.bodyOffset, let bLen = d.bodyLength, bLen > 0, !keepThis {
                let rel = bOff - sliceOffset
                guard rel >= 0, rel + bLen <= bytes.count else { continue }
                bytes.replaceSubrange(rel..<(rel + bLen), with: stub)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Slice raw bytes from a file using UTF-8 offset + length stored in the index.
func sliceFile(_ root: URL, _ rel: String, offset: Int, length: Int) -> String? {
    let url = root.appendingPathComponent(rel)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let end = min(data.count, offset + length)
    guard offset >= 0, offset <= end else { return nil }
    let sub = data.subdata(in: offset..<end)
    return String(data: sub, encoding: .utf8)
}

