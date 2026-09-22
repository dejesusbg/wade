import AppKit
import SwiftUI
import WadeIPC

// Phase 0 skeleton: menu bar residency only (CLAUDE.md §5.1). No windows, no cursor-follow.

@main
struct WadeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    // Plain `let`, not `@State`: the App value lives for the whole process, and
    // Command Line Tools ship without the SwiftUIMacros plugin that `@State` needs.
    private let model = AppModel()

    var body: some Scene {
        MenuBarExtra("Wade", systemImage: model.glyph) {
            MenuContent(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: no Dock icon. (An LSUIElement Info.plist replaces this once we ship an .app bundle.)
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var backendState = BackendClient.State.disconnected
    private(set) var lastPong: Date?
    private(set) var lastTrigger: TriggerFired?

    private let client = BackendClient()

    init() {
        client.start()
        Task { [client] in
            for await state in client.states { self.backendState = state }
        }
        Task { [client] in
            for await message in client.messages {
                switch message {
                case .pong: self.lastPong = .now
                case .triggerFired(let trigger): self.lastTrigger = trigger
                }
            }
        }
    }

    var glyph: String {
        switch backendState {
        case .disconnected: "circle.dashed"
        case .connected: lastTrigger == nil ? "circle" : "circle.fill"
        }
    }

    func ping() { client.send(Ping()) }

    func sendTestEvent() {
        client.send(TKGEvent(
            eventType: .focusChange,
            appBundleId: Bundle.main.bundleIdentifier ?? "wade.dev",
            windowTitle: "Phase 0 test event"
        ))
    }
}

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(model.backendState == .connected ? "Backend: connected" : "Backend: not running")
        if let lastPong = model.lastPong {
            Text("Last pong: \(lastPong.formatted(date: .omitted, time: .standard))")
        }
        if let trigger = model.lastTrigger {
            Text("Last trigger: \(trigger.jspaceConcepts.joined(separator: ", "))")
        }
        Divider()
        Button("Ping backend") { model.ping() }
            .disabled(model.backendState != .connected)
        Button("Send test tkg_event") { model.sendTestEvent() }
            .disabled(model.backendState != .connected)
        Divider()
        Button("Quit Wade") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
