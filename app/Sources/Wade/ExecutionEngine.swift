import Foundation
import WadeExecution
import WadeIPC
import WadeCore
import WadeTools
import os

/// Runs the execution stage for each Stage 2 fire and exposes the streaming text to SwiftUI
/// (shown in the menu-bar popover). The providers are the user's primary and optional fallback
/// from Settings, run through `ProviderChain` (no provider is special-cased).
@MainActor
@Observable
final class ExecutionEngine {
    enum Status: Equatable {
        case streaming
        case done
        case dropped  // the model said there's nothing worth offering
        case failed(String)
    }

    /// An action the model proposed; runs only when the user clicks "Do it".
    struct Proposal: Identifiable {
        enum State: Equatable { case pending, running, done(String), failed(String) }
        let action: ProposedAction
        var state = State.pending
        var id: String { action.id }

        /// Plain-language description for the button's label.
        var summary: String {
            let args = (try? JSONSerialization.jsonObject(with: Data(action.argumentsJSON.utf8)) as? [String: Any]) ?? [:]
            switch action.tool.name {
            case ComposedTools.saveNoteName:
                return "Save note \u{201C}\(args["title"] as? String ?? "Note")\u{201D}"
            case "github__fork_repository":
                return "Fork \(args["owner"] as? String ?? "?")/\(args["repo"] as? String ?? "?") to your account"
            case "github__issue_write":
                return "Create issue \u{201C}\(args["title"] as? String ?? "…")\u{201D} in \(args["owner"] as? String ?? "?")/\(args["repo"] as? String ?? "?")"
            default:
                return "Run \(action.tool.name)"
            }
        }
    }

    struct Suggestion: Identifiable {
        let id: String
        let mode: String?
        let kind: String?
        let concepts: [String]
        var providerName = ""
        var sendsDataOffDevice = false
        var skipped: [String] = []  // providers tried first and why they didn't run
        var proposals: [Proposal] = []
        var toolsRan: [String] = []  // read-only tools the model used while composing
        var refused = 0  // proposals Wade's check turned down (e.g. a note with invented facts)
        var text = ""
        var status = Status.streaming
        let startedAt = Date()
        var firstTokenAfter: TimeInterval?
        var finishedAfter: TimeInterval?
        var seen = false      // the popover has shown it
        var feedback: Feedback?

        /// What feedback records as "what Wade suggested".
        var asSuggested: String {
            let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let actions = proposals.map(\.summary).joined(separator: "; ")
            return [text, actions].filter { !$0.isEmpty }.joined(separator: " · ")
        }

        var phase: SuggestionSurface.Phase {
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !proposals.isEmpty
            switch status {
            case .streaming: return .composing(hasText: hasText)
            case .done: return .finished(hasText: hasText)
            case .dropped: return .quiet
            case .failed: return .failed
            }
        }
    }

    /// Explicit feedback given in the popover (CLAUDE.md §5.7: explicit only).
    enum Feedback: Equatable { case accepted, rejected, corrected }

    private(set) var current: Suggestion?

    var primaryID: String {
        didSet { UserDefaults.standard.set(primaryID, forKey: Self.primaryKey) }
    }
    var fallbackID: String? {
        didSet { UserDefaults.standard.set(fallbackID ?? "", forKey: Self.fallbackKey) }
    }
    /// Seconds a provider may take to produce its first text before the next one is tried.
    var timeoutSeconds: Double {
        didSet { UserDefaults.standard.set(timeoutSeconds, forKey: Self.timeoutKey) }
    }
    /// Opt-in verdict log for Phase 7 analysis (no text; see `VerdictLog`).
    var researchLogEnabled: Bool {
        didSet { UserDefaults.standard.set(researchLogEnabled, forKey: Self.researchLogKey) }
    }
    private let verdicts = VerdictLog()
    static let timeoutRange: ClosedRange<Double> = 1.5...10  // below ~1.5s even the on-device model misses its first answer after launch
    /// Which vendors have a key in the Keychain (for Settings; keys themselves are never held here).
    private(set) var keyed: Set<Vendor> = Set(Vendor.allCases.filter { APIKeyStore.read($0) != nil })

    var chain: [ProviderDescriptor] {
        [ProviderCatalog.find(primaryID), ProviderCatalog.find(fallbackID)]
            .compactMap { $0 }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private let memory: MemoryModel
    private let integrations: IntegrationsModel
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "wade", category: "execution")
    private static let primaryKey = "execution.primary"
    private static let fallbackKey = "execution.fallback"
    private static let timeoutKey = "execution.timeout"
    private static let researchLogKey = "research.log"

