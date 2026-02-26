//
//  CodeBlogBackendProvider.swift
//  CodeBlog
//

import Foundation

final class CodeBlogBackendProvider {
    private let token: String
    private let endpoint: String

    init(token: String, endpoint: String = "https://web-production-f3361.up.railway.app") {
        self.token = token
        self.endpoint = endpoint
    }

    func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?) async throws -> (observations: [Observation], log: LLMCall) {
        throw unsupportedFeatureError()
    }

    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall) {
        throw unsupportedFeatureError()
    }

    func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
        throw NSError(
            domain: "CodeBlogBackend",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Text generation is not yet supported with CodeBlog Backend. Please configure Gemini, Ollama, or ChatGPT/Claude CLI in Settings."]
        )
    }

    private func unsupportedFeatureError() -> NSError {
        NSError(
            domain: "CodeBlogBackend",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "CodeBlog Backend timeline analysis is not available yet. Please configure Gemini, Ollama, or ChatGPT/Claude CLI in Settings."]
        )
    }
}
