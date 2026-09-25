import AppKit
import SwiftUI
import WadeIPC

// Menu bar residency only (CLAUDE.md §5.1): no Dock icon, no cursor-follow. The icon and its
// popover are AppKit (`StatusItemController`), so Wade can open the popover itself when a
// suggestion arrives. Windows exist only for onboarding and settings. No global hotkey in v1.

@main
struct WadeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Everything is owned by the delegate; SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var windows: WindowPresenter?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let windows = WindowPresenter(model: model)
        self.model = model
        self.windows = windows
        statusItem = StatusItemController(model: model, windows: windows)
        if !model.memory.onboardingCompleted { windows.show(.onboarding) }
    }
}

@MainActor
@Observable
final class AppModel {
    let permission = AccessibilityPermission()
    let memory = MemoryModel()
    @ObservationIgnored private(set) lazy var integrations = IntegrationsModel(memory: memory)
    @ObservationIgnored private(set) lazy var execution = ExecutionEngine(memory: memory, integrations: integrations)
    private(set) var backendState = BackendClient.State.disconnected
    private(set) var lastTrigger: TriggerFired?
    private(set) var eventCount = 0
    private(set) var lastEvent: TKGEvent?

    private let client = BackendClient()
    @ObservationIgnored private lazy var observer = ActivityObserver { [weak self] event in
        self?.forward(event)
    }

    init() {
        client.start()
        Task { [client] in
            for await state in client.states { self.backendState = state }
        }
        Task { [client] in
            for await message in client.messages {
                if case .triggerFired(let trigger) = message {
                    self.lastTrigger = trigger
                    self.execution.run(trigger)  // shown in the menu-bar popover
                }
            }
        }
        syncObserver()
        _ = integrations  // start the opted-in MCP servers
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.integrations.stop() }
        }
        // Developer hook: `open Wade.app --args --sample-suggestion` runs the sample trigger
        // through the real execution engine (same as the menu's "Try a Sample Suggestion").
        if CommandLine.arguments.contains("--sample-suggestion") {
            Task { @MainActor [weak self] in self?.execution.runSample() }
        }
        if CommandLine.arguments.contains("--sample-note") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))  // let the MCP servers start
                self?.execution.runSampleNote()
            }
        }
    }

    /// Observe only with consent (onboarding done) and permission (AX trusted). Re-evaluated
    /// whenever either changes, so revoking access in System Settings stops observation.
    private func syncObserver() {
        let shouldRun = withObservationTracking {
            memory.onboardingCompleted && permission.isTrusted
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncObserver() }
        }
        if shouldRun { observer.start() } else { observer.stop() }
    }

    var isObserving: Bool { memory.onboardingCompleted && permission.isTrusted }

    private func forward(_ event: TKGEvent) {
        eventCount += 1
        lastEvent = event
        client.send(event)
    }

    var backendConnected: Bool { backendState == .connected }

    /// One line for the popover's footer.
    var statusLine: String {
        if !backendConnected { return "Backend not running" }
        if !memory.onboardingCompleted { return "Setup not finished" }
        if !permission.isTrusted { return "Accessibility access needed" }
        return "Watching for moments · \(eventCount) events sent"
    }

    var statusSymbol: String {
        backendConnected && isObserving ? "eye" : "eye.slash"
    }
}
