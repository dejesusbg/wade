import Foundation

/// Minimal Server-Sent Events parser for the Messages API stream: accumulates `event:` / `data:`
/// lines and emits an event at each blank line. Pure and line-driven, so it's unit-tested
/// without a network.
struct SSEParser {
    struct Event: Equatable {
        var event: String?
        var data: String
    }

    private var event: String?
    private var data: [String] = []

    /// Feed one line (without its trailing newline). Returns an event when a blank line ends one.
    mutating func feed(_ line: String) -> Event? {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if line.isEmpty {
            defer { event = nil; data = [] }
            guard event != nil || !data.isEmpty else { return nil }
            return Event(event: event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }  // comment / keep-alive
        let (field, value) = split(line)
        switch field {
        case "event": event = value
        case "data": data.append(value)
        default: break  // id, retry: unused here
        }
        return nil
    }

    private func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.hasPrefix(" ") { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }
}

/// What a Messages API stream event means for us.
enum MessagesStreamEvent: Equatable {
    case text(String)
    case done(stopReason: String?)
    case error(type: String, message: String)
    case ignored

    /// Decodes one SSE event's `data` JSON (shapes per the Messages API streaming docs).
    static func decode(_ event: SSEParser.Event) -> MessagesStreamEvent {
        guard let json = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return .ignored }
        switch type {
        case "content_block_delta":
            let delta = json["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String {
                return .text(text)
            }
            return .ignored  // thinking / tool-input deltas: not rendered
        case "message_delta":
            let stop = (json["delta"] as? [String: Any])?["stop_reason"] as? String
            return stop == nil ? .ignored : .done(stopReason: stop)
        case "error":
            let err = json["error"] as? [String: Any]
            return .error(type: err?["type"] as? String ?? "error", message: err?["message"] as? String ?? "")
        default:
            return .ignored  // message_start, content_block_start/stop, message_stop, ping
        }
    }
}
