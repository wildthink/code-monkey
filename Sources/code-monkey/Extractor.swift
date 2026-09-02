import Foundation
import SwiftSyntax
import SwiftParser

//# ai:section: "Parsing"
/// Parses a Swift source string into declaration records: kind, container,
/// signature, byte offsets, leading doc comments, and `//# ai:` directives.
//# ai:invariant: returned decls are in source order (top-to-bottom)
//# ai:invariant: byte offsets are UTF-8, suitable for Data.subdata / replaceSubrange
//# ai:warn: code inside string literals is intentionally NOT visited — preserves the escape hatch
enum Extractor {
    struct Decl {
        var declId: String
        var kind: String
        var name: String
        var signature: String
        var container: String?
        var containerKind: String?
        var access: String?
        /// `@_spi(Group)` groups this decl is behind, effective rather than declared: a member
        /// inherits every group its enclosing type or extension carries, the way Swift does.
        /// Empty means not SPI. Orthogonal to `access` — SPI is a second axis, not a level.
        //# ai:invariant: outer groups come first; a decl's own groups are appended, deduped
        var spi: [String] = []
        var modifiers: [String]
        var startLine: Int
        var endLine: Int
        var declOffset: Int           // includes leading attributes
        var declLength: Int
        var bodyOffset: Int?
        var bodyLength: Int?
        var doc: String               // joined /// and /** */ lines (text only)
        var directives: [Directive]
        /// Names in the inheritance clause of a type or extension: superclass and protocols,
        /// undistinguished. Empty for everything that is not a type or an extension.
        //# ai:warn: syntax cannot tell a superclass from a protocol here — `conformances`
        //# ai:warn: resolves that later, by looking each name up in the index
        var inherits: [String] = []
    }

    struct Directive {
        var tag: String               // e.g. "ai:invariant"
        var value: String
        var line: Int
    }

    /// One name used somewhere in the source. Purely syntactic — `receiver` is the raw text of
    /// whatever the name was reached through, not a resolved type. Attribution to an enclosing
    /// declaration happens later, from `offset`.
    struct CallSite: Sendable {
        var name: String              // callee or member name
        var receiver: String?         // base expression text, when there was one
        var kind: String              // call | ref
        var line: Int
        var offset: Int               // UTF-8, absolute in the file
    }

    /// A name bound to a *stated* type inside a declaration: a local `let`/`var`, a parameter,
    /// or a typed closure parameter. This is the receiver-typing evidence the call graph needs
    /// for names that are not properties.
    //# ai:invariant: `type` is a bare nominal name — generics, optionals and `any`/`some` are
    //# ai:invariant: peeled off; collections and tuples are left unrecorded on purpose
    struct Binding: Sendable {
        var name: String
        var type: String
        var line: Int
        var offset: Int               // UTF-8, absolute in the file
    }

    /// One `import` line. The counterpart to `Decl.spi`: SPI is a two-sided contract, and the
    /// consuming side is only visible here — `@_spi(Group) import Module` is what lets a file
    /// touch that module's SPI at all.
    //# ai:invariant: `module` is the first path component; `path` is the whole dotted path
    struct Import: Sendable {
        var module: String            // `import struct Foo.Bar` -> "Foo"
        var path: String              // `import struct Foo.Bar` -> "Foo.Bar"
        var kind: String?             // struct | class | func | ... on a scoped import; else nil
        var spi: [String]             // groups from `@_spi(...)`; empty for a plain import
        var testable: Bool            // `@testable import`
        var line: Int
    }

    struct Extraction: Sendable {
        var decls: [Decl]
        var imports: [Import]
        var callSites: [CallSite]
        var bindings: [Binding]
    }

    static func extract(source: String, file: String) -> [Decl] {
        extractAll(source: source, file: file).decls
    }

    /// Two passes over one parse: `DeclVisitor` stops at declaration boundaries, `CallSiteVisitor`
    /// descends into every expression. Keeping them separate leaves the decl walk untouched, and
    /// lets the second pass be skipped outright when the call graph isn't wanted.
    static func extractAll(source: String, file: String, callSites: Bool = true) -> Extraction {
        let tree = Parser.parse(source: source)
        let locator = SourceLocationConverter(fileName: file, tree: tree)
        let decls = DeclVisitor(source: source, locator: locator)
        decls.walk(tree)
        guard callSites else {
            return Extraction(decls: decls.decls, imports: decls.imports, callSites: [], bindings: [])
        }
        let calls = CallSiteVisitor(locator: locator)
        calls.walk(tree)
        return Extraction(decls: decls.decls, imports: decls.imports,
                          callSites: calls.sites, bindings: calls.bindings)
    }
}

