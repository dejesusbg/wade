// Test fixture: a throwaway app that shows real error alerts so `error_dialog` detection
// can be checked end to end. Built and driven by scripts/dialog-probe.sh.
//
//   t=0   alert A "…Error 42…" appears          → expect error_dialog (window created)
//   t=2   (driver switches to Finder and back)  → expect NO new event (same dialog)
//   t=6   alert A closes
//   t=8   alert B "…Error 43…" appears          → expect error_dialog, same signature as A
//   t=11  alert B closes, app exits
import AppKit

@MainActor func show(_ number: Int, for seconds: Double) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    // Clearly labeled: this pops up on a real screen. Still contains error keywords + a number.
    alert.messageText = "Wade test \u{2014} simulated error, nothing is wrong"
    alert.informativeText = "Error \(number): this failure is fake. It closes by itself in a few seconds."
    let timer = Timer(timeInterval: seconds, repeats: false) { _ in
        MainActor.assumeIsolated { NSApp.abortModal() }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    NSApp.activate()
    alert.runModal()
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.finishLaunching()
MainActor.assumeIsolated {
    show(42, for: 6)
    RunLoop.main.run(until: .now + 2)
    show(43, for: 3)
}
