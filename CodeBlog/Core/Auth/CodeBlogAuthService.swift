//
//  CodeBlogAuthService.swift
//  CodeBlog
//
//  Handles OAuth login via local HTTP callback server.
//  Mirrors the CLI's auth/oauth.ts logic.
//

import Foundation
import AppKit

// MARK: - Token model

struct CodeBlogToken: Codable {
    let apiKey: String
    let username: String?
    let agentName: String?
}

/// Resolves CodeBlog API key for runtime calls.
/// Local testing path: prefer onboarding/login persisted value in UserDefaults
/// so chat & MCP are not blocked by keychain environment differences.
enum CodeBlogTokenResolver {
    private static let defaultsTokenKey = "codeblog_api_key"

    static func currentToken() -> String? {
        if let token = UserDefaults.standard.string(forKey: defaultsTokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }

        if let token = KeychainManager.shared.retrieve(for: "codeblog")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }

        return nil
    }
}

// MARK: - Auth service

@MainActor
final class CodeBlogAuthService: ObservableObject {

    static let shared = CodeBlogAuthService()

    @Published var token: CodeBlogToken? = nil
    @Published var currentAgentId: String? = nil
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    let serverURL = "https://codeblog.ai"
    private let tokenKey = "codeblog_api_key"
    private let usernameKey = "codeblog_username"
    private let agentNameKey = "codeblog_agent_name"
    private let agentIdKey = "codeblog_agent_id"

    private var callbackServer: CallbackHTTPServer? = nil

    private init() {
        loadSavedToken()
    }

    // MARK: - Persistence

    var isAuthenticated: Bool { token != nil }

    private func loadSavedToken() {
        currentAgentId = UserDefaults.standard.string(forKey: agentIdKey)
        guard
            let key = UserDefaults.standard.string(forKey: tokenKey),
            !key.isEmpty
        else { return }
        let username = UserDefaults.standard.string(forKey: usernameKey)
        let agentName = UserDefaults.standard.string(forKey: agentNameKey)
        token = CodeBlogToken(apiKey: key, username: username, agentName: agentName)
        _ = KeychainManager.shared.store(key, for: "codeblog")
    }

    private func saveToken(_ t: CodeBlogToken) {
        UserDefaults.standard.set(t.apiKey, forKey: tokenKey)
        UserDefaults.standard.set(t.username, forKey: usernameKey)
        UserDefaults.standard.set(t.agentName, forKey: agentNameKey)
        _ = KeychainManager.shared.store(t.apiKey, for: "codeblog")
        token = t
    }

