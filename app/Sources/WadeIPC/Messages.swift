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
    case contentSnapshot = "content_snapshot"
    case selection
}

/// Scalar JSON value for event-type-specific `metadata` (counts, durations, hashes, flags).
public enum MetadataValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }
}

extension MetadataValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .int(v) }
    public init(floatLiteral v: Double) { self = .double(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}

/// Swift → Python, frequent and small.
public struct TKGEvent: Codable, Sendable, Equatable {
    public var type = "tkg_event"
    public var eventType: TKGEventType
    public var timestamp: Double
    public var appBundleId: String
    public var windowTitle: String
    public var metadata: [String: MetadataValue]

    public init(
        eventType: TKGEventType,
        timestamp: Double = Date().timeIntervalSince1970,
        appBundleId: String,
        windowTitle: String,
        metadata: [String: MetadataValue] = [:]
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
    /// Winning anchor family, e.g. "coding" → "wade is coding…". Optional: extends the brief's shape.
    public var mode: String?
    /// The Stage 1 moment that led here: stuck, selection, settled.
    public var kind: String?
    /// What was on screen (app, title, url, excerpt, selection, error_text), for the execution stage.
    public var context: [String: String]?

    public init(suggestionId: String, gateScore: Double, jspaceConcepts: [String], tkgDigest: String,
                timestamp: Double, mode: String? = nil, kind: String? = nil, context: [String: String]? = nil) {
        self.suggestionId = suggestionId
        self.gateScore = gateScore
        self.jspaceConcepts = jspaceConcepts
        self.tkgDigest = tkgDigest
        self.timestamp = timestamp
        self.mode = mode
        self.kind = kind
        self.context = context
    }
}

/// The app's settings that Stage 1 uses. Sent on every connect and whenever one changes.
public struct BackendConfig: Codable, Sendable, Equatable {
    public var type = "config"
    public var settledDwellS: Double  // "settled_dwell_s" on the wire

    public init(settledDwellS: Double) {
        self.settledDwellS = settledDwellS
    }
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
