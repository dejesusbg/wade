import Foundation

// Wire protocol with the Python backend (CLAUDE.md §5.2): newline-delimited JSON over AF_UNIX.
// Keep in sync with backend/src/wade_backend/protocol.py.

public enum TKGEventType: String, Codable, Sendable {
    case focusChange = "focus_change"
    case keypressBurst = "keypress_burst"
    case undo
    case errorDialog = "error_dialog"
    case idleStart = "idle_start"
    case idleEnd = "idle_end"
}

/// Swift → Python, frequent and small.
public struct TKGEvent: Codable, Sendable {
    public var type = "tkg_event"
    public var eventType: TKGEventType
    public var timestamp: Double
    public var appBundleId: String
    public var windowTitle: String
    public var metadata: [String: String]

    public init(
        eventType: TKGEventType,
        timestamp: Double = Date().timeIntervalSince1970,
        appBundleId: String,
        windowTitle: String,
        metadata: [String: String] = [:]
    ) {
        self.eventType = eventType
        self.timestamp = timestamp
        self.appBundleId = appBundleId
        self.windowTitle = windowTitle
        self.metadata = metadata
    }
}

/// Python → Swift, rare, sent only when Stage 2 fires.
public struct TriggerFired: Codable, Sendable, Equatable {
    public var suggestionId: String
    public var gateScore: Double
    public var jspaceConcepts: [String]
    public var tkgDigest: String
    public var timestamp: Double
}

/// Liveness check only; not part of the trigger protocol proper.
public struct Ping: Codable, Sendable {
    public var type = "ping"
    public init() {}
}

public enum InboundMessage: Sendable {
    case triggerFired(TriggerFired)
    case pong(timestamp: Double)
}

enum Wire {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private struct Envelope: Decodable { let type: String }
    private struct Pong: Decodable { let timestamp: Double }

    /// Returns nil for message types this build doesn't understand, so the protocol can grow.
    static func decodeInbound(_ line: Data) throws -> InboundMessage? {
        switch try decoder.decode(Envelope.self, from: line).type {
        case "trigger_fired": .triggerFired(try decoder.decode(TriggerFired.self, from: line))
        case "pong": .pong(timestamp: try decoder.decode(Pong.self, from: line).timestamp)
        default: nil
        }
    }
}

public enum SocketPath {
    public static let envVar = "WADE_SOCKET_PATH"

    public static var `default`: String {
        if let override = ProcessInfo.processInfo.environment[envVar], !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Wade/wade.sock").path(percentEncoded: false)
    }
}
