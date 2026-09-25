import Foundation

/// Minimal Server-Sent Events parser shared by the direct-API wires: accumulates `event:` / `data:`
/// lines and emits an event at each blank line. Pure and line-driven, so it's unit-tested
/// without a network.
public struct SSEParser {
    public struct Event: Equatable, Sendable {
        public var event: String?
        public var data: String
    }

    private var event: String?
    private var data: [String] = []

    public init() {}

    /// Feed one line (without its trailing newline). Returns an event when a blank line ends one.
    public mutating func feed(_ line: String) -> Event? {
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
