// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Wade",
    platforms: [.macOS("27.0")],
    dependencies: [
        // Official Claude provider for Apple's Foundation Models framework (beta, macOS 27).
        .package(url: "https://github.com/anthropics/ClaudeForFoundationModels.git", from: "0.1.0"),
        // Official MCP Swift SDK (client side: stdio transport to local MCP servers).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        // Wire protocol + UDS client shared by the app and the headless check tool.
        .target(name: "WadeIPC"),
        // UI-free logic: memory stores, integrations catalog, event detectors. Unit-tested.
        .target(name: "WadeCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // Execution stage (CLAUDE.md §5.5): provider-agnostic suggestion writing with real streaming.
        .target(name: "WadeExecution", dependencies: [
            "WadeIPC", "WadeCore",
            .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
        ]),
        // MCP tool layer (CLAUDE.md §5.6): runs opted-in MCP servers, lists and calls their tools.
        .target(name: "WadeTools", dependencies: [
            "WadeExecution", "WadeCore",
            .product(name: "MCP", package: "swift-sdk"),
        ]),
        .executableTarget(name: "Wade", dependencies: ["WadeIPC", "WadeCore", "WadeExecution", "WadeTools"]),
        // Headless UDS round-trip check (no GUI, no permissions).
        .executableTarget(name: "wade-ipc-check", dependencies: ["WadeIPC"]),
        // Headless execution check: stream a sample suggestion through one provider.
        .executableTarget(name: "wade-exec-check", dependencies: ["WadeExecution", "WadeIPC", "WadeTools"]),
        .testTarget(name: "WadeCoreTests", dependencies: ["WadeCore"]),
        .testTarget(name: "WadeIPCTests", dependencies: ["WadeIPC"]),
        .testTarget(name: "WadeExecutionTests", dependencies: ["WadeExecution"]),
        .testTarget(name: "WadeToolsTests", dependencies: ["WadeTools"]),
    ]
)
