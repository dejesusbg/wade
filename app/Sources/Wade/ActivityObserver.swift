import AppKit
import ApplicationServices
import WadeCore
import WadeIPC
import os

/// Turns raw macOS signals into `tkg_event`s (CLAUDE.md §5.2). Raw only: interpretation
/// (switch frequency, recurrence, which moments are worth a check) is Stage 1's job in Python.
///
/// | event            | source                                                          |
/// |------------------|-----------------------------------------------------------------|
/// | focus_change     | NSWorkspace app activation + AX focused-window / title change   |
/// | content_snapshot | 4s after a focus change: URL + ≤500-char excerpt of the content |
/// | selection        | AX selected-text change, debounced, ≥15 chars                   |
/// | error_dialog     | AX window/sheet, dialog-like role, error-like text              |
/// | keypress_burst   | global keyDown monitor → TypingBurstDetector (counts only)      |
/// | undo             | global keyDown monitor, ⌘Z                                       |
/// | idle_start/end   | CGEventSource seconds-since-last-input, polled                 |
///
/// Privacy: key contents are never captured. Screen text (excerpts, selections, dialog text) is
/// capped, sent only to the local backend, and never read from secure (password) fields.
@MainActor
final class ActivityObserver {
    private let emit: (TKGEvent) -> Void
    private let log = Logger(subsystem: "wade", category: "observer")
    private let ownBundleId = Bundle.main.bundleIdentifier
    /// Never observed: Wade itself, and the lock screen / screen saver (nothing to help with there,
    /// and a locked Mac isn't "settled" on anything).
    private lazy var ignoredBundleIds: Set<String> = Set([ownBundleId, "com.apple.loginwindow",
                                                           "com.apple.ScreenSaver.Engine"].compactMap { $0 })

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
    private var snapshotTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var lastSelection = ""

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

        // Chromium builds its page accessibility tree lazily, seconds after it's first asked to.
        // Ask every running browser now so the tree exists by the time a snapshot needs it.
        for app in NSWorkspace.shared.runningApplications
        where Self.chromiumBrowsers.contains(app.bundleIdentifier ?? "") {
            enableManualAccessibility(AXUIElementCreateApplication(app.processIdentifier))
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
        snapshotTask?.cancel()
        selectionTask?.cancel()
        pendingFocusCause = nil
        detachAX()
        workspaceToken = nil
        keyMonitor = nil
        tick = nil
        lastEmittedFocus = nil
        lastSelection = ""
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
        guard !ignoredBundleIds.contains(bundleId) else { return }
        // Right after activation the app may not report its focused window yet; by now it usually
        // does. Same for an alert shown *as* the app activates: it can land before we attached.
        if let title = readFocusedWindowTitle() { windowTitle = title }
        inspectFocusedWindowForErrorDialog()
        if let last = lastEmittedFocus, last.bundleId == bundleId, last.title == windowTitle { return }
        lastEmittedFocus = (bundleId, windowTitle)
        // app_name lets the digest say "Chrome" instead of guessing from the bundle id.
        send(.focusChange, metadata: ["cause": .string(cause), "app_name": .string(appName)])
        scheduleSnapshot()
    }

    // MARK: Content snapshot

