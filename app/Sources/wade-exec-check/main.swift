import Foundation
import WadeExecution
import WadeIPC

// Headless Phase 4 check: stream the sample "repo page" suggestion through one catalog entry and
// print deltas as they arrive, with time to first token and total time. Keys come from Wade's
// Keychain (Settings → Suggestions), never the command line.
//
//   swift run wade-exec-check [catalog id]      # default: the catalog's default primary
//   swift run wade-exec-check list

let arg = CommandLine.arguments.dropFirst().first ?? ProviderCatalog.defaultPrimaryID
func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

if arg == "list" {
    for d in ProviderCatalog.all {
        let key = !d.vendor.needsKey ? "no key needed" : (APIKeyStore.read(d.vendor) == nil ? "NO KEY" : "key ok")
        out("\(d.id.padding(toLength: 30, withPad: " ", startingAt: 0)) \(key)\(d.setupRequired == nil ? "" : " · needs setup")\n")
    }
    exit(0)
}
guard let descriptor = ProviderCatalog.find(arg) else { out("unknown id \(arg); try `list`\n"); exit(2) }

let prompt = ExecutionPrompt(
    trigger: TriggerFired(
        suggestionId: "check", gateScore: 0, jspaceConcepts: ["download", "clone"],
        tkgDigest: "In Google Chrome ('dejesusbg/monet: A lightweight JavaScript library…', github.com) for 16s.",
        timestamp: 0, mode: "coding", kind: "settled",
        context: ["app": "Google Chrome", "url": "https://github.com/dejesusbg/monet",
                  "excerpt": "Code · Local · Clone · HTTPS · SSH · GitHub CLI · https://github.com/dejesusbg/monet.git · Clone using the web URL. · Download ZIP"]),
    facts: [], corrections: [])

let start = Date()
var first: TimeInterval?
var chunks = 0
do {
    for try await event in ProviderChain.run([descriptor], prompt: prompt, resolve: { d in
        d.makeProvider(key: APIKeyStore.read(d.vendor))
    }) {
        switch event {
        case .using(let title, let off): out("provider: \(title) (off-device: \(off))\n")
        case .skipped(let title, let reason): out("skipped \(title): \(reason)\n")
        case .text(let delta):
            if first == nil { first = Date().timeIntervalSince(start) }
            chunks += 1
            out(delta)
        }
    }
    out(String(format: "\n\n%d chunks · first token %.2fs · total %.2fs\n", chunks, first ?? -1, Date().timeIntervalSince(start)))
} catch {
    out("\nFAILED: \(error.localizedDescription)\n")
    exit(1)
}
