import Testing
@testable import WadeCore

struct SuggestionSurfaceTests {
    typealias S = SuggestionSurface

    @Test func opensOnFirstWordsOnlyOnce() {
        #expect(!S.shouldAutoOpen(phase: .composing(hasText: false), alreadyShown: false))
        #expect(S.shouldAutoOpen(phase: .composing(hasText: true), alreadyShown: false))
        #expect(!S.shouldAutoOpen(phase: .composing(hasText: true), alreadyShown: true))
        #expect(!S.shouldAutoOpen(phase: .finished(hasText: true), alreadyShown: true))
    }

    @Test func neverOpensForQuietFailedOrNothing() {
        for phase: S.Phase in [.none, .quiet, .failed, .finished(hasText: false)] {
            #expect(!S.shouldAutoOpen(phase: phase, alreadyShown: false))
        }
    }

    @Test func iconStates() {
        #expect(S.icon(observing: false, phase: .composing(hasText: true), seen: false) == .notObserving)
        #expect(S.icon(observing: true, phase: .none, seen: false) == .idle)
        #expect(S.icon(observing: true, phase: .composing(hasText: false), seen: false) == .composing)
        #expect(S.icon(observing: true, phase: .finished(hasText: true), seen: false) == .ready)
        #expect(S.icon(observing: true, phase: .finished(hasText: true), seen: true) == .idle)
        #expect(S.icon(observing: true, phase: .quiet, seen: false) == .idle)
    }
}
