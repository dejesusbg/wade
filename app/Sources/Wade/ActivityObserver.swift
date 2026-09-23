import AppKit
import ApplicationServices
import WadeCore
import WadeIPC
import os

/// Turns raw macOS signals into `tkg_event`s (CLAUDE.md §5.2). Raw only: interpretation
/// (switch frequency, recurrence, idle-then-burst) is the TKG's job in Python.
///
/// | event          | source                                                        |
/// |----------------|---------------------------------------------------------------|
/// | focus_change   | NSWorkspace app activation + AX focused-window / title change |
/// | error_dialog   | AX window/sheet created, dialog-like role, error-like text    |
/// | keypress_burst | global keyDown monitor → TypingBurstDetector (counts only)    |
/// | undo           | global keyDown monitor, ⌘Z                                     |
/// | idle_start/end | CGEventSource seconds-since-last-input, polled               |
///
/// Privacy: key contents are never stored or sent; dialog text is reduced to a hash.
@MainActor
final class ActivityObserver {
    private let emit: (TKGEvent) -> Void
    private let log = Logger(subsystem: "wade", category: "observer")
    private let ownBundleId = Bundle.main.bundleIdentifier

    private var running = false
    private var workspaceToken: NSObjectProtocol?
    private var keyMonitor: Any?
    private var tick: Timer?

    private var axObserver: AXObserver?
    private var axApp: AXUIElement?

    private var bundleId = ""
    private var appName = ""
    private var windowTitle = ""
    private var lastEmittedFocus: (bundleId: String, title: String)?
    private var focusDebounce: Task<Void, Never>?

    /// Last reported dialog. The element identity stops re-reporting one dialog when you switch
    /// back to it; a *new* dialog with the same signature is a real recurrence and is reported.
    private var lastErrorDialog: AXUIElement?

    private var bursts = TypingBurstDetector()
    private var idle = IdleDetector()

    init(emit: @escaping (TKGEvent) -> Void) {
        self.emit = emit
    }

