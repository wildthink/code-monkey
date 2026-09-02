import Testing
import Foundation
import CommandREPL
import LineEditor
import MCP
@testable import code_monkey
@testable import code_monkey_mcp

@Suite("Glob")
struct GlobTests {
    @Test func star() {
        #expect(Glob.match(pattern: "*.swift", path: "Foo.swift"))
        #expect(!Glob.match(pattern: "*.swift", path: "sub/Foo.swift"))
    }
    @Test func doubleStar() {
        #expect(Glob.match(pattern: "**/*.swift", path: "a/b/c/Foo.swift"))
        #expect(Glob.match(pattern: "**/.build/**", path: "x/.build/y/z.o"))
        #expect(Glob.match(pattern: "Sources/**", path: "Sources/a/b.swift"))
    }
    @Test func charClass() {
        #expect(Glob.match(pattern: "[abc].txt", path: "a.txt"))
        #expect(!Glob.match(pattern: "[abc].txt", path: "d.txt"))
    }
}

@Suite("Extractor")
struct ExtractorTests {
    @Test func typesAndMembers() {
        let src = """
        /// User account.
        //# ai:invariant: id is unique
        //# ai:why: domain model
        public struct UserService {
            public var users: [UUID: User] = [:]

            /// Create.
            //# ai:prompt: never log raw email
            public func createUser(email: String, role: UserRole = .user) async throws -> User {
                fatalError()
            }
        }
        """
        let decls = Extractor.extract(source: src, file: "Test.swift")
        #expect(decls.contains { $0.name == "UserService" && $0.kind == "struct" })
        let createUser = decls.first { $0.name == "createUser" }
        #expect(createUser != nil)
        #expect(createUser?.container == "UserService")
        #expect(createUser?.containerKind == "struct")
        #expect(createUser?.modifiers.contains("async") == true)
        #expect(createUser?.modifiers.contains("throws") == true)
        #expect(createUser?.access == "public")
        #expect(createUser?.directives.contains { $0.tag == "ai:prompt" } == true)
        let typeDecl = decls.first { $0.name == "UserService" }
        #expect(typeDecl?.directives.contains { $0.tag == "ai:invariant" } == true)
        #expect(typeDecl?.directives.contains { $0.tag == "ai:why" } == true)
        #expect(typeDecl?.doc.contains("User account.") == true)
    }

    @Test func enumCasesAreIndexedOnePerElement() {
        let src = """
        enum Role: String {
            case admin, guest
            case member(String)
        }
        """
        let cases = Extractor.extract(source: src, file: "Test.swift").filter { $0.kind == "case" }
        #expect(cases.map(\.name) == ["admin", "guest", "member"])
        // A shared `case a, b` decl must not drag its neighbour's comma into the signature.
        #expect(cases.map(\.signature) == ["case admin", "case guest", "case member(String)"])
        #expect(cases.allSatisfy { $0.container == "Role" })
    }

    @Test func subscriptsCarryParameterTypesInTheirDeclId() {
        let src = """
        struct Matrix {
            subscript(row: Int, col: Int) -> Double {
                get { 0 }
                set { }
            }
        }
        """
        let sub = Extractor.extract(source: src, file: "Test.swift").first { $0.kind == "subscript" }
        #expect(sub?.declId == "Matrix.subscript(row:Int,col:Int)")
        // A real accessor body is dropped from the signature; the byte range still covers it.
        #expect(sub?.signature == "subscript(row: Int, col: Int) -> Double")
        #expect(sub?.bodyOffset != nil)
    }

    @Test func subscriptRequirementKeepsItsAccessorKeywords() {
        let src = """
        protocol Container {
            associatedtype Element
            subscript(index: Int) -> Element { get }
        }
        """
        let decls = Extractor.extract(source: src, file: "Test.swift")
        #expect(decls.first { $0.kind == "subscript" }?.signature
                == "subscript(index: Int) -> Element { get }")
        #expect(decls.first { $0.kind == "associatedtype" }?.name == "Element")
    }

    @Test func operatorDeclarationsAndPrecedenceGroupsAreIndexed() {
        let src = """
        infix operator <>: ComparisonPrecedence
        prefix operator ~~

        precedencegroup PipePrecedence {
            associativity: left
        }

        extension Int {
            static func <> (lhs: Int, rhs: Int) -> Bool { lhs != rhs }
        }
        """
        let decls = Extractor.extract(source: src, file: "Test.swift")
        let ops = decls.filter { $0.kind == "operator" }
        #expect(ops.map(\.name) == ["<>", "~~"])
        #expect(ops.first?.signature == "infix operator <>: ComparisonPrecedence")
        #expect(decls.first { $0.kind == "precedencegroup" }?.signature == "precedencegroup PipePrecedence")
        // The operator *implementation* is an ordinary FunctionDecl and always was.
        #expect(decls.contains { $0.kind == "func" && $0.name == "<>" && $0.container == "Int" })
    }

    @Test func callSitesSeparateCallsFromReferences() {
        let src = """
        struct Client {
            let store: Store
            func work() {
                store.save()
                helper()
                Fold.apply()
                let n = store.name
                self.work()
            }
        }
        """
        let sites = Extractor.extractAll(source: src, file: "Test.swift").callSites
        let calls = sites.filter { $0.kind == "call" }
        #expect(calls.contains { $0.name == "save" && $0.receiver == "store" })
        #expect(calls.contains { $0.name == "helper" && $0.receiver == nil })
        #expect(calls.contains { $0.name == "apply" && $0.receiver == "Fold" })
        #expect(calls.contains { $0.name == "work" && $0.receiver == "self" })

        let refs = sites.filter { $0.kind == "ref" }
        #expect(refs.contains { $0.name == "name" && $0.receiver == "store" })
        // A callee token is recorded once, as a call — never a second time as a ref.
        #expect(!refs.contains { $0.name == "save" })
        #expect(!refs.contains { $0.name == "helper" })
        // `self` is never a reference worth indexing, even though it appears as a receiver.
        #expect(!sites.contains { $0.name == "self" })
    }

    @Test func deinitIsIndexed() {
        let src = """
        final class Handle {
            deinit { print("closed") }
        }
        """
        let d = Extractor.extract(source: src, file: "Test.swift").first { $0.kind == "deinit" }
        #expect(d?.declId == "Handle.deinit")
        #expect(d?.bodyOffset != nil)
    }
}

@Suite("Fold")
struct FoldTests {
    private static let source = """
    struct S {
        func a() -> Int { return 1 }
        func b() -> Int { return 2 }
        func c() -> Int { return 3 }
    }
    """

    /// Extracts real decls from `source` and finds the struct target + its three func descendants.
    private func setup() -> (sliceOffset: Int, sourceSlice: String, descendants: [Fold.Descendant]) {
        let decls = Extractor.extract(source: Self.source, file: "S.swift")
        let target = decls.first { $0.name == "S" }!
        let funcs = decls.filter { $0.kind == "func" }.sorted { $0.declOffset > $1.declOffset }
        let descendants: [Fold.Descendant] = funcs.map { d in
            Fold.Descendant(
                declId: "S.\(d.name)", kind: d.kind,
                declOffset: d.declOffset, declLength: d.declLength,
                bodyOffset: d.bodyOffset, bodyLength: d.bodyLength
            )
        }
        let startUTF8 = Self.source.utf8.distance(from: Self.source.utf8.startIndex,
                                                  to: Self.source.utf8.index(Self.source.utf8.startIndex, offsetBy: target.declOffset))
        let endUTF8 = startUTF8 + target.declLength
        let slice = String(decoding: Array(Self.source.utf8)[startUTF8..<endUTF8], as: UTF8.self)
        return (target.declOffset, slice, descendants)
    }

    @Test func foldsAllBodies() {
        let (off, slice, descs) = setup()
        let out = Fold.apply(source: slice, sliceOffset: off, descendants: descs, keep: [], deep: false)
        #expect(out.contains("func a() -> Int { ... }"))
        #expect(out.contains("func b() -> Int { ... }"))
        #expect(out.contains("func c() -> Int { ... }"))
        #expect(!out.contains("return 1"))
        #expect(!out.contains("return 2"))
        #expect(!out.contains("return 3"))
    }

    @Test func keepInlinesBody() {
        let (off, slice, descs) = setup()
        let out = Fold.apply(source: slice, sliceOffset: off, descendants: descs, keep: ["S.b"], deep: false)
        #expect(out.contains("func a() -> Int { ... }"))
        #expect(out.contains("func b() -> Int { return 2 }"))
        #expect(out.contains("func c() -> Int { ... }"))
        #expect(!out.contains("return 1"))
        #expect(!out.contains("return 3"))
    }
}

