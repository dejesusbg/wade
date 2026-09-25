import Foundation
import os

/// Starts the Python backend when Wade opens, and stops it when Wade quits, so the two never
/// need separate terminals. If a backend is already running (e.g. started by hand with
/// `--eval-log`), the app just connects to it and launches nothing.
///
/// Development layout only for v1: the backend is found next to the app's source tree
/// (`<repo>/backend`, from `<repo>/app/build/Wade.app`) or at the path in the
/// `backend.directory` default, and run with `uv`. Its output is discarded: INFO lines include
/// window titles, and nothing with screen content is written to disk unless asked for.
@MainActor
@Observable
final class BackendLauncher {
    enum State: Equatable {
        case idle, external, starting, running, failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private let log = Logger(subsystem: "wade", category: "backend")
    static let maxRestarts = 3

    /// Called once shortly after launch, with whether the app is already connected.
    func startIfNeeded(alreadyConnected: Bool) {
        guard process == nil else { return }
        if alreadyConnected {
            state = .external
            log.info("backend already running; not launching one")
            return
        }
        guard let dir = Self.backendDirectory() else {
            state = .failed("backend folder not found (set the backend.directory default)")
            return
        }
        guard let uv = Self.uvPath() else {
            state = .failed("uv not found (brew install uv)")
            return
        }
        launch(uv: uv, dir: dir)
    }

    private func launch(uv: URL, dir: URL) {
        let p = Process()
        p.executableURL = uv
        // --exit-with-pid: the backend exits when Wade is gone, even if Wade is killed or crashes.
        p.arguments = ["run", "--project", dir.path, "wade-backend",
                       "--exit-with-pid", String(ProcessInfo.processInfo.processIdentifier)]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.exited(status: proc.terminationStatus, uv: uv, dir: dir) }
        }
        do {
            try p.run()
            process = p
            state = .starting
            log.info("launched backend (pid \(p.processIdentifier)) from \(dir.path, privacy: .public)")
        } catch {
            state = .failed("couldn't start the backend: \(error.localizedDescription)")
        }
    }

    func connected() {
        if process != nil { state = .running }
    }

    private func exited(status: Int32, uv: URL, dir: URL) {
        process = nil
        guard !stopping else { return }
        log.error("backend exited with status \(status)")
        if restarts < Self.maxRestarts {
            restarts += 1
            launch(uv: uv, dir: dir)
        } else {
            state = .failed("the backend keeps stopping (exit \(status)); run `uv run wade-backend` in backend/ to see why")
        }
    }

    @ObservationIgnored private var stopping = false

    /// On quit: SIGTERM, which the backend handles by closing and removing its socket.
    func stop() {
        stopping = true
        guard let p = process, p.isRunning else { return }
        p.terminate()
        p.waitUntilExit()
        process = nil
    }

    static func backendDirectory() -> URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "backend.directory") {
            let url = URL(filePath: (custom as NSString).expandingTildeInPath)
            if fm.fileExists(atPath: url.appending(path: "pyproject.toml").path) { return url }
        }
        // <repo>/app/build/Wade.app → <repo>/backend
        let repo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appending(path: "backend")
        return fm.fileExists(atPath: dir.appending(path: "pyproject.toml").path) ? dir : nil
    }

    static func uvPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0) }
    }
}
