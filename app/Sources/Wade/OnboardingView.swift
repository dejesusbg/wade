import SwiftUI

/// First-run flow. Explains Accessibility *before* the system prompt appears (CLAUDE.md §5.1),
/// then collects integration opt-ins and a few user-stated facts. Observation only starts
/// once this is finished and access is granted.
struct OnboardingView: View {
    let permission: AccessibilityPermission
    let memory: MemoryModel
    @Environment(\.dismissWindow) private var dismissWindow

    private enum Step: Int, CaseIterable {
        case access, integrations, facts
    }

    @State private var step = Step.access

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case .access: accessStep
                case .integrations: integrationsStep
                case .facts: factsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            Divider()
            HStack {
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if step != .access {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
                }
                if step == .facts {
                    // No Return shortcut here: Return in the fact field must add the fact.
                    Button("Finish") {
                        memory.completeOnboarding()
                        dismissWindow()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") { step = Step(rawValue: step.rawValue + 1)! }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == .access && !permission.isTrusted)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 440)
        .onAppear { NSApp.activate() }
    }

    private var accessStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wade helps when you look stuck").font(.title2.bold())
            Text("""
                Wade sits in your menu bar and stays quiet. It only speaks up when what you're doing \
                suggests you could use a hand, like bouncing between the same windows or hitting the \
                same error again.
                """)
            Text("To notice that, Wade needs Accessibility access. With it, Wade sees:")
            VStack(alignment: .leading, spacing: 6) {
                Label("Which app and window are in front, and when that changes", systemImage: "macwindow")
                Label("When error dialogs appear (reduced to a fingerprint, not stored as text)", systemImage: "exclamationmark.triangle")
                Label("How much you're typing, never what you type", systemImage: "keyboard")
                Label("When you step away and come back", systemImage: "moon.zzz")
            }
            .padding(.leading, 4)
            Text("Everything stays on this Mac. You can revoke access anytime in System Settings.")
                .font(.callout).foregroundStyle(.secondary)

            if permission.isTrusted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Button("Grant Accessibility Access…") { permission.request() }
                        .buttonStyle(.borderedProminent)
                    Button("Open System Settings") { permission.openSystemSettings() }
                }
            }
        }
    }

    private var integrationsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What can Wade use?").font(.title2.bold())
            Text("Pick what Wade may use when it suggests something. Everything is off until you turn it on, and you can change it later in Settings.")
            Form { IntegrationsList(memory: memory) }
                .formStyle(.grouped)
            Text("Wade asks for any account access separately when an integration first connects.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var factsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Anything Wade should know?").font(.title2.bold())
            Text("Optional. Short facts about you or your work help Wade make better suggestions. Wade only knows what you tell it here or when you correct a suggestion. It never guesses from what it watches.")
            Form { FactsEditor(memory: memory) }
                .formStyle(.grouped)
        }
    }
}
