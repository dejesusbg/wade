import Foundation
import Testing
@testable import WadeCore

struct VerdictLogTests {
    @Test func appendsSnakeCaseLinesWithoutText() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wade-verdicts-\(UUID().uuidString)/verdicts.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = VerdictLog(url: url)
        log.append(Verdict(ts: 1, suggestionId: "abc", event: .composed, mode: "coding", kind: "settled",
                           outcome: "done", provider: "Apple on-device", firstTokenS: 1.2, totalS: 1.5,
                           tools: ["github__fork_repository"]))
        log.append(Verdict(ts: 2, suggestionId: "abc", event: .rejected))
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        #expect(first["suggestion_id"] as? String == "abc")
        #expect(first["event"] as? String == "composed")
        #expect(first["first_token_s"] as? Double == 1.2)
        #expect(first["sample"] as? Bool == false)
        #expect(Set(first.keys).isSubset(of: ["ts", "suggestion_id", "event", "sample", "mode", "kind", "outcome",
                                              "provider", "first_token_s", "total_s", "tools"]))
        #expect(lines[1].contains("\"rejected\""))
    }

    @Test func samplesAreMarked() {
        #expect(Verdict(suggestionId: "sample-1234", event: .opened).sample)
        #expect(!Verdict(suggestionId: "0f3a-uuid", event: .opened).sample)
    }
}
