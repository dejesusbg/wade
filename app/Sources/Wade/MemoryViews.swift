import SwiftUI
import WadeCore

/// Opt-in list for integrations. Shared by onboarding and Settings.
struct IntegrationsList: View {
    let memory: MemoryModel

    var body: some View {
        ForEach(IntegrationCatalog.all) { integration in
            Toggle(isOn: Binding(
                get: { memory.enabledIntegrations.contains(integration.id) },
                set: { memory.setIntegration(integration.id, enabled: $0) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(integration.name)
                        Text(integration.summary).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: integration.systemImage)
                }
            }
        }
    }
}

/// Add / edit / remove user-stated facts. Shared by onboarding and Settings.
struct FactsEditor: View {
    let memory: MemoryModel
    @State private var draft = ""

    var body: some View {
        ForEach(memory.facts) { fact in
            HStack {
                TextField("Fact", text: Binding(
                    get: { fact.text },
                    set: { memory.updateFact(fact.id, text: $0) }
                ))
                .textFieldStyle(.plain)
                Button("Remove", systemImage: "minus.circle") { memory.deleteFact(fact.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        HStack {
            TextField("e.g. \u{201C}I'm a nurse\u{201D} or \u{201C}I mostly work in Xcode and Safari\u{201D}", text: $draft)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        memory.addFact(draft)
        draft = ""
    }
}