    init(memory: MemoryModel, integrations: IntegrationsModel) {
        self.memory = memory
        self.integrations = integrations
        let d = UserDefaults.standard
        researchLogEnabled = d.bool(forKey: Self.researchLogKey)
        primaryID = d.string(forKey: Self.primaryKey).flatMap { ProviderCatalog.find($0)?.id }
            ?? ProviderCatalog.defaultPrimaryID
        let storedTimeout = d.double(forKey: Self.timeoutKey)
        let defaultTimeout = Double(ProviderChain.defaultFirstTokenTimeout.components.seconds)
            + Double(ProviderChain.defaultFirstTokenTimeout.components.attoseconds) / 1e18
        timeoutSeconds = storedTimeout > 0 ? min(max(storedTimeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
                                          : defaultTimeout
        if let stored = d.string(forKey: Self.fallbackKey) {
            fallbackID = stored.isEmpty ? nil : ProviderCatalog.find(stored)?.id
        } else {
            fallbackID = ProviderCatalog.defaultFallbackID
        }
    }

    func saveKey(_ key: String, for vendor: Vendor) {
        APIKeyStore.save(key, for: vendor)
        refreshKeys()
    }

    func removeKey(for vendor: Vendor) {
        APIKeyStore.delete(vendor)
        refreshKeys()
    }

    private func refreshKeys() {
        keyed = Set(Vendor.allCases.filter { APIKeyStore.read($0) != nil })
    }

    func run(_ trigger: TriggerFired) {
        task?.cancel()
        let prompt = ExecutionPrompt(trigger: trigger, facts: memory.facts, corrections: memory.corrections)
        let chain = chain
        current = Suggestion(id: trigger.suggestionId, mode: trigger.mode, kind: trigger.kind, concepts: trigger.jspaceConcepts)
        log.info("execution: \(chain.map(\.id).joined(separator: " → "), privacy: .public) for \(trigger.kind ?? "?", privacy: .public)/\(trigger.mode ?? "?", privacy: .public)")

        let manager = integrations.manager
        let timeout = Duration.milliseconds(Int(timeoutSeconds * 1000))
        let onToolEvent: @Sendable (ExecutionEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.record(event) }
        }
        task = Task { [weak self] in
            // Tools for this moment: a small curated subset of what the opted-in servers offer.
            let offered = ToolSelection.pick(from: await manager.allTools(), mode: trigger.mode,
                                             kind: trigger.kind, url: trigger.context?["url"])
            let tools = ToolBox(tools: offered, runner: manager,
                                validate: ComposedTools.validator(context: prompt.context, digest: prompt.digest), onEvent: onToolEvent)
            let stream = ProviderChain.run(chain, prompt: prompt, tools: tools, firstTokenTimeout: timeout) { descriptor in
                descriptor.makeProvider(key: APIKeyStore.read(descriptor.vendor))
            }
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled, var s = self.current else { return }
                    // Mutate a local copy, then assign: reading and writing `current` in one
                    // expression is an exclusivity violation (a runtime abort).
                    switch event {
                    case .skipped(let title, let reason):
                        s.skipped.append("\(title): \(reason)")
                    case .using(let title, let offDevice):
                        s.providerName = title
                        s.sendsDataOffDevice = offDevice
                    case .text(let delta):
                        if s.firstTokenAfter == nil { s.firstTokenAfter = Date().timeIntervalSince(s.startedAt) }
                        s.text += delta
                    }
                    self.current = s
                }
                guard let self else { return }
                // An offer whose only action was refused (and none was proposed) has nothing
                // to click: "Save the comparison…" with no button. Drop it like NOTHING.
                let offerWithoutAction = (self.current?.refused ?? 0) > 0 && (self.current?.proposals.isEmpty ?? true)
                self.finish(self.isNothing(self.current?.text ?? "") || offerWithoutAction ? .dropped : .done)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.finish(.failed(error.localizedDescription))
            }
        }
    }

    private func record(_ event: ExecutionEvent) {
        guard var s = current else { return }
        switch event {
        case .proposed(let action):
            // One proposal per tool: a model retrying the same call shouldn't stack buttons.
            s.proposals.removeAll { $0.action.tool.name == action.tool.name && $0.state == .pending }
            s.proposals.append(Proposal(action: action))
        case .toolRan(let name, let ok):
            s.toolsRan.append(ok ? name : "\(name) (failed)")
        case .refused(let name, let reason):
            s.refused += 1
            log.info("refused \(name, privacy: .public): \(reason, privacy: .public)")
        case .text:
            break
        }
        current = s
    }

    var phase: SuggestionSurface.Phase { current?.phase ?? .none }

    /// Append a verdict for the current suggestion, when the research log is on.
    func note(_ event: Verdict.Event, tools: [String]? = nil) {
        guard researchLogEnabled, let s = current else { return }
        var outcome: String?
        if event == .composed {
            switch s.status {
            case .done: outcome = "done"
            case .dropped: outcome = "dropped"
            case .failed: outcome = "failed"
            case .streaming: outcome = nil
            }
        }
        verdicts.append(Verdict(suggestionId: s.id, event: event, mode: s.mode, kind: s.kind, outcome: outcome,
                                provider: s.providerName.isEmpty ? nil : s.providerName,
                                firstTokenS: s.firstTokenAfter, totalS: s.finishedAfter,
                                tools: tools ?? (event == .composed ? s.proposals.map(\.action.tool.name) : nil)))
    }

    func markSeen() {
        guard var s = current, !s.seen else { return }
        s.seen = true
        current = s
    }

    /// "Thanks": the suggestion was fine. Not stored as a correction; nothing to correct.
    func accept() {
        setFeedback(.accepted)
        note(.accepted)
    }

    /// "Not helpful": stored as a rejection, so later suggestions see it.
    func reject() {
        guard let s = current, s.feedback == nil else { return }
        memory.addCorrection(suggestionId: s.id, suggestion: s.asSuggested,
                             correction: "Not helpful here.", provenance: .rejection)
        setFeedback(.rejected)
        note(.rejected)
    }

    /// "Correct…": what the user said would have helped instead.
    func correct(_ text: String) {
        guard let s = current, s.feedback != .rejected, s.feedback != .corrected, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        memory.addCorrection(suggestionId: s.id, suggestion: s.asSuggested, correction: text, provenance: .correction)
        setFeedback(.corrected)
        note(.corrected)
    }

    private func setFeedback(_ feedback: Feedback) {
        guard var s = current else { return }
        s.feedback = feedback
        current = s
        log.info("feedback \(String(describing: feedback), privacy: .public) on \(s.id, privacy: .public)")
    }

    /// The user clicked "Do it": run the proposed action through its MCP server.
    func perform(_ proposalID: String) {
        guard let index = current?.proposals.firstIndex(where: { $0.id == proposalID }),
              let action = current?.proposals[index].action, current?.proposals[index].state == .pending else { return }
        setProposal(proposalID, .running)
        if current?.feedback == nil { setFeedback(.accepted) }
        log.info("user accepted \(action.tool.name, privacy: .public)")
        let manager = integrations.manager
        Task { [weak self] in
            do {
                let result = try await manager.call(action.tool, argumentsJSON: action.argumentsJSON)
                self?.setProposal(proposalID, .done(String(result.prefix(300))))
                self?.note(.actionDone, tools: [action.tool.name])
            } catch {
                self?.setProposal(proposalID, .failed(error.localizedDescription))
                self?.note(.actionFailed, tools: [action.tool.name])
            }
        }
    }

    private func setProposal(_ id: String, _ state: Proposal.State) {
        guard var s = current, let i = s.proposals.firstIndex(where: { $0.id == id }) else { return }
        s.proposals[i].state = state
        current = s
    }

    /// A made-up selection moment shaped like the UX demo's "save to notes", to exercise the
    /// tool path (proposal + Do it) without waiting for a real Stage 2 fire.
    func runSampleNote() {
        run(TriggerFired(
            suggestionId: "sample-note-\(UUID().uuidString.prefix(8))", gateScore: 0,
            jspaceConcepts: ["save", "annotate"],
            tkgDigest: "In Safari ('Frontiers | AI and digital accessibility', frontiersin.org) for 40s.",
            timestamp: Date().timeIntervalSince1970, mode: "researching", kind: "selection",
            context: ["app": "Safari", "url": "https://www.frontiersin.org/articles/10.3389/frai.2024.00001/full",
                      "selection": "AI is already being used to analyze medical images and detect diseases such as cancer, which could improve accessibility of diagnosis for people with disabilities."]))
    }

    /// A made-up trigger shaped like the UX demo's "code fast" moment, to test streaming end to
    /// end without waiting for a real Stage 2 fire.
    func runSample() {
        run(Self.sampleTrigger())
    }

    static func sampleTrigger() -> TriggerFired {
        TriggerFired(
            suggestionId: "sample-\(UUID().uuidString.prefix(8))", gateScore: 0,
            jspaceConcepts: ["download", "clone"],
            tkgDigest: "In Google Chrome ('dejesusbg/monet: A lightweight JavaScript library…', github.com) for 16s.",
            timestamp: Date().timeIntervalSince1970, mode: "coding", kind: "settled",
            context: ["app": "Google Chrome", "title": "dejesusbg/monet",
                      "url": "https://github.com/dejesusbg/monet",
                      "excerpt": "Code · Local · Codespaces · Clone · HTTPS · SSH · GitHub CLI · https://github.com/dejesusbg/monet.git · Clone using the web URL. · Download ZIP"])
    }

    private func finish(_ status: Status) {
        guard var c = current else { return }
        c.status = status
        c.finishedAfter = Date().timeIntervalSince(c.startedAt)
        current = c
        note(.composed)
        log.info("execution done: \(String(describing: status), privacy: .public) via \(c.providerName, privacy: .public) first token \(c.firstTokenAfter ?? -1)s total \(c.finishedAfter ?? -1)s skipped \(c.skipped.count) proposals \(c.proposals.count) tools-ran \(c.toolsRan.count)")
    }

    private func isNothing(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .uppercased() == ExecutionPrompt.nothing
    }
}
