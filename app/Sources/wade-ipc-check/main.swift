import Foundation
import WadeIPC

// Headless Phase 0 check: connect to a running backend, send a tkg_event and a ping,
// and require a pong back within the timeout. Exit 0 on success, 1 otherwise.

let timeout: Duration = .seconds(5)
let client = BackendClient()
client.start()

let ok = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
        for await state in client.states where state == .connected {
            client.send(TKGEvent(
                eventType: .focusChange,
                appBundleId: "com.wade.ipc-check",
                windowTitle: "Phase 0 round-trip"
            ))
            client.send(Ping())
            break
        }
        for await message in client.messages {
            if case .pong(let ts) = message {
                print("pong received (backend timestamp \(ts))")
                return true
            }
        }
        return false
    }
    group.addTask {
        try? await Task.sleep(for: timeout)
        return false
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
}

client.stop()
if ok {
    print("OK: UDS round-trip to \(SocketPath.default)")
    exit(0)
} else {
    FileHandle.standardError.write(Data("FAIL: no pong from \(SocketPath.default) within \(timeout)\n".utf8))
    exit(1)
}