@Suite("Code")
struct CodeTests {
    /// Mirrors the columns `CodeCmd.selectColumns` pulls, so `CodeNode` sees what it sees live.
    private static func row(_ id: Int64, _ kind: String, _ name: String, _ signature: String,
                            offset: Int64, length: Int64, body: (Int64, Int64)? = nil,
                            access: String? = nil, file: String = "Sources/T.swift") -> DatabaseRow {
        var v: [String: DatabaseValue] = [
            "id": .integer(id), "decl_id": .text(name), "kind": .text(kind), "name": .text(name),
            "signature": .text(signature), "access": access.map { .text($0) } ?? .null,
            "start_line": .integer(1), "end_line": .integer(1),
            "decl_offset": .integer(offset), "decl_length": .integer(length),
            "body_offset": .null, "body_length": .null,
            "file_id": .integer(1), "file_path": .text(file),
        ]
        if let body { v["body_offset"] = .integer(body.0); v["body_length"] = .integer(body.1) }
        return DatabaseRow(v, columns: Array(v.keys))
    }

    private static func renderer(members: Set<String>, roots: Set<String>? = nil,
                                 depth: BodyDepth = .stub, expand: String? = nil,
                                 nameFilter: String? = nil, access: Set<String>? = nil,
                                 spi: SPIFilter? = nil, root: URL = URL(fileURLWithPath: "/tmp")) -> Renderer {
        Renderer(project: Project(root: root, config: Config()),
                 memberKinds: members, rootKinds: roots, depth: depth, expand: expand,
                 nameFilter: nameFilter,
                 allowedAccess: access, spiFilter: spi, annotations: [:], numbers: false)
    }

