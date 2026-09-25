import Foundation
import Testing
@testable import WadeExecution

/// Fixtures are the real notes from the 2026-09-25 runs (on-device model), good and bad.
struct GroundingTests {
    let richContext = ["app": "Google Chrome", "title": "Pixel 10 vs Galaxy S26 - specs", "url": "https://www.gsmarena.com/compare.php3",
                       "excerpt": "Compare · Pixel 10 · Galaxy S26 · Display 6.3\" OLED 120Hz · 6.2\" AMOLED 120Hz · Battery 4700 mAh · 4000 mAh · Charging 30W · 25W · Weight 198 g · 167 g · Main camera 50 MP · 50 MP · Price about $799 · about $849"]
    let thinContext = ["app": "Google Chrome", "title": "Pixel 10 vs Galaxy S26 - specs", "url": "https://www.gsmarena.com/compare.php3",
                       "excerpt": "Pixel 10 vs Galaxy S26 - specs · Compare"]
    let selectionContext = ["app": "Safari", "url": "https://www.frontiersin.org/articles/10.3389/frai.2024.00001/full",
                            "selection": "AI is already being used to analyze medical images and detect diseases such as cancer, which could improve accessibility of diagnosis for people with disabilities."]

    func problem(_ content: String, _ context: [String: String]) -> String? {
        let json = String(data: try! JSONSerialization.data(withJSONObject: ["title": "t", "content": content]), encoding: .utf8)!
        return Grounding.problem(withNote: json, context: context, digest: "In Google Chrome for 1min.")
    }

    @Test func goodNotesPass() {
        #expect(problem("- Display: Pixel 10 6.3\" OLED 120Hz vs Galaxy S26 6.2\" AMOLED 120Hz\n- Battery: Pixel 10 4700 mAh vs Galaxy S26 4000 mAh\n- Charging: 30W vs 25W\n- Price: about $799 vs about $849\nSource: https://www.gsmarena.com/compare.php3", richContext) == nil)
        #expect(problem("- AI analyzes medical images to detect cancer, improving diagnosis for people with disabilities. Source: https://www.frontiersin.org/articles/10.3389/frai.2024.00001/full", selectionContext) == nil)
        #expect(problem("AI is already being used to analyze medical images and detect diseases such as cancer.\nSource: https://www.frontiersin.org/x", selectionContext) == nil)
    }

    @Test func inventedNumbersAreCaught() {
        let p = problem("- Pixel 10: 128 GB storage, Snapdragon 8 Gen 3, 12MP main camera\n- Galaxy S26: 256 GB storage\nSource: https://www.gsmarena.com/compare.php3", thinContext)
        #expect(p?.contains("128") == true && p?.contains("aren't on screen") == true)
    }

    @Test func inventedClaimsAreCaught() {
        let p = problem("- Pixel 10: higher specs, faster processing\n- Galaxy S26: lower specs, more battery\nSource: https://www.gsmarena.com/compare.php3", thinContext)
        #expect(p?.contains("says things that aren't on screen") == true)
    }

    @Test func linkNotesAreCaughtEvenWhenPadded() {
        #expect(problem("[iPhone Duo vs iPhone 17 Pro - Apple (UK)](https://www.apple.com/uk/iphone/compare/)", thinContext)?.contains("only a link") == true)
        let padded = "- Pixel 10: [specs from gsmarena.com](https://www.gsmarena.com/compare.php3)\n- Galaxy S26: [specs from gsmarena.com](https://www.gsmarena.com/compare.php3)\n\nTitle: Pixel 10 vs Galaxy S26 - specs"
        #expect(problem(padded, thinContext) != nil)
    }

    @Test func aTitleRestatedAsANoteAddsNothing() {
        #expect(problem("A comparison of the Pixel 10 and the Galaxy S26 specs on the compare page.", thinContext)?.contains("beyond the page title") == true)
    }

    @Test func urlDigitsAndThousandsDontCount() {
        #expect(Grounding.ungroundedNumbers(in: "About 1,240,000 results. Source: https://a.b/10.3389/x", source: "About 1240000 results").isEmpty)
        #expect(Grounding.ungroundedNumbers(in: "Gen 3", source: "https://x.com/compare.php3") == ["3"])
    }

    @Test func toolBoxRefusesAnInvalidProposal() async {
        final class Events: @unchecked Sendable { var proposed = 0; var refused = 0 }
        let events = Events()
        let note = MCPTool(name: "wade__save_note", description: "Save", readOnly: false)
        let context = thinContext
        let box = ToolBox(tools: [note], runner: nil,
                          validate: { _, args in Grounding.problem(withNote: args, context: context) }) { e in
            if case .proposed = e { events.proposed += 1 }
            if case .refused = e { events.refused += 1 }
        }
        let refused = await box.handle(note.name, argumentsJSON: #"{"title":"t","content":"- Storage: 128 GB, lots of fast storage space"}"#)
        #expect(refused.hasPrefix("Not proposed:"))
        #expect(events.proposed == 0 && events.refused == 1)
    }
}
