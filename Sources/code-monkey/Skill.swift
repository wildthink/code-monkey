import ArgumentParser
import CryptoKit
import Foundation

//# ai:section: "Skill"

// MARK: - Skill

/// The agent skill — `SKILL.md`, compiled into the binary it describes.
///
/// Copies of these rules drift: a review on 2026-11-19 found a claude.ai account skill two months
/// behind the tool, advertising commands that no longer existed. Carrying the text in the binary
/// fixes the source of truth; stamping what is handed out, and checking installed copies against
/// the embedded text, is what makes a stale copy visible instead of silently wrong.
//# ai:invariant: `unstamped(stamped(x)) == x` — doctor's comparison depends on it
//# ai:see: Makefile `$(SKILLTEXT)` rule, ServerInstructions (the short form)
enum Skill {
    static let name = "code-monkey"

    /// SKILL.md exactly as it stood when this binary was built.
    static var markdown: String { SkillText.markdown }

    /// First 12 hex digits of SHA-256 over the unstamped text.
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private static let versionKey = "  code-monkey-version: "
    private static let digestKey = "  code-monkey-digest: "

    /// The text with a `metadata` block naming the version and digest, just before the
    /// frontmatter closes. Agent Skills frontmatter allows a string-to-string `metadata` map, so
    /// clients that don't know these keys ignore them.
    static func stamped(_ text: String = markdown, version: String = BuildInfo.version) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return text }
        let keys = ["\(versionKey)\"\(version)\"", "\(digestKey)\"\(digest(text))\""]
        // YAML allows one `metadata` key, so a file that already has the block gets ours inside it.
        if let existing = lines[1..<close].firstIndex(of: "metadata:") {
            lines.insert(contentsOf: keys, at: existing + 1)
        } else {
            lines.insert(contentsOf: ["metadata:"] + keys, at: close)
        }
        return lines.joined(separator: "\n")
    }

    /// Removes exactly what `stamped` added. A copy that never carried a stamp passes through.
    static func unstamped(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { $0.hasPrefix(versionKey) || $0.hasPrefix(digestKey) }
        // Only a `metadata:` left with no children was ours; anything else belongs to the file.
        if let i = lines.firstIndex(of: "metadata:"),
           i + 1 >= lines.count || !lines[i + 1].hasPrefix("  ") {
            lines.remove(at: i)
        }
        return lines.joined(separator: "\n")
    }

    /// The version a stamped copy names, if it carries one.
    static func stampedVersion(_ text: String) -> String? {
        text.components(separatedBy: "\n").first { $0.hasPrefix(versionKey) }
            .map { String($0.dropFirst(versionKey.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
    }

    /// The `name:` from a file's frontmatter, to tell this skill from someone else's.
    static func frontmatterName(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        for line in lines.dropFirst() {
            if line == "---" { return nil }
            if line.hasPrefix("name:") {
                return line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: installed copies

    enum Status: String, Codable, Sendable {
        /// Byte-for-byte the text this binary carries, stamp aside.
        case current
        /// Differs — older, newer, or edited. The stamp, when present, says which version.
        case stale
    }

    /// Where a host keeps this skill, and how to bring a stale copy up to date there.
    struct Location: Sendable {
        let kind: String
        let file: URL
        let remedy: String
    }

    struct Installed: Codable, Sendable {
        let kind: String
        let path: String
        let status: Status
        let stamped_version: String?
    }

    /// Every place a host is known to load this skill from.
    ///
    /// The account-synced copy is read-only from here: the desktop app syncs it from claude.ai and
    /// overwrites local edits, so its remedy is an upload, not a write.
    //# ai:why: a list rather than a scan — each entry needs its own remedy, and a scan of the
    //# ai:why: home directory would be slow and would find copies nobody loads
    static func locations(project: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Location] {
        let fm = FileManager.default
        var out: [Location] = [
            Location(kind: "claude-code-user",
                     file: home.appendingPathComponent(".claude/skills/\(name)/SKILL.md"),
                     remedy: "code-monkey skill --write ~/.claude/skills"),
        ]
        if let project {
            out.append(Location(kind: "claude-code-project",
                                file: project.appendingPathComponent(".claude/skills/\(name)/SKILL.md"),
                                remedy: "code-monkey skill --write .claude/skills"))
        }
        // <base>/<org>/<account>/skills/code-monkey/SKILL.md, two opaque ids deep.
        let synced = home.appendingPathComponent(
            "Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin")
        for org in (try? fm.contentsOfDirectory(at: synced, includingPropertiesForKeys: nil)) ?? [] {
            for account in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? [] {
                out.append(Location(kind: "claude-account",
                                    file: account.appendingPathComponent("skills/\(name)/SKILL.md"),
                                    remedy: "code-monkey skill --zip code-monkey.zip, then upload it to claude.ai"))
            }
        }
        return out
    }

    static func status(of text: String) -> Status {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return norm(unstamped(text)) == norm(markdown) ? .current : .stale
    }

    /// Every known location holding a copy of *this* skill, with its status.
    static func installed(project: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [(Location, Installed)] {
        locations(project: project, home: home).compactMap { loc in
            guard let text = try? String(contentsOf: loc.file, encoding: .utf8),
                  frontmatterName(text) == name else { return nil }
            return (loc, Installed(kind: loc.kind, path: loc.file.path, status: status(of: text),
                                   stamped_version: stampedVersion(text)))
        }
    }

    // MARK: zip

    /// A stored (uncompressed) zip holding `code-monkey/SKILL.md` — the shape claude.ai's skill
    /// upload takes. Written by hand rather than by shelling out to `zip`/`ditto`: forty lines
    /// buy a command with no subprocess and no dependency on what the host has installed.
    static func zip(_ text: String) -> Data {
        let path = Data("\(name)/SKILL.md".utf8)
        let body = Data(text.utf8)
        let crc = crc32(body)
        let (time, date) = dosTimestamp(Date())
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }

        var local = Data(le32(0x0403_4b50))
        local += le16(20) + le16(0) + le16(0) + le16(time) + le16(date)
        local += le32(crc) + le32(UInt32(body.count)) + le32(UInt32(body.count))
        local += le16(path.count) + le16(0)
        local += path
        local += body

        var central = Data(le32(0x0201_4b50))
        central += le16(20) + le16(20) + le16(0) + le16(0) + le16(time) + le16(date)
        central += le32(crc) + le32(UInt32(body.count)) + le32(UInt32(body.count))
        central += le16(path.count) + le16(0) + le16(0) + le16(0) + le16(0)
        central += le32(0o100644 << 16) + le32(0)   // external attrs: a regular file, 0644
        central += path

        var end = Data(le32(0x0605_4b50))
        end += le16(0) + le16(0) + le16(1) + le16(1)
        end += le32(UInt32(central.count)) + le32(UInt32(local.count)) + le16(0)
        return local + central + end
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    private static func dosTimestamp(_ date: Date) -> (time: Int, date: Int) {
        let c = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let time = (c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2
        let day = max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)
        return (time, day)
    }
}

// MARK: - Command

struct SkillCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Print, install, or package the agent skill this binary carries.",
        discussion: """
        The skill is SKILL.md as it stood when this binary was built, stamped with the version \
        and a digest in its frontmatter `metadata`. `doctor` compares every installed copy it \
        can find against it, so a copy that has fallen behind the tool is reported rather than \
        silently teaching commands that no longer exist.

        With no option, prints the stamped skill. `--write` installs it as \
        `<dir>/code-monkey/SKILL.md`, refusing to replace a file that is some other skill. \
        `--zip` writes the upload bundle claude.ai takes for an account skill, which the \
        desktop app then syncs; that copy cannot be written locally.

        EXAMPLES
          code-monkey skill --write ~/.claude/skills      Claude Code, every project
          code-monkey skill --write .claude/skills        Claude Code, this project only
          code-monkey skill --zip code-monkey.zip         upload to claude.ai
          code-monkey skill > SKILL.md                    anywhere else
        """)

    @Option(name: .long, help: "Install into this skills directory, as <dir>/code-monkey/SKILL.md.")
    var write: String?

    @Option(name: .long, help: "Write a zip bundle for uploading as a claude.ai account skill.")
    var zip: String?

    func validate() throws {
        if write != nil && zip != nil { throw ValidationError("pass --write or --zip, not both") }
    }

    func run() throws {
        // Files end in a newline; `print` adds the one the bare form needs.
        let text = Skill.stamped()
        let file = text + "\n"
        let fm = FileManager.default
        if let write {
            let dir = URL(fileURLWithPath: (write as NSString).expandingTildeInPath)
                .appendingPathComponent(Skill.name)
            let dest = dir.appendingPathComponent("SKILL.md")
            if let existing = try? String(contentsOf: dest, encoding: .utf8),
               Skill.frontmatterName(existing) != Skill.name {
                FileHandle.standardError.write(Data(
                    "refusing to replace \(dest.path): it is not the \(Skill.name) skill\n".utf8))
                throw ExitCode(1)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try file.write(to: dest, atomically: true, encoding: .utf8)
            print("wrote \(dest.path) (\(BuildInfo.version), \(Skill.digest(Skill.markdown)))")
        } else if let zip {
            let url = URL(fileURLWithPath: (zip as NSString).expandingTildeInPath)
            try Skill.zip(file).write(to: url, options: .atomic)
            print("wrote \(url.path) — upload it as a skill in claude.ai")
        } else {
            print(text)
        }
    }
}
