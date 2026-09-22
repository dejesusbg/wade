import Foundation
import Network
import os

/// Client side of the Unix-domain-socket link to the Python backend.
///
/// The backend owns the socket (it's the server); the app connects and reconnects
/// on its own, so either process can be (re)started independently.
/// All mutable state is confined to `queue`.
public final class BackendClient: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case disconnected
        case connected
    }

    public let messages: AsyncStream<InboundMessage>
    public let states: AsyncStream<State>

    private let socketPath: String
    private let reconnectDelay: Duration
    private let queue = DispatchQueue(label: "wade.ipc")
    private let log = Logger(subsystem: "wade", category: "ipc")
    private let messageSink: AsyncStream<InboundMessage>.Continuation
    private let stateSink: AsyncStream<State>.Continuation

    private var connection: NWConnection?
    private var buffer = Data()
    private var running = false
    private var state = State.disconnected

    public init(socketPath: String = SocketPath.default, reconnectDelay: Duration = .seconds(2)) {
        self.socketPath = socketPath
        self.reconnectDelay = reconnectDelay
        (messages, messageSink) = AsyncStream.makeStream()
        (states, stateSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        stateSink.yield(.disconnected)
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            connect()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            connection?.cancel()
            connection = nil
            setState(.disconnected)
        }
    }

    /// Fire-and-forget. Messages sent while disconnected are dropped: TKG events are
    /// only meaningful in real time, so replaying a stale backlog would mislead the gate.
    public func send(_ message: some Encodable & Sendable) {
        let data: Data
        do {
            data = try Wire.encoder.encode(message) + [UInt8(ascii: "\n")]
        } catch {
            log.error("encode failed: \(error)")
            return
        }
        queue.async { [self] in
            guard state == .connected, let connection else { return }
            connection.send(content: data, completion: .contentProcessed { [log] error in
                if let error { log.error("send failed: \(error)") }
            })
        }
    }

    // MARK: - Queue-confined

    private func connect() {
        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connection = conn
        buffer.removeAll()
        conn.stateUpdateHandler = { [weak self, weak conn] newState in
            guard let self, let conn else { return }
            self.handle(newState, for: conn)
        }
        conn.start(queue: queue)
    }

    private func handle(_ newState: NWConnection.State, for conn: NWConnection) {
        guard conn === connection else { return }  // stale callback from a replaced connection
        switch newState {
        case .ready:
            log.info("connected to \(self.socketPath)")
            setState(.connected)
            receive(on: conn)
        case .waiting, .failed:
            // .waiting is what a missing socket file looks like; treat it as a failure and retry.
            dropAndRetry(conn)
        case .cancelled, .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            if let data { self.consume(data) }
            if isComplete || error != nil {
                self.dropAndRetry(conn)
            } else {
                self.receive(on: conn)
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            do {
                if let message = try Wire.decodeInbound(Data(line)) {
                    messageSink.yield(message)
                }
            } catch {
                log.warning("dropping malformed message: \(error)")
            }
        }
    }

    private func dropAndRetry(_ conn: NWConnection) {
        conn.cancel()
        connection = nil
        setState(.disconnected)
        guard running else { return }
        queue.asyncAfter(deadline: .now() + reconnectDelay.timeInterval) { [self] in
            if running && connection == nil { connect() }
        }
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        stateSink.yield(newState)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (s, atto) = components
        return TimeInterval(s) + TimeInterval(atto) / 1e18
    }
}
