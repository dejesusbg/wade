import AppKit
import SwiftUI
import WadeIPC

// Menu bar residency only (CLAUDE.md §5.1): no Dock icon, no cursor-follow. Windows exist
// only for onboarding and settings. No global hotkey in v1 — triggering is automatic.

@main
struct WadeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Wade", systemImage: model.glyph) {
            MenuContent(model: model)
        }

        Window("Welcome to Wade", id: "onboarding") {
            OnboardingView(permission: model.permission, memory: model.memory)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.memory.onboardingCompleted ? .suppressed : .presented)

        Settings {
            SettingsView(permission: model.permission, memory: model.memory)
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let permission = AccessibilityPermission()
    let memory = MemoryModel()
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
                if case .triggerFired(let trigger) = message { self.lastTrigger = trigger }
            }
        }
        syncObserver()
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

    var glyph: String {
        if backendState == .disconnected || !isObserving { return "circle.dashed" }
        return lastTrigger == nil ? "circle" : "circle.fill"
    }
}

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.backendState == .connected ? "Backend: connected" : "Backend: not running")
        if !model.memory.onboardingCompleted {
            Text("Setup not finished")
        } else if !model.permission.isTrusted {
            Text("Accessibility access needed")
            Button("Grant Accessibility Access…") { model.permission.request() }
        } else {
            Text("Observing · \(model.eventCount) events sent")
            if let e = model.lastEvent {
                Text("Last: \(e.eventType.rawValue) · \(e.appBundleId)")
            }
            if let t = model.lastTrigger {
                // Placeholder until the Phase 6 popover: shows Stage 2 fires as they arrive.
                Text("wade is \(t.mode ?? "thinking")… · \(t.jspaceConcepts.prefix(3).joined(separator: ", "))")
            }
        }
        Divider()
        Button(model.memory.onboardingCompleted ? "Setup…" : "Finish Setup…") {
            openWindow(id: "onboarding")
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Wade") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
