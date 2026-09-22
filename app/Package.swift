// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Wade",
    platforms: [.macOS(.v26)],
    targets: [
        // Wire protocol + UDS client shared by the app and the headless check tool.
        .target(name: "WadeIPC"),
        .executableTarget(name: "Wade", dependencies: ["WadeIPC"]),
        // Headless UDS round-trip check (no GUI, no permissions), for Phase 0 / CI.
        .executableTarget(name: "wade-ipc-check", dependencies: ["WadeIPC"]),
    ]
)