    /// A rung's member set says what to show *inside* a declaration. Judging roots by it made
    /// `code -L0 <file>` match nothing at all, and made `code -L1 <file>` silently omit any
    /// declaration with no properties — a file outline quietly missing entries.
    @Test func aRungNeverDecidesWhetherARootIsListed() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "NoProperties", "struct NoProperties", offset: 0, length: 100),
            Self.row(2, "func", "method", "func method()", offset: 10, length: 40, body: (25, 20)),
            Self.row(3, "func", "freeFunction", "func freeFunction()", offset: 110, length: 40, body: (128, 20)),
        ])
        // Rung 0: no members shown, but both roots must still be listed.
        let rung0 = Self.renderer(members: Ladder.rung(0).members)
        #expect(forest.filter(rung0.includeRoot).map(\.name) == ["NoProperties", "freeFunction"])
        // Rung 1: properties only — neither root has any, and both must survive regardless.
        let rung1 = Self.renderer(members: Ladder.rung(1).members)
        #expect(forest.filter(rung1.includeRoot).map(\.name) == ["NoProperties", "freeFunction"])
    }

    @Test func anExplicitKindFlagStillFiltersRoots() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "Thing", "struct Thing", offset: 0, length: 100),
            Self.row(2, "func", "method", "func method()", offset: 10, length: 40, body: (25, 20)),
            Self.row(3, "func", "freeFunction", "func freeFunction()", offset: 110, length: 40, body: (128, 20)),
        ])
        // `code . --types` is a type listing: the free function is not a type and holds nothing.
        let types = Self.renderer(members: MemberGroup.types.kinds, roots: MemberGroup.types.kinds)
        #expect(forest.filter(types.includeRoot).map(\.name) == ["Thing"])
        // `code . --funcs` keeps free functions and the types whose members matched.
        let funcs = Self.renderer(members: MemberGroup.funcs.kinds, roots: MemberGroup.funcs.kinds)
        #expect(forest.filter(funcs.includeRoot).map(\.name) == ["Thing", "freeFunction"])
    }

    @Test func ladderAddsMembersThenBodies() {
        #expect(Ladder.rung(0).members.isEmpty)
        #expect(Ladder.rung(0).depth == .stub)
        #expect(Ladder.rung(1).members.contains("let") && Ladder.rung(1).members.contains("case"))
        #expect(!Ladder.rung(1).members.contains("func"))
        #expect(Ladder.rung(2).members.contains("func") && Ladder.rung(2).depth == .stub)
        #expect(Ladder.rung(3).depth == .full)
    }

    @Test func selectorSplitsTargetFromMemberFilter() {
        let root = URL(fileURLWithPath: "/tmp/proj")
        let typed = CodeSelector.parse("Walk:enum", root: root)
        #expect(typed.name == "Walk" && typed.member == "enum" && typed.path == nil)
        #expect(typed.namesARoot)

        let file = CodeSelector.parse("Sources/A.swift", root: root)
        #expect(file.path == "Sources/A.swift" && file.name == nil)
        #expect(!file.namesARoot)

        // `.` means the whole project, not an empty path filter that matches nothing.
        #expect(CodeSelector.parse(".", root: root).path == nil)
        #expect(CodeSelector.parse(nil, root: root).name == nil)
    }

    @Test func forestNestsByOffsetAndLeavesNeverAdoptSiblings() {
        // `case a, b` share one decl range — the second must not become a child of the first.
        let rows = [
            Self.row(1, "struct", "Outer", "struct Outer", offset: 0, length: 100),
            Self.row(2, "let", "x", "let x: Int", offset: 10, length: 10),
            Self.row(3, "enum", "Inner", "enum Inner", offset: 30, length: 40),
            Self.row(4, "case", "a", "case a", offset: 40, length: 12),
            Self.row(5, "case", "b", "case b", offset: 40, length: 12),
            Self.row(6, "func", "after", "func after()", offset: 110, length: 10),
        ]
        let forest = CodeNode.buildForest(rows)
        #expect(forest.map(\.name) == ["Outer", "after"])
        #expect(forest[0].children.map(\.name) == ["x", "Inner"])
        #expect(forest[0].children[1].children.map(\.name) == ["a", "b"])
    }

    @Test func rungZeroRendersBareShell() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "Walker", "struct Walker", offset: 0, length: 100),
            Self.row(2, "let", "project", "let project: Project", offset: 10, length: 20),
        ])
        #expect(Self.renderer(members: []).render(forest[0], indent: 0) == ["struct Walker {}"])
    }

    @Test func memberFilterNarrowsAndKeepsEnclosingShell() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "Walker", "struct Walker", offset: 0, length: 200),
            Self.row(2, "let", "project", "let project: Project", offset: 10, length: 20),
            Self.row(3, "func", "enumerateSwiftFiles", "func enumerateSwiftFiles() -> [URL]",
                     offset: 40, length: 60, body: (70, 20)),
            Self.row(4, "func", "isExcluded", "func isExcluded() -> Bool", offset: 110, length: 40, body: (130, 15)),
        ])
        let out = Self.renderer(members: MemberGroup.funcs.kinds, nameFilter: "enum")
            .render(forest[0], indent: 0)
        #expect(out == ["struct Walker {", "    func enumerateSwiftFiles() -> [URL] {}", "}"])
    }

    @Test func nestedTypeSurvivesAKindFilterItDoesNotMatch() {
        // --funcs must not hide a function just because it lives inside a nested type.
        let forest = CodeNode.buildForest([
            Self.row(1, "enum", "Outer", "enum Outer", offset: 0, length: 200),
            Self.row(2, "struct", "Inner", "struct Inner", offset: 20, length: 100),
            Self.row(3, "func", "work", "func work()", offset: 40, length: 40, body: (55, 20)),
        ])
        let out = Self.renderer(members: MemberGroup.funcs.kinds).render(forest[0], indent: 0)
        #expect(out == ["enum Outer {", "    struct Inner {", "        func work() {}", "    }", "}"])
    }

    @Test func computedPropertyHeaderDropsItsAccessorBody() {
        // VariableDeclSyntax.trimmedDescription swallows the whole accessor block.
        let forest = CodeNode.buildForest([
            Self.row(1, "var", "dbPath", "var dbPath: URL { root.appending(config.path) }",
                     offset: 0, length: 40, body: (18, 22)),
        ])
        #expect(Self.renderer(members: MemberGroup.vars.kinds).render(forest[0], indent: 0)
                == ["var dbPath: URL {}"])
    }

    @Test func protocolRequirementKeepsItsAccessorKeywords() {
        let forest = CodeNode.buildForest([
            Self.row(1, "var", "id", "var id: String { get set }", offset: 0, length: 26, body: (15, 11)),
        ])
        #expect(Self.renderer(members: MemberGroup.vars.kinds).render(forest[0], indent: 0)
                == ["var id: String { get set }"])
    }

    @Test func multiLineInitializerIsElidedAtTheEquals() {
        let forest = CodeNode.buildForest([
            Self.row(1, "let", "toml", "static let toml: String = \"\"\"\nline one\nline two\n\"\"\"",
                     offset: 0, length: 50),
        ])
        #expect(Self.renderer(members: MemberGroup.vars.kinds).render(forest[0], indent: 0)
                == ["static let toml: String = ..."])
    }

    @Test func accessFilterHidesMembersBelowTheFloor() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "S", "struct S", offset: 0, length: 200, access: "public"),
            Self.row(2, "func", "open", "public func open()", offset: 20, length: 40, body: (40, 18), access: "public"),
            Self.row(3, "func", "hidden", "private func hidden()", offset: 70, length: 40, body: (92, 16), access: "private"),
        ])
        let out = Self.renderer(members: MemberGroup.funcs.kinds, access: Set(AccessLevel.atOrAbove(.public)))
            .render(forest[0], indent: 0)
        #expect(out == ["struct S {", "    public func open() {}", "}"])
    }

    @Test func subscriptRequirementIsNotDoubledByTheRenderer() {
        // The stored signature already carries `{ get }` — the header must be cut at the brace
        // before the requirement is re-attached.
        let forest = CodeNode.buildForest([
            Self.row(1, "subscript", "subscript", "subscript(index: Int) -> Element { get }",
                     offset: 0, length: 42, body: (34, 8)),
        ])
        #expect(Self.renderer(members: MemberGroup.funcs.kinds).render(forest[0], indent: 0)
                == ["subscript(index: Int) -> Element { get }"])
    }

    @Test func kindGroupsCoverEveryExtractedKind() {
        // Anything the extractor emits must be reachable through --all, or it silently vanishes.
        let extracted: Set<String> = [
            "struct", "class", "enum", "protocol", "actor", "extension", "typealias",
            "associatedtype", "operator", "precedencegroup", "func", "init", "deinit",
            "subscript", "var", "let", "case",
        ]
        #expect(extracted.subtracting(MemberGroup.allKinds).isEmpty)
    }

    @Test func foldDepthMarksBodiesAsElided() {
        let forest = CodeNode.buildForest([
            Self.row(1, "func", "work", "func work() -> Int", offset: 0, length: 40, body: (18, 20)),
        ])
        #expect(Self.renderer(members: MemberGroup.funcs.kinds, depth: .fold).render(forest[0], indent: 0)
                == ["func work() -> Int { ... }"])
    }

    // MARK: --expand

    /// Writes a real file so `.full` has something to slice, then renders `Thing` from offsets
    /// into that text. `--expand` is the only path that reaches back into source below rung 3.
    private static func withSource(_ text: String, _ check: (URL) throws -> Void) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("expand-\(UUID().uuidString)")
        let sources = tmp.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try text.write(to: sources.appendingPathComponent("T.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try check(tmp)
    }

    /// The read `:member` cannot express: one real body *plus* its siblings' signatures.
    /// `Thing:work --body` hides `other`; `-L2` alone stubs `work`.
    @Test func expandLiftsOneMemberAboveTheRung() throws {
        let workText = "func work() -> Int {\n        return 1\n    }"
        let otherText = "func other() {}"
        let text = "struct Thing {\n    \(workText)\n    \(otherText)\n}\n"
        func span(_ needle: String) -> (Int64, Int64) {
            let range = text.range(of: needle)!
            return (Int64(text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound.samePosition(in: text.utf8)!)),
                    Int64(needle.utf8.count))
        }
        let work = span(workText), other = span(otherText)

        try Self.withSource(text) { root in
            let forest = CodeNode.buildForest([
                Self.row(1, "struct", "Thing", "struct Thing", offset: 0, length: Int64(text.utf8.count)),
                Self.row(2, "func", "work", "func work() -> Int", offset: work.0, length: work.1,
                         body: (work.0 + 19, work.1 - 19)),
                Self.row(3, "func", "other", "func other()", offset: other.0, length: other.1,
                         body: (other.0 + 13, 2)),
            ])
            let r = Self.renderer(members: Ladder.rung(2).members, expand: "work", root: root)
            #expect(r.render(forest[0], indent: 0) == [
                "struct Thing {",
                "    func work() -> Int {",
                "        return 1",
                "    }",
                "",
                "    func other() {}",
                "}",
            ])
        }
    }

    /// Below the rung that would have listed it, `--expand` must force the member in — otherwise
    /// `code Thing -L0 --expand work` is a silent no-op and the flag only works where it is redundant.
    @Test func expandForcesAMemberInBelowItsRung() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "Thing", "struct Thing", offset: 0, length: 100),
            Self.row(2, "func", "work", "func work()", offset: 10, length: 20, body: (21, 8)),
            Self.row(3, "func", "other", "func other()", offset: 40, length: 20, body: (51, 8)),
        ])
        // Rung 0 shows no members at all; only the expanded one earns a line.
        let r = Self.renderer(members: Ladder.rung(0).members, expand: "work")
        #expect(r.render(forest[0], indent: 0) == ["struct Thing {", "    func work() {}", "}"])
        // An access floor is an explicit constraint and still outranks `--expand`.
        let gated = Self.renderer(members: Ladder.rung(2).members, expand: "work", access: ["public"])
        #expect(!gated.include(forest[0].children[0]))
    }

    /// Naming a type expands the type: expansion is inherited by everything nested inside it,
    /// so `--expand SomeType` is not a no-op just because the match is not a leaf.
    @Test func expandIsInheritedByNestedDeclarations() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "Outer", "struct Outer", offset: 0, length: 200),
            Self.row(2, "struct", "Inner", "struct Inner", offset: 10, length: 100),
            Self.row(3, "func", "deep", "func deep()", offset: 30, length: 20, body: (41, 8)),
        ])
        // Rung 0 would show nothing inside `Outer`; the match drags `Inner` and its member in.
        let r = Self.renderer(members: Ladder.rung(0).members, expand: "Inner")
        #expect(r.render(forest[0], indent: 0) == [
            "struct Outer {", "    struct Inner {", "        func deep() {}", "    }", "}",
        ])
    }

    /// A project-wide map is mostly read from the top, and test decls are the part that is
    /// almost never what the reader came for. They sink, but they are never dropped — the
    /// count returned is what lets the seam be drawn and labelled.
    @Test func testDeclsSinkToTheEndWithoutBeingLost() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "Walker", "struct Walker", offset: 0, length: 50),
            Self.row(2, "struct", "GlobTests", "struct GlobTests", offset: 60, length: 50,
                     file: "Tests/PkgTests/GlobTests.swift"),
            Self.row(3, "struct", "Fold", "struct Fold", offset: 120, length: 50),
        ])
        var sunk = forest
        let count = CodeCmd.sinkTests(&sunk)
        #expect(count == 1)
        #expect(sunk.map(\.name) == ["Walker", "Fold", "GlobTests"])
        #expect(sunk.count == forest.count)
    }

    /// An all-test result has no production half to divide from, so nothing moves and the
    /// caller gets a count it can use to skip drawing a seam.
    @Test func anAllTestForestIsLeftAlone() {
        var forest = CodeNode.buildForest([
            Self.row(1, "struct", "GlobTests", "struct GlobTests", offset: 0, length: 50,
                     file: "Tests/PkgTests/GlobTests.swift"),
            Self.row(2, "struct", "FoldTests", "struct FoldTests", offset: 60, length: 50,
                     file: "Tests/PkgTests/FoldTests.swift"),
        ])
        #expect(CodeCmd.sinkTests(&forest) == 2)
        #expect(forest.map(\.name) == ["GlobTests", "FoldTests"])
    }

    /// A suite parked outside a `Tests` directory is still a suite. The root's own name is the
    /// only container there is to judge it by — but only for a type: a free `func fooTests()`
    /// in production code is not a test suite.
    @Test func aSuiteOutsideATestDirectoryStillSinks() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "Walker", "struct Walker", offset: 0, length: 50),
            Self.row(2, "struct", "GlobTests", "struct GlobTests", offset: 60, length: 50),
            Self.row(3, "class", "WalkerTestCase", "class WalkerTestCase", offset: 120, length: 50),
        ])
        #expect(forest.map(\.isTest) == [false, true, true])

        // A production type whose name merely ends in lowercase "tests" is not caught.
        let contest = CodeNode.buildForest([
            Self.row(1, "struct", "Contests", "struct Contests", offset: 0, length: 50),
        ])
        #expect(contest.map(\.isTest) == [false])
    }

    /// Signature scanning is lexical on purpose. It over-collects — `String`, `Int`, the
    /// attribute on an `@MainActor` — and the index filters the noise out by simply not
    /// declaring those names. What it must not do is miss a type inside a nesting.
    @Test func typeNamesAreHarvestedThroughNestingAndPunctuation() {
        let sig = "static func apply(source: String, kids: [Descendant], keep: Set<Rule>) -> Fold.Result?"
        let names = CodeCmd.typeNames(in: sig)
        #expect(names.isSuperset(of: ["String", "Descendant", "Set", "Rule", "Fold", "Result"]))
        // Lowercase identifiers are argument labels and parameter names, never types.
        #expect(names.isDisjoint(with: ["apply", "source", "kids", "keep", "static", "func"]))
    }

    /// `--peek` explains the bodies that actually printed, so it has to agree with the renderer
    /// about which those are. A member only reachable at a higher rung is not one of them.
    @Test func onlyTheLeavesThatRenderInFullArePeekedAt() {
        let forest = CodeNode.buildForest([
            Self.row(1, "struct", "Walker", "struct Walker", offset: 0, length: 200),
            Self.row(2, "func", "walk", "func walk() -> Descendant", offset: 20, length: 60, body: (45, 30)),
            Self.row(3, "func", "reset", "func reset()", offset: 100, length: 60, body: (125, 30)),
        ])
        // `--expand reset` expands that one member and nothing else. (A pattern matching the
        // *root* — `walk` against `Walker` — expands the whole type by design, so this picks a
        // name only the member carries.)
        let expanding = Self.renderer(members: Ladder.rung(2).members, expand: "reset")
        #expect(forest.flatMap { expanding.expandedLeaves($0) }.map(\.name) == ["reset"])

        // Matching the root expands everything nested inside it, and the leaves follow.
        let wholeType = Self.renderer(members: Ladder.rung(2).members, expand: "walk")
        #expect(forest.flatMap { wholeType.expandedLeaves($0) }.map(\.name) == ["walk", "reset"])

        // At rung 0 with no expansion nothing renders in full, so there is nothing to explain.
        let shell = Self.renderer(members: Ladder.rung(0).members)
        #expect(forest.flatMap { shell.expandedLeaves($0) }.isEmpty)
    }

    /// `code` and `calls` must not disagree about what a test is; both read this one rule.
    @Test func theTestConventionIsPathShapedNotNameShaped() {
        #expect(TestConvention.isTestPath("Tests/PkgTests/Foo.swift"))
        #expect(TestConvention.isTestPath("Sources/AppTests/Helper.swift"))
        #expect(!TestConvention.isTestPath("Sources/App/Contest.swift"))
        #expect(TestConvention.isTestContainer("GlobTests"))
        #expect(TestConvention.isTestContainer("WalkerTestCase"))
        #expect(!TestConvention.isTestContainer("Walker"))
        #expect(!TestConvention.isTestContainer(nil))
    }
}

