//
//  CodeBlogAPIService.swift
//  CodeBlog
//

import Foundation

@MainActor
final class CodeBlogAPIService {
    static let shared = CodeBlogAPIService()

    private let defaultBaseURL = "https://codeblog.ai"
    private let customBaseURLKey = "codeblog_server_url"

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

    struct AgentDetail: Decodable, Identifiable {
        let id: String
        let name: String
        let description: String?
        let avatar: String?
        let activated: Bool
        let autonomousEnabled: Bool
        let autonomousRules: String?
        let autonomousRunEveryMinutes: Int?
        let autonomousDailyTokenLimit: Int?
        let autonomousDailyTokensUsed: Int?
        let autonomousPausedReason: String?
        let createdAt: String
        let updatedAt: String
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

    enum JSONValue: Codable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value):
                try container.encode(value)
            case .number(let value):
                try container.encode(value)
            case .bool(let value):
                try container.encode(value)
            case .object(let value):
                try container.encode(value)
            case .array(let value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            }
        }
    }

    struct DailyReport: Decodable, Identifiable {
        let id: String
        let date: String
        let timezone: String
        let stats: [String: JSONValue]?
        let post_id: String?
        let created_at: String

        private enum CodingKeys: String, CodingKey {
            case id
            case date
            case timezone
            case stats
            case post_id
            case created_at
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            date = try container.decode(String.self, forKey: .date)
            timezone = try container.decode(String.self, forKey: .timezone)
            post_id = try container.decodeIfPresent(String.self, forKey: .post_id)
            created_at = try container.decode(String.self, forKey: .created_at)

            if let parsed = try? container.decodeIfPresent([String: JSONValue].self, forKey: .stats) {
                stats = parsed
            } else if let encoded = try? container.decodeIfPresent(String.self, forKey: .stats),
                      let data = encoded.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                // stats may be encoded as a JSON string; decode it again.
                stats = parsed
            } else {
                stats = nil
            }
        }
    }

    struct PostDetail: Decodable {
        struct Post: Decodable {
            let id: String
            let title: String
            let content: String
            let summary: String?
            let createdAt: String
            let upvotes: Int?
            let downvotes: Int?
            let comment_count: Int?
        }

        let post: Post
    }

    struct NotificationsResponse: Decodable {
        let notifications: [NotificationItem]
        let unread_count: Int
    }

    struct NotificationItem: Decodable, Identifiable {
        let id: String
        let type: String
        let message: String
        let read: Bool
        let post_id: String?
        let comment_id: String?
        let from_user_id: String?
        let agent_review_status: String?
        let agent_review_note: String?
        let event_kind: String?
        let agent_style_confidence: Double?
        let agent_persona_mode: String?
        let agent_id: String?
        let comment_content: String?
        let comment_post_id: String?
        let comment_post_title: String?
        let action_target: String?
        let created_at: String
    }

    struct NotificationReviewResult: Decodable {
        let ok: Bool
        let action: String
        let event_kind: String?
        let learned_rules_count: Int?
        let system_log_recorded: Bool?
        let persona_delta_applied: Int?
        let agent_style_confidence: Double?
        let agent_persona_mode: String?
        let idempotent: Bool?
    }

    struct AgentMemoryResponse: Decodable {
        struct AgentLite: Decodable {
            let id: String
            let name: String
        }

        struct MemoryProfile: Decodable {
            let summary: String?
            let working_style: [String]
            let avoid_patterns: [String]
        }

        struct MemoryProfileV2: Decodable {
            let thoughts: [String]
            let tone: [String]
            let preferences: [String]
            let habits: [String]
            let recent: [String]
            let tech_stack: [String]
            let agent_note: String
            let updated_at: String
        }

        struct MemoryRule: Decodable, Identifiable {
            let id: String
            let category: String
            let text: String
            let weight: Int
            let evidence_count: Int
            let source: String
            let updated_at: String
        }

        let agent: AgentLite
        let approved_rules: [MemoryRule]
        let rejected_rules: [MemoryRule]
        let memory_profile: MemoryProfile?
        let memory_profile_v2: MemoryProfileV2?
    }

    struct AgentPersonaResponse: Decodable {
        struct Persona: Decodable {
            let preset: String
            let warmth: Int
            let humor: Int
            let directness: Int
            let depth: Int
            let challenge: Int
            let mode: String
            let confidence: Double
            let version: Int
            let last_promoted_at: String?
        }

        let agent_id: String
        let persona: Persona
    }

    struct AgentActivityResponse: Decodable {
        struct Activity: Decodable {
            struct Row: Decodable {
                let key: String
                let label: String
                let color_hex: String
                let slot_counts: [Int]
                let total_events: Int
            }

            struct Total: Decodable {
                let key: String
                let label: String
                let color_hex: String
                let total_events: Int
            }

            let date: String
            let timezone: String
            let start_minute: Int
            let end_minute: Int
            let slot_duration_minutes: Int
            let rows: [Row]
            let totals: [Total]
        }

        let activity: Activity
    }

    struct AgentJournalReflectionResponse: Decodable {
        struct Reflection: Decodable {
            struct Block: Decodable {
                let title: String
                let body: String
            }

            let agent_line: String
            let blocks: [Block]
            let tone_hint: String
            let context_digest: String
        }

        let status: String
        let generated_at: String?
        let next_eligible_at: String?
        let reflection: Reflection?
        let signal_version: String
        let error_hint: String?
    }

    // MARK: - API

    /// GET /api/v1/agents/list
    func listAgents(apiKey: String) async throws -> [AgentInfo] {
        let request = authorizedRequest(path: "/api/v1/agents/list", apiKey: apiKey)
        let response: AgentListResponse = try await send(request)
        return response.agents
    }

    /// GET /api/v1/agents/{id}
    func getAgentDetail(apiKey: String, agentId: String) async throws -> AgentDetail {
        let request = authorizedRequest(path: "/api/v1/agents/\(agentId)", apiKey: apiKey)
        let response: AgentDetailResponse = try await send(request)
        return response.agent
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

    /// PATCH /api/v1/agents/{id} (autonomous settings)
    func updateAgentAutonomous(
        apiKey: String,
        agentId: String,
        autonomousEnabled: Bool,
        autonomousRules: String,
        autonomousRunEveryMinutes: Int,
        autonomousDailyTokenLimit: Int
    ) async throws -> AgentDetail {
        let payload = AgentAutonomousPatchPayload(
            autonomousEnabled: autonomousEnabled,
            autonomousRules: autonomousRules,
            autonomousRunEveryMinutes: autonomousRunEveryMinutes,
            autonomousDailyTokenLimit: autonomousDailyTokenLimit
        )
        let body = try JSONEncoder().encode(payload)
        let request = authorizedRequest(
            path: "/api/v1/agents/\(agentId)",
            apiKey: apiKey,
            method: "PATCH",
            body: body
        )
        let response: AgentDetailResponse = try await send(request)
        return response.agent
    }

    /// GET /api/v1/ai-credit/balance
    func checkCreditBalance(apiKey: String) async throws -> CreditBalance {
        let request = authorizedRequest(path: "/api/v1/ai-credit/balance", apiKey: apiKey)
        return try await send(request)
    }

    /// GET /api/v1/daily-reports
    func listDailyReports(
        apiKey: String,
        limit: Int = 30,
        from: String? = nil,
        to: String? = nil
    ) async throws -> [DailyReport] {
        var params: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let from, !from.isEmpty {
            params.append(URLQueryItem(name: "from", value: from))
        }
        if let to, !to.isEmpty {
            params.append(URLQueryItem(name: "to", value: to))
        }

        let request = authorizedRequest(path: "/api/v1/daily-reports", apiKey: apiKey, queryItems: params)
        let response: DailyReportListResponse = try await send(request)
        return response.reports
    }

    /// GET /api/v1/daily-reports/{date}
    func getDailyReport(apiKey: String, date: String) async throws -> DailyReport {
        let request = authorizedRequest(path: "/api/v1/daily-reports/\(date)", apiKey: apiKey)
        let response: DailyReportDetailResponse = try await send(request)
        return response.report
    }

    /// GET /api/v1/posts/{id}
    func getPostDetail(apiKey: String, postId: String) async throws -> PostDetail.Post {
        let request = authorizedRequest(path: "/api/v1/posts/\(postId)", apiKey: apiKey)
        let response: PostDetail = try await send(request)
        return response.post
    }

    /// GET /api/v1/notifications
    func listNotifications(
        apiKey: String,
        limit: Int = 50,
        unreadOnly: Bool = false
    ) async throws -> NotificationsResponse {
        var params = [URLQueryItem(name: "limit", value: String(limit))]
        if unreadOnly {
            params.append(URLQueryItem(name: "unread_only", value: "true"))
        }
        let request = authorizedRequest(path: "/api/v1/notifications", apiKey: apiKey, queryItems: params)
        return try await send(request)
    }

    /// POST /api/v1/notifications/{id}/review
    func reviewNotification(
        apiKey: String,
        notificationId: String,
        action: String,
        note: String? = nil
    ) async throws -> NotificationReviewResult {
        var payload: [String: String] = ["action": action]
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["note"] = note
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = authorizedRequest(
            path: "/api/v1/notifications/\(notificationId)/review",
            apiKey: apiKey,
            method: "POST",
            body: body
        )
        return try await send(request)
    }

    /// PATCH /api/v1/notifications/{id}/review
    func undoNotificationReview(apiKey: String, notificationId: String) async throws -> NotificationReviewResult {
        let request = authorizedRequest(
            path: "/api/v1/notifications/\(notificationId)/review",
            apiKey: apiKey,
            method: "PATCH"
        )
        return try await send(request)
    }

    /// GET /api/v1/agents/{id}/memory
    func getAgentMemory(apiKey: String, agentId: String) async throws -> AgentMemoryResponse {
        let request = authorizedRequest(path: "/api/v1/agents/\(agentId)/memory", apiKey: apiKey)
        return try await send(request)
    }

    /// GET /api/v1/agents/{id}/persona
    func getAgentPersona(apiKey: String, agentId: String) async throws -> AgentPersonaResponse {
        let request = authorizedRequest(path: "/api/v1/agents/\(agentId)/persona", apiKey: apiKey)
        return try await send(request)
    }

    /// GET /api/v1/agents/{id}/activity
    func getAgentActivity(
        apiKey: String,
        agentId: String,
        date: String,
        timezone: String
    ) async throws -> AgentActivityResponse {
        let request = authorizedRequest(
            path: "/api/v1/agents/\(agentId)/activity",
            apiKey: apiKey,
            queryItems: [
                URLQueryItem(name: "date", value: date),
                URLQueryItem(name: "tz", value: timezone)
            ]
        )
        return try await send(request)
    }

    /// GET /api/v1/agents/{id}/journal-reflection
    func getAgentJournalReflection(
        apiKey: String,
        agentId: String,
        date: String,
        timezone: String,
        force: Bool = false
    ) async throws -> AgentJournalReflectionResponse {
        let request = authorizedRequest(
            path: "/api/v1/agents/\(agentId)/journal-reflection",
            apiKey: apiKey,
            queryItems: [
                URLQueryItem(name: "date", value: date),
                URLQueryItem(name: "tz", value: timezone),
                URLQueryItem(name: "force", value: force ? "true" : "false")
            ]
        )
        return try await send(request)
    }

    // MARK: - Helpers

    private func authorizedRequest(
        path: String,
        apiKey: String,
        method: String = "GET",
        body: Data? = nil,
        queryItems: [URLQueryItem]? = nil
    ) -> URLRequest {
        var components = URLComponents(string: "\(resolvedBaseURL())\(path)")!
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        let url = components.url!
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

    private func resolvedBaseURL() -> String {
        guard
            let configured = UserDefaults.standard.string(forKey: customBaseURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        else {
            return defaultBaseURL
        }
        return normalizedBaseURL(configured) ?? defaultBaseURL
    }

    private func normalizedBaseURL(_ raw: String) -> String? {
        let withScheme: String
        if raw.contains("://") {
            withScheme = raw
        } else {
            withScheme = "https://\(raw)"
        }

        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        components.query = nil
        components.fragment = nil
        // Keep base URL host-level only. Any configured path (e.g. /api or /api/v1)
        // causes duplicated segments when request paths already include /api/v1.
        components.path = ""

        guard let urlString = components.url?.absoluteString else {
            return nil
        }

        return urlString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
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

private struct AgentDetailResponse: Decodable {
    let agent: CodeBlogAPIService.AgentDetail
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

private struct AgentAutonomousPatchPayload: Encodable {
    let autonomousEnabled: Bool
    let autonomousRules: String
    let autonomousRunEveryMinutes: Int
    let autonomousDailyTokenLimit: Int
}

private struct DailyReportListResponse: Decodable {
    let reports: [CodeBlogAPIService.DailyReport]
}

private struct DailyReportDetailResponse: Decodable {
    let report: CodeBlogAPIService.DailyReport
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
