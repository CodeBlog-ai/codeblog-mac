//
//  MCPSetupService.swift
//  CodeBlog
//

import Foundation

@MainActor
final class MCPSetupService {
    static let shared = MCPSetupService()

    struct MCPStatus: Sendable {
        let isInstalled: Bool
        let version: String?
        let isConfiguredInClaude: Bool
        let isConfiguredInCodex: Bool
    }

    private let fileManager = FileManager.default

    private init() {}

    func checkStatus() async -> MCPStatus {
        let claudePath = claudeSettingsURL.path
        let codexPath = codexConfigURL.path

        return await Task.detached(priority: .utility) {
            let versionResult = LoginShellRunner.run("codeblog-mcp --version", timeout: 15)
            let isInstalled = versionResult.exitCode == 0
            let version = isInstalled
                ? versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first
                : nil

            return MCPStatus(
                isInstalled: isInstalled,
                version: version,
                isConfiguredInClaude: Self.isConfiguredInClaudeSettings(path: claudePath),
                isConfiguredInCodex: Self.isConfiguredInCodex(path: codexPath)
            )
        }.value
    }

    func installMCP() async throws {
        let result = await runShell("npm install -g codeblog-mcp", timeout: 300)
        guard result.exitCode == 0 else {
            throw MCPSetupError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func configureClaudeMCP(apiKey: String) async throws {
        let fileURL = claudeSettingsURL
        try ensureParentDirectory(for: fileURL)

        var settings = try readJSONDictionary(from: fileURL)
        var mcpServers = settings["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["codeblog"] = [
            "command": "npx",
            "args": ["codeblog-mcp"],
            "env": ["CODEBLOG_API_KEY": apiKey]
        ]
        settings["mcpServers"] = mcpServers

        try writeJSONDictionary(settings, to: fileURL)
    }

    func configureCodexMCP(apiKey: String) async throws {
        let fileURL = codexConfigURL
        try ensureParentDirectory(for: fileURL)

        let existingContent: String
        if fileManager.fileExists(atPath: fileURL.path) {
            existingContent = try String(contentsOf: fileURL, encoding: .utf8)
        } else {
            existingContent = ""
        }

        let codeblogBlock = codexMCPBlock(apiKey: apiKey)
        let updatedContent: String

        let pattern = #"(?ms)^\[mcp_servers\.codeblog\][\s\S]*?(?=^\[|\z)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(existingContent.startIndex..., in: existingContent)

        if let match = regex.firstMatch(in: existingContent, options: [], range: range) {
            let nsString = existingContent as NSString
            updatedContent = nsString.replacingCharacters(in: match.range, with: codeblogBlock + "\n")
        } else if existingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updatedContent = codeblogBlock + "\n"
        } else {
            updatedContent = existingContent.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + codeblogBlock + "\n"
        }

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private var claudeSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/settings.json", isDirectory: false)
    }

    private var codexConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex/config.toml", isDirectory: false)
    }

    private func runShell(_ command: String, timeout: TimeInterval) async -> LoginShellResult {
        await Task.detached(priority: .utility) {
            LoginShellRunner.run(command, timeout: timeout)
        }.value
    }

    private func ensureParentDirectory(for fileURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }

    private func readJSONDictionary(from url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }

        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }

        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = object as? [String: Any] else {
            throw MCPSetupError.invalidJSON(url.path)
        }
        return dict
    }

    private func writeJSONDictionary(_ dict: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        var text = String(data: data, encoding: .utf8) ?? "{}"
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func codexMCPBlock(apiKey: String) -> String {
        let escapedKey = apiKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        [mcp_servers.codeblog]
        command = "npx"
        args = ["codeblog-mcp"]

        [mcp_servers.codeblog.env]
        CODEBLOG_API_KEY = "\(escapedKey)"
        """
    }

    nonisolated private static func isConfiguredInClaudeSettings(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any]
        else {
            return false
        }

        return servers["codeblog"] != nil
    }

    nonisolated private static func isConfiguredInCodex(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return false
        }

        return content.contains("[mcp_servers.codeblog]")
    }
}

enum MCPSetupError: LocalizedError {
    case invalidJSON(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let path):
            return "Invalid JSON format in \(path)."
        case .commandFailed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "MCP command failed." : trimmed
        }
    }
}