    /// Once the user has stayed on a context for a few seconds, capture what it *is*: its URL and
    /// a short excerpt. Glances shorter than that never read any content.
    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        let context = (bundleId, windowTitle)
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.running,
                  self.bundleId == context.0, self.windowTitle == context.1 else { return }
            if self.takeSnapshot(allowRetry: true) { return }
            // A Chromium page tree can still be building; one more try, then send what we have.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self.running,
                  self.bundleId == context.0, self.windowTitle == context.1 else { return }
            self.takeSnapshot(allowRetry: false)
        }
    }

    /// Returns false (sending nothing) when a Chromium page's tree isn't ready and a retry is allowed.
    @discardableResult
    private func takeSnapshot(allowRetry: Bool) -> Bool {
        guard let window = axElement(axApp, kAXFocusedWindowAttribute) else { return true }
        let webArea = findWebArea(in: window)
        if webArea == nil, allowRetry, Self.chromiumBrowsers.contains(bundleId) { return false }
        // On web pages, start from the ARIA `main` landmark when there is one: skips site navigation.
        let main = webArea.flatMap { area in
            findElement(in: area) { axString($0, kAXSubroleAttribute) == "AXLandmarkMain" }
        }

        var metadata: [String: MetadataValue] = ["app_name": .string(appName)]
        // The window's document is the top-level page. The web area found from the window's center
        // can be an embedded frame, whose URL is less meaningful and can carry tokens in its query.
        if let url = axURL(window, kAXDocumentAttribute) ?? (webArea.flatMap { axURL($0, kAXURLAttribute) }) {
            metadata["url"] = .string(url)
        }
        let visible = visibleTextOfFocusedElement()
        let excerpt = visible
            ?? ContentText.clip(joining: collectText(under: main ?? webArea ?? window, maxChars: 600), max: Limits.excerpt)
        if !excerpt.isEmpty { metadata["excerpt"] = .string(excerpt) }
        // Counts only, never content.
        log.info("snapshot: url=\(metadata["url"] != nil) web=\(webArea != nil) main=\(main != nil) visibleRange=\(visible != nil) excerptChars=\(excerpt.count)")
        send(.contentSnapshot, metadata: metadata)
        return true
    }

    /// For native document editors (Pages, Word, TextEdit, Xcode): the text actually on screen,
    /// not the file's start. Deliberately *not* for single-line fields or anything inside a web
    /// page: those are search boxes, forms and chat inputs, i.e. what the user is typing.
    private func visibleTextOfFocusedElement() -> String? {
        guard let element = axElement(axApp, kAXFocusedUIElementAttribute), !isSecure(element),
              axString(element, kAXRoleAttribute) == kAXTextAreaRole,
              !isInsideWebArea(element) else { return nil }
        guard let rangeValue = axValue(element, kAXVisibleCharacterRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &range),
              range.length > 0,
              let param = AXValueCreate(.cfRange, &range) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, param, &text) == .success,
              let string = text as? String else { return nil }
        let clipped = ContentText.clip(string, max: Limits.excerpt)
        return clipped.isEmpty ? nil : clipped
    }

    // MARK: Selection

    private func scheduleSelection(from element: AXUIElement) {
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            // Wait for the drag/shift-select to finish.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.running else { return }
            self.reportSelection(from: element)
        }
    }

    private func reportSelection(from element: AXUIElement) {
        // Single-line inputs (address bars, search boxes, form fields) select their whole content
        // automatically on click, so a "selection" there is what's typed in the field, not text the
        // user chose. Page text and multi-line editors still count.
        let role = axString(element, kAXRoleAttribute) ?? ""
        guard !isSecure(element), !Self.singleLineInputRoles.contains(role),
              let raw = axString(element, kAXSelectedTextAttribute) else { return }
        let text = ContentText.clip(raw, max: Limits.selection)
        guard text.count >= Limits.minSelection, text != lastSelection else { return }
        lastSelection = text
        send(.selection, metadata: ["text": .string(text), "length": .int(raw.count)])
    }

    // MARK: Accessibility observer (per frontmost app)

    private func attachAX(pid: pid_t) {
        detachAX()
        let app = AXUIElementCreateApplication(pid)
        // Never let a hung app stall our main thread for long.
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chromium browsers only build their web accessibility tree when an assistive app asks.
        if Self.chromiumBrowsers.contains(bundleId) { enableManualAccessibility(app) }

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
                     kAXWindowCreatedNotification, kAXSheetCreatedNotification,
                     kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        axApp = app
    }

    private static let singleLineInputRoles: Set<String> = [
        kAXTextFieldRole, kAXComboBoxRole, "AXSearchField",
    ]

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    private func enableManualAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]

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
        case kAXSelectedTextChangedNotification:
            scheduleSelection(from: element)
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

        let texts = collectText(under: element, maxChars: 1_000)
        guard ErrorSignature.looksLikeError(texts) else { return }

        // The same dialog arrives via WindowCreated *and* via focus/activation; report it once.
        if let last = lastErrorDialog, CFEqual(last, element) { return }
        lastErrorDialog = element

        send(.errorDialog, metadata: [
            "signature": .string(ErrorSignature.make(from: texts)),
            "role": .string(subrole ?? role ?? ""),
            "text": .string(ContentText.clip(joining: texts, max: Limits.dialogText)),
        ])
    }

    private func inspectFocusedWindowForErrorDialog() {
        if let window = axElement(axApp, kAXFocusedWindowAttribute) { inspectForErrorDialog(window) }
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

    private enum Limits {
        static let excerpt = 500
        static let selection = 500
        static let minSelection = 15
        static let dialogText = 200
        static let walkElements = 400
    }

    private func send(_ type: TKGEventType, timestamp: Double = Date().timeIntervalSince1970,
                      metadata: [String: MetadataValue] = [:]) {
        guard !ignoredBundleIds.contains(bundleId) else { return }
        emit(TKGEvent(eventType: type, timestamp: timestamp, appBundleId: bundleId,
                      windowTitle: windowTitle, metadata: metadata))
    }

    private func readFocusedWindowTitle() -> String? {
        axElement(axApp, kAXFocusedWindowAttribute).flatMap { axString($0, kAXTitleAttribute) }
    }

    /// Depth-first walk in document order collecting static text, capped by characters and
    /// elements visited. (Breadth-first ran out of budget in big web pages' layout containers
    /// before reaching any text.) Secure fields are skipped entirely, never read.
    private func collectText(under root: AXUIElement, maxChars: Int) -> [String] {
        var stack = [root], texts: [String] = [], chars = 0, visited = 0
        while let element = stack.popLast(), chars < maxChars, visited < Limits.walkElements {
            visited += 1
            let role = axString(element, kAXRoleAttribute)
            // Skip editable subtrees entirely: in web pages, text typed into chat boxes, search
            // fields and forms is exposed as ordinary text under them.
            if isSecure(element) || Self.editableRoles.contains(role ?? "") { continue }
            if role == kAXStaticTextRole,
               let value = axString(element, kAXValueAttribute),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(value)
                chars += value.count
            }
            stack.append(contentsOf: axChildren(element).reversed())
        }
        return texts
    }

    /// The page content's web area. Searching down from the window runs out of budget in browser
    /// chrome (tab strip, toolbars, bookmarks), so start from something inside the page, either the
    /// element at the window's center or the focused element, and walk up to the nearest web area.
    private func findWebArea(in window: AXUIElement) -> AXUIElement? {
        let starts = [elementAtCenter(of: window), axElement(axApp, kAXFocusedUIElementAttribute)]
        for start in starts.compactMap({ $0 }) {
            var element: AXUIElement? = start
            for _ in 0..<80 {
                guard let current = element else { break }
                if axString(current, kAXRoleAttribute) == "AXWebArea" { return current }
                element = axElement(current, kAXParentAttribute)
            }
        }
        return nil
    }

    private func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var current = axElement(element, kAXParentAttribute)
        for _ in 0..<80 {
            guard let el = current else { return false }
            if axString(el, kAXRoleAttribute) == "AXWebArea" { return true }
            current = axElement(el, kAXParentAttribute)
        }
        return false
    }

    private func elementAtCenter(of window: AXUIElement) -> AXUIElement? {
        guard let axApp,
              let posValue = axValue(window, kAXPositionAttribute), CFGetTypeID(posValue) == AXValueGetTypeID(),
              let sizeValue = axValue(window, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(unsafeDowncast(posValue, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            axApp, Float(origin.x + size.width / 2), Float(origin.y + size.height / 2), &hit)
        return result == .success ? hit : nil
    }

    /// Breadth-first: landmarks sit near the top of a web area's tree.
    private func findElement(in root: AXUIElement, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root], index = 0
        while index < queue.count, index < Limits.walkElements {
            let element = queue[index]
            index += 1
            if matches(element) { return element }
            queue.append(contentsOf: axChildren(element))
        }
        return nil
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        axString(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
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

/// URL-valued attributes come back as CFURL (AXURL) or sometimes a string (AXDocument).
private func axURL(_ element: AXUIElement?, _ attribute: String) -> String? {
    switch axValue(element, attribute) {
    case let url as URL: url.absoluteString
    case let string as String where !string.isEmpty: string
    default: nil
    }
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
