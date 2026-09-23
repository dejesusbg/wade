// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Wade",
    platforms: [.macOS(.v26)],
    targets: [
        // Wire protocol + UDS client shared by the app and the headless check tool.
        .target(name: "WadeIPC"),
        // UI-free logic: memory stores, integrations catalog, event detectors. Unit-tested.
        .target(name: "WadeCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Wade", dependencies: ["WadeIPC", "WadeCore"]),
        // Headless UDS round-trip check (no GUI, no permissions).
        .executableTarget(name: "wade-ipc-check", dependencies: ["WadeIPC"]),
        .testTarget(name: "WadeCoreTests", dependencies: ["WadeCore"]),
        .testTarget(name: "WadeIPCTests", dependencies: ["WadeIPC"]),
    ]
)
