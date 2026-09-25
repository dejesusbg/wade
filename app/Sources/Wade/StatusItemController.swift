import AppKit
import SwiftUI
import WadeCore

/// The menu-bar icon and its popover (CLAUDE.md §5.1). AppKit rather than `MenuBarExtra`,
/// because Wade has to open the popover itself when a suggestion arrives, and `MenuBarExtra`
/// can only be opened by a click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let windows: WindowPresenter
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var shownSuggestionID: String?  // the suggestion the popover last opened for, by itself or by click
    private var autoCloseTask: Task<Void, Never>?
    /// An auto-opened popover closes after this long untouched; the icon keeps showing the suggestion.
    static let autoCloseAfter: Duration = .seconds(20)

    init(model: AppModel, windows: WindowPresenter) {
        self.model = model
        self.windows = windows
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: model, windows: windows,
                                                             engaged: { [weak self] in self?.userEngaged() },
                                                             close: { [weak self] in self?.close() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Wade")
        }
        track()
    }

    /// Re-evaluated whenever the suggestion or observation state changes.
    private func track() {
        let (icon, autoOpen, id) = withObservationTracking {
            let phase = model.execution.phase
            let current = model.execution.current
            let icon = SuggestionSurface.icon(observing: model.isObserving && model.backendConnected,
                                              phase: phase, seen: current?.seen ?? true)
            let autoOpen = SuggestionSurface.shouldAutoOpen(phase: phase, alreadyShown: current?.id == shownSuggestionID)
            return (icon, autoOpen, current?.id)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        item.button?.image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: "Wade")
        if autoOpen, let id { show(for: id, automatically: true) }
    }

    @objc private func togglePopover() {
        if popover.isShown { close(); return }
        NSApp.activate()  // opened by the user: let the popover take keyboard focus
        show(for: model.execution.current?.id, automatically: false)
    }

    private func show(for id: String?, automatically: Bool) {
        shownSuggestionID = id
        guard let button = item.button else { return }
        if !popover.isShown {
            // Auto-opened without activating Wade, so whatever the user is typing keeps focus.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // Seen only when the user looks on purpose; an auto-open that closes untouched leaves
        // the icon filled, so the suggestion isn't lost.
        if !automatically { model.execution.markSeen() }
        if id != nil { model.execution.note(automatically ? .shownAuto : .opened) }
        autoCloseTask?.cancel()
        if automatically { scheduleAutoClose() }
    }

    private func scheduleAutoClose() {
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoCloseAfter)
            guard let self, !Task.isCancelled, self.popover.isShown else { return }
            // Keep it open while the pointer is over it (the user is reading).
            if let frame = self.popover.contentViewController?.view.window?.frame,
               frame.contains(NSEvent.mouseLocation) {
                self.scheduleAutoClose()
            } else {
                if self.model.execution.current?.seen == false { self.model.execution.note(.closedUnseen) }
                self.close()
            }
        }
    }

    private func userEngaged() {
        autoCloseTask?.cancel()
        model.execution.markSeen()
    }

    func close() {
        autoCloseTask?.cancel()
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        autoCloseTask?.cancel()
    }
}

/// Popover content: the suggestion, then a status line and the app's menu.
private struct PopoverView: View {
    let model: AppModel
    let windows: WindowPresenter
    let engaged: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SuggestionView(engine: model.execution, engaged: engaged)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: model.statusSymbol).foregroundStyle(.secondary)
                Text(model.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.memory.onboardingCompleted && !model.permission.isTrusted {
                    Button("Grant Access…") { model.permission.request() }.controlSize(.small)
                }
                Menu {
                    Button("Try a Sample Suggestion") { engaged(); model.execution.runSample() }
                    Button("Try a Sample Note Action") { engaged(); model.execution.runSampleNote() }
                    Divider()
                    Button(model.memory.onboardingCompleted ? "Setup…" : "Finish Setup…") {
                        close(); windows.show(.onboarding)
                    }
                    Button("Settings…") { close(); windows.show(.settings) }
                    Divider()
                    Button("Quit Wade") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}