// MARK: - Attributes

/// The `@_spi(...)` and `@testable` attributes, read off any node that can carry attributes.
///
/// Groups are parsed from the attribute's own text rather than from its argument node: `_spi`
/// takes a bare identifier, which SwiftSyntax has modelled differently across releases, while
/// the text between the parentheses has been stable throughout.
//# ai:warn: name equality is exact — `@_spi_available` is a different attribute and never matches
enum SPIAttribute {
    static func groups(of node: some SyntaxProtocol) -> [String] {
        guard let attributed = node.asProtocol(WithAttributesSyntax.self) else { return [] }
        return groups(in: attributed.attributes)
    }

    static func groups(in attributes: AttributeListSyntax) -> [String] {
        var out: [String] = []
        for element in attributes {
            guard case .attribute(let attr) = element,
                  attr.attributeName.trimmedDescription == "_spi",
                  let group = parenthesized(attr.trimmedDescription),
                  !group.isEmpty, !out.contains(group)
            else { continue }
            out.append(group)
        }
        return out
    }

    static func isTestable(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard case .attribute(let attr) = element else { return false }
            return attr.attributeName.trimmedDescription == "testable"
        }
    }

    private static func parenthesized(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")"),
              open < close
        else { return nil }
        return String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Call sites

/// Records every name used in an expression, with the text it was reached through.
/// This is a *syntactic* pass: `foo.bar()` yields `bar` with receiver `foo` and nothing
/// resolves `foo` to a type. Ambiguity is dealt with at query time, where the index can
/// weigh candidates — see `CallGraph`.
//# ai:warn: the callee of a call is recorded once, as a `call`; marking it consumed stops the
//# ai:warn: member-access and identifier visitors from recording the same token again as a `ref`
private final class CallSiteVisitor: SyntaxVisitor {
    private let locator: SourceLocationConverter
    private(set) var sites: [Extractor.CallSite] = []
    private(set) var bindings: [Extractor.Binding] = []
    private var consumed: Set<SyntaxIdentifier> = []

    /// Names that are never a declaration reference worth indexing.
    private static let ignored: Set<String> = ["self", "Self", "super", "nil", "true", "false", "_"]

