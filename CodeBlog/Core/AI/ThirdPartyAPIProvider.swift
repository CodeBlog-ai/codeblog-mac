//
//  ThirdPartyAPIProvider.swift
//  CodeBlog
//
//  Third-party API provider supporting OpenAI-compatible and Anthropic endpoints.
//

import Foundation
import AppKit

final class ThirdPartyAPIProvider {
    let apiKey: String
    let baseURL: String
    let model: String
    let providerKind: ThirdPartyProvider

    private let screenshotInterval: TimeInterval = 10

    init(apiKey: String, baseURL: String, model: String, providerKind: ThirdPartyProvider) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.providerKind = providerKind
    }

    /// Convenience: build from persisted UserDefaults + Keychain
    static func fromDefaults() -> ThirdPartyAPIProvider? {
        guard let kindRaw = UserDefaults.standard.string(forKey: ThirdPartyProviderDefaults.providerKindKey),
              let kind = ThirdPartyProvider(rawValue: kindRaw) else { return nil }

        let baseURL = UserDefaults.standard.string(forKey: ThirdPartyProviderDefaults.baseURLKey) ?? kind.defaultBaseURL
        let model = UserDefaults.standard.string(forKey: ThirdPartyProviderDefaults.modelKey) ?? kind.defaultModel

        let keychainKey = ThirdPartyProviderDefaults.keychainKey(for: kind)
        guard let apiKey = KeychainManager.shared.retrieve(for: keychainKey), !apiKey.isEmpty else { return nil }

        return ThirdPartyAPIProvider(apiKey: apiKey, baseURL: baseURL, model: model, providerKind: kind)
    }

    // MARK: - Private Types

    private struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMsg]
        var temperature: Double = 0.7
        var max_tokens: Int = 4000
        var stream: Bool = false
    }

    private struct ChatMsg: Codable {
        let role: String
        let content: [MsgContent]
    }

    private struct MsgContent: Codable {
        let type: String
        let text: String?
        let image_url: ImageURL?

        struct ImageURL: Codable {
            let url: String
        }
    }

    private struct ChatResponseOAI: Codable {
        let choices: [Choice]
        struct Choice: Codable {
            let message: Msg
        }
        struct Msg: Codable {
            let content: String
        }
    }

    // Anthropic message format
    private struct AnthropicRequest: Codable {
        let model: String
        let max_tokens: Int
        let messages: [AnthropicMessage]
        var temperature: Double = 0.7
    }

    private struct AnthropicMessage: Codable {
        let role: String
        let content: [AnthropicContent]
    }

    private struct AnthropicContent: Codable {
        let type: String
        let text: String?
        let source: AnthropicImageSource?
    }

    private struct AnthropicImageSource: Codable {
        let type: String       // "base64"
        let media_type: String // "image/jpeg"
        let data: String       // base64 string
    }

    private struct AnthropicResponse: Codable {
        let content: [AnthropicResponseContent]
    }

    private struct AnthropicResponseContent: Codable {
        let type: String
        let text: String?
    }

    // MARK: - Core API Call

    private func callAPI(systemPrompt: String?, userText: String, imageBase64: String? = nil, expectJSON: Bool = false, operation: String, batchId: Int64? = nil) async throws -> String {
        if providerKind.usesAnthropicFormat {
            return try await callAnthropicAPI(systemPrompt: systemPrompt, userText: userText, imageBase64: imageBase64, operation: operation, batchId: batchId)
        } else {
            return try await callOpenAICompatibleAPI(systemPrompt: systemPrompt, userText: userText, imageBase64: imageBase64, expectJSON: expectJSON, operation: operation, batchId: batchId)
        }
    }

    private func callOpenAICompatibleAPI(systemPrompt: String?, userText: String, imageBase64: String?, expectJSON: Bool, operation: String, batchId: Int64?) async throws -> String {
        guard let url = LocalEndpointUtilities.chatCompletionsURL(baseURL: baseURL) else {
            throw makeError("Invalid base URL: \(baseURL)")
        }

        var messages: [ChatMsg] = []
        if let sys = systemPrompt {
            messages.append(ChatMsg(role: "system", content: [MsgContent(type: "text", text: sys, image_url: nil)]))
        }

        var userContent: [MsgContent] = [MsgContent(type: "text", text: userText, image_url: nil)]
        if let b64 = imageBase64 {
            userContent.append(MsgContent(type: "image_url", text: nil, image_url: MsgContent.ImageURL(url: "data:image/jpeg;base64,\(b64)")))
        }
        messages.append(ChatMsg(role: "user", content: userContent))

        let body = ChatRequest(model: model, messages: messages)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 60

        let callGroupId = UUID().uuidString
        let ctx = LLMCallContext(
            batchId: batchId, callGroupId: callGroupId, attempt: 1,
            provider: "thirdparty_\(providerKind.rawValue)", model: model, operation: operation,
            requestMethod: "POST", requestURL: url,
            requestHeaders: request.allHTTPHeaderFields,
            requestBody: operation == "describe_frame" ? nil : request.httpBody,
            startedAt: Date()
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw makeError("Invalid response")
        }

        let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible { acc[k] = v.description }
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            LLMLogger.logFailure(ctx: ctx, http: LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data), finishedAt: Date(), errorDomain: "ThirdPartyAPI", errorCode: httpResponse.statusCode, errorMessage: errorBody)
            throw makeError("API error \(httpResponse.statusCode): \(errorBody)")
        }

        let decoded = try JSONDecoder().decode(ChatResponseOAI.self, from: data)
        LLMLogger.logSuccess(ctx: ctx, http: LLMHTTPInfo(httpStatus: 200, responseHeaders: responseHeaders, responseBody: data), finishedAt: Date())
        return decoded.choices.first?.message.content ?? ""
    }

    private func callAnthropicAPI(systemPrompt: String?, userText: String, imageBase64: String?, operation: String, batchId: Int64?) async throws -> String {
        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)messages" : "\(baseURL)/messages"
        guard let url = URL(string: urlString) else {
            throw makeError("Invalid Anthropic base URL")
        }

        var userContent: [AnthropicContent] = []
        if let b64 = imageBase64 {
            userContent.append(AnthropicContent(type: "image", text: nil, source: AnthropicImageSource(type: "base64", media_type: "image/jpeg", data: b64)))
        }
        userContent.append(AnthropicContent(type: "text", text: userText, source: nil))

        let messages = [AnthropicMessage(role: "user", content: userContent)]
        let body = AnthropicRequest(model: model, max_tokens: 4000, messages: messages)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 60

        let callGroupId = UUID().uuidString
        let ctx = LLMCallContext(
            batchId: batchId, callGroupId: callGroupId, attempt: 1,
            provider: "thirdparty_anthropic", model: model, operation: operation,
            requestMethod: "POST", requestURL: url,
            requestHeaders: request.allHTTPHeaderFields,
            requestBody: operation == "describe_frame" ? nil : request.httpBody,
            startedAt: Date()
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw makeError("Invalid response")
        }

        let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible { acc[k] = v.description }
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            LLMLogger.logFailure(ctx: ctx, http: LLMHTTPInfo(httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders, responseBody: data), finishedAt: Date(), errorDomain: "ThirdPartyAPI", errorCode: httpResponse.statusCode, errorMessage: errorBody)
            throw makeError("Anthropic API error \(httpResponse.statusCode): \(errorBody)")
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        LLMLogger.logSuccess(ctx: ctx, http: LLMHTTPInfo(httpStatus: 200, responseHeaders: responseHeaders, responseBody: data), finishedAt: Date())
        return decoded.content.first(where: { $0.type == "text" })?.text ?? ""
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(domain: "ThirdPartyAPIProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    // MARK: - Helper: Text-Only Call

    private func callTextAPI(_ prompt: String, operation: String, expectJSON: Bool = false, batchId: Int64? = nil) async throws -> String {
        let systemPrompt = expectJSON ? "You are a helpful assistant. Always respond with valid JSON." : "You are a helpful assistant."
        return try await callAPI(systemPrompt: systemPrompt, userText: prompt, operation: operation, batchId: batchId)
    }

    // MARK: - Screenshot Frame Handling

    private struct FrameData {
        let image: Data  // Base64-encoded image as UTF-8 Data
        let timestamp: TimeInterval
    }

    private func getSimpleFrameDescription(_ frame: FrameData, batchId: Int64?) async -> String? {
        let prompt = """
        Describe what you see on this computer screen in 1-2 sentences.
        Focus on: what application/site is open, what the user is doing, and any relevant details visible.
        Be specific and factual.
        """

        guard let base64String = String(data: frame.image, encoding: .utf8) else { return nil }

        do {
            return try await callAPI(systemPrompt: nil, userText: prompt, imageBase64: base64String, operation: "describe_frame", batchId: batchId)
        } catch {
            print("[ThirdPartyAPI] Frame description failed: \(error)")
            return nil
        }
    }

    private func loadScreenshotAsFrameData(_ screenshot: Screenshot, relativeTo baseTimestamp: Int) -> FrameData? {
        guard let imageData = loadScreenshotData(screenshot) else { return nil }
        let base64String = imageData.base64EncodedString()
        let base64Data = Data(base64String.utf8)
        return FrameData(image: base64Data, timestamp: TimeInterval(screenshot.capturedAt - baseTimestamp))
    }

    private func loadScreenshotData(_ screenshot: Screenshot, maxHeight: Double = 720, jpegQuality: CGFloat = 0.85) -> Data? {
        let url = URL(fileURLWithPath: screenshot.filePath)
        guard let image = NSImage(contentsOf: url) else {
            return try? Data(contentsOf: url)
        }
        let size = image.size
        guard size.height > 0, size.width > 0 else { return nil }

        if size.height <= maxHeight {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
        }

        let scale = maxHeight / size.height
        let newSize = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize))
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }

    // MARK: - Observation Merging

    private func mergeFrameDescriptions(_ frames: [(timestamp: TimeInterval, description: String)], batchStartTime: Date, videoDuration: TimeInterval, batchId: Int64?) async throws -> [Observation] {
        let frameList = frames.map { "[\(formatTime($0.timestamp))]: \($0.description)" }.joined(separator: "\n")
        let prompt = """
        You have a series of timestamped observations from screen recordings. Group them into coherent activity segments.

        Frame descriptions:
        \(frameList)

        Group these into activity observations. Each observation should cover a period of related activity.
        Respond with a JSON array of objects, each with:
        - "start_offset": seconds from start (number)
        - "end_offset": seconds from start (number)
        - "observation": a concise description of the activity

        Respond with ONLY the JSON array, no other text.
        """

        let response = try await callTextAPI(prompt, operation: "merge_observations", expectJSON: true, batchId: batchId)
        return parseObservations(response, batchStartTime: batchStartTime, batchId: batchId ?? 0)
    }

    private func parseObservations(_ json: String, batchStartTime: Date, batchId: Int64) -> [Observation] {
        struct RawObs: Decodable {
            let start_offset: Double
            let end_offset: Double
            let observation: String
        }

        let cleaned = json.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let items = try? JSONDecoder().decode([RawObs].self, from: data) else {
            return [Observation(id: nil, batchId: batchId, startTs: Int(batchStartTime.timeIntervalSince1970), endTs: Int(batchStartTime.timeIntervalSince1970) + 300, observation: cleaned, metadata: nil, llmModel: model, createdAt: Date())]
        }

        let baseTs = Int(batchStartTime.timeIntervalSince1970)
        return items.map {
            Observation(id: nil, batchId: batchId, startTs: baseTs + Int($0.start_offset), endTs: baseTs + Int($0.end_offset), observation: $0.observation, metadata: nil, llmModel: model, createdAt: Date())
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Activity Card Generation Helpers

    private struct TitleSummaryResponse: Codable {
        let reasoning: String
        let title: String
        let summary: String
        let category: String
        let appSites: AppSites?
    }

    private struct MergeDecision: Codable {
        let reason: String
        let combine: Bool
    }

    private func formatTimestampForPrompt(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func generateTitleAndSummary(observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?) async throws -> (TitleSummaryResponse, String) {
        let categoryList = categories.map { "- \($0.name)" }.joined(separator: "\n")
        let obsList = observations.map { "- \($0.observation)" }.joined(separator: "\n")

        let prompt = """
        Based on these screen observations, generate an activity card:

        Observations:
        \(obsList)

        Available categories:
        \(categoryList)

        Respond with ONLY a JSON object:
        {
          "reasoning": "brief reasoning",
          "title": "short activity title (3-8 words)",
          "summary": "one sentence summary",
          "category": "one of the categories above",
          "appSites": {"primary": "main app/site or null", "secondary": "secondary app/site or null"}
        }
        """

        let response = try await callTextAPI(prompt, operation: "generate_title_summary", expectJSON: true, batchId: batchId)

        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw makeError("Failed to parse title/summary response")
        }

        let result = try JSONDecoder().decode(TitleSummaryResponse.self, from: data)
        return (result, "TitleSummary: \(cleaned)")
    }

    private func checkShouldMerge(previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?) async throws -> (Bool, String) {
        let prompt = """
        Should these two activity cards be merged into one?

        Card 1: "\(previousCard.title)" (\(previousCard.startTime) - \(previousCard.endTime))
        Summary: \(previousCard.summary)
        Category: \(previousCard.category)

        Card 2: "\(newCard.title)" (\(newCard.startTime) - \(newCard.endTime))
        Summary: \(newCard.summary)
        Category: \(newCard.category)

        Respond with ONLY a JSON object: {"reason": "brief reason", "combine": true/false}
        """

        let response = try await callTextAPI(prompt, operation: "check_merge", expectJSON: true, batchId: batchId)

        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let decision = try? JSONDecoder().decode(MergeDecision.self, from: data) else {
            return (false, "MergeCheck: parse failed, defaulting to no merge")
        }

        return (decision.combine, "MergeCheck: \(cleaned)")
    }

    private func mergeTwoCards(previousCard: ActivityCardData, newCard: ActivityCardData, batchId: Int64?) async throws -> (ActivityCardData, String) {
        let prompt = """
        Merge these two activity cards into one:

        Card 1: "\(previousCard.title)" (\(previousCard.startTime) - \(previousCard.endTime))
        Summary: \(previousCard.summary)
        Category: \(previousCard.category)

        Card 2: "\(newCard.title)" (\(newCard.startTime) - \(newCard.endTime))
        Summary: \(newCard.summary)
        Category: \(newCard.category)

        Respond with ONLY a JSON object:
        {"reasoning": "...", "title": "merged title", "summary": "merged summary", "category": "category"}
        """

        let response = try await callTextAPI(prompt, operation: "merge_cards", expectJSON: true, batchId: batchId)

        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(TitleSummaryResponse.self, from: data) else {
            // Fallback: just use the new card
            return (newCard, "Merge parse failed, using new card")
        }

        let merged = ActivityCardData(
            startTime: previousCard.startTime,
            endTime: newCard.endTime,
            category: parsed.category,
            subcategory: "",
            title: parsed.title,
            summary: parsed.summary,
            detailedSummary: "",
            distractions: nil,
            appSites: parsed.appSites ?? previousCard.appSites
        )

        return (merged, "Merge: \(cleaned)")
    }

    private func normalizeCategory(_ raw: String, categories: [LLMCategoryDescriptor]) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return categories.first?.name ?? "" }
        let normalized = cleaned.lowercased()
        if let match = categories.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }) {
            return match.name
        }
        return categories.first?.name ?? cleaned
    }

    private func calculateDurationInMinutes(from startStr: String, to endStr: String) -> Double {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let start = formatter.date(from: startStr),
              let end = formatter.date(from: endStr) else { return 0 }
        return end.timeIntervalSince(start) / 60
    }
}

