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
///
/// Text fields are `labelsHidden()`: inside a grouped `Form`, a TextField's title renders as
/// a row label and squeezes the actual input to nothing.
struct FactsEditor: View {
    let memory: MemoryModel
    @State private var draft = ""

    var body: some View {
        ForEach(memory.facts) { fact in
            FactRow(fact: fact, memory: memory)
        }
        HStack {
            TextField("New fact", text: $draft,
                      prompt: Text("e.g. \u{201C}I'm a nurse\u{201D} or \u{201C}I mostly work in Xcode and Safari\u{201D}"))
                .labelsHidden()
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

/// Edits locally and saves on Return or when focus leaves, so clearing the text mid-edit
/// doesn't delete the fact and each keystroke doesn't hit SQLite.
private struct FactRow: View {
    let fact: OnboardingFact
    let memory: MemoryModel
    @State private var text: String
    @FocusState private var focused: Bool

    init(fact: OnboardingFact, memory: MemoryModel) {
        self.fact = fact
        self.memory = memory
        _text = State(initialValue: fact.text)
    }

    var body: some View {
        HStack {
            TextField("Fact", text: $text)
                .labelsHidden()
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            Button("Remove", systemImage: "minus.circle") { memory.deleteFact(fact.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private func commit() {
        guard text != fact.text else { return }
        memory.updateFact(fact.id, text: text)  // empty text deletes the fact
    }
}