@Suite("Get")
struct GetTests {
    @Test func dependencyExtractionDedupesAndOrders() {
        let sig = "func createUser(email: String, role: UserRole) async throws -> User"
        #expect(DependencyExtractor.extract(signature: sig) == ["String", "UserRole", "User"])
    }
    @Test func dependencyExtractionEmptyForLowercaseOnly() {
        #expect(DependencyExtractor.extract(signature: "func ping() -> Bool") == ["Bool"])
    }
    @Test func ownershipModuleFromSourceRoot() {
        #expect(Ownership.module(forFile: "Sources/code-monkey/Get.swift", sources: ["Sources"]) == "code-monkey")
    }
    @Test func ownershipModuleFallsBackToDashOutsideSources() {
        #expect(Ownership.module(forFile: "README.md", sources: ["Sources"]) == "-")
    }
    @Test func fieldParseRejectsUnknown() {
        #expect(throws: FieldParseError.self) { try GetField.parse("signature,bogus") }
    }
    @Test func fieldParseAcceptsKnownList() throws {
        let fields = try GetField.parse("signature, callers")
        #expect(fields == [.signature, .callers])
    }
}

@Suite("Index")
struct IndexTests {
    @Test func indexAndQueryAndRefresh() async throws {
        let tmp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = try Project.load(explicitRoot: tmp.path)
        try FileManager.default.createDirectory(at: project.dbDir, withIntermediateDirectories: true)
        let db = try Database(path: project.dbPath, mode: .readWrite)
        try await Schema.bootstrap(db)

        let r1 = try await Indexer(project: project, db: db).run(full: false)
        #expect(r1.added > 0)
        let fresh = try await Indexer.check(project: project, db: db)
        #expect(!fresh.needsRefresh)

        let rows = try await db.query("SELECT name FROM declarations WHERE name='createUser'")
        #expect(rows.count == 1)

        let readOnly = try Database(path: project.dbPath, mode: .readOnly)
        let readRows = try await readOnly.query("SELECT name FROM declarations WHERE name='createUser'")
        #expect(readRows.count == 1)
        await #expect(throws: (any Error).self) {
            try await readOnly.run("INSERT INTO meta(key,value) VALUES('read-only-test','1')")
        }

        // Refresh w/o changes — should skip.
        let r2 = try await Indexer(project: project, db: db).run(full: false)
        #expect(r2.added == 0 && r2.updated == 0 && r2.skipped >= 1)

