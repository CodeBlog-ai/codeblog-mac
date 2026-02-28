import Foundation

enum LocalEndpointUtilities {
    /// Builds a chat-completions endpoint URL from a user-provided base URL.
    /// The base may already include `/v1` (e.g., https://openrouter.ai/api/v1) or a full `/v1/chat/completions` path.
    static func chatCompletionsURL(baseURL: String) -> URL? {
        endpointURL(baseURL: baseURL, terminalSegments: ["chat", "completions"])
    }

    /// Builds a models endpoint URL from a user-provided base URL.
    /// Handles inputs like `/v1`, `/v1/chat/completions`, `/models`, and missing `/v1`.
    static func modelsURL(baseURL: String) -> URL? {
        endpointURL(baseURL: baseURL, terminalSegments: ["models"])
    }

    /// Builds Anthropic messages endpoint from a user-provided base URL.
    /// Handles `/v1`, `/v1/messages`, and missing `/v1`.
    static func anthropicMessagesURL(baseURL: String) -> URL? {
        endpointURL(baseURL: baseURL, terminalSegments: ["messages"])
    }

    private static func endpointURL(baseURL: String, terminalSegments: [String]) -> URL? {
        guard let normalized = normalizedComponents(baseURL: baseURL) else {
            return nil
        }

        let root = apiRootSegments(from: normalized.pathSegments)
        let full = root + terminalSegments
        var components = normalized.components
        components.path = "/" + full.joined(separator: "/")
        return components.url
    }

    private static func normalizedComponents(baseURL: String) -> NormalizedURLComponents? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme != nil, components.host != nil else { return nil }

        var segments = pathSegments(from: components.path)
        segments = segments.map(normalizePathSegment)
        components.path = "/" + segments.joined(separator: "/")
        return NormalizedURLComponents(components: components, pathSegments: segments)
    }

    private static func apiRootSegments(from segments: [String]) -> [String] {
        var normalized = segments

        // If the base points to a concrete endpoint, strip it back to API root.
        if hasSuffix(normalized, ["chat", "completions"]) {
            normalized.removeLast(2)
        } else if hasSuffix(normalized, ["responses"]) ||
                    hasSuffix(normalized, ["models"]) ||
                    hasSuffix(normalized, ["model"]) ||
                    hasSuffix(normalized, ["messages"]) {
            normalized.removeLast()
        }

        if normalized.last == "v1" {
            return normalized
        }

        if let v1Index = normalized.firstIndex(of: "v1") {
            return Array(normalized[...v1Index])
        }

        if normalized.isEmpty {
            return ["v1"]
        }

        normalized.append("v1")
        return normalized
    }

    private static func hasSuffix(_ segments: [String], _ suffix: [String]) -> Bool {
        guard segments.count >= suffix.count else { return false }
        return Array(segments.suffix(suffix.count)) == suffix
    }

    private static func pathSegments(from path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        return path
            .split(separator: "/")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private static func normalizePathSegment(_ segment: String) -> String {
        switch segment.lowercased() {
        case "vi", "vl":
            // Common typo when users manually type `/v1`.
            return "v1"
        default:
            return segment
        }
    }
}

private struct NormalizedURLComponents {
    var components: URLComponents
    var pathSegments: [String]
}
