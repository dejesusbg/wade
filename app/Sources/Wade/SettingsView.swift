import SwiftUI

/// "What Wade knows": both memory stores, fully visible and editable (CLAUDE.md §5.7).
struct SettingsView: View {
    let permission: AccessibilityPermission
    let memory: MemoryModel
    let execution: ExecutionEngine
    let integrations: IntegrationsModel
    let app: AppModel

    var body: some View {
        TabView {
            Tab("About You", systemImage: "person") {
                Form {
                    Section {
                        FactsEditor(memory: memory)
                    } header: {
                        Text("Facts you've told Wade")
                    }
                    Section("Integrations") { IntegrationsList(memory: memory) }
                }
                .formStyle(.grouped)
            }
            Tab("Corrections", systemImage: "arrow.uturn.backward") {
                Form {
                    Section {
                        if memory.corrections.isEmpty {
                            Text("None yet. When you correct or turn down a suggestion, what you said shows up here.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(memory.corrections) { c in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.correction)
                                    Text("Instead of: \(c.suggestion) · \(c.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Forget", systemImage: "trash") { memory.deleteCorrection(c.id) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Learned from your corrections")
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Integrations", systemImage: "puzzlepiece.extension") {
                IntegrationsSettingsView(memory: memory, integrations: integrations)
            }
            Tab("Suggestions", systemImage: "text.bubble") {
                ExecutionSettingsView(engine: execution, app: app)
            }
            Tab("Permissions", systemImage: "lock.shield") {
                Form {
                    LabeledContent("Accessibility") {
                        if permission.isTrusted {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            HStack {
                                Button("Grant Access…") { permission.request() }
                                Button("Open System Settings") { permission.openSystemSettings() }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 520, height: 420)
        .overlay(alignment: .bottom) {
            if let error = memory.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .onAppear { NSApp.activate() }
    }
}