// MARK: - Screenshot Transcription

extension ThirdPartyAPIProvider {
    func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?) async throws -> (observations: [Observation], log: LLMCall) {
        guard !screenshots.isEmpty else {
            throw makeError("No screenshots to transcribe")
        }

        let callStart = Date()
        let sorted = screenshots.sorted { $0.capturedAt < $1.capturedAt }

        let targetSamples = 15
        let strideAmount = max(1, sorted.count / targetSamples)
        let sampled = Swift.stride(from: 0, to: sorted.count, by: strideAmount).map { sorted[$0] }

        let firstTs = sampled.first!.capturedAt

        var frameDescriptions: [(timestamp: TimeInterval, description: String)] = []
        for screenshot in sampled {
            guard let frame = loadScreenshotAsFrameData(screenshot, relativeTo: firstTs) else { continue }
            if let desc = await getSimpleFrameDescription(frame, batchId: batchId) {
                frameDescriptions.append((timestamp: frame.timestamp, description: desc))
            }
        }

        guard !frameDescriptions.isEmpty else {
            throw makeError("Failed to describe any screenshots. Check your API key and connection.")
        }

        let lastTs = sampled.last!.capturedAt
        let observations = try await mergeFrameDescriptions(
            frameDescriptions,
            batchStartTime: batchStartTime,
            videoDuration: TimeInterval(lastTs - firstTs),
            batchId: batchId
        )

        let log = LLMCall(
            timestamp: callStart,
            latency: Date().timeIntervalSince(callStart),
            input: "Screenshot transcription: \(screenshots.count) screenshots → \(observations.count) observations",
            output: "Processed \(screenshots.count) screenshots via \(providerKind.displayName)"
        )

        return (observations, log)
    }
}