        // Edit a file, refresh — should update only that file.
        let f = tmp.appendingPathComponent("Sources/UserService.swift")
        try ("// touched\n" + (try String(contentsOf: f, encoding: .utf8))).write(to: f, atomically: true, encoding: .utf8)
        let stale = try await Indexer.check(project: project, db: db)
        #expect(stale.modified == ["Sources/UserService.swift"])
        let r3 = try await Indexer(project: project, db: db).run(full: false)
        #expect(r3.updated == 1)
    }

    @Test func actorSerializesTransactions() async throws {
        let tmp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = try Project.load(explicitRoot: tmp.path)
        let db = try Database(path: project.dbPath, mode: .readWrite)
        try await Schema.bootstrap(db)
        try await db.run("CREATE TABLE counter(value INTEGER NOT NULL)")
        try await db.run("INSERT INTO counter(value) VALUES(0)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await db.transaction { db in
                        let value = try db.query("SELECT value FROM counter").first?.int64("value") ?? 0
                        try db.run("UPDATE counter SET value=?", [value + 1])
                    }
                }
            }
            try await group.waitForAll()
        }

        let value = try await db.query("SELECT value FROM counter").first?.int64("value")
        #expect(value == 20)
    }

    @Test func configuredAuditPath() async throws {
        let tmp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        var config = Config()
        config.audit = ".code-monkey/custom-audit.log"
        let project = Project(root: tmp, config: config)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    AuditLog.append(
                        "list",
                        path: tmp.path,
                        note: "tier=T0 index=\(index)",
                        project: project
                    )
                }
            }
        }

        let log = tmp.appendingPathComponent(".code-monkey/custom-audit.log")
        let text = try String(contentsOf: log, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        #expect(lines.count == 20)
        for line in lines {
            let event = try JSONDecoder().decode(AuditLog.Event.self, from: Data(line.utf8))
            #expect(event.operation == "list")
            #expect(event.path == tmp.path)
        }
    }

    @Test func jsonEnvelopeIsStable() throws {
        let envelope = Printer.Envelope(
            command: "list",
            tier: "T0",
            result_count: 1,
            warnings: [],
            freshness: "fresh",
            data: ["id": "UserService"]
        )
        let data = try JSONEncoder().encode(envelope)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["command"] as? String == "list")
        #expect(object["tier"] as? String == "T0")
        #expect(object["result_count"] as? Int == 1)
    }

    /// The grading rules in `CallGraph.grade` are the whole value of a syntactic call graph —
    /// an ungraded one just relocates the ambiguity. These assert each rule on real indexed source.
    @Test func callGraphGradesEdgesByReceiverType() async throws {
        let tmp = try makeCallProject()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = try Project.load(explicitRoot: tmp.path)
        try FileManager.default.createDirectory(at: project.dbDir, withIntermediateDirectories: true)
        let db = try Database(path: project.dbPath, mode: .readWrite)
        try await Schema.bootstrap(db)
        _ = try await Indexer(project: project, db: db).run(full: true)

        let graph = CallGraph(db: db)
        guard let run = try await graph.resolve(query: "Client.run()", file: nil).first else {
            Issue.record("Client.run not indexed"); return
        }
        let edges = try await graph.callees(of: run, includeRefs: false)
        func edge(_ declId: String) -> CallEdge? { edges.first { $0.target.declId == declId } }

        // `store` is declared `let store: Store`, so `store.save()` resolves by type...
        #expect(edge("Store.save()")?.confidence == .high)
        // ...and that corroborated match refutes the identically-named rival.
        #expect(edge("Other.save()") == nil)
        // A unique free function reached with no receiver.
        #expect(edge("helper()")?.confidence == .high)
        // Type-qualified: the receiver names the container outright.
        #expect(edge("Store.reset()")?.confidence == .high)
        // The false positive this grading exists to prevent: `items` is a local `[String]`,
        // so `items.append(...)` must not claim to call the project's own `Log.append`.
        #expect(edge("Log.append(_:String)")?.confidence != .high)
        // Repeated calls collapse to one edge carrying a count.
        #expect(edge("Store.save()")?.occurrences == 2)

        // And the reverse direction agrees.
        guard let save = try await graph.resolve(query: "Store.save()", file: nil).first else {
            Issue.record("Store.save not indexed"); return
        }
        let callers = try await graph.callers(of: save, includeRefs: false)
        #expect(callers.contains { $0.target.declId == "Client.run()" && $0.confidence == .high })
    }

    /// Call sites are most of the index file, so they're optional. What matters is that turning
    /// them off is *detectable* — an empty call graph must not read as a fact about the code.
    @Test func callSitesCanBeDisabledAndTheAbsenceIsDetectable() async throws {
        let tmp = try makeCallProject()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = try Project.load(explicitRoot: tmp.path)
        try FileManager.default.createDirectory(at: project.dbDir, withIntermediateDirectories: true)
        let db = try Database(path: project.dbPath, mode: .readWrite)
        try await Schema.bootstrap(db)

        _ = try await Indexer(project: project, db: db).run(full: true, callSites: false)
        #expect(try await db.query("SELECT COUNT(*) AS c FROM call_sites").first?.int64("c") == 0)
        #expect(try await db.query("SELECT COUNT(*) AS c FROM declarations").first?.int64("c") ?? 0 > 0)
        #expect(try await CallGraph(db: db).callSitesIndexed() == false)

        // Re-enabling backfills without a schema change.
        _ = try await Indexer(project: project, db: db).run(full: true, callSites: true)
        #expect(try await db.query("SELECT COUNT(*) AS c FROM call_sites").first?.int64("c") ?? 0 > 0)
        #expect(try await CallGraph(db: db).callSitesIndexed() == true)

        // And off again clears the table rather than leaving stale rows behind.
        _ = try await Indexer(project: project, db: db).run(full: true, callSites: false)
        #expect(try await db.query("SELECT COUNT(*) AS c FROM call_sites").first?.int64("c") == 0)
    }

    @Test func configReadsTheCallSiteToggle() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cm-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Default when the key is absent — the call graph works out of the box.
        try "sources = [\"Sources\"]\n".write(to: tmp.appendingPathComponent(".code-monkey.toml"),
                                              atomically: true, encoding: .utf8)
        #expect(try Config.load(at: tmp).parse.extractCallSites)

        try "sources = [\"Sources\"]\n\n[parse]\nextract_call_sites = false\n"
            .write(to: tmp.appendingPathComponent(".code-monkey.toml"), atomically: true, encoding: .utf8)
        #expect(try Config.load(at: tmp).parse.extractCallSites == false)
    }

    /// The receiver of a call is far more often a local or a parameter than a property.
    /// Before `bindings`, both read as unknown, so a true caller reached through one was graded
    /// `low` and vanished under the default floor — a false negative that looked like a fact.
    @Test func callGraphResolvesReceiversBoundLocallyAndByParameter() async throws {
        let tmp = try makeCallProject()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = try Project.load(explicitRoot: tmp.path)
        try FileManager.default.createDirectory(at: project.dbDir, withIntermediateDirectories: true)
        let db = try Database(path: project.dbPath, mode: .readWrite)
        try await Schema.bootstrap(db)
        _ = try await Indexer(project: project, db: db).run(full: true)
        let graph = CallGraph(db: db)

        func callees(_ declId: String) async throws -> [CallEdge] {
            guard let target = try await graph.resolve(query: declId, file: nil).first else {
                Issue.record("\(declId) not indexed"); return []
            }
            return try await graph.callees(of: target, includeRefs: false)
        }

        // `let local = Store()` states the type as plainly as an annotation does.
        let local = try await callees("Client.viaLocal()")
        #expect(local.first { $0.target.declId == "Store.save()" }?.confidence == .high)
        #expect(local.first { $0.target.declId == "Other.save()" } == nil)

        // A parameter's type is stated, never guessed — and it refutes the rival of the same name.
        let param = try await callees("Client.viaParameter(arg:Other)")
        #expect(param.first { $0.target.declId == "Other.save()" }?.confidence == .high)
        #expect(param.first { $0.target.declId == "Store.save()" } == nil)

        // The reverse direction is the one that was silently empty before.
        guard let save = try await graph.resolve(query: "Store.save()", file: nil).first else {
            Issue.record("Store.save not indexed"); return
        }
        let callers = try await graph.callers(of: save, includeRefs: false)
        #expect(callers.contains { $0.target.declId == "Client.viaLocal()" && $0.confidence == .high })
        // `arg.save()` resolves to `Other`, so it is charted against `Store.save` as a refuted
        // guess rather than dropped — visible under `--min low`, hidden by the default floor.
        #expect(callers.first { $0.target.declId == "Client.viaParameter(arg:Other)" }?.confidence == .low)
    }

    /// Dispatch through a protocol lands on the requirement, where no work happens. Without
    /// conformances the graph stopped there, and protocol-oriented code read as uncalled —
    /// the single largest structural gap in a name-matched Swift call graph.
    @Test func callGraphCrossesProtocolDispatchInBothDirections() async throws {
        let tmp = try makeCallProject()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = try Project.load(explicitRoot: tmp.path)
        try FileManager.default.createDirectory(at: project.dbDir, withIntermediateDirectories: true)
        let db = try Database(path: project.dbPath, mode: .readWrite)
        try await Schema.bootstrap(db)
        _ = try await Indexer(project: project, db: db).run(full: true)
        let graph = CallGraph(db: db)

        guard let target = try await graph.resolve(query: "Client.viaProtocol(saver:anySaver)",
                                                   file: nil).first else {
            Issue.record("Client.viaProtocol not indexed"); return
        }
        let edges = try await graph.callees(of: target, includeRefs: false)
        // The requirement itself is corroborated — the receiver is declared `any Saver`.
        #expect(edges.first { $0.target.declId == "Saver.persist()" }?.confidence == .high)
        // Every conforming implementation is charted behind it, as a possibility: only one runs.
        for impl in ["FileSaver.persist()", "MemorySaver.persist()"] {
            let edge = edges.first { $0.target.declId == impl }
            #expect(edge?.confidence == .medium, "\(impl) should be charted as a possibility")
            #expect(edge?.via == "Saver.persist()")
        }

        // And the blast-radius question — "who reaches this implementation?" — is answered by
        // whoever reaches the requirement, at the default floor rather than below it.
        guard let impl = try await graph.resolve(query: "FileSaver.persist()", file: nil).first else {
            Issue.record("FileSaver.persist not indexed"); return
        }
        let callers = try await graph.callers(of: impl, includeRefs: false)
        #expect(callers.first { $0.target.declId == "Client.viaProtocol(saver:anySaver)" }?
                .confidence == .medium)
    }

    /// Conformances are written as often on an extension as on the declaration, and dropping
    /// the extension form would leave most real Swift conformances unindexed.
    @Test func conformancesDeclaredOnExtensionsAreIndexed() async throws {
        let src = """
        protocol Saver { func persist() }
        struct Late {}
        extension Late: Saver {
            func persist() {}
        }
        final class Box<T>: Late, Sendable {}
        """
        let decls = Extractor.extract(source: src, file: "T.swift")
        #expect(decls.first { $0.kind == "extension" && $0.name == "Late" }?.inherits == ["Saver"])
        #expect(decls.first { $0.kind == "class" }?.inherits == ["Late", "Sendable"])
        // A type that inherits nothing carries an empty list, not a phantom entry.
        #expect(decls.first { $0.kind == "struct" && $0.name == "Late" }?.inherits == [])
    }

    /// Test classification is conventional, and the convention has to cover both the SPM
    /// directory layout and a suite that lives elsewhere — otherwise "no test covers this"
    /// is a statement about the naming, not about the coverage.
    @Test func testDeclarationsAreRecognisedByPathAndByContainer() {
        func target(file: String, container: String?) -> CallTarget {
            CallTarget(rowId: 1, declId: "x", name: "x", kind: "func",
                       container: container, file: file, startLine: 1)
        }
        #expect(target(file: "Tests/AppTests/FooTests.swift", container: nil).isTest)
        #expect(target(file: "Sources/App/Foo.swift", container: "FooTests").isTest)
        #expect(target(file: "Sources/App/Foo.swift", container: "LegacyTestCase").isTest)
        // A directory whose name merely ends in Tests counts; one that merely contains the
        // word does not — `Sources/Contests/` is not a test target.
        #expect(target(file: "AppTests/Foo.swift", container: nil).isTest)
        #expect(!target(file: "Sources/Contests/Foo.swift", container: nil).isTest)
        #expect(!target(file: "Sources/App/Foo.swift", container: "Store").isTest)
    }

    private func makeCallProject() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cm-calls-\(UUID().uuidString)")
        let sources = tmp.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let src = """
        struct Store {
            func save() {}
            func reset() {}
        }

        struct Other {
            func save() {}
        }

        enum Log {
            static func append(_ line: String) {}
        }

        func helper() {}

        protocol Saver {
            func persist()
        }

        struct FileSaver: Saver {
            func persist() {}
        }

        struct MemorySaver: Saver {
            func persist() {}
        }

        struct Client {
            let store: Store

            func run() {
                store.save()
                store.save()
                helper()
                Store.reset()
                var items: [String] = []
                items.append("x")
            }

            func viaLocal() {
                let local = Store()
                local.save()
            }

            func viaParameter(arg: Other) {
                arg.save()
            }

            func viaProtocol(saver: any Saver) {
                saver.persist()
            }
        }
        """
        try src.write(to: sources.appendingPathComponent("Calls.swift"), atomically: true, encoding: .utf8)
        try Config.defaultTOML.write(to: tmp.appendingPathComponent(".code-monkey.toml"),
                                     atomically: true, encoding: .utf8)
        return tmp
    }

    /// A WAL database needs its `-shm` sidecar, and a read-only handle cannot create one.
    /// A fresh clone or a reboot ships `index.db` alone, which used to make every read command
    /// die at the first prepare() with "unable to open database file".
    @Test func readOnlyOpenSurvivesMissingWalSidecars() async throws {
        let tmp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = try Project.load(explicitRoot: tmp.path)
        try FileManager.default.createDirectory(at: project.dbDir, withIntermediateDirectories: true)
        do {
            let db = try Database(path: project.dbPath, mode: .readWrite)
            try await Schema.bootstrap(db)
            _ = try await Indexer(project: project, db: db).run(full: false)
        }
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: project.dbPath.path + suffix))
        }
        #expect(!FileManager.default.fileExists(atPath: project.dbPath.path + "-shm"))

        let readOnly = try Database(path: project.dbPath, mode: .readOnly)
        let rows = try await readOnly.query("SELECT name FROM declarations WHERE name='createUser'")
        #expect(rows.count == 1)
        // Still read-only, despite holding a read-write handle.
        await #expect(throws: (any Error).self) {
            try await readOnly.run("INSERT INTO meta(key,value) VALUES('ro','1')")
        }
    }

    /// A version bump is a rebuild, not a migration — but only `index` may pay for it.
    @Test func staleSchemaIsRebuiltOnlyWhenResetIsAllowed() async throws {
        let tmp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = try Project.load(explicitRoot: tmp.path)
        let db = try Database(path: project.dbPath, mode: .readWrite)
        #expect(try await Schema.bootstrap(db) == false)   // fresh index is not stale
        try await Indexer(project: project, db: db).run(full: false)
        #expect(try await db.query("SELECT id FROM declarations").count > 0)

        // Pose as an index written by an older schema.
        try await db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','1')")

        // Every writable command other than `index` refuses rather than discarding rows.
        await #expect(throws: SchemaError.self) {
            _ = try await Schema.bootstrap(db)
        }
        #expect(try await db.query("SELECT id FROM declarations").count > 0)

        #expect(try await Schema.bootstrap(db, allowReset: true) == true)
        #expect(try await db.query("SELECT id FROM declarations").isEmpty)
        let stamped = try await db.query("SELECT value FROM meta WHERE key='schema_version'")
            .first?.string("value")
        #expect(stamped == String(Schema.version))
        // And the rebuilt shape carries the current columns.
        #expect(try await db.query("SELECT spi FROM declarations").isEmpty)
        #expect(try await db.query("SELECT spi FROM imports").isEmpty)
    }

    /// The failure this guards against is not a crash — it is confident, readable-looking
    /// garbage. Recorded offsets still resolve against an edited file; they just land in the
    /// wrong place, and the slice comes out shredded mid-word. Refusing is the only honest
    /// answer, and only for the files a read would actually open.
    @Test func editedFilesAreRefusedBeforeTheyCanBeSlicedAtStaleOffsets() async throws {
        let tmp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = try Project.load(explicitRoot: tmp.path)
        try FileManager.default.createDirectory(at: project.dbDir, withIntermediateDirectories: true)
        let db = try Database(path: project.dbPath, mode: .readWrite)
        try await Schema.bootstrap(db)
        _ = try await Indexer(project: project, db: db).run(full: false)

        let indexed = "Sources/UserService.swift"
        var drifted = try await SourceFreshness.stale([indexed], project: project, db: db)
        #expect(drifted.isEmpty)

        // Prepending shifts every offset in the file — the exact edit that shreds a slice.
        let url = project.root.appendingPathComponent(indexed)
        let original = try String(contentsOf: url, encoding: .utf8)
        try ("// a new first line\n" + original).write(to: url, atomically: true, encoding: .utf8)

        drifted = try await SourceFreshness.stale([indexed], project: project, db: db)
        #expect(drifted == [indexed])
        await #expect(throws: (any Error).self) {
            try await SourceFreshness.require([indexed], project: project, db: db)
        }

        // A path the index never recorded is stale too: nothing recorded, nothing to trust.
        let unknown = try await SourceFreshness.stale(["Sources/NeverIndexed.swift"],
                                                      project: project, db: db)
        #expect(unknown == ["Sources/NeverIndexed.swift"])

        // Nothing to slice, nothing to check — a shell-level read stays available on a stale index.
        #expect(try await SourceFreshness.stale([], project: project, db: db).isEmpty)
    }

    private func makeTempProject() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let sources = tmp.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let svc = """
        import Foundation

        public struct UserService {
            public var users: [String: String] = [:]

            //# ai:invariant: id is unique
            public func createUser(email: String) async throws -> String {
                return email
            }
        }
        """
        try svc.write(to: sources.appendingPathComponent("UserService.swift"), atomically: true, encoding: .utf8)
        // Root marker.
        try Config.defaultTOML.write(to: tmp.appendingPathComponent(".code-monkey.toml"), atomically: true, encoding: .utf8)
        return tmp
    }
}