    init(locator: SourceLocationConverter) {
        self.locator = locator
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            consume(member)
            record(member.declName.baseName, receiver: member.base?.trimmedDescription, kind: "call")
        } else if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            consumed.insert(ref.id)
            record(ref.baseName, receiver: nil, kind: "call")
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if !consumed.contains(node.id) {
            consume(node)
            record(node.declName.baseName, receiver: node.base?.trimmedDescription, kind: "ref")
        }
        return .visitChildren
    }

    /// A member access owns two nodes that both reach the identifier visitor: the access itself
    /// and its `declName`, which is a `DeclReferenceExpr`. Marking only the outer one leaves the
    /// inner to be recorded a second time, as a bare reference with no receiver.
    private func consume(_ node: MemberAccessExprSyntax) {
        consumed.insert(node.id)
        consumed.insert(node.declName.id)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if !consumed.contains(node.id) {
            record(node.baseName, receiver: nil, kind: "ref")
        }
        return .visitChildren
    }

    // MARK: Bindings

    /// Function and initialiser parameters. A parameter's type is stated, never guessed, so it
    /// is the strongest receiver evidence available short of a semantic index.
    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = (node.secondName ?? node.firstName).text
        bind(name, to: Self.nominal(node.type), at: node.positionAfterSkippingLeadingTrivia)
        return .visitChildren
    }

    /// `{ (db: Database) in ... }` — untyped closure parameters state nothing and are skipped.
    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        guard let type = node.type else { return .visitChildren }
        let name = (node.secondName ?? node.firstName).text
        bind(name, to: Self.nominal(type), at: node.positionAfterSkippingLeadingTrivia)
        return .visitChildren
    }

    /// `let graph = CallGraph(db: db)` and `let db: Database = ...`.
    ///
    /// Only bindings written inside a body are recorded. A stored property at type scope is
    /// already reachable through `declarations`, and recording it here would attribute it to
    /// itself rather than to any caller.
    //# ai:why: this is what makes `graph.resolve(...)` grade `high` instead of `low` — without
    //# ai:why: it, every receiver that is a local reads as unknown and true callers are dropped
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard Self.isInsideBody(node) else { return .visitChildren }
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let type = binding.typeAnnotation.map { Self.nominal($0.type) }
                ?? binding.initializer.flatMap { Self.constructedType($0.value) }
            bind(pattern.identifier.text, to: type,
                 at: pattern.positionAfterSkippingLeadingTrivia)
        }
        return .visitChildren
    }

    /// `guard let graph = CallGraph(db: db) else` / `if let x = ...`. The shorthand `if let x`
    /// rebinds an existing name and states nothing new, so it carries no initializer to read.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        guard let pattern = node.pattern.as(IdentifierPatternSyntax.self) else { return .visitChildren }
        let type = node.typeAnnotation.map { Self.nominal($0.type) }
            ?? node.initializer.flatMap { Self.constructedType($0.value) }
        bind(pattern.identifier.text, to: type, at: pattern.positionAfterSkippingLeadingTrivia)
        return .visitChildren
    }

    private func bind(_ name: String, to type: String?, at position: AbsolutePosition) {
        guard let type, !type.isEmpty, !name.isEmpty, !Self.ignored.contains(name) else { return }
        bindings.append(Extractor.Binding(
            name: name,
            type: type,
            line: locator.location(for: position).line,
            offset: position.utf8Offset
        ))
    }

    /// True when some ancestor is a code block — i.e. the declaration is a local, not a member.
    private static func isInsideBody(_ node: some SyntaxProtocol) -> Bool {
        var parent = node.parent
        while let current = parent {
            if current.is(CodeBlockSyntax.self) || current.is(ClosureExprSyntax.self) { return true }
            parent = current.parent
        }
        return false
    }

    /// Peels a type down to the nominal name it is *about*: `Database?` → `Database`,
    /// `any Storage` → `Storage`, `Repo<Item>` → `Repo`, `inout Foo` → `Foo`, and the sugared
    /// forms to the types they stand for — `[String]` → `Array`, `[K: V]` → `Dictionary`.
    ///
    /// Desugaring rather than giving up is the point. A receiver known to be an `Array` cannot
    /// be reaching a project declaration named `AuditLog`, so `out.append(x)` is refuted instead
    /// of merely unexplained — and a project `extension Array` still matches by container name.
    //# ai:why: the old version returned nil for collections to avoid answering `String` for
    //# ai:why: `[String: Foo]`; naming the container type answers the real question safely
    //# ai:warn: tuples and function types get a sentinel that matches no container — by design
    private static func nominal(_ type: TypeSyntax) -> String? {
        var current = type
        while true {
            if let optional = current.as(OptionalTypeSyntax.self) { current = optional.wrappedType }
            else if let forced = current.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { current = forced.wrappedType }
            else if let some = current.as(SomeOrAnyTypeSyntax.self) { current = some.constraint }
            else if let attributed = current.as(AttributedTypeSyntax.self) { current = attributed.baseType }
            else if let tuple = current.as(TupleTypeSyntax.self), tuple.elements.count == 1,
                    let only = tuple.elements.first { current = only.type }   // `(Foo)` is just `Foo`
            else { break }
        }
        if let identifier = current.as(IdentifierTypeSyntax.self) {
            let name = identifier.name.text
            // `Self` is whatever the enclosing type is, which `grade` already handles better.
            return name == "Self" ? nil : name
        }
        // Member types name their own last component: `Extractor.Decl` is a `Decl`.
        if let member = current.as(MemberTypeSyntax.self) { return member.name.text }
        if current.is(ArrayTypeSyntax.self) { return "Array" }
        if current.is(DictionaryTypeSyntax.self) { return "Dictionary" }
        if current.is(FunctionTypeSyntax.self) { return "(function)" }
        if current.is(TupleTypeSyntax.self) { return "(tuple)" }
        return nil
    }

    /// The type produced by an initialiser expression, when the expression *says* it.
    /// `CallGraph(db: db)` does; `makeGraph()` and `store.graph` do not.
    //# ai:warn: a lowercase callee is a function call, not a constructor — inferring a type from
    //# ai:warn: it would invent one
    private static func constructedType(_ expr: ExprSyntax) -> String? {
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return nil }
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            return name.first?.isUppercase == true ? name : nil
        }
        // `Extractor.Decl(...)` and `Foo.init(...)`.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if name == "init", let base = member.base?.as(DeclReferenceExprSyntax.self) {
                return base.baseName.text.first?.isUppercase == true ? base.baseName.text : nil
            }
            return name.first?.isUppercase == true ? name : nil
        }
        return nil
    }

    private func record(_ token: TokenSyntax, receiver: String?, kind: String) {
        let name = token.text
        guard !name.isEmpty, !name.hasPrefix("$"), !Self.ignored.contains(name) else { return }
        let position = token.positionAfterSkippingLeadingTrivia
        sites.append(Extractor.CallSite(
            name: name,
            receiver: (receiver?.isEmpty ?? true) ? nil : receiver,
            kind: kind,
            line: locator.location(for: position).line,
            offset: position.utf8Offset
        ))
    }
}