// MARK: - Activity Card Generation

extension ThirdPartyAPIProvider {
    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall) {
        let callStart = Date()
        var logs: [String] = []

        let sorted = context.batchObservations.sorted { $0.startTs < $1.startTs }
        guard let first = sorted.first, let last = sorted.last else {
            throw makeError("No observations provided")
        }

        let (titleSummary, firstLog) = try await generateTitleAndSummary(observations: sorted, categories: context.categories, batchId: batchId)
        logs.append(firstLog)

        let category = normalizeCategory(titleSummary.category, categories: context.categories)

        let initialCard = ActivityCardData(
            startTime: formatTimestampForPrompt(first.startTs),
            endTime: formatTimestampForPrompt(last.endTs),
            category: category,
            subcategory: "",
            title: titleSummary.title,
            summary: titleSummary.summary,
            detailedSummary: "",
            distractions: nil,
            appSites: titleSummary.appSites
        )

        var allCards = context.existingCards

        if !allCards.isEmpty, let lastCard = allCards.last {
            let lastCardDuration = calculateDurationInMinutes(from: lastCard.startTime, to: lastCard.endTime)

            if lastCardDuration >= 40 {
                allCards.append(initialCard)
            } else {
                let gap = calculateDurationInMinutes(from: lastCard.endTime, to: initialCard.startTime)
                if gap > 5 {
                    allCards.append(initialCard)
                } else {
                    let candidateDuration = calculateDurationInMinutes(from: lastCard.startTime, to: initialCard.endTime)
                    if candidateDuration > 60 {
                        allCards.append(initialCard)
                    } else {
                        let (shouldMerge, mergeLog) = try await checkShouldMerge(previousCard: lastCard, newCard: initialCard, batchId: batchId)
                        logs.append(mergeLog)

                        if shouldMerge {
                            let (merged, mergeCreateLog) = try await mergeTwoCards(previousCard: lastCard, newCard: initialCard, batchId: batchId)
                            let mergedDuration = calculateDurationInMinutes(from: merged.startTime, to: merged.endTime)

                            if mergedDuration > 60 {
                                allCards.append(initialCard)
                            } else {
                                logs.append(mergeCreateLog)
                                allCards[allCards.count - 1] = merged
                            }
                        } else {
                            allCards.append(initialCard)
                        }
                    }
                }
            }
        } else {
            allCards.append(initialCard)
        }

        let log = LLMCall(
            timestamp: callStart,
            latency: Date().timeIntervalSince(callStart),
            input: "Activity card generation via \(providerKind.displayName)",
            output: logs.joined(separator: "\n\n---\n\n")
        )

        return (allCards, log)
    }
}

// MARK: - Text Generation

extension ThirdPartyAPIProvider {
    func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
        let callStart = Date()
        let response = try await callTextAPI(prompt, operation: "generate_text")

        let log = LLMCall(
            timestamp: callStart,
            latency: Date().timeIntervalSince(callStart),
            input: prompt,
            output: response
        )

        return (response.trimmingCharacters(in: .whitespacesAndNewlines), log)
    }
}
