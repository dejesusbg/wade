import Foundation
import WadeExecution
import WadeIPC

// Headless Phase 4 check: stream the sample "repo page" suggestion through one provider and
// print the deltas as they arrive, with time to first token and total time.
//
//   swift run wade-exec-check [on-device|haiku|haiku-direct|sonnet]
//   (Claude providers read the key from $ANTHROPIC_API_KEY, else from Wade's Keychain entry.)

let arg = CommandLine.arguments.dropFirst().first ?? "on-device"
let choice: ProviderChoice = switch arg {
case "haiku": .claudeHaikuAFM
case "haiku-direct": .claudeHaikuDirect
case "sonnet": .claudeSonnetAFM
default: .onDevice
}
let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? APIKeyStore.read()
let provider = choice.makeProvider(apiKey: key)

let prompt = ExecutionPrompt(
    trigger: TriggerFired(
        suggestionId: "check", gateScore: 0, jspaceConcepts: ["download", "clone"],
        tkgDigest: "In Google Chrome ('dejesusbg/monet: A lightweight JavaScript library…', github.com) for 16s.",
        timestamp: 0, mode: "coding", kind: "settled",
        context: ["app": "Google Chrome", "url": "https://github.com/dejesusbg/monet",
                  "excerpt": "Code · Local · Clone · HTTPS · SSH · GitHub CLI · https://github.com/dejesusbg/monet.git · Clone using the web URL. · Download ZIP"]),
    facts: [], corrections: [])

FileHandle.standardOutput.write(Data("provider: \(provider.displayName) (off-device: \(provider.sendsDataOffDevice))\n".utf8))
let start = Date()
var first: TimeInterval?
var chunks = 0
do {
    for try await delta in provider.generate(prompt: prompt, tools: []) {
        if first == nil { first = Date().timeIntervalSince(start) }
        chunks += 1
        FileHandle.standardOutput.write(Data(delta.utf8))
    }
    print(String(format: "\n\n%d chunks · first token %.2fs · total %.2fs", chunks, first ?? -1, Date().timeIntervalSince(start)))
} catch {
    print("\nFAILED: \(error.localizedDescription)")
    exit(1)
}
