import Carbon.HIToolbox
import Foundation

/// ⌥Space accepts the action in the popover (runs "Do it"), without reaching for the mouse
/// and without Wade taking focus from the app being typed in (CLAUDE.md §5.1: a hotkey as a
/// secondary path, not the primary interaction).
///
/// Registered only while the popover shows a pending action, so the rest of the time ⌥Space
/// types what it normally types. Uses `RegisterEventHotKey`, which needs no Input Monitoring
/// permission (it isn't a keyboard monitor).
@MainActor
final class AcceptHotKey {
    static let display = "⌥Space"

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    nonisolated(unsafe) private static var current: AcceptHotKey?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { AcceptHotKey.current?.action() } }
            return noErr
        }, 1, &spec, nil, &handler)
        Self.current = self
    }

    var isActive: Bool { ref != nil }

    func setActive(_ active: Bool) {
        if active, ref == nil {
            let id = EventHotKeyID(signature: OSType(0x5741_4445), id: 1)  // 'WADE'
            let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
            if status != noErr { ref = nil }
        } else if !active, let r = ref {
            UnregisterEventHotKey(r)
            ref = nil
        }
    }
}
