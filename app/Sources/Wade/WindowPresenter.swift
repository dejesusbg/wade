import AppKit
import SwiftUI

/// Onboarding and Settings windows, owned by AppKit so they can be opened from the popover
/// (SwiftUI's `openWindow` / `SettingsLink` only work from views inside a SwiftUI scene).
@MainActor
final class WindowPresenter {
    enum Kind { case onboarding, settings }

    private let model: AppModel
    private var windows: [Kind: NSWindow] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func show(_ kind: Kind) {
        let window = windows[kind] ?? make(kind)
        windows[kind] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ kind: Kind) {
        windows[kind]?.close()
    }

    private func make(_ kind: Kind) -> NSWindow {
        let content: AnyView
        let title: String
        switch kind {
        case .onboarding:
            title = "Welcome to Wade"
            content = AnyView(OnboardingView(permission: model.permission, memory: model.memory,
                                             finish: { [weak self] in self?.close(.onboarding) }))
        case .settings:
            title = "Wade Settings"
            content = AnyView(SettingsView(permission: model.permission, memory: model.memory,
                                           execution: model.execution, integrations: model.integrations, app: model))
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
