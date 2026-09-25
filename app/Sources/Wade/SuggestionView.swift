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
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Why: \(s.concepts.prefix(4).joined(separator: ", "))")
                    Text("\(s.providerName)\(s.sendsDataOffDevice ? " · sent to Anthropic" : " · stayed on this Mac")"
                         + timing(s))
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No suggestion yet.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Try a sample suggestion") { engine.runSample() }
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

/// Settings → Suggestions: which model writes suggestions, and the Claude API key.
struct ExecutionSettingsView: View {
    @Bindable var engine: ExecutionEngine
    @State private var keyDraft = ""

    var body: some View {
        Form {
            Section("Who writes suggestions") {
                Picker("Model", selection: $engine.selected) {
                    ForEach(ProviderChoiceList.all) { Text($0.title).tag($0) }
                }
                if engine.effective != engine.selected {
                    Label("No API key yet, so Wade uses Apple's on-device model for now.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if engine.hasAPIKey {
                    LabeledContent("Claude API key") {
                        HStack {
                            Text("Saved in your Keychain").foregroundStyle(.secondary)
                            Button("Remove") { engine.removeAPIKey() }
                        }
                    }
                } else {
                    HStack {
                        SecureField("sk-ant-…", text: $keyDraft).labelsHidden()
                        Button("Save") { engine.saveAPIKey(keyDraft); keyDraft = "" }
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("Claude API key")
            } footer: {
                Text("""
                    Watching your screen always stays on this Mac. Only when Wade writes a suggestion \
                    with Claude is that suggestion's context (what's on screen, recent activity, and \
                    the facts you gave Wade) sent to Anthropic's API, billed to your key. Apple's \
                    on-device model keeps everything on this Mac.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private enum ProviderChoiceList {
    static let all = ProviderChoice.allCases
}