@Suite("SPI")
struct SPITests {
    static let source = """
    @_spi(Internal) import struct Other.Thing
    @testable import Helper
    @_spi(Internal) @_spi(Testing) import Deep
    import Foundation

    @_spi(Internal) public struct Widget {
        public func inherited() {}
        @_spi(Testing) public func alsoTesting() {}
        public var count: Int = 0
    }

    public struct Plain {
        public func normal() {}
    }

    @_spi(Testing) public extension Plain {
        func fromExtension() {}
    }

    @_spi_available(iOS 1.0, *) public func decoy() {}
    """

    @Test func membersInheritTheirContainersGroups() {
        let decls = Extractor.extract(source: Self.source, file: "Test.swift")
        func spi(_ id: String) -> [String]? { decls.first { $0.declId == id }?.spi }

        #expect(spi("Widget") == ["Internal"])
        #expect(spi("Widget.inherited()") == ["Internal"])
        // Own group appended to the inherited one, outer first, no duplicates.
        #expect(spi("Widget.alsoTesting()") == ["Internal", "Testing"])
        #expect(spi("Widget.count") == ["Internal"])
        #expect(spi("Plain") == [])
        #expect(spi("Plain.normal()") == [])
        // An extension's group reaches members that carry no attribute of their own.
        #expect(spi("Plain.fromExtension()") == ["Testing"])
    }

    @Test func spiIsOrthogonalToAccess() {
        let decls = Extractor.extract(source: Self.source, file: "Test.swift")
        let widget = decls.first { $0.declId == "Widget" }
        #expect(widget?.access == "public")
        #expect(widget?.spi == ["Internal"])
    }

    @Test func lookalikeAttributesNeverMatch() {
        let decls = Extractor.extract(source: Self.source, file: "Test.swift")
        #expect(decls.first { $0.declId == "decoy()" }?.spi == [])
    }

    @Test func importsRecordGroupsAndTestable() {
        let imports = Extractor.extractAll(source: Self.source, file: "Test.swift").imports
        #expect(imports.map(\.module) == ["Other", "Helper", "Deep", "Foundation"])

        let scoped = imports[0]
        #expect(scoped.path == "Other.Thing")
        #expect(scoped.kind == "struct")
        #expect(scoped.spi == ["Internal"])
        #expect(scoped.line == 1)

        #expect(imports[1].testable)
        #expect(imports[1].spi == [])
        #expect(imports[2].spi == ["Internal", "Testing"])
        #expect(imports[3].spi == [])
        #expect(!imports[3].testable)
    }

    @Test func filterMatchesWholeGroupNames() {
        #expect(SPIFilter.parse("any").matches(["Internal"]))
        #expect(!SPIFilter.parse("any").matches([]))
        #expect(SPIFilter.parse("none").matches([]))
        #expect(!SPIFilter.parse("none").matches(["Internal"]))
        #expect(SPIFilter.parse("Testing").matches(["Internal", "Testing"]))
        // A prefix is not a match — the stored column is comma-joined.
        #expect(!SPIFilter.parse("Test").matches(["Testing"]))
    }

    @Test func groupClauseEscapesLikeWildcards() {
        // `_` leads SPI group names by convention and is a LIKE wildcard.
        let (sql, binds) = SPIFilter.parse("_Hidden").clause(column: "d.spi")
        #expect(sql.contains("ESCAPE"))
        #expect(binds.count == 1)
        #expect("\(binds[0])".contains("\\_Hidden"))
    }

    @Test func groupsRoundTripThroughTheColumn() {
        #expect(SPIFilter.groups("Internal,Testing") == ["Internal", "Testing"])
        #expect(SPIFilter.groups("") == [])
        #expect(SPIFilter.groups(nil) == [])
    }
}

// MARK: - repl

/// The shell declares no commands, options, or values of its own: it reads them back off the
/// `ParsableCommand` definitions via `_dumpHelp()`. These pin that wiring, so a change to an
/// option's type cannot quietly stop completing.
@Suite("Repl")
struct ReplTests {
    static func complete(_ line: String) throws -> [Completion] {
        let model = try CommandModel(CodeMonkey.self)
        let provider = CommandCompletionProvider(root: CodeMonkey.self, model: model)
        return provider.complete(CompletionRequest(line: line, cursor: line.count)).candidates
    }

    @Test func subcommandsCompleteInCommandPosition() throws {
        let values = try Self.complete("cal").map(\.value)
        #expect(values.contains("calls"))
    }

    @Test func optionNamesCompleteAfterASubcommand() throws {
        let values = try Self.complete("get --bo").map(\.value)
        #expect(values.contains("--body-mode"))
    }

    /// The payoff of typing the option vocabularies: `--min` was a `String` and offered nothing.
    @Test func enumOptionValuesCompleteWithTheirDescriptions() throws {
        let candidates = try Self.complete("calls Walker --min ")
        #expect(candidates.map(\.value).sorted() == ["high", "low", "medium"])
        #expect(candidates.allSatisfy { $0.detail?.isEmpty == false })
    }

    @Test func accessLevelsCompleteForEveryCommandThatTakesThem() throws {
        for line in ["code --access ", "weave --access "] {
            let values = try Self.complete(line).map(\.value)
            #expect(values.contains("public"), "\(line) did not offer access levels")
            #expect(values.contains("fileprivate"), "\(line) did not offer access levels")
        }
    }

