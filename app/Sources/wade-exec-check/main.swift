import Foundation
import WadeExecution
import WadeIPC
import WadeTools

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

if arg == "tools-e2e" {
    // Phase 5 end to end, headless: real filesystem MCP server on a scratch folder, a selection
    // moment, the chosen provider composes with tools, then a simulated "Do it" click.
    //   wade-exec-check tools-e2e <folder> [catalog id]
    let rest = Array(CommandLine.arguments.dropFirst(2))
    guard let folder = rest.first else { out("usage: tools-e2e <folder> [id]\n"); exit(2) }
    let manager = MCPManager()
    await manager.apply([MCPServerSpec.filesystem(folders: [folder])].compactMap { $0 }, notesFolder: folder)
    out("servers: \(await manager.statuses.map { "\($0.integration): \($0.state)" })\n")

    let trigger = TriggerFired(
        suggestionId: "e2e", gateScore: 0, jspaceConcepts: ["save", "annotate"],
        tkgDigest: "In Safari ('Frontiers | AI and digital accessibility', frontiersin.org) for 40s.",
        timestamp: 0, mode: "researching", kind: "selection",
        context: ["app": "Safari", "url": "https://www.frontiersin.org/articles/10.3389/frai.2024.00001/full",
                  "selection": "AI is already being used to analyze medical images and detect diseases such as cancer, which could improve accessibility of diagnosis for people with disabilities."])
    let all = await manager.allTools()
    out("all: \(all.map { "\($0.name)\($0.readOnly ? "" : "*")" }.joined(separator: ", "))\n")
    let offered = ToolSelection.pick(from: all, mode: trigger.mode, kind: trigger.kind, url: trigger.context?["url"])
    out("offered: \(offered.map { "\($0.name)\($0.readOnly ? "" : "*")" }.joined(separator: ", "))  (* = runs only on click)\n")

    final class Box: @unchecked Sendable { var proposals: [ProposedAction] = []; var ran: [String] = [] }
    let box = Box()
    struct LoggingRunner: ToolRunner {
        let inner: MCPManager
        func call(_ tool: MCPTool, argumentsJSON: String) async throws -> String {
            out("  call \(tool.name) \(argumentsJSON)\n")
            do { let r = try await inner.call(tool, argumentsJSON: argumentsJSON); out("  → \(r.prefix(160))\n"); return r }
            catch { out("  → error: \(error.localizedDescription)\n"); throw error }
        }
    }
    let tools = ToolBox(tools: offered, runner: LoggingRunner(inner: manager)) { event in
        switch event {
        case .proposed(let p): box.proposals.append(p)
        case .toolRan(let name, let ok): box.ran.append("\(name)\(ok ? "" : " (failed)")")
        case .text: break
        }
    }
    let id = rest.count > 1 ? rest[1] : "apple.on-device"
    guard let d = ProviderCatalog.find(id) else { out("unknown id\n"); exit(2) }
    let prompt = ExecutionPrompt(trigger: trigger, facts: [], corrections: [])
    let t0 = Date()
    out("\n--- suggestion (\(d.title)):\n")
    do {
        for try await e in ProviderChain.run([d], prompt: prompt, tools: tools, firstTokenTimeout: .seconds(20),
                                             resolve: { $0.makeProvider(key: APIKeyStore.read($0.vendor)) }) {
            if case .text(let t) = e { out(t) }
        }
    } catch { out("\nFAILED: \(error.localizedDescription)") }
    out(String(format: "\n--- %.1fs · read-only tools ran: %@ · proposed: %d\n", Date().timeIntervalSince(t0),
               box.ran.isEmpty ? "none" : box.ran.joined(separator: ", "), box.proposals.count))
    for p in box.proposals {
        out("PROPOSED \(p.tool.name) \(p.argumentsJSON.prefix(300))\n")
        out("simulating the user's click on Do it…\n")
        do { out("RESULT: \(try await manager.call(p.tool, argumentsJSON: p.argumentsJSON).prefix(300))\n") }
        catch { out("ACTION FAILED: \(error.localizedDescription)\n") }
    }
    await manager.stopAll()
    exit(0)
}