    func logout() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: usernameKey)
        UserDefaults.standard.removeObject(forKey: agentNameKey)
        UserDefaults.standard.removeObject(forKey: agentIdKey)
        KeychainManager.shared.delete(for: "codeblog")
        token = nil
        currentAgentId = nil
    }

    /// Agent 创建/切换后更新认证信息。
    /// 与 CLI 保持一致：agent api_key 会替换 OAuth token。
    func updateAuthAfterAgentSwitch(newApiKey: String, agentId: String, agentName: String?) {
        let newToken = CodeBlogToken(apiKey: newApiKey, username: token?.username, agentName: agentName)
        saveToken(newToken)
        currentAgentId = agentId
        UserDefaults.standard.set(agentId, forKey: agentIdKey)
        _ = KeychainManager.shared.store(newApiKey, for: "codeblog")
    }

    /// 将当前 apiKey 存入 Keychain `codeblog` key。
    func storeApiKeyInKeychain() {
        guard let apiKey = token?.apiKey else { return }
        _ = KeychainManager.shared.store(apiKey, for: "codeblog")
    }

    // MARK: - OAuth login

    /// Opens browser to codeblog.ai/auth/cli, waits for callback with api_key.
    func loginWithBrowser() async {
        isLoading = true
        error = nil

        do {
            let t = try await performOAuthFlow()
            saveToken(t)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func performOAuthFlow() async throws -> CodeBlogToken {
        // Find an available port (try 54321, 54322, 54323)
        let candidates = [54321, 54322, 54323]
        var server: CallbackHTTPServer? = nil
        var chosenPort = 0

        for port in candidates {
            let s = CallbackHTTPServer(port: port)
            if s.start() {
                server = s
                chosenPort = port
                break
            }
        }

        guard let server else {
            throw AuthError.noPortAvailable
        }

        self.callbackServer = server

        // Open browser
        let authURL = URL(string: "\(serverURL)/auth/cli?port=\(chosenPort)&source=app")!
        NSWorkspace.shared.open(authURL)

        // Wait for callback (timeout 5 min)
        let params = try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await server.waitForCallback()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw AuthError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        server.stop()
        self.callbackServer = nil

        guard let apiKey = params["api_key"], !apiKey.isEmpty else {
            throw AuthError.noTokenReceived
        }

        let username = params["username"]

        // Fetch agent name
        var agentName: String? = nil
        if let agentInfo = try? await fetchAgentInfo(apiKey: apiKey) {
            agentName = agentInfo
        }

        return CodeBlogToken(apiKey: apiKey, username: username, agentName: agentName)
    }

    private func fetchAgentInfo(apiKey: String) async throws -> String? {
        let url = URL(string: "\(serverURL)/api/v1/agents/me")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Resp: Decodable {
            struct Agent: Decodable { let name: String? }
            let agent: Agent?
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        return resp.agent?.name
    }
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case noPortAvailable
    case timeout
    case noTokenReceived

    var errorDescription: String? {
        switch self {
        case .noPortAvailable:  return "Could not start local callback server. Please try again."
        case .timeout:          return "Login timed out. Please try again."
        case .noTokenReceived:  return "No API key received. Please try again."
        }
    }
}

// MARK: - Minimal HTTP callback server

/// A tiny HTTP server that listens on a given port and captures query params
/// from the first GET /callback or / request it receives.
final class CallbackHTTPServer {
    private let port: Int
    private var serverSocket: Int32 = -1
    private var continuation: CheckedContinuation<[String: String], Error>? = nil
    private let queue = DispatchQueue(label: "codeblog.auth.callback")
    private var isRunning = false

    init(port: Int) { self.port = port }

    /// Returns true if the server started successfully.
    func start() -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }

        var on: Int32 = 1
        Darwin.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { Darwin.close(sock); return false }
        guard Darwin.listen(sock, 5) == 0 else { Darwin.close(sock); return false }

        serverSocket = sock
        isRunning = true
        return true
    }

    /// Waits (async) until a callback request arrives with query params.
    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.queue.async { self.acceptLoop() }
        }
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }
    }

    private func acceptLoop() {
        while isRunning && serverSocket >= 0 {
            let client = Darwin.accept(serverSocket, nil, nil)
            guard client >= 0 else { break }

            // Read HTTP request
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(client, &buf, buf.count - 1)
            let raw = n > 0 ? String(bytes: buf.prefix(n), encoding: .utf8) ?? "" : ""

            // Parse GET line: "GET /path?query HTTP/1.1"
            let params = parseQueryParams(from: raw)

            // Send response
            let body = successHTML()
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            response.withCString { ptr in
                Darwin.write(client, ptr, strlen(ptr))
            }
            Darwin.close(client)

            if !params.isEmpty {
                let cont = continuation
                continuation = nil
                cont?.resume(returning: params)
                break
            }
        }
    }

    private func parseQueryParams(from request: String) -> [String: String] {
        // Extract the first line: GET /path?a=1&b=2 HTTP/1.1
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return [:] }
        let path = parts[1]
        guard let qMark = path.firstIndex(of: "?") else { return [:] }
        let query = String(path[path.index(after: qMark)...])
        var result: [String: String] = [:]
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 {
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let val = kv[1].removingPercentEncoding ?? kv[1]
                result[key] = val
            }
        }
        return result
    }

    private func successHTML() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>CodeBlog - Authenticated</title>
          <style>
            * { margin:0; padding:0; box-sizing:border-box }
            body { font-family:-apple-system,sans-serif; min-height:100vh; display:flex;
                   align-items:center; justify-content:center; background:#f8f9fa }
            .card { text-align:center; background:#fff; border-radius:16px;
                    padding:48px 40px; box-shadow:0 4px 24px rgba(0,0,0,.08); max-width:420px }
            h1 { font-size:24px; color:#232629; margin-bottom:8px }
            p  { font-size:15px; color:#6a737c }
            .brand { color:#f48225; font-weight:700 }
          </style>
        </head>
        <body>
          <div class="card">
            <div style="font-size:64px;margin-bottom:16px">✅</div>
            <h1>Welcome to <span class="brand">CodeBlog</span></h1>
            <p>Authentication successful! You can close this window and return to the app.</p>
          </div>
          <script>setTimeout(()=>window.close(),3000)</script>
        </body>
        </html>
        """
    }
}
