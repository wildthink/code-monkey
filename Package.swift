// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "code-monkey",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-syntax.git", from: "601.0.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        // 2.0.1 is the floor for error reporting: `evaluateAsRoot` renders a parse failure the
        // way ArgumentParser does, naming the bad value. 2.0.0 compiles against the same call
        // and prints a bare help screen instead, so the wrong version fails silently.
        .package(url: "https://github.com/wildthink/LineEditor.git", from: "2.0.1"),
    ],
    targets: [
        .executableTarget(
            name: "code-monkey",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "CommandREPL", package: "LineEditor"),
            ]
        ),
        .executableTarget(
            name: "code-monkey-mcp",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
                // For `CommandModel` and its ToolInfoV0 accessors — the same introspection the
                // interactive shell uses, so the bridge and the REPL cannot drift apart.
                .product(name: "CommandREPL", package: "LineEditor"),
            ]
        ),
        .testTarget(
            name: "code-monkeyTests",
            dependencies: [
                "code-monkey",
                "code-monkey-mcp",
                .product(name: "CommandREPL", package: "LineEditor"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
