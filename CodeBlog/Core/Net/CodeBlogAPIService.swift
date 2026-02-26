//
//  CodeBlogAPIService.swift
//  CodeBlog
//

import Foundation

@MainActor
final class CodeBlogAPIService {
    static let shared = CodeBlogAPIService()

    private let baseURL = "https://codeblog.ai"

    private init() {}

    // MARK: - Models

    struct AgentInfo: Codable, Identifiable {
        let id: String
        let name: String
        let description: String?
        let source_type: String
        let avatar: String?
        let activated: Bool
        let claimed: Bool
        let is_current: Bool
        let posts_count: Int
        let created_at: String
    }

    struct AgentCreateResult: Codable {
        let id: String
        let name: String
        let api_key: String
        let source_type: String
        let created_at: String
    }

    struct AgentSwitchResult: Codable {
        let id: String
        let name: String
        let api_key: String
        let source_type: String
        let activated: Bool
    }

    struct CreditBalance: Codable {
        let balance_cents: Int
        let balance_usd: String
    }

    // MARK: - API

    /// GET /api/v1/agents/list
    func listAgents(apiKey: String) async throws -> [AgentInfo] {
        let request = authorizedRequest(path: "/api/v1/agents/list", apiKey: apiKey)
        let response: AgentListResponse = try await send(request)
        return response.agents
    }

    /// POST /api/v1/agents/create
    func createAgent(apiKey: String, name: String, sourceType: String) async throws -> AgentCreateResult {
        let payload = AgentCreatePayload(name: name, source_type: sourceType)
        let body = try JSONEncoder().encode(payload)
        let request = authorizedRequest(path: "/api/v1/agents/create", apiKey: apiKey, method: "POST", body: body)
        let response: AgentCreateResponse = try await send(request)
        return response.agent
    }

    /// POST /api/v1/agents/switch
    func switchAgent(apiKey: String, agentId: String) async throws -> AgentSwitchResult {
        let payload = AgentSwitchPayload(agent_id: agentId)
        let body = try JSONEncoder().encode(payload)
        let request = authorizedRequest(path: "/api/v1/agents/switch", apiKey: apiKey, method: "POST", body: body)
        let response: AgentSwitchResponse = try await send(request)
        return response.agent
    }

    /// PATCH /api/v1/agents/{id}/persona
    func updateAgentPersona(apiKey: String, agentId: String, preset: String, warmth: Int, humor: Int, directness: Int, depth: Int, challenge: Int) async throws {
        let payload = PersonaPatchPayload(preset: preset, warmth: warmth, humor: humor, directness: directness, depth: depth, challenge: challenge)
        let body = try JSONEncoder().encode(payload)
        let request = authorizedRequest(path: "/api/v1/agents/\(agentId)/persona", apiKey: apiKey, method: "PATCH", body: body)
        // We don't need the response, just verify it succeeds
        let _: PersonaPatchResponse = try await send(request)
    }

    /// GET /api/v1/ai-credit/balance
    func checkCreditBalance(apiKey: String) async throws -> CreditBalance {
        let request = authorizedRequest(path: "/api/v1/ai-credit/balance", apiKey: apiKey)
        return try await send(request)
    }

    // MARK: - Helpers

    private func authorizedRequest(path: String, apiKey: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        print("[CodeBlogAPI] \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIServiceError.invalidResponse
        }

        print("[CodeBlogAPI] Status: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            let msg = Self.errorMessage(from: data)
            print("[CodeBlogAPI] Error: \(msg ?? "unknown")")
            throw APIServiceError.httpStatus(httpResponse.statusCode, msg)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            print("[CodeBlogAPI] Decoding failed: \(error)")
            throw APIServiceError.decodingFailed
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = (object["error"] as? String) ?? (object["message"] as? String)
        else {
            return nil
        }
        return message
    }
}

// MARK: - Private API Shapes

private struct AgentListResponse: Decodable {
    let agents: [CodeBlogAPIService.AgentInfo]
}

private struct AgentCreatePayload: Encodable {
    let name: String
    let source_type: String
}

private struct AgentCreateResponse: Decodable {
    let agent: CodeBlogAPIService.AgentCreateResult
}

private struct AgentSwitchPayload: Encodable {
    let agent_id: String
}

private struct AgentSwitchResponse: Decodable {
    let agent: CodeBlogAPIService.AgentSwitchResult
}

private struct PersonaPatchPayload: Encodable {
    let preset: String
    let warmth: Int
    let humor: Int
    let directness: Int
    let depth: Int
    let challenge: Int
}

private struct PersonaPatchResponse: Decodable {
    let agent_id: String
}

private enum APIServiceError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String?)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "CodeBlog API returned an invalid response."
        case .httpStatus(let statusCode, let message):
            if let message, !message.isEmpty {
                return message
            }
            return "CodeBlog API request failed (status \(statusCode))."
        case .decodingFailed:
            return "CodeBlog API response format is invalid."
        }
    }
}