// MARK: - Visitor

private final class DeclVisitor: SyntaxVisitor {
    let source: String
    let locator: SourceLocationConverter
    private(set) var decls: [Extractor.Decl] = []
    private(set) var imports: [Extractor.Import] = []
    /// `spi` on a frame is already the *effective* set for that scope — pushed as the union of
    /// the enclosing frame's groups and the container's own, so nesting needs no walk.
    private var stack: [(name: String, kind: String, spi: [String])] = []

    init(source: String, locator: SourceLocationConverter) {
        self.source = source
        self.locator = locator
        super.init(viewMode: .sourceAccurate)
    }

    /// Imports are recorded rather than declared: they own no `decl_id` and nothing can be
    /// nested inside one, so they never enter `decls` or the container stack.
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let components = node.path.map { $0.name.text }
        guard let module = components.first else { return .skipChildren }
        imports.append(Extractor.Import(
            module: module,
            path: components.joined(separator: "."),
            kind: node.importKindSpecifier?.text,
            spi: SPIAttribute.groups(in: node.attributes),
            testable: SPIAttribute.isTestable(node.attributes),
            line: locator.location(for: node.positionAfterSkippingLeadingTrivia).line
        ))
        return .skipChildren
    }

    // Containers
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(typeDecl: node, name: node.name.text, kind: "struct")
        stack.append((node.name.text, "struct", pushedSPI(node)))
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(typeDecl: node, name: node.name.text, kind: "class")
        stack.append((node.name.text, "class", pushedSPI(node)))
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(typeDecl: node, name: node.name.text, kind: "enum")
        stack.append((node.name.text, "enum", pushedSPI(node)))
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        record(typeDecl: node, name: node.name.text, kind: "protocol")
        stack.append((node.name.text, "protocol", pushedSPI(node)))
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(typeDecl: node, name: node.name.text, kind: "actor")
        stack.append((node.name.text, "actor", pushedSPI(node)))
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extName = node.extendedType.trimmedDescription
        record(typeDecl: node, name: extName, kind: "extension")
        stack.append((extName, "extension", pushedSPI(node)))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { stack.removeLast() }

    // Members
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let args = paramSignature(node.signature.parameterClause.parameters)
        let sig = node.with(\.body, nil).trimmedDescription
        emit(node: Syntax(node), kind: "func", name: name, signatureOverride: sig,
             declId: stableId(name: "\(name)(\(args))"),
             bodyNode: node.body.map { Syntax($0) }, modifiers: collectFnModifiers(node))
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let args = paramSignature(node.signature.parameterClause.parameters)
        let sig = node.with(\.body, nil).trimmedDescription
        emit(node: Syntax(node), kind: "init", name: "init", signatureOverride: sig,
             declId: stableId(name: "init(\(args))"),
             bodyNode: node.body.map { Syntax($0) }, modifiers: collectFnModifiers(node))
        return .skipChildren
    }

    /// Operator *implementations* (`static func == `, `prefix func -`) are already
    /// `FunctionDeclSyntax` and need nothing extra — only the declarations below are separate nodes.
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let args = paramSignature(node.parameterClause.parameters)
        // `{ get set }` on a requirement is part of the declaration, not an implementation —
        // keep it, the way `VariableDeclSyntax` already does. A real accessor body is dropped.
        let isRequirement = node.accessorBlock.map { block in
            if case .accessors(let list) = block.accessors { return list.allSatisfy { $0.body == nil } }
            return false
        } ?? false
        emit(node: Syntax(node), kind: "subscript", name: "subscript",
             signatureOverride: isRequirement
                ? node.trimmedDescription
                : node.with(\.accessorBlock, nil).trimmedDescription,
             declId: stableId(name: "subscript(\(args))"),
             bodyNode: node.accessorBlock.map { Syntax($0) },
             modifiers: plainModifiers(node.modifiers))
        return .skipChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        emit(node: Syntax(node), kind: "deinit", name: "deinit",
             signatureOverride: node.with(\.body, nil).trimmedDescription,
             declId: stableId(name: "deinit"),
             bodyNode: node.body.map { Syntax($0) },
             modifiers: plainModifiers(node.modifiers))
        return .skipChildren
    }

    /// `infix operator <>: SomePrecedence` — always top-level; carries no body.
    override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        emit(node: Syntax(node), kind: "operator", name: node.name.text,
             signatureOverride: node.trimmedDescription,
             declId: stableId(name: node.name.text), bodyNode: nil, modifiers: [])
        return .skipChildren
    }

    /// The signature is the header alone — the `{ higherThan: ... }` block is real content,
    /// so it stays reachable through the decl's byte range rather than being inlined here.
    override func visit(_ node: PrecedenceGroupDeclSyntax) -> SyntaxVisitorContinueKind {
        emit(node: Syntax(node), kind: "precedencegroup", name: node.name.text,
             signatureOverride: "precedencegroup \(node.name.text)",
             declId: stableId(name: node.name.text), bodyNode: nil,
             modifiers: plainModifiers(node.modifiers))
        return .skipChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        emit(node: Syntax(node), kind: "associatedtype", name: node.name.text,
             signatureOverride: node.trimmedDescription,
             declId: stableId(name: node.name.text), bodyNode: nil,
             modifiers: plainModifiers(node.modifiers))
        return .skipChildren
    }

    private func plainModifiers(_ modifiers: DeclModifierListSyntax) -> [String] {
        modifiers.map { $0.name.text }.filter { !$0.isEmpty }
    }

    /// "label:Type, label:Type" — includes types so overloads disambiguate.
    /// Whitespace stripped for compactness.
    private func paramSignature(_ params: FunctionParameterListSyntax) -> String {
        params.map { p in
            let label = p.firstName.text == "_" ? "_" : p.firstName.text
            let type = p.type.trimmedDescription.replacingOccurrences(of: " ", with: "")
            return "\(label):\(type)"
        }.joined(separator: ",")
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Each binding emits its own row.
        for binding in node.bindings {
            let name = binding.pattern.trimmedDescription
            let sig = node.trimmedDescription
            emit(node: Syntax(node), kind: node.bindingSpecifier.text, name: name,
                 signatureOverride: sig, declId: stableId(name: name),
                 bodyNode: binding.accessorBlock.map { Syntax($0) },
                 modifiers: collectVarModifiers(node))
        }
        return .skipChildren
    }

    /// `case a, b` emits one row per element, mirroring how `VariableDeclSyntax` bindings
    /// are split. Both rows share the parent decl's offsets.
    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            emit(node: Syntax(node), kind: "case", name: element.name.text,
                 signatureOverride: "case \(element.with(\.trailingComma, nil).trimmedDescription)",
                 declId: stableId(name: element.name.text),
                 bodyNode: nil, modifiers: [])
        }
        return .skipChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        emit(node: Syntax(node), kind: "typealias", name: node.name.text,
             signatureOverride: node.trimmedDescription, declId: stableId(name: node.name.text),
             bodyNode: nil, modifiers: [])
        return .skipChildren
    }

    // MARK: helpers

    private func record(typeDecl node: some SyntaxProtocol, name: String, kind: String) {
        let sig: String = {
            // signature = node up to (but not including) member block, joined.
            // We just take trimmedDescription of the node's leading parts up to '{'.
            let text = node.trimmedDescription
            if let brace = text.firstIndex(of: "{") {
                return String(text[..<brace]).trimmingCharacters(in: .whitespaces)
            }
            return text
        }()
        let inherited = (node.asProtocol(DeclGroupSyntax.self))?.inheritanceClause?
            .inheritedTypes.compactMap { Self.inheritedName($0.type) } ?? []
        emit(node: Syntax(node), kind: kind, name: name, signatureOverride: sig,
             declId: stableId(name: name), bodyNode: nil, modifiers: collectTypeModifiers(node),
             inherits: inherited)
    }

    /// The bare name of an inherited type. `Codable` stays `Codable`, `Collection<Int>` becomes
    /// `Collection`, `Swift.Equatable` becomes `Equatable`; `any`/`some` wrappers are peeled.
    private static func inheritedName(_ type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
        if let member = type.as(MemberTypeSyntax.self) { return member.name.text }
        if let some = type.as(SomeOrAnyTypeSyntax.self) { return inheritedName(some.constraint) }
        return nil
    }

    private func collectFnModifiers(_ node: some SyntaxProtocol) -> [String] {
        var mods: [String] = []
        if let f = node.as(FunctionDeclSyntax.self) {
            mods.append(contentsOf: f.modifiers.map { $0.name.text })
            if f.signature.effectSpecifiers?.asyncSpecifier != nil { mods.append("async") }
            if f.signature.effectSpecifiers?.throwsClause != nil { mods.append("throws") }
        }
        if let i = node.as(InitializerDeclSyntax.self) {
            mods.append(contentsOf: i.modifiers.map { $0.name.text })
            if i.signature.effectSpecifiers?.asyncSpecifier != nil { mods.append("async") }
            if i.signature.effectSpecifiers?.throwsClause != nil { mods.append("throws") }
        }
        return mods.filter { !$0.isEmpty }
    }

    private func collectVarModifiers(_ node: VariableDeclSyntax) -> [String] {
        var mods = node.modifiers.map { $0.name.text }
        mods.append(node.bindingSpecifier.text)  // 'let' or 'var'
        return mods.filter { !$0.isEmpty }
    }

    private func collectTypeModifiers(_ node: some SyntaxProtocol) -> [String] {
        guard let dg = node.asProtocol(DeclGroupSyntax.self) else { return [] }
        return dg.modifiers.map { $0.name.text }.filter { !$0.isEmpty }
    }

    /// A container's own groups unioned with the ones it already sits behind. Pushed onto the
    /// stack so every member below inherits the whole chain in one lookup.
    private func pushedSPI(_ node: some SyntaxProtocol) -> [String] {
        effectiveSPI(own: SPIAttribute.groups(of: node))
    }

    private func effectiveSPI(own: [String]) -> [String] {
        var out = stack.last?.spi ?? []
        for group in own where !out.contains(group) { out.append(group) }
        return out
    }

    private func stableId(name: String) -> String {
        if stack.isEmpty { return name }
        let path = stack.map { $0.name }.joined(separator: ".")
        return "\(path).\(name)"
    }

    /// Common emit path: computes offsets, doc comment, directives, and appends to `decls`.
    private func emit(node: Syntax,
                      kind: String,
                      name: String,
                      signatureOverride: String?,
                      declId: String,
                      bodyNode: Syntax?,
                      modifiers: [String],
                      inherits: [String] = []) {
        let positionWithTrivia = node.position.utf8Offset
        let positionNoTrivia = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let endPos = node.endPositionBeforeTrailingTrivia.utf8Offset
        let startLine = locator.location(for: node.positionAfterSkippingLeadingTrivia).line
        let endLine = locator.location(for: node.endPositionBeforeTrailingTrivia).line

        let (doc, directives, attrStartOffset) = parseLeadingTrivia(node: node, fallbackOffset: positionNoTrivia)
        // declOffset starts at the earliest of: leading trivia start (so we keep attrs),
        // but we don't grab doc comments themselves — only attributes.
        // attrStartOffset is the byte where attributes/whitespace-after-doc begins.
        let declOffset = max(positionWithTrivia, attrStartOffset)
        let declLength = endPos - declOffset

        var bodyOffset: Int? = nil
        var bodyLength: Int? = nil
        if let b = bodyNode {
            bodyOffset = b.position.utf8Offset
            bodyLength = b.endPosition.utf8Offset - b.position.utf8Offset
        }

        let access = modifiers.first {
            ["public", "private", "fileprivate", "internal", "open", "package"].contains($0)
        }

        decls.append(Extractor.Decl(
            declId: declId,
            kind: kind,
            name: name,
            signature: signatureOverride ?? node.trimmedDescription,
            container: stack.last?.name,
            containerKind: stack.last?.kind,
            access: access,
            spi: effectiveSPI(own: SPIAttribute.groups(of: node)),
            modifiers: modifiers,
            startLine: startLine,
            endLine: endLine,
            declOffset: declOffset,
            declLength: declLength,
            bodyOffset: bodyOffset,
            bodyLength: bodyLength,
            doc: doc,
            directives: directives,
            inherits: inherits
        ))
    }

    /// Walks leading trivia: collects /// and /** */ doc text and //# ai: directives.
    /// Returns (doc, directives, attrStartOffsetBytes).
    /// attrStartOffsetBytes = byte where the attribute/declaration starts (doc comments excluded).
    //# ai:invariant: doc comments are NOT included in decl_offset/decl_length — only attributes are
    //# ai:invariant: directives are collected even when interleaved with whitespace/newlines
    //# ai:warn: order matters — once we see a non-doc piece, later doc lines are ignored
    private func parseLeadingTrivia(node: Syntax, fallbackOffset: Int) -> (String, [Extractor.Directive], Int) {
        var docLines: [String] = []
        var directives: [Extractor.Directive] = []
        var attrStart = fallbackOffset

        var pos = node.position.utf8Offset
        var sawNonDoc = false
        for piece in node.leadingTrivia {
            let len = piece.sourceLength.utf8Length
            switch piece {
            case .docLineComment(let text):
                if !sawNonDoc {
                    docLines.append(stripDocPrefix(text))
                }
            case .docBlockComment(let text):
                if !sawNonDoc {
                    docLines.append(stripDocBlock(text))
                }
            case .lineComment(let text):
                if let d = parseDirective(line: text, startByte: pos) {
                    directives.append(d)
                } else {
                    sawNonDoc = true
                    attrStart = pos
                }
            case .blockComment:
                sawNonDoc = true
                attrStart = pos
            case .newlines, .spaces, .tabs, .carriageReturns, .carriageReturnLineFeeds, .formfeeds, .verticalTabs:
                break
            default:
                sawNonDoc = true
                attrStart = pos
            }
            pos += len
        }
        if !sawNonDoc { attrStart = fallbackOffset }
        return (docLines.joined(separator: "\n"), directives, attrStart)
    }

    private func stripDocPrefix(_ s: String) -> String {
        var t = s
        if t.hasPrefix("///") { t.removeFirst(3) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func stripDocBlock(_ s: String) -> String {
        var t = s
        if t.hasPrefix("/**") { t.removeFirst(3) }
        if t.hasSuffix("*/") { t.removeLast(2) }
        return t
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \t*")) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `//# ai:<tag>(: <value>)?`
    /// Returns nil if line is not an ai directive.
    private func parseDirective(line raw: String, startByte: Int) -> Extractor.Directive? {
        var s = raw
        // Strip leading `//` then trim.
        if s.hasPrefix("//") { s.removeFirst(2) } else { return nil }
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("ai:") else { return nil }
        // tag = ai:<word>, value = remainder after first ":" or whitespace after the tag word
        let afterAi = s.dropFirst(3)
        // Find end of tag word.
        let tagEnd = afterAi.firstIndex { !$0.isLetter && !$0.isNumber && $0 != "_" } ?? afterAi.endIndex
        let tagWord = String(afterAi[..<tagEnd])
        guard !tagWord.isEmpty else { return nil }
        var rest = String(afterAi[tagEnd...])
        if rest.hasPrefix(":") { rest.removeFirst() }
        let value = rest.trimmingCharacters(in: .whitespaces)
        let line = locator.location(for: AbsolutePosition(utf8Offset: startByte)).line
        return Extractor.Directive(tag: "ai:" + tagWord, value: value, line: line)
    }
}
