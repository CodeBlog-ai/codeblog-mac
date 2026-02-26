import SwiftUI

struct AgentHomeView: View {
    @StateObject private var auth = CodeBlogAuthService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: CodeBlog brand title + current agent subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text("CodeBlog")
                    .font(.custom("InstrumentSerif-Regular", size: 42))
                    .foregroundColor(Color(hex: "1F1C17"))

                if let agentName = auth.token?.agentName, !agentName.isEmpty {
                    Text("Chatting as @\(agentName)")
                        .font(.custom("Nunito", size: 13))
                        .fontWeight(.medium)
                        .foregroundColor(Color(hex: "9B7753"))
                } else {
                    Text("AI Chat")
                        .font(.custom("Nunito", size: 13))
                        .fontWeight(.medium)
                        .foregroundColor(Color(hex: "9B7753"))
                }
            }
            .padding(.leading, 10)

            // Chat interface
            ChatView()
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(hex: "FFFAF5")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(hex: "E9DDD0"), lineWidth: 1)
                )
                .shadow(color: Color(hex: "D99A5A").opacity(0.14), radius: 16, x: 0, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // Silently ensure MCP is configured whenever the Agent page appears
            Task { await ensureMCPConfigured() }
        }
    }

    /// Silently configure MCP for Claude/Codex CLI.
    /// No user-facing messages — just ensure the config files are correct.
    @MainActor
    private func ensureMCPConfigured() async {
        guard let apiKey = KeychainManager.shared.retrieve(for: "codeblog"),
              !apiKey.isEmpty else {
            print("[AgentHome] No API key in Keychain, skipping MCP setup")
            return
        }

        let status = await MCPSetupService.shared.checkStatus()

        // If codeblog-mcp is not installed, try to install it silently
        if !status.isInstalled {
            print("[AgentHome] codeblog-mcp not found, installing...")
            try? await MCPSetupService.shared.installMCP()
        }

        // Configure Claude and Codex MCP silently
        do {
            if !status.isConfiguredInClaude {
                try await MCPSetupService.shared.configureClaudeMCP(apiKey: apiKey)
                print("[AgentHome] Configured Claude MCP")
            }
            if !status.isConfiguredInCodex {
                try await MCPSetupService.shared.configureCodexMCP(apiKey: apiKey)
                print("[AgentHome] Configured Codex MCP")
            }
        } catch {
            print("[AgentHome] MCP config error (non-fatal): \(error)")
        }
    }
}
