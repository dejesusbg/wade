import Foundation
import Testing
import WadeExecution
@testable import WadeTools

private func tool(_ name: String, readOnly: Bool = true, integration: String = "github") -> MCPTool {
    MCPTool(name: name, description: name, readOnly: readOnly, integration: integration)
}

@Suite struct ToolSelectionTests {
    private let all = [
        ComposedTools.saveNote(), tool("files__write_file", readOnly: false, integration: "filesystem"),
        tool("files__list_directory", integration: "filesystem"),
        tool("github__get_latest_release"), tool("github__list_releases"),
        tool("github__fork_repository", readOnly: false), tool("github__issue_write", readOnly: false),
        tool("github__merge_pull_request", readOnly: false), tool("github__delete_file", readOnly: false),
    ]

    @Test func notesMomentGetsOnlySaveNote() {
        let picked = ToolSelection.pick(from: all, mode: "researching", kind: "selection", url: "https://example.org/paper")
        #expect(picked.map(\.name) == [ComposedTools.saveNoteName])
    }

    @Test func githubPageGetsTheCuratedSetNeverDangerousWrites() {
        let picked = ToolSelection.pick(from: all, mode: "coding", kind: "settled", url: "https://github.com/dejesusbg/monet")
        #expect(picked.map(\.name) == ["github__get_latest_release", "github__list_releases",
                                       "github__fork_repository", "github__issue_write"])
        #expect(!picked.contains { $0.name.contains("merge") || $0.name.contains("delete") })
        #expect(picked.count <= ToolSelection.maxTools)
    }

    @Test func missingServersMeanNoTools() {
        #expect(ToolSelection.pick(from: [], mode: "coding", kind: "settled", url: "https://github.com/a/b").isEmpty)
    }
}

@Suite struct ComposedToolsTests {
    @Test func saveNoteExpandsToWriteFileInsideTheFolder() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let (serverTool, json) = try ComposedTools.expand(
            ComposedTools.saveNote(), argumentsJSON: #"{"title":"AI in imaging","content":"Quote"}"#,
            notesFolder: "/Users/x/Notes", now: date)
        #expect(serverTool == "write_file")
        let args = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: String]
        #expect(args["path"]!.hasPrefix("/Users/x/Notes/") && args["path"]!.hasSuffix(" AI in imaging.md"))
        #expect(args["content"] == "# AI in imaging\n\nQuote\n")
    }

    @Test func titlesCannotEscapeTheFolder() throws {
        #expect(ComposedTools.safeFileName("../../etc/passwd") == "etc passwd")
        #expect(ComposedTools.safeFileName("a/b\\c:d") == "a b c d")
        #expect(ComposedTools.safeFileName("   ") == "Note")
        let (_, json) = try ComposedTools.expand(ComposedTools.saveNote(),
                                                 argumentsJSON: #"{"title":"../../x","content":""}"#, notesFolder: "/n")
        let path = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: String])["path"]!
        #expect((path as NSString).deletingLastPathComponent == "/n")
    }

    @Test func noFolderMeansNoSave() {
        #expect(throws: (any Error).self) {
            try ComposedTools.expand(ComposedTools.saveNote(), argumentsJSON: "{}", notesFolder: nil)
        }
    }
}

@Suite struct ServerSpecTests {
    @Test func filesystemNeedsFoldersAndPinsTheVersion() {
        #expect(MCPServerSpec.filesystem(folders: []) == nil)
        if let spec = MCPServerSpec.filesystem(folders: ["/tmp/a"]) {  // nil if npx isn't installed
            #expect(spec.arguments.contains("@modelcontextprotocol/server-filesystem@2026.8.31"))
            #expect(spec.arguments.last == "/tmp/a")
        }
    }

    @Test func githubTokenOnlyInTheEnvironment() {
        #expect(MCPServerSpec.github(token: "") == nil)
        if let spec = MCPServerSpec.github(token: "ghp_test") {
            #expect(spec.environment["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_test")
            #expect(!spec.arguments.contains { $0.contains("ghp_test") })
        }
    }
}