    /// `--spi` stays an open set, so it advertises only the two words it reserves.
    @Test func spiOffersItsMagicWordsWithoutClosingTheSet() throws {
        let values = try Self.complete("imports --spi ").map(\.value)
        #expect(values.sorted() == ["any", "none"])
    }

    /// Commands that read stdin would consume the session's own input.
    @Test func stdinReadingCommandsAreRefusedNotRun() {
        let blocked = [["clip", "Walker"], ["file", "write", "/tmp/x"], ["file", "append", "/tmp/x"]]
        let allowed = [["file", "read", "/tmp/x"], ["file", "log"], ["get", "Walker"]]
        for argv in blocked {
            #expect(ReplGuards.stdinCommand(matching: argv) != nil, "\(argv) must be refused")
        }
        for argv in allowed {
            #expect(ReplGuards.stdinCommand(matching: argv) == nil, "\(argv) must run")
        }
    }

    /// `-L2` is split apart in `main()`; every other dispatch path has to agree.
    @Test func levelShorthandIsSplitForAnyDispatchPath() {
        #expect(CodeMonkey.normalized(["code", "-L2", "Walker"]) == ["code", "-L", "2", "Walker"])
        #expect(CodeMonkey.normalized(["code", "-L", "2"]) == ["code", "-L", "2"])
        #expect(CodeMonkey.normalized(["get", "-Label"]) == ["get", "-Label"])
        #expect(CodeMonkey.normalized(["calls", "--limit", "25"]) == ["calls", "--limit", "25"])
    }
}

// MARK: - audit

/// The audit log is the only record of what the tool was *asked* to do — argv is thrown away
/// the moment ArgumentParser parses it, so these pin the parts that survive.
@Suite("Audit")
struct AuditTests {
    /// A recorded line has to re-parse as written, which is why `record` is given the
    /// post-`normalized()` vector and not the raw one.
    @Test func recordedArgvReParses() throws {
        let argv = CodeMonkey.normalized(["code", "-L2", "Walker"])
        let event = AuditLog.Event(timestamp: "t", operation: argv[0], path: "/p", note: nil,
                                   argv: argv, status: "ok", ms: 1)
        let round = AuditLog.decode([try Self.line(event)])
        #expect(round.count == 1)
        let replayed = try #require(round.first?.argv)
        #expect(replayed == ["code", "-L", "2", "Walker"])
        // The point of round-tripping: the vector still resolves to a real command.
        let model = try CommandModel(CodeMonkey.self)
        #expect(model.resolve(path: [replayed[0]]).consumed == [replayed[0]])
    }

    /// Nil fields are omitted rather than written as null, so the older per-operation entries
    /// stay byte-identical and a reader tells the two kinds apart by `argv` alone.
    @Test func operationEntriesCarryNoArgv() throws {
        let legacy = AuditLog.Event(timestamp: "t", operation: "write", path: "/p", note: "ctx")
        let text = try Self.line(legacy)
        #expect(!text.contains("argv"))
        #expect(!text.contains("null"))
        #expect(AuditLog.decode([text]).first?.argv == nil)
    }

    /// The log is append-only and shared; a torn final write must not take the reader down.
    @Test func undecodableLinesAreSkippedNotThrown() {
        let good = #"{"timestamp":"t","operation":"get","path":"/p","argv":["get","X"]}"#
        #expect(AuditLog.decode(["", "{oops", good]).map(\.operation) == ["get"])
    }

    /// `record` resolves the project from argv, because parsing is what may have failed.
    @Test func projectIsScrapedFromArgvInEitherSpelling() {
        #expect(AuditLog.optionValue("--project", in: ["get", "X", "--project", "/tmp/a"]) == "/tmp/a")
        #expect(AuditLog.optionValue("--project", in: ["get", "X", "--project=/tmp/b"]) == "/tmp/b")
        #expect(AuditLog.optionValue("--project", in: ["get", "X"]) == nil)
        // A trailing `--project` has no value to take; it must not read off the end.
        #expect(AuditLog.optionValue("--project", in: ["get", "--project"]) == nil)
    }

    private static func line(_ event: AuditLog.Event) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(event), as: UTF8.self)
    }
}

// MARK: - audit stats

/// The stats pass is the only thing that reads the log back as evidence, and every number in
/// it comes from argv resolved against the live command tree — so these pin the resolution,
/// not the arithmetic.
@Suite("Audit stats")
struct AuditStatsTests {
    static func parse(_ argv: [String]) throws -> AuditStats.Invocation {
        try #require(AuditStats.parse(argv, model: try CommandModel(CodeMonkey.self)))
    }

    /// The case that made this use the command tree instead of a leading-dash test: `/tmp/x`
    /// is a value, not a target, and counting it as one corrupts every target statistic.
    @Test func optionValuesAreNotMistakenForPositionals() throws {
        let invocation = try Self.parse(["get", "--project", "/tmp/x", "Walker", "--json"])
        #expect(invocation.positionals == ["Walker"])
        #expect(invocation.value("--project") == "/tmp/x")
        #expect(invocation.has("--json"))
        #expect(AuditStats.target(of: invocation) == "Walker")
    }

    @Test func subcommandPathsResolveWholeAndEqualsFormParses() throws {
        let invocation = try Self.parse(["file", "log", "--last=50", "--argv"])
        #expect(invocation.command == "file log")
        #expect(invocation.value("--last") == "50")
        #expect(invocation.has("--argv"))
    }

    /// argv is the honest depth signal; the `tier` a command reports about itself is often
    /// just the command's own name.
    @Test func depthComesFromArgvNotFromTheReportedTier() throws {
        #expect(AuditStats.depth(of: try Self.parse(["code", "-L", "2", "Walker"])) == "L2")
        #expect(AuditStats.depth(of: try Self.parse(["code", "Walker"])) == "L default")
        #expect(AuditStats.depth(of: try Self.parse(["code", "-L", "3", "W", "--expand", "is"]))
                == "L3+expand")
        #expect(AuditStats.depth(of: try Self.parse(["get", "Walker"])) == "shell")
        #expect(AuditStats.depth(of: try Self.parse(["get", "W", "--body-mode", "fold"]))
                == "body:fold")
        // Not part of the disclosure ladder, so deliberately unclassified.
        #expect(AuditStats.depth(of: try Self.parse(["calls", "Walker"])) == nil)
    }

    /// A recorded argv naming an option this build dropped must not resolve to something else.
    @Test func argvThatNoLongerParsesIsCountedNotGuessed() throws {
        let model = try CommandModel(CodeMonkey.self)
        #expect(AuditStats.parse(["no-such-command", "X"], model: model) == nil)
        let report = AuditStats.build(from: [Self.event(["no-such-command", "X"]),
                                             Self.event(["get", "Walker"])],
                                      model: model)
        #expect(report.invocations == 2)
        #expect(report.parsed == 1)
    }

    /// `query`'s positional is redacted before it reaches the log, so it can never be a target.
    @Test func redactedSqlIsNeverATarget() throws {
        let redacted = AuditLog.redacting(["query", "SELECT 1", "--project", "/tmp/x"])
        #expect(redacted == ["query", "<sql>", "--project", "/tmp/x"])
        #expect(AuditLog.redacting(["get", "SELECT 1"]) == ["get", "SELECT 1"])
        #expect(AuditStats.target(of: try Self.parse(redacted)) == nil)
    }

    /// The re-read signal: the cheap tier ran, then a deeper one on the same target.
    @Test func reReadsAreCountedPerPairWithinTheWindow() throws {
        let report = AuditStats.build(
            from: [Self.event(["get", "Walker"], at: 0),
                   Self.event(["code", "-L", "2", "Walker"], at: 5),
                   Self.event(["get", "Walker"], at: 10_000),        // outside the window
                   Self.event(["code", "-L", "2", "Walker"], at: 10_005)],
            model: try CommandModel(CodeMonkey.self))
        let pair = try #require(report.repeated_targets.first { $0.then == "code L2" })
        #expect(pair.target == "Walker")
        #expect(pair.first == "get shell")
        #expect(pair.count == 2)
        // The gap-crossing pair is not a re-read, so `get shell` never follows `code L2`.
        #expect(!report.repeated_targets.contains { $0.first == "code L2" })
    }

    @Test func nearestRankPercentiles() {
        #expect(AuditStats.percentile([], 50) == nil)
        #expect(AuditStats.percentile([7], 90) == 7)
        #expect(AuditStats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 50) == 5)
        #expect(AuditStats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90) == 9)
    }

    private static func event(_ argv: [String], at seconds: TimeInterval = 0) -> AuditLog.Event {
        let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        return AuditLog.Event(timestamp: stamp, operation: argv[0], path: "/p", note: nil,
                              argv: argv, status: "ok", ms: 10)
    }
}

// MARK: - mcp bridge

/// The MCP tool surface is generated from the same `ParsableCommand` definitions the CLI and the
/// shell read, so these pin the generation rather than transcribing schemas a second time.
@Suite("Bridge")
struct BridgeTests {
    static func bridge() throws -> ToolBridge {
        ToolBridge(root: try CommandModel(CodeMonkey.self).root, policy: ToolPolicy())
    }