if arg == "github-e2e" {
    // Phase 5, headless: real github-mcp-server with the saved token, a repo-page moment,
    // composition with tools. Proposals are only printed, never executed (they'd change GitHub).
    //   wade-exec-check github-e2e [owner/repo] [catalog id]
    let rest = Array(CommandLine.arguments.dropFirst(2))
    let repo = rest.first ?? "dejesusbg/monet"
    guard let token = APIKeyStore.read(account: "github-token") else { out("no GitHub token in the Keychain\n"); exit(1) }
    let manager = MCPManager()
    await manager.apply([MCPServerSpec.github(token: token)].compactMap { $0 })
    out("servers: \(await manager.statuses.map { "\($0.integration): \($0.state)" })\n")
    let trigger = TriggerFired(
        suggestionId: "gh", gateScore: 0, jspaceConcepts: ["download", "clone"],
        tkgDigest: "In Google Chrome ('\(repo)', github.com) for 16s.", timestamp: 0, mode: "coding", kind: "settled",
        context: ["app": "Google Chrome", "url": "https://github.com/\(repo)",
                  "excerpt": "Code · Releases · Clone · HTTPS · https://github.com/\(repo).git · Download ZIP"])
    let all = await manager.allTools()
    out("all: \(all.map { "\($0.name)\($0.readOnly ? "" : "*")" }.joined(separator: ", "))\n")
    let offered = ToolSelection.pick(from: all, mode: trigger.mode, kind: trigger.kind, url: trigger.context?["url"])
    out("offered: \(offered.map { "\($0.name)\($0.readOnly ? "" : "*")" }.joined(separator: ", "))  (* = click-only)\n")
    final class Box: @unchecked Sendable { var proposals: [ProposedAction] = []; var ran: [String] = [] }
    let box = Box()
    struct LoggingRunner: ToolRunner {
        let inner: MCPManager
        func call(_ tool: MCPTool, argumentsJSON: String) async throws -> String {
            out("  call \(tool.name) \(argumentsJSON)\n")
            do { let r = try await inner.call(tool, argumentsJSON: argumentsJSON); out("  → \(r.prefix(160))\n"); return r }
            catch { out("  → error: \(error.localizedDescription)\n"); throw error }
        }
    }
    let tools = ToolBox(tools: offered, runner: LoggingRunner(inner: manager)) { event in
        switch event {
        case .proposed(let p): box.proposals.append(p)
        case .toolRan(let name, let ok): box.ran.append("\(name)\(ok ? "" : " (failed)")")
        case .text: break
        }
    }
    guard let d = ProviderCatalog.find(rest.count > 1 ? rest[1] : "apple.on-device") else { exit(2) }
    let t0 = Date()
    out("\n--- suggestion (\(d.title)):\n")
    do {
        for try await e in ProviderChain.run([d], prompt: ExecutionPrompt(trigger: trigger, facts: [], corrections: []),
                                             tools: tools, firstTokenTimeout: .seconds(20),
                                             resolve: { $0.makeProvider(key: APIKeyStore.read($0.vendor)) }) {
            if case .text(let t) = e { out(t) }
        }
    } catch { out("\nFAILED: \(error.localizedDescription)") }
    out(String(format: "\n--- %.1fs · lookups ran: %@\n", Date().timeIntervalSince(t0), box.ran.isEmpty ? "none" : box.ran.joined(separator: ", ")))
    for p in box.proposals { out("PROPOSED (not executed) \(p.tool.name) \(p.argumentsJSON.prefix(200))\n") }
    // Direct lookup, to confirm the token and server work independent of the model's choices.
    if let latest = offered.first(where: { $0.name == "github__get_latest_release" }) {
        let parts = repo.split(separator: "/").map(String.init)
        let args = #"{"owner":"\#(parts[0])","repo":"\#(parts[1])"}"#
        do { out("direct get_latest_release: \(try await manager.call(latest, argumentsJSON: args).prefix(200))\n") }
        catch { out("direct get_latest_release failed: \(error.localizedDescription)\n") }
    }
    await manager.stopAll()
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
