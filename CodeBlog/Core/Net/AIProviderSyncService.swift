//
//  AIProviderSyncService.swift
//  CodeBlog
//
//  将 mac 端 LLM 配置同步到 web 端，让 MCP Agent 使用相同的 AI 提供商
//

import Foundation

@MainActor
final class AIProviderSyncService {
    static let shared = AIProviderSyncService()

    private let baseURL = "https://codeblog.ai"
    private let lastSyncKey = "aiProviderLastSyncDate"

    private init() {}

    // MARK: - Public

    /// 当前 mac 端配置是否可同步到 web
    var isSyncable: Bool {
        webPayload(for: LLMProviderType.load()) != nil
    }

    /// 上次同步时间
    var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    /// 把当前 mac 端 AI 配置推送到 web
    func pushToWeb() async throws {
        guard let apiKey = CodeBlogTokenResolver.currentToken() else {
            throw SyncError.notLoggedIn
        }

        let providerType = LLMProviderType.load()

        guard let payload = webPayload(for: providerType) else {
            print("[AIProviderSync] Provider not syncable: \(providerType.canonicalProviderID)")
            return
        }

        let body = try JSONEncoder().encode(payload)

        var request = URLRequest(url: URL(string: "\(baseURL)/api/auth/ai-provider")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        print("[AIProviderSync] PUT /api/auth/ai-provider provider=\(payload.provider)")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw SyncError.httpError(http.statusCode)
        }

        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        print("[AIProviderSync] Sync successful")
    }

    // MARK: - Mapping

    private struct WebAIProviderPayload: Encodable {
        let provider: String            // "anthropic" | "openai" | "openai-compatible" | "google"
        let apiKey: String
        let baseUrl: String?
        let model: String?
        let api: String                 // same as provider for most cases
        let compatProfile: String?
        let displayName: String?
    }

    private func webPayload(for providerType: LLMProviderType) -> WebAIProviderPayload? {
        switch providerType {

        case .thirdPartyAPI(let thirdParty, let endpoint, let model):
            return payload(for: thirdParty, endpoint: endpoint, model: model)

        case .geminiDirect:
            // Gemini Direct uses its own API key stored separately; skip sync unless key exists
            let key = UserDefaults.standard.string(forKey: "geminiDirectAPIKey") ?? ""
            guard !key.isEmpty else { return nil }
            return WebAIProviderPayload(
                provider: "google",
                apiKey: key,
                baseUrl: nil,
                model: UserDefaults.standard.string(forKey: "geminiDirectModel"),
                api: "google",
                compatProfile: nil,
                displayName: "Google Gemini"
            )

        case .ollamaLocal, .chatGPTClaude, .codeblogBackend:
            // Local / CLI / platform — not synced
            return nil
        }
    }

    private func payload(
        for thirdParty: ThirdPartyProvider,
        endpoint: String,
        model: String?
    ) -> WebAIProviderPayload? {
        // Read the API key from Keychain
        let keychainKey = ThirdPartyProviderDefaults.keychainKey(for: thirdParty)
        let apiKey = KeychainManager.shared.retrieve(for: keychainKey) ?? ""
        guard !apiKey.isEmpty else { return nil }

        switch thirdParty {
        case .anthropic:
            return WebAIProviderPayload(
                provider: "anthropic",
                apiKey: apiKey,
                baseUrl: nil,
                model: model,
                api: "anthropic",
                compatProfile: nil,
                displayName: "Anthropic"
            )
        case .openai:
            return WebAIProviderPayload(
                provider: "openai",
                apiKey: apiKey,
                baseUrl: nil,
                model: model,
                api: "openai",
                compatProfile: nil,
                displayName: "OpenAI"
            )
        case .openrouter, .groq, .xai, .perplexity, .custom:
            return WebAIProviderPayload(
                provider: "openai-compatible",
                apiKey: apiKey,
                baseUrl: endpoint.isEmpty ? nil : endpoint,
                model: model,
                api: "openai-compatible",
                compatProfile: thirdParty.rawValue,
                displayName: thirdParty.displayName
            )
        }
    }
}

// MARK: - Errors

extension AIProviderSyncService {
    enum SyncError: LocalizedError {
        case notLoggedIn
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "User not logged in"
            case .invalidResponse: return "Invalid server response"
            case .httpError(let code): return "HTTP error \(code)"
            }
        }
    }
}