    func start() {
        guard !running else { return }
        running = true
        log.info("observer started")

        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let bundleId = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.appActivated(pid: pid, bundleId: bundleId) }
        }

        // Key events from *other* apps. Requires Accessibility trust — no Input Monitoring.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isUndo = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && event.charactersIgnoringModifiers?.lowercased() == "z"
            MainActor.assumeIsolated { self?.keyDown(isUndo: isUndo) }
        }

        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }

        let front = NSWorkspace.shared.frontmostApplication
        appActivated(pid: front?.processIdentifier, bundleId: front?.bundleIdentifier)
    }

    func stop() {
        guard running else { return }
        running = false
        if let workspaceToken { NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        tick?.invalidate()
        focusDebounce?.cancel()
        pendingFocusCause = nil
        detachAX()
        workspaceToken = nil
        keyMonitor = nil
        tick = nil
        lastEmittedFocus = nil
        bursts = TypingBurstDetector()
        idle = IdleDetector()
        log.info("observer stopped")
    }

    // MARK: Focus

    private func appActivated(pid: pid_t?, bundleId: String?) {
        guard let pid, let bundleId else { return }
        closeBurst()  // a typing run belongs to one app
        self.bundleId = bundleId
        appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        attachAX(pid: pid)
        windowTitle = readFocusedWindowTitle() ?? ""
        scheduleFocusEmit(cause: "app_activated")
        // An app often comes forward *because* it's showing an alert, which was created before
        // we attached, so no WindowCreated arrives for it. Check what's focused now.
        inspectFocusedWindowForErrorDialog()
    }

    /// App/window switches emit after a short settle. Title-only changes must hold still for 2s:
    /// spinners and progress counters in titles (terminals, build tools, CLIs) tick every
    /// second and would otherwise read as constant context switching. A pending app/window
    /// emit is never replaced by a title tick; it reads the latest title when it fires.
    private var pendingFocusCause: String?

    private func scheduleFocusEmit(cause: String) {
        let isTitleOnly = cause == "title_changed"
        if isTitleOnly, let pending = pendingFocusCause, pending != cause { return }
        focusDebounce?.cancel()
        pendingFocusCause = cause
        focusDebounce = Task { [weak self] in
            try? await Task.sleep(for: isTitleOnly ? .seconds(2) : .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.pendingFocusCause = nil
            self.emitFocusIfChanged(cause: cause)
        }
    }

    private func emitFocusIfChanged(cause: String) {
        guard bundleId != ownBundleId else { return }
        // Right after activation the app may not report its focused window yet; by now it usually
        // does. Same for an alert shown *as* the app activates: it can land before we attached.
        if let title = readFocusedWindowTitle() { windowTitle = title }
        inspectFocusedWindowForErrorDialog()
        if let last = lastEmittedFocus, last.bundleId == bundleId, last.title == windowTitle { return }
        lastEmittedFocus = (bundleId, windowTitle)
        // app_name lets the digest say "Chrome" instead of guessing from the bundle id.
        send(.focusChange, metadata: ["cause": .string(cause), "app_name": .string(appName)])
    }

    // MARK: Accessibility observer (per frontmost app)

    private func attachAX(pid: pid_t) {
        detachAX()
        let app = AXUIElementCreateApplication(pid)
        // Never let a hung app stall our main thread for long.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<ActivityObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { me.handleAX(name, element: element) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification,
                     kAXWindowCreatedNotification, kAXSheetCreatedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        axApp = app
    }

    private func detachAX() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        axApp = nil
    }

    private func handleAX(_ notification: String, element: AXUIElement) {
        guard running else { return }
        switch notification {
        case kAXFocusedWindowChangedNotification:
            windowTitle = readFocusedWindowTitle() ?? ""
            scheduleFocusEmit(cause: "window_changed")
            inspectFocusedWindowForErrorDialog()
        case kAXTitleChangedNotification:
            // Only the focused window's title matters; ignore tabs/buttons/background windows.
            guard let focused = axElement(axApp, kAXFocusedWindowAttribute), CFEqual(focused, element) else { return }
            windowTitle = axString(element, kAXTitleAttribute) ?? ""
            scheduleFocusEmit(cause: "title_changed")
        case kAXWindowCreatedNotification, kAXSheetCreatedNotification:
            inspectForErrorDialog(element)
        default:
            break
        }
    }

    // MARK: Error dialogs
    //
    // Heuristic, v1: a new sheet or dialog-subrole window whose static text looks like an
    // error (EN/ES keywords). Misses in-window error UI (e.g. Xcode's "Build Failed" banner,
    // which isn't a dialog) — a known gap, revisited if Phase 7 shows it matters.

    private func inspectForErrorDialog(_ element: AXUIElement) {
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        let isDialog = role == kAXSheetRole
            || subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole
        guard isDialog else { return }

        var texts: [String] = []
        collectStaticText(element, into: &texts, depth: 0)
        guard ErrorSignature.looksLikeError(texts) else { return }

        // The same dialog arrives via WindowCreated *and* via focus/activation; report it once.
        if let last = lastErrorDialog, CFEqual(last, element) { return }
        lastErrorDialog = element

        send(.errorDialog, metadata: [
            "signature": .string(ErrorSignature.make(from: texts)),
            "role": .string(subrole ?? role ?? ""),
        ])
    }

    private func inspectFocusedWindowForErrorDialog() {
        if let window = axElement(axApp, kAXFocusedWindowAttribute) { inspectForErrorDialog(window) }
    }

    private func collectStaticText(_ element: AXUIElement, into texts: inout [String], depth: Int) {
        guard depth < 6, texts.count < 30 else { return }
        if axString(element, kAXRoleAttribute) == kAXStaticTextRole,
           let value = axString(element, kAXValueAttribute), !value.isEmpty {
            texts.append(value)
        }
        for child in axChildren(element) {
            collectStaticText(child, into: &texts, depth: depth + 1)
        }
    }

    // MARK: Keys and idle

    private func keyDown(isUndo: Bool) {
        guard running else { return }
        if isUndo {
            send(.undo)
            return
        }
        if let burst = bursts.keyDown(at: Date().timeIntervalSince1970) { sendBurst(burst) }
    }

    private func onTick() {
        let now = Date().timeIntervalSince1970
        if let burst = bursts.flush(now: now) { sendBurst(burst) }

        // kCGAnyInputEventType (~0): keyboard, mouse, scroll — no extra permission needed.
        let anyInput = CGEventType(rawValue: ~0)!
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        switch idle.sample(secondsSinceInput: quiet, now: now) {
        case .started(let at)?:
            send(.idleStart, timestamp: at)
        case .ended(let at, let seconds)?:
            send(.idleEnd, timestamp: at, metadata: ["idle_seconds": .double(seconds.rounded())])
        case nil:
            break
        }
    }

    private func closeBurst() {
        if let burst = bursts.close() { sendBurst(burst) }
    }

    private func sendBurst(_ burst: TypingBurstDetector.Burst) {
        send(.keypressBurst, timestamp: burst.end, metadata: [
            "key_count": .int(burst.keyCount),
            "duration_s": .double((burst.duration * 10).rounded() / 10),
            "started_at": .double(burst.start),
        ])
    }

    // MARK: Helpers

    private func send(_ type: TKGEventType, timestamp: Double = Date().timeIntervalSince1970,
                      metadata: [String: MetadataValue] = [:]) {
        guard bundleId != ownBundleId else { return }
        emit(TKGEvent(eventType: type, timestamp: timestamp, appBundleId: bundleId,
                      windowTitle: windowTitle, metadata: metadata))
    }

    private func readFocusedWindowTitle() -> String? {
        axElement(axApp, kAXFocusedWindowAttribute).flatMap { axString($0, kAXTitleAttribute) }
    }
}

// MARK: - AX attribute access

private func axValue(_ element: AXUIElement?, _ attribute: String) -> CFTypeRef? {
    guard let element else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

private func axString(_ element: AXUIElement?, _ attribute: String) -> String? {
    axValue(element, attribute) as? String
}

private func axElement(_ element: AXUIElement?, _ attribute: String) -> AXUIElement? {
    guard let value = axValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let array = axValue(element, kAXChildrenAttribute) as? [AnyObject] else { return [] }
    return array.compactMap { item in
        CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
    }
}
