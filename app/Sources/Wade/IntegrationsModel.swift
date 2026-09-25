import AppKit
import Foundation
import WadeExecution
import WadeTools

/// Runs the MCP servers for the integrations the user opted into (CLAUDE.md §5.6), with the
/// folders and token they gave. Re-applies whenever any of those change.
@MainActor
@Observable
final class IntegrationsModel {
    /// Folders the Files integration may touch. The first one is where notes are saved.
    private(set) var folders: [String] {
        didSet { UserDefaults.standard.set(folders, forKey: Self.foldersKey) }
    }
    private(set) var hasGitHubToken = APIKeyStore.read(account: IntegrationsModel.githubAccount) != nil
    private(set) var statuses: [String: String] = [:]  // integration → "connected (14 tools)" / error

    let manager = MCPManager()
    private let memory: MemoryModel
    private static let foldersKey = "integrations.files.folders"
    static let githubAccount = "github-token"

    init(memory: MemoryModel) {
        self.memory = memory
        folders = UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []
        track()
    }

    var notesFolder: String? { folders.first }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Allow"
        panel.message = "Choose folders Wade may read and write (notes are saved in the first one)."
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.map { $0.path(percentEncoded: false) }
        folders += picked.filter { !folders.contains($0) }
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
    }

    func saveGitHubToken(_ token: String) {
        APIKeyStore.save(token, account: Self.githubAccount)
        hasGitHubToken = APIKeyStore.read(account: Self.githubAccount) != nil
        apply()
    }

    func removeGitHubToken() {
        APIKeyStore.delete(account: Self.githubAccount)
        hasGitHubToken = false
        apply()
    }

    /// Re-apply whenever opt-ins or folders change (the token setters call `apply` directly).
    private func track() {
        withObservationTracking {
            _ = memory.enabledIntegrations
            _ = folders
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        apply()
    }

    func apply() {
        var specs: [MCPServerSpec] = []
        let enabled = memory.enabledIntegrations
        if enabled.contains("filesystem") {
            if let spec = MCPServerSpec.filesystem(folders: folders) { specs.append(spec) }
        }
        if enabled.contains("github") {
            if let token = APIKeyStore.read(account: Self.githubAccount), let spec = MCPServerSpec.github(token: token) {
                specs.append(spec)
            }
        }
        let notes = notesFolder
        Task { [manager] in
            await manager.apply(specs, notesFolder: notes)
            let current = await manager.statuses
            await MainActor.run { [weak self] in self?.updateStatuses(current, enabled: enabled) }
        }
    }

    private func updateStatuses(_ current: [MCPManager.Status], enabled: Set<String>) {
        var result: [String: String] = [:]
        for s in current { result[s.integration] = s.state }
        if enabled.contains("filesystem"), result["filesystem"] == nil {
            result["filesystem"] = folders.isEmpty ? "add a folder to start" : "not running (is Node installed?)"
        }
        if enabled.contains("github"), result["github"] == nil {
            result["github"] = hasGitHubToken ? "not running (is github-mcp-server installed?)" : "add a token to start"
        }
        statuses = result
    }

    func stop() {
        Task { [manager] in await manager.stopAll() }
    }
}
