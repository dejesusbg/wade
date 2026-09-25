import SwiftUI
import WadeCore
import WadeExecution

/// The suggestion, as shown in the menu-bar popover (CLAUDE.md §5.1, Phase 6): streamed text,
/// proposed actions, the "why" readout, and explicit feedback that writes to the corrections
/// store (§5.7).
struct SuggestionView: View {
    let engine: ExecutionEngine
    /// Called on any click inside, so an auto-opened popover doesn't close under the user.
    var engaged: () -> Void = {}
    @State private var correcting = false
    @State private var correction = ""
    @FocusState private var correctionFocused: Bool

    var body: some View {
        if let s = engine.current {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("wade").fontWeight(.semibold)
                    Text("is \(s.mode ?? "thinking")…").foregroundStyle(.secondary)
                    Spacer()
                    if s.status == .streaming { ProgressView().controlSize(.small) }
                }
                Group {
                    switch s.status {
                    case .dropped:
                        Text("Nothing worth offering here, so Wade stays quiet.").foregroundStyle(.secondary)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    default:
                        Text(s.text.isEmpty ? " " : s.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(s.proposals) { proposal in
                    ProposalRow(proposal: proposal) { engaged(); engine.perform(proposal.id) }
                }
                if s.phase != .quiet, s.phase != .failed, s.status != .streaming {
                    feedback(s)
                }
                why(s)
            }
        } else {
            Text("Nothing to say right now. Wade speaks up when it sees a moment worth it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func feedback(_ s: ExecutionEngine.Suggestion) -> some View {
        switch s.feedback {
        case .rejected:
            Label("Noted: Wade will keep that in mind.", systemImage: "hand.thumbsdown").font(.callout).foregroundStyle(.secondary)
        case .corrected:
            Label("Saved to Corrections: Wade will use it next time.", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
        case .accepted, nil:
            if correcting {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("What would have helped?", text: $correction,
                              prompt: Text("e.g. \u{201C}just the release binary next time\u{201D}"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...3)
                        .focused($correctionFocused)
                        .onSubmit(saveCorrection)
                    HStack {
                        Spacer()
                        Button("Cancel") { correcting = false; correction = "" }
                        Button("Save", action: saveCorrection)
                            .buttonStyle(.borderedProminent)
                            .disabled(correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                HStack {
                    if s.feedback == nil {  // after "Thanks" or "Do it", a correction is still welcome
                        Button("Thanks") { engaged(); engine.accept() }
                        Button("Not helpful") { engaged(); engine.reject() }
                    }
                    Button("Correct…") {
                        engaged()
                        NSApp.activate()  // the field needs keyboard focus; only on this click
                        correcting = true
                        correctionFocused = true
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    private func saveCorrection() {
        engine.correct(correction)
        correcting = false
        correction = ""
    }

    private func why(_ s: ExecutionEngine.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Why: \(s.concepts.prefix(4).joined(separator: ", "))")
            if !s.providerName.isEmpty {
                Text("\(s.providerName)\(s.sendsDataOffDevice ? " · sent to the provider" : " · stayed on this Mac")"
                     + timing(s))
            }
            ForEach(s.skipped, id: \.self) { Text("Skipped \($0)") }
            if !s.toolsRan.isEmpty { Text("Looked up: \(s.toolsRan.joined(separator: ", "))") }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func timing(_ s: ExecutionEngine.Suggestion) -> String {
        guard let first = s.firstTokenAfter else { return "" }
        let total = s.finishedAfter.map { String(format: ", done %.1fs", $0) } ?? ""
        return String(format: " · first words %.1fs", first) + total
    }
}

/// A proposed action and its "Do it" button. Nothing runs until that click.
private struct ProposalRow: View {
    let proposal: ExecutionEngine.Proposal
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "bolt.circle")
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.summary)
                switch proposal.state {
                case .done(let result): Text(result).font(.caption).foregroundStyle(.green).lineLimit(2)
                case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                default: EmptyView()
                }
            }
            Spacer()
            switch proposal.state {
            case .pending:
                Button(action: perform) {
                    HStack(spacing: 4) {
                        Text("Do it")
                        Text(AcceptHotKey.display).font(.caption).opacity(0.75)
                    }
                }
                .buttonStyle(.borderedProminent)
                .help("Runs this action. Shortcut: \(AcceptHotKey.display), while this popover is showing.")
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Settings → Integrations: which MCP servers run, with what access.
struct IntegrationsSettingsView: View {
    let memory: MemoryModel
    let integrations: IntegrationsModel
    @State private var tokenDraft = ""

    var body: some View {
        Form {
            Section {
                toggle("filesystem", "Files")
                if memory.enabledIntegrations.contains("filesystem") {
                    ForEach(integrations.folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: folder == integrations.notesFolder ? "note.text" : "folder")
                            Text(folder).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove", systemImage: "minus.circle") { integrations.removeFolder(folder) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }
                    Button("Add Folder…") { integrations.addFolders() }
                    status("filesystem")
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Wade can read and write only inside these folders. Notes are saved in the first one. Writing anything always waits for your \"Do it\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                toggle("github", "GitHub")
                if memory.enabledIntegrations.contains("github") {
                    if integrations.hasGitHubToken {
                        LabeledContent("Token") {
                            HStack {
                                Text("Saved in Keychain").foregroundStyle(.secondary)
                                Button("Remove") { integrations.removeGitHubToken() }
                            }
                        }
                    } else {
                        HStack {
                            SecureField("Personal access token", text: $tokenDraft).labelsHidden()
                            Button("Save") { integrations.saveGitHubToken(tokenDraft); tokenDraft = "" }
                                .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    status("github")
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Lookups (releases, issues) may run while Wade writes a suggestion. Anything that changes GitHub (fork, create an issue) always waits for your \"Do it\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ id: String, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { memory.enabledIntegrations.contains(id) },
                                    set: { memory.setIntegration(id, enabled: $0) }))
    }

    @ViewBuilder
    private func status(_ id: String) -> some View {
        if let state = integrations.statuses[id] {
            Label(state, systemImage: state.hasPrefix("connected") ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(state.hasPrefix("connected") ? .green : .orange)
        }
    }
}

/// Settings → Suggestions: primary and fallback writers (same list, no special cases) and one
/// API key per cloud vendor.
struct ExecutionSettingsView: View {
    @Bindable var engine: ExecutionEngine
    @Bindable var app: AppModel
    @State private var drafts: [Vendor: String] = [:]

    var body: some View {
        Form {
            Section {
                Picker("Primary", selection: $engine.primaryID) {
                    ForEach(ProviderCatalog.all) { d in
                        Text(label(d)).tag(d.id)
                    }
                }
                Picker("Fallback", selection: Binding(get: { engine.fallbackID ?? "" },
                                                      set: { engine.fallbackID = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(ProviderCatalog.all) { d in
                        Text(label(d)).tag(d.id)
                    }
                }
                LabeledContent("Give up after") {
                    HStack {
                        Stepper(value: $engine.timeoutSeconds, in: ExecutionEngine.timeoutRange, step: 0.5) {
                            Text(String(format: "%.1f s", engine.timeoutSeconds)).monospacedDigit()
                        }
                        resetButton(isDefault: engine.timeoutSeconds == ExecutionEngine.defaultTimeoutSeconds) {
                            engine.timeoutSeconds = ExecutionEngine.defaultTimeoutSeconds
                        }
                    }
                }
            } header: {
                Text("Who writes suggestions")
            } footer: {
                Text("If the primary can't run (no key, setup missing, rate limit, unavailable) or hasn't written anything by \"Give up after\", the fallback writes instead. Both come from the same list. A suggestion that arrives late is no help, so keep this short.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("A page counts as settled after") {
                    HStack {
                        Stepper(value: $app.settledDwell, in: AppModel.settledRange, step: 1) {
                            Text(String(format: "%.0f s", app.settledDwell)).monospacedDigit()
                        }
                        resetButton(isDefault: app.settledDwell == AppModel.settledDefault) {
                            app.settledDwell = AppModel.settledDefault
                        }
                    }
                }
            } header: {
                Text("When Wade looks")
            } footer: {
                Text("How long you stay on one page or document before Wade takes a look at it. Shorter means Wade checks sooner, and checks more of the pages you only pass through. Selected text and repeated errors don't wait for this. Search results and the browser's own pages are never checked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Vendor.allCases.filter(\.needsKey), id: \.self) { vendor in
                    keyRow(vendor)
                }
            } header: {
                Text("API keys")
            } footer: {
                Text("""
                    Watching your screen always stays on this Mac. Only when a cloud model writes a \
                    suggestion is that suggestion's context (what's on screen, recent activity, the \
                    facts you gave Wade) sent to that vendor's API, billed to your key. Keys are \
                    stored in your Keychain. Apple's on-device model keeps everything on this Mac.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep a research log of suggestions and your feedback", isOn: $engine.researchLogEnabled)
                if engine.researchLogEnabled {
                    Button("Show Log in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([VerdictLog.defaultURL.deletingLastPathComponent()])
                    }
                }
            } header: {
                Text("Research log")
            } footer: {
                Text("""
                    Off by default. When on, Wade notes what happened to each suggestion (shown,                     accepted, not helpful, corrected, ignored) with its mode and timing, in a file on                     this Mac, to measure how often Wade is right. It never stores suggestion text,                     corrections or anything from your screen.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func resetButton(isDefault: Bool, action: @escaping () -> Void) -> some View {
        Button("Reset", systemImage: "arrow.counterclockwise", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(isDefault)
            .help("Reset to the default")
    }

    private func label(_ d: ProviderDescriptor) -> String {
        if d.setupRequired != nil { return "\(d.title) (needs setup)" }
        if d.vendor.needsKey && !engine.keyed.contains(d.vendor) { return "\(d.title) (no key)" }
        return d.title
    }

    @ViewBuilder
    private func keyRow(_ vendor: Vendor) -> some View {
        LabeledContent(vendor.name) {
            if engine.keyed.contains(vendor) {
                HStack {
                    Text("Saved in Keychain").foregroundStyle(.secondary)
                    Button("Remove") { engine.removeKey(for: vendor) }
                }
            } else {
                HStack {
                    SecureField("API key", text: Binding(get: { drafts[vendor, default: ""] },
                                                         set: { drafts[vendor] = $0 }))
                        .labelsHidden()
                        .frame(minWidth: 180)
                    Button("Save") {
                        engine.saveKey(drafts[vendor, default: ""], for: vendor)
                        drafts[vendor] = nil
                    }
                    .disabled(drafts[vendor, default: ""].trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
