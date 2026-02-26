//
//  LLMTypes.swift
//  CodeBlog
//

import Foundation

// MARK: - Third-Party Provider Types

enum ThirdPartyProvider: String, Codable, CaseIterable {
    case openai
    case anthropic
    case openrouter
    case groq
    case xai
    case perplexity
    case custom

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openrouter: return "OpenRouter"
        case .groq: return "Groq"
        case .xai: return "xAI (Grok)"
        case .perplexity: return "Perplexity"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var shortDescription: String {
        switch self {
        case .openai: return "GPT-4o, GPT-4o-mini, o3-mini"
        case .anthropic: return "Claude Sonnet, Claude Haiku"
        case .openrouter: return "Access 200+ models via one API"
        case .groq: return "Ultra-fast inference"
        case .xai: return "Grok models with real-time knowledge"
        case .perplexity: return "Search-augmented AI models"
        case .custom: return "Any OpenAI-compatible endpoint"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .xai: return "https://api.x.ai/v1"
        case .perplexity: return "https://api.perplexity.ai"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-20250514"
        case .openrouter: return "openai/gpt-4o-mini"
        case .groq: return "llama-3.3-70b-versatile"
        case .xai: return "grok-2-latest"
        case .perplexity: return "sonar"
        case .custom: return ""
        }
    }

    var keyPrefix: String? {
        switch self {
        case .openai: return "sk-"
        case .anthropic: return "sk-ant-"
        case .openrouter: return "sk-or-"
        case .groq: return "gsk_"
        case .xai: return "xai-"
        case .perplexity: return "pplx-"
        case .custom: return nil
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openai: return "sk-..."
        case .anthropic: return "sk-ant-..."
        case .openrouter: return "sk-or-..."
        case .groq: return "gsk_..."
        case .xai: return "xai-..."
        case .perplexity: return "pplx-..."
        case .custom: return "your-api-key"
        }
    }

    /// Asset catalog image name; nil means use iconSystemName as SF Symbol fallback
    var iconAssetName: String? {
        switch self {
        case .openai: return "OpenAILogo"
        case .anthropic: return "AnthropicLogo"
        case .openrouter: return "OpenRouterLogo"
        case .groq: return "GroqLogo"
        case .xai: return nil  // fallback to SF Symbol
        case .perplexity: return "PerplexityLogo"
        case .custom: return nil
        }
    }

    var iconSystemName: String {
        switch self {
        case .openai: return "brain"
        case .anthropic: return "sparkles"
        case .openrouter: return "arrow.triangle.branch"
        case .groq: return "bolt.fill"
        case .xai: return "bolt.horizontal.fill"
        case .perplexity: return "magnifyingglass"
        case .custom: return "server.rack"
        }
    }

    var usesAnthropicFormat: Bool {
        self == .anthropic
    }

    /// Validates the API key format for this provider
    func validateKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let prefix = keyPrefix else { return true }

        // Special case: OpenAI keys should not start with Anthropic or OpenRouter prefixes
        if self == .openai {
            if trimmed.hasPrefix("sk-ant-") || trimmed.hasPrefix("sk-or-") {
                return false
            }
        }
        return trimmed.hasPrefix(prefix)
    }
}

enum ThirdPartyProviderDefaults {
    static let providerKindKey = "thirdPartyProviderKind"
    static let baseURLKey = "thirdPartyBaseURL"
    static let modelKey = "thirdPartyModel"

    static func keychainKey(for provider: ThirdPartyProvider) -> String {
        "thirdparty_\(provider.rawValue)"
    }
}

struct ActivityGenerationContext {
    let batchObservations: [Observation]
    let existingCards: [ActivityCardData]  // Cards that overlap with current analysis window
    let currentTime: Date  // Current time to prevent future timestamps
    let categories: [LLMCategoryDescriptor]
}

enum LLMProviderType: Codable {
    case geminiDirect
    case codeblogBackend(endpoint: String = "https://web-production-f3361.up.railway.app")
    case ollamaLocal(endpoint: String = "http://localhost:11434")
    case chatGPTClaude
    case thirdPartyAPI(provider: ThirdPartyProvider = .openai, endpoint: String = "https://api.openai.com/v1", model: String? = "gpt-4o-mini")

    private static let providerDefaultsKey = "llmProviderType"
    private static let selectedProviderDefaultsKey = "selectedLLMProvider"
    private static let localBaseURLDefaultsKey = "llmLocalBaseURL"
    private static let chatCLIPreferredToolDefaultsKey = "chatCLIPreferredTool"

    static func load(from defaults: UserDefaults = .standard) -> LLMProviderType {
        if let savedData = defaults.data(forKey: providerDefaultsKey),
           let decoded = try? JSONDecoder().decode(LLMProviderType.self, from: savedData) {
            return decoded
        }

        guard let migrated = migrateLegacySelection(from: defaults) else {
            return .geminiDirect
        }

        migrated.persist(to: defaults)
        return migrated
    }

    func persist(to defaults: UserDefaults = .standard) {
        if let encoded = try? JSONEncoder().encode(self) {
            defaults.set(encoded, forKey: Self.providerDefaultsKey)
        }
        defaults.set(canonicalProviderID, forKey: Self.selectedProviderDefaultsKey)
    }

    var canonicalProviderID: String {
        switch self {
        case .geminiDirect:
            return "gemini"
        case .codeblogBackend:
            return "codeblog"
        case .ollamaLocal:
            return "ollama"
        case .chatGPTClaude:
            return "chatgpt_claude"
        case .thirdPartyAPI:
            return "thirdparty"
        }
    }

