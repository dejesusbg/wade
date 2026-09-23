import Foundation
import Testing
@testable import WadeIPC

@Suite struct MessagesTests {
    @Test func tkgEventEncodesSnakeCaseWithTypedMetadata() throws {
        let event = TKGEvent(
            eventType: .keypressBurst, timestamp: 1.5, appBundleId: "com.apple.Safari",
            windowTitle: "t", metadata: ["key_count": 12, "duration_s": 3.25, "flag": true, "sig": "ab"])
        let json = try JSONSerialization.jsonObject(with: Wire.encoder.encode(event)) as! [String: Any]
        #expect(json["type"] as? String == "tkg_event")
        #expect(json["event_type"] as? String == "keypress_burst")
        #expect(json["app_bundle_id"] as? String == "com.apple.Safari")
        let meta = json["metadata"] as! [String: Any]
        #expect(meta["key_count"] as? Int == 12)
        #expect(meta["duration_s"] as? Double == 3.25)
        #expect(meta["flag"] as? Bool == true)
        #expect(meta["sig"] as? String == "ab")

        #expect(try Wire.decoder.decode(TKGEvent.self, from: Wire.encoder.encode(event)) == event)
    }

    @Test func decodesTriggerFiredFromBackendShape() throws {
        let line = Data(#"{"type":"trigger_fired","suggestion_id":"abc","gate_score":0.83,"jspace_concepts":["stuck","error"],"tkg_digest":"d","timestamp":1.0}"#.utf8)
        guard case .triggerFired(let t) = try Wire.decodeInbound(line) else {
            Issue.record("expected trigger_fired"); return
        }
        #expect(t.suggestionId == "abc")
        #expect(t.jspaceConcepts == ["stuck", "error"])
    }

    @Test func newEventTypesUseBackendNames() throws {
        let snap = TKGEvent(eventType: .contentSnapshot, appBundleId: "a", windowTitle: "t",
                            metadata: ["url": "https://github.com/dejesusbg/monet", "excerpt": "monet"])
        let json = try JSONSerialization.jsonObject(with: Wire.encoder.encode(snap)) as! [String: Any]
        #expect(json["event_type"] as? String == "content_snapshot")
        #expect(TKGEventType.selection.rawValue == "selection")
    }

    @Test func ignoresUnknownTypes() throws {
        #expect(try Wire.decodeInbound(Data(#"{"type":"future_thing"}"#.utf8)) == nil)
    }
}
