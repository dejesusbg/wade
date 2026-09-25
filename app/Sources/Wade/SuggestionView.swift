import SwiftUI
import WadeExecution

/// Phase 4 placeholder surface: shows the current suggestion streaming in. Phase 6 replaces it
/// with the popover anchored to the menu bar icon (with accept / reject / correct).
struct SuggestionView: View {
    let engine: ExecutionEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = engine.current {
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
                    }
                }
                .font(.body)
                ForEach(s.proposals) { proposal in
                    ProposalRow(proposal: proposal) { engine.perform(proposal.id) }
                }
                Divider()
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
            } else {
                Text("No suggestion yet.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Sample: repo page") { engine.runSample() }
                Button("Sample: save a note") { engine.runSampleNote() }
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { NSApp.activate() }
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
            case .pending: Button("Do it", action: perform).buttonStyle(.borderedProminent)
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
                    Stepper(value: $engine.timeoutSeconds, in: ExecutionEngine.timeoutRange, step: 0.5) {
                        Text(String(format: "%.1f s", engine.timeoutSeconds)).monospacedDigit()
                    }
                }
            } header: {
                Text("Who writes suggestions")
            } footer: {
                Text("If the primary can't run (no key, setup missing, rate limit, unavailable) or hasn't written anything by \"Give up after\", the fallback writes instead. Both come from the same list. A suggestion that arrives late is no help, so keep this short.")
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
        }
        .formStyle(.grouped)
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