    private static func migrateLegacySelection(from defaults: UserDefaults) -> LLMProviderType? {
        guard let rawSelection = defaults.string(forKey: selectedProviderDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !rawSelection.isEmpty else {
            return nil
        }

        switch rawSelection {
        case "gemini":
            return .geminiDirect
        case "codeblog":
            return .codeblogBackend()
        case "ollama":
            let endpoint = defaults.string(forKey: localBaseURLDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let endpoint, !endpoint.isEmpty {
                return .ollamaLocal(endpoint: endpoint)
            }
            return .ollamaLocal()
        case "chatgpt":
            if defaults.string(forKey: chatCLIPreferredToolDefaultsKey) == nil {
                defaults.set("codex", forKey: chatCLIPreferredToolDefaultsKey)
            }
            return .chatGPTClaude
        case "claude":
            if defaults.string(forKey: chatCLIPreferredToolDefaultsKey) == nil {
                defaults.set("claude", forKey: chatCLIPreferredToolDefaultsKey)
            }
            return .chatGPTClaude
        case "chatgpt_claude":
            return .chatGPTClaude
        case "thirdparty":
            let kind = ThirdPartyProvider(rawValue: defaults.string(forKey: ThirdPartyProviderDefaults.providerKindKey) ?? "") ?? .openai
            let endpoint = defaults.string(forKey: ThirdPartyProviderDefaults.baseURLKey) ?? kind.defaultBaseURL
            let model = defaults.string(forKey: ThirdPartyProviderDefaults.modelKey)
            return .thirdPartyAPI(provider: kind, endpoint: endpoint, model: model)
        default:
            return nil
        }
    }
}

enum LLMProviderID: String, Codable, CaseIterable {
    case gemini
    case codeblog
    case ollama
    case chatGPTClaude = "chatgpt_claude"
    case thirdPartyAPI = "thirdparty"

    var analyticsName: String {
        switch self {
        case .gemini:
            return "gemini"
        case .codeblog:
            return "codeblog"
        case .ollama:
            return "ollama"
        case .chatGPTClaude:
            return "chat_cli"
        case .thirdPartyAPI:
            return "thirdparty"
        }
    }

    static func from(_ providerType: LLMProviderType) -> LLMProviderID {
        switch providerType {
        case .geminiDirect:
            return .gemini
        case .codeblogBackend:
            return .codeblog
        case .ollamaLocal:
            return .ollama
        case .chatGPTClaude:
            return .chatGPTClaude
        case .thirdPartyAPI:
            return .thirdPartyAPI
        }
    }

    func providerLabel(chatTool: ChatCLITool? = nil) -> String {
        switch self {
        case .gemini:
            return "gemini"
        case .codeblog:
            return "codeblog"
        case .ollama:
            return "local"
        case .chatGPTClaude:
            return chatTool == .claude ? "claude" : "chatgpt"
        case .thirdPartyAPI:
            let kind = ThirdPartyProvider(rawValue: UserDefaults.standard.string(forKey: ThirdPartyProviderDefaults.providerKindKey) ?? "") ?? .openai
            return kind.displayName.lowercased()
        }
    }
}

enum LLMProviderRoutingPreferences {
    static let backupProviderDefaultsKey = "llmBackupProviderId"
    static let backupChatCLIToolDefaultsKey = "llmBackupChatCLITool"

    static func loadBackupProvider(from defaults: UserDefaults = .standard) -> LLMProviderID? {
        guard let rawValue = defaults.string(forKey: backupProviderDefaultsKey) else {
            return nil
        }
        return LLMProviderID(rawValue: rawValue)
    }

    static func saveBackupProvider(_ provider: LLMProviderID?, to defaults: UserDefaults = .standard) {
        if let provider {
            defaults.set(provider.rawValue, forKey: backupProviderDefaultsKey)
        } else {
            defaults.removeObject(forKey: backupProviderDefaultsKey)
        }
    }

    static func loadBackupChatCLITool(from defaults: UserDefaults = .standard) -> ChatCLITool? {
        guard let rawValue = defaults.string(forKey: backupChatCLIToolDefaultsKey) else {
            return nil
        }
        return ChatCLITool(rawValue: rawValue)
    }

    static func saveBackupChatCLITool(_ tool: ChatCLITool?, to defaults: UserDefaults = .standard) {
        if let tool {
            defaults.set(tool.rawValue, forKey: backupChatCLIToolDefaultsKey)
        } else {
            defaults.removeObject(forKey: backupChatCLIToolDefaultsKey)
        }
    }
}

struct BatchingConfig {
    let targetDuration: TimeInterval
    let maxGap: TimeInterval
    let cardLookbackDuration: TimeInterval

    static let standard = BatchingConfig(
        targetDuration: 15 * 60,      // 15-minute analysis batches
        maxGap: 2 * 60,               // Split batches if gap exceeds 2 minutes
        cardLookbackDuration: 45 * 60 // Build cards with a 45-minute lookback window
    )
}


struct AppSites: Codable {
    let primary: String?
    let secondary: String?
}

struct ActivityCardData: Codable {
    let startTime: String
    let endTime: String
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String
    let distractions: [Distraction]?
    let appSites: AppSites?
}

// Distraction is defined in StorageManager.swift
// LLMCall is defined in StorageManager.swift
