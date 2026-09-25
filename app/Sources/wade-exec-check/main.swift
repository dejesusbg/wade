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

if arg == "gemini-models" {
    // Which Gemini models this key can call for streaming text (key from the Keychain, sent in a
    // header, never printed).
    guard let key = APIKeyStore.read(.google) else { out("no Gemini key in the Keychain\n"); exit(1) }
    var r = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
    r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    let (data, response) = try await URLSession.shared.data(for: r)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = json["models"] as? [[String: Any]] else {
        out("HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")\n"); exit(1)
    }
    for m in models {
        let name = (m["name"] as? String ?? "").replacingOccurrences(of: "models/", with: "")
        let methods = m["supportedGenerationMethods"] as? [String] ?? []
        guard name.contains("flash"), methods.contains("streamGenerateContent") || methods.contains("generateContent") else { continue }
        out("\(name.padding(toLength: 40, withPad: " ", startingAt: 0)) \(m["displayName"] as? String ?? "")\n")
    }
    exit(0)
}

if arg == "gemini-raw" {
    // Probe: POST a JSON body file to a Gemini API path and print the raw response lines with
    // timings. Key from the Keychain, sent in a header, never printed.
    //   wade-exec-check gemini-raw <path?query> <body.json>
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count == 2, let key = APIKeyStore.read(.google),
          let body = FileManager.default.contents(atPath: args[1]) else { out("usage/key/body missing\n"); exit(2) }
    var r = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/\(args[0])")!)
    r.httpMethod = "POST"
    r.timeoutInterval = 30
    r.setValue("application/json", forHTTPHeaderField: "content-type")
    r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    r.httpBody = body
    let t0 = Date()
    let (bytes, response) = try await URLSession.shared.bytes(for: r)
    out(String(format: "HTTP %d after %.2fs\n", (response as? HTTPURLResponse)?.statusCode ?? 0, Date().timeIntervalSince(t0)))
    for try await line in bytes.lines {
        out(String(format: "[%5.2fs] %@\n", Date().timeIntervalSince(t0), String(line.prefix(300))))
    }
    exit(0)
}

if arg == "list" {
    for d in ProviderCatalog.all {
        let key = !d.vendor.needsKey ? "no key needed" : (APIKeyStore.read(d.vendor) == nil ? "NO KEY" : "key ok")
        out("\(d.id.padding(toLength: 30, withPad: " ", startingAt: 0)) \(key)\(d.setupRequired == nil ? "" : " · needs setup")\n")
    }
    exit(0)
}
guard var descriptor = ProviderCatalog.find(arg) else { out("unknown id \(arg); try `list`\n"); exit(2) }
// Optional second argument overrides the model id (e.g. to try a pinned Gemini version).
if let model = CommandLine.arguments.dropFirst(2).first {
    descriptor = ProviderDescriptor(id: descriptor.id, vendor: descriptor.vendor, route: descriptor.route,
                                    model: model, title: "\(descriptor.title) [\(model)]", setupRequired: descriptor.setupRequired)
}

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
