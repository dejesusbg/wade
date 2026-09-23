import Testing
@testable import WadeCore

@Suite struct TypingBurstDetectorTests {
    @Test func reportsRunAfterGap() {
        var d = TypingBurstDetector(gap: 2, minKeys: 3)
        for t in [0.0, 0.2, 0.4, 0.6] { #expect(d.keyDown(at: t) == nil) }
        #expect(d.flush(now: 1.0) == nil)  // not quiet long enough yet
        #expect(d.flush(now: 2.7) == .init(start: 0, end: 0.6, keyCount: 4))
        #expect(d.flush(now: 10) == nil)   // reported once only
    }

    @Test func newKeyAfterGapClosesPreviousRun() {
        var d = TypingBurstDetector(gap: 2, minKeys: 2)
        _ = d.keyDown(at: 0)
        _ = d.keyDown(at: 1)
        #expect(d.keyDown(at: 5) == .init(start: 0, end: 1, keyCount: 2))
        #expect(d.close() == nil)  // the single key at t=5 is below minKeys
    }

    @Test func dropsShortRuns() {
        var d = TypingBurstDetector(gap: 2, minKeys: 5)
        _ = d.keyDown(at: 0)
        _ = d.keyDown(at: 0.1)
        #expect(d.flush(now: 5) == nil)
    }
}

@Suite struct IdleDetectorTests {
    @Test func startAndEndEdges() {
        var d = IdleDetector(threshold: 30)
        #expect(d.sample(secondsSinceInput: 10, now: 100) == nil)
        #expect(d.sample(secondsSinceInput: 31, now: 121) == .started(at: 90))
        #expect(d.sample(secondsSinceInput: 60, now: 150) == nil)  // still idle, no repeat
        #expect(d.sample(secondsSinceInput: 1, now: 200) == .ended(at: 199, idleSeconds: 109))
        #expect(!d.isIdle)
    }
}

@Suite struct ErrorSignatureTests {
    @Test func detectsErrorsInEnglishAndSpanish() {
        #expect(ErrorSignature.looksLikeError(["Build Failed", "3 issues"]))
        #expect(ErrorSignature.looksLikeError(["No se pudo guardar el documento"]))
        #expect(!ErrorSignature.looksLikeError(["Do you want to save changes?"]))
    }

    @Test func signatureIgnoresNumbersCaseAndWhitespace() {
        let a = ErrorSignature.make(from: ["Error at line 42", "Build  FAILED"])
        let b = ErrorSignature.make(from: ["error at line 57", "build failed"])
        let c = ErrorSignature.make(from: ["Permission denied"])
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 16)
    }
}

@Suite struct ContentTextTests {
    @Test func normalizesWhitespaceAndCaps() {
        #expect(ContentText.clip("  a \n\n b\tc  ", max: 50) == "a b c")
        #expect(ContentText.clip("abcdefghij", max: 5) == "abcd…")
        #expect(ContentText.clip("abcdefghij", max: 10) == "abcdefghij")
        #expect(ContentText.clip(joining: ["Error 42:", "disk\nfull"], max: 200) == "Error 42: disk full")
    }
}
