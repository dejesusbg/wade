import AppKit
import ApplicationServices

/// Tracks whether Wade is trusted for Accessibility. There is no change notification for
/// this, so it's polled — cheap, and it also catches the user revoking access later.
@MainActor
@Observable
final class AccessibilityPermission {
    private(set) var isTrusted = AXIsProcessTrusted()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
    }

    /// Shows the system prompt. Only call after Wade has explained why it needs access.
    func request() {
        // "AXTrustedCheckOptionPrompt" == kAXTrustedCheckOptionPrompt (a non-Sendable global in Swift 6).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
