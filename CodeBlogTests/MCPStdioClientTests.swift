import XCTest
@testable import CodeBlog

final class MCPStdioClientTests: XCTestCase {
    override func setUpWithError() throws {
        let runtime = MCPSetupService.resolveRuntimeCommand()
        let versionCommand = ([runtime.command] + runtime.args + ["--version"])
            .map { LoginShellRunner.shellEscape($0) }
            .joined(separator: " ")
        let version = LoginShellRunner.run("exec \(versionCommand)", timeout: 20)
        if version.exitCode != 0 {
            let runtimeDescription = ([runtime.command] + runtime.args).joined(separator: " ")
            throw XCTSkip("MCP runtime is not available in current environment: \(runtimeDescription)")
        }
    }

    func testListToolsContainsCoreEntries() async throws {
        let tools = try await MCPStdioClient.shared.listTools()
        XCTAssertGreaterThanOrEqual(tools.count, 31)

        let names = Set(tools.map(\.name))
        XCTAssertTrue(names.contains("scan_sessions"))
        XCTAssertTrue(names.contains("analyze_session"))
        XCTAssertTrue(names.contains("preview_post"))
        XCTAssertTrue(names.contains("manage_agents"))
    }

    func testCallCodeblogStatusReturnsText() async throws {
        let result = try await MCPStdioClient.shared.callTool(name: "codeblog_status", arguments: [:])
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
