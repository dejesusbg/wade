import Foundation
import WadeExecution

/// Which tools a model is offered for one suggestion. A small, relevant subset, because the
/// on-device model has a small context window (about 4K tokens) and 45+ tool schemas won't fit
/// next to the prompt. Offering a tool never means running it: the action rule is in `ToolBox`.
public enum ToolSelection {
    /// Curated per integration: a couple of lookups that make suggestions specific, plus the
    /// actions worth offering. Everything else stays available to future versions, not offered.
    static let curated: [String: [String]] = [
        // Notes moments get the composed save_note (easy for a small model) and one lookup.
        "filesystem": [],
        "github": ["get_latest_release", "list_releases", "fork_repository", "issue_write"],
    ]
    public static let maxTools = 6

    public static func pick(from tools: [MCPTool], mode: String?, kind: String?, url: String?) -> [MCPTool] {
        let onGitHub = url.flatMap { URL(string: $0)?.host }.map { $0 == "github.com" || $0.hasSuffix(".github.com") } ?? false
        let notesMoment = kind == "selection" || ["writing", "researching", "explaining"].contains(mode ?? "")

        var wanted: [String] = []
        if onGitHub { wanted += curated["github", default: []].map { "github__\($0)" } }
        if notesMoment || !onGitHub {
            wanted.append(ComposedTools.saveNoteName)
            wanted += curated["filesystem", default: []].map { "files__\($0)" }
        }

        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return Array(wanted.compactMap { byName[$0] }.prefix(maxTools))
    }
}