    static func schema(_ tool: String) throws -> [String: Value] {
        let tools = try bridge().tools()
        guard let match = tools.first(where: { $0.name == tool }) else {
            Issue.record("no tool named \(tool)"); return [:]
        }
        return match.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
    }

    @Test func everyRunnableCommandBecomesATool() throws {
        let names = try Self.bridge().commands.map(\.name)
        #expect(names.contains("code_monkey_get"))
        #expect(names.contains("code_monkey_calls"))
        // A grouping command is not runnable, so it yields its children instead of itself.
        #expect(!names.contains("code_monkey_file"))
        #expect(names.contains("code_monkey_file_read"))
        #expect(names.contains("code_monkey_file_append"))
        // An interactive shell is not something a client can drive.
        #expect(!names.contains("code_monkey_repl"))
        #expect(!names.contains("code_monkey_help"))
    }

    /// The seam with the typed option vocabularies: an option declared as an enum arrives here
    /// as a JSON Schema `enum`. Declared as a `String` it carries no constraint at all.
    @Test func typedOptionsBecomeSchemaEnums() throws {
        let calls = try Self.schema("code_monkey_calls")
        let values = calls["min"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(values?.sorted() == ["high", "low", "medium"])
        // The per-value glosses ride along in the description.
        let text = calls["min"]?.objectValue?["description"]?.stringValue ?? ""
        #expect(text.contains("only the name matched"))

        let get = try Self.schema("code_monkey_get")
        let modes = get["body_mode"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(modes?.sorted() == ["fold", "full", "ref"])
    }

    /// `--spi` takes a bare group name, so a value list would be a lie.
    @Test func openSetOptionsCarryNoEnum() throws {
        let imports = try Self.schema("code_monkey_imports")
        #expect(imports["spi"] != nil)
        #expect(imports["spi"]?.objectValue?["enum"] == nil)
    }

    @Test func integerOptionsAreTypedAsIntegers() throws {
        let get = try Self.schema("code_monkey_get")
        #expect(get["limit"]?.objectValue?["type"]?.stringValue == "integer")
        #expect(get["offset"]?.objectValue?["type"]?.stringValue == "integer")
        #expect(get["query"]?.objectValue?["type"]?.stringValue == "string")
        #expect(get["deep"]?.objectValue?["type"]?.stringValue == "boolean")
        let code = try Self.schema("code_monkey_code")
        #expect(code["level"]?.objectValue?["type"]?.stringValue == "integer")
    }

    /// Flags the server drives itself must not be offered to the client.
    @Test func serverDrivenFlagsAreHidden() throws {
        #expect(try Self.schema("code_monkey_index")["call_sites"] == nil)
        #expect(try Self.schema("code_monkey_index")["no_call_sites"] == nil)
        #expect(try Self.schema("code_monkey_clip")["paste_replacing"] == nil)
        // `--format json` is injected, so offering the option would advertise a dead knob.
        #expect(try Self.schema("code_monkey_get")["format"] == nil)
        for tool in ["code_monkey_get", "code_monkey_calls", "code_monkey_index"] {
            #expect(try Self.schema(tool)["json"] == nil, "\(tool) exposed --json")
        }
    }

    /// Verified here rather than by calling it: `clip` rewrites source in place.
    @Test func clipSendsItsBodyOnStdinAndForcesTheWriteFlag() throws {
        let (argv, stdin) = try Self.bridge().invocation(
            for: "code_monkey_clip",
            arguments: ["pattern": .string("Walker.relPath"),
                        "file": .string("Sources/code-monkey/Walker.swift"),
                        "new_body": .string("func relPath() {}")])
        #expect(argv.first == "clip")
        #expect(argv.contains("Walker.relPath"))
        #expect(argv.contains("--paste-replacing"))
        #expect(argv.contains("--file"))
        #expect(stdin == "func relPath() {}")
        // The body is a payload, never an argv token.
        #expect(!argv.contains("func relPath() {}"))
    }

    @Test func fileWriteRoutesContentToStdin() throws {
        let (argv, stdin) = try Self.bridge().invocation(
            for: "code_monkey_file_append",
            arguments: ["path": .string("/tmp/x"), "content": .string("hello")])
        #expect(argv.prefix(3) == ["file", "append", "/tmp/x"])
        #expect(stdin == "hello")
    }

    /// One comma-separated string in, one `--keep` per entry out.
    @Test func commaSeparatedOptionsExpandToRepeatedFlags() throws {
        let (argv, _) = try Self.bridge().invocation(
            for: "code_monkey_get",
            arguments: ["query": .string("Walker"), "body_mode": .string("fold"),
                        "keep": .string("relPath, isExcluded")])
        #expect(argv.filter { $0 == "--keep" }.count == 2)
        #expect(argv.contains("relPath"))
        #expect(argv.contains("isExcluded"))
        // Both JSON spellings, because Get.swift gates its two modes on different flags.
        #expect(argv.contains("--json"))
        #expect(argv.contains("--format"))
    }

    /// A client that sends a number for a string option means what the shell would read.
    @Test func numericValuesRenderAsArgvTokens() throws {
        let (argv, _) = try Self.bridge().invocation(
            for: "code_monkey_calls",
            arguments: ["query": .string("Walker"), "depth": .int(3), "limit": .double(10)])
        #expect(argv.contains("3"))
        #expect(argv.contains("10"))
    }

    @Test func missingRequiredArgumentsAreRefusedBeforeSpawning() throws {
        #expect(throws: (any Error).self) {
            try Self.bridge().invocation(for: "code_monkey_calls", arguments: [:])
        }
        #expect(throws: (any Error).self) {
            try Self.bridge().invocation(for: "code_monkey_nope", arguments: [:])
        }
    }

    /// Tool names are derived now, so a renamed subcommand would empty a profile silently.
    @Test func everyProfileNameResolvesToARealTool() throws {
        let bridge = try Self.bridge()
        #expect(bridge.policy.danglingProfileNames(against: bridge.tools()).isEmpty)
    }

    /// An editing session still has to read the declaration it is about to replace. `write`
    /// once built on `essential`, which advertised `clip` to a client that could not `get`.
    @Test func theWriteProfileCanAlsoRead() throws {
        let bridge = try Self.bridge()
        let names = Set(try #require(bridge.policy.tools(bridge.tools(), profile: "write")).map(\.name))
        #expect(names.isSuperset(of: ToolPolicy.Profile.read))
        #expect(names.contains("code_monkey_get"))
        #expect(names.contains("code_monkey_clip"))
    }
}

/// Tool descriptions are the CLI's own prose now, adapted rather than rewritten. These pin the
/// two adaptations, because both fail silently: a stale shell transcript just looks like
/// documentation, and an un-renamed flag names a property the client cannot set.
@Suite("Bridge prose")
struct BridgeProseTests {
    static func description(_ tool: String) throws -> String {
        let bridge = ToolBridge(root: try CommandModel(CodeMonkey.self).root, policy: ToolPolicy())
        guard let match = bridge.tools().first(where: { $0.name == tool }) else {
            Issue.record("no tool named \(tool)"); return ""
        }
        return match.description ?? ""
    }

    /// `EXAMPLES` blocks are literal shell invocations; a client has no shell to run them in.
    @Test func shellExamplesAreLeftOnTheHelpScreen() throws {
        for tool in ["code_monkey_code", "code_monkey_calls", "code_monkey_imports", "code_monkey_get"] {
            let text = try Self.description(tool)
            #expect(!text.contains("EXAMPLES"), "\(tool) leaked its examples block")
            #expect(!text.contains("code-monkey "), "\(tool) leaked a shell invocation")
        }
    }

    /// The CLI documents `--body-mode`; the client can only set `body_mode`.
    @Test func optionsAreRenamedToThePropertiesTheClientSets() throws {
        let get = try Self.description("code_monkey_get")
        #expect(get.contains("`body_mode`"))
        #expect(get.contains("`name_like`"))
        let calls = try Self.description("code_monkey_calls")
        #expect(calls.contains("`include_refs`"))
        // No published description may name a flag the client cannot pass.
        for tool in ["code_monkey_get", "code_monkey_code", "code_monkey_calls", "code_monkey_clip"] {
            #expect(!(try Self.description(tool)).contains("--"), "\(tool) still spells a flag")
        }
    }

    /// The CLI keeps its own spelling — the renaming is for the bridge's benefit, not the CLI's.
    @Test func theHelpScreenKeepsTheDashes() {
        #expect(GetCmd.configuration.discussion.contains("`--body-mode`"))
        #expect(CallsCmd.configuration.discussion.contains("`--include-refs`"))
    }

    /// Every tool's description now comes from its own `CommandConfiguration`.
    @Test func noToolCarriesAHandWrittenDescription() throws {
        let bridge = ToolBridge(root: try CommandModel(CodeMonkey.self).root, policy: ToolPolicy())
        for tool in bridge.tools() {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
        }
        // `version` declares no abstract, so it falls back to its command name rather than "".
        #expect(try Self.description("code_monkey_version") == "version")
    }
}
