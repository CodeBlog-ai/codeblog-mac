import Foundation

final class MCPChatRuntime {
    private enum ProviderTransport {
        case openAICompatible(endpoint: URL, headers: [String: String], model: String, providerLabel: String)
        case anthropic(endpoint: URL, apiKey: String, model: String, providerLabel: String)
    }

    private struct OpenAIToolCall {
        let id: String
        let name: String
        let argumentsRaw: String
        let rawObject: [String: Any]
    }

    private struct OpenAIToolCallBuilder {
        var id: String = ""
        var name: String = ""
        var argumentsRaw: String = ""
    }

    private struct AnthropicToolCall {
        let id: String
        let name: String
        let input: [String: JSONValue]
        let inputRaw: String
    }

    private struct AnthropicResponsePayload {
        let text: String
        let toolCalls: [AnthropicToolCall]
        let rawBlocks: [[String: Any]]
    }

    private let mcpClient = MCPStdioClient.shared

    func generateChatStreaming(prompt: String, sessionId: String? = nil) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await run(prompt: prompt, sessionId: sessionId, continuation: continuation)
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func run(
        prompt: String,
        sessionId: String?,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        let session = sessionId ?? "mcp-\(UUID().uuidString)"
        continuation.yield(.sessionStarted(id: session))

        let providerType = LLMProviderType.load()
        guard providerType.canonicalProviderID != "chatgpt_claude" else {
            throw NSError(
                domain: "MCPChatRuntime",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ChatCLI provider should be handled by ChatCLIRunner."]
            )
        }

        var tools: [MCPToolDefinition] = []
        do {
            tools = try await mcpClient.listTools()
        } catch {
            print("[MCPChatRuntime] MCP tools unavailable, continuing without tools: \(error.localizedDescription)")
        }

        let transport = try await resolveTransport(for: providerType)

        switch transport {
        case .openAICompatible(let endpoint, let headers, let model, let providerLabel):
            try await runOpenAICompatibleLoop(
                prompt: prompt,
                endpoint: endpoint,
                headers: headers,
                model: model,
                providerLabel: providerLabel,
                tools: tools,
                continuation: continuation
            )
        case .anthropic(let endpoint, let apiKey, let model, _):
            try await runAnthropicLoop(
                prompt: prompt,
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                tools: tools,
                continuation: continuation
            )
        }
    }

    // MARK: - OpenAI-compatible streaming loop

    private func runOpenAICompatibleLoop(
        prompt: String,
        endpoint: URL,
        headers: [String: String],
        model: String,
        providerLabel: String,
        tools: [MCPToolDefinition],
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var messages: [[String: Any]] = [
            ["role": "user", "content": prompt]
        ]
        var fullText = ""
        var latestPreviewID: String?

        for _ in 0..<10 {
            var turnText = ""
            var builders: [Int: OpenAIToolCallBuilder] = [:]

            try await streamOpenAIRequest(
                endpoint: endpoint,
                headers: headers,
                model: model,
                providerLabel: providerLabel,
                messages: messages,
                tools: tools,
                onTextDelta: { delta in
                    turnText += delta
                    continuation.yield(.textDelta(delta))
                },
                onToolCallDelta: { index, idChunk, nameChunk, argsChunk in
                    var builder = builders[index] ?? OpenAIToolCallBuilder()
                    if let id = idChunk, !id.isEmpty { builder.id = id }
                    if let name = nameChunk, !name.isEmpty {
                        // Name arrives complete (not chunked) — set, don't append
                        if builder.name.isEmpty {
                            builder.name = name
                        }
                    }
                    if let args = argsChunk, !args.isEmpty {
                        builder.argumentsRaw = mergeArgumentsChunk(existing: builder.argumentsRaw, incoming: args)
                    }
                    builders[index] = builder
                }
            )

            fullText += turnText

            let toolCalls = buildToolCalls(from: builders)

            if toolCalls.isEmpty {
                continuation.yield(.complete(text: fullText.trimmingCharacters(in: .whitespacesAndNewlines)))
                continuation.finish()
                return
            }

            let assistantMessage: [String: Any] = [
                "role": "assistant",
                "content": turnText,
                "tool_calls": toolCalls.map { $0.rawObject },
            ]
            messages.append(assistantMessage)

            for call in toolCalls {
                var parsedArguments = parseArguments(call.argumentsRaw)
                if call.name == "confirm_post" {
                    let providedPreviewID = normalizedPreviewID(from: parsedArguments)
                    if providedPreviewID == nil,
                       let previewID = latestPreviewID, !previewID.isEmpty {
                        parsedArguments["preview_id"] = .string(previewID)
                    }
                }
                let effectiveArgsRaw = argumentsJSONString(parsedArguments) ?? call.argumentsRaw

                print("[MCPChatRuntime] Tool call: \(call.name), args: \(effectiveArgsRaw)")
                continuation.yield(.toolStart(callID: call.id, name: call.name, args: effectiveArgsRaw))

                do {
                    let result = try await mcpClient.callTool(name: call.name, arguments: parsedArguments)
                    if call.name == "preview_post",
                       let previewID = extractPreviewID(from: result.text) {
                        latestPreviewID = previewID
                    }
                    continuation.yield(.toolResult(
                        callID: call.id,
                        name: call.name,
                        result: result.text,
                        isError: result.isError,
                        exitCode: result.isError ? 1 : 0
                    ))
                    messages.append([
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": result.text,
                    ])
                } catch {
                    let message = error.localizedDescription
                    continuation.yield(.toolResult(
                        callID: call.id,
                        name: call.name,
                        result: message,
                        isError: true,
                        exitCode: 1
                    ))
                    messages.append([
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": "ERROR: \(message)",
                    ])
                }
            }
        }

        continuation.yield(.complete(text: fullText.trimmingCharacters(in: .whitespacesAndNewlines)))
        continuation.finish()
    }

    /// Streams an OpenAI-compatible chat request via SSE,
    /// calling back on each text delta and tool-call delta chunk.
    private func streamOpenAIRequest(
        endpoint: URL,
        headers: [String: String],
        model: String,
        providerLabel: String,
        messages: [[String: Any]],
        tools: [MCPToolDefinition],
        onTextDelta: (String) -> Void,
        onToolCallDelta: (_ index: Int, _ id: String?, _ name: String?, _ args: String?) -> Void
    ) async throws {
        let toolDefs: [[String: Any]] = tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.inputSchema.mapValues { $0.foundationValue },
                ],
            ]
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.3,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !toolDefs.isEmpty {
            body["tools"] = toolDefs
            body["tool_choice"] = "auto"
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "MCPChatRuntime", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from \(providerLabel)"])
        }

        if !(200...299).contains(http.statusCode) {
            // Read full error body for diagnostics
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let errorText = String(data: errorData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "MCPChatRuntime", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        var receivedSSEData = false
        var rawAccumulator = ""

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            // Detect non-SSE response (HTML or plain error) early
            if !receivedSSEData {
                rawAccumulator += line + "\n"
                let lower = rawAccumulator.lowercased()
                if lower.contains("<!doctype html") || lower.contains("<html") {
                    throw NSError(
                        domain: "MCPChatRuntime",
                        code: -21,
                        userInfo: [NSLocalizedDescriptionKey: "\(providerLabel) AI 服务暂时不可用（上游返回了非 API 响应）。请稍后重试。"]
                    )
                }
                // Check for JSON error response (e.g. {"error": ...})
                if line.hasPrefix("{"), let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = json["error"] as? [String: Any] ?? (json["error"] as? String).map({ ["message": $0] }) {
                    let msg = errorObj["message"] as? String ?? "Unknown error"
                    throw NSError(
                        domain: "MCPChatRuntime",
                        code: -22,
                        userInfo: [NSLocalizedDescriptionKey: "\(providerLabel) 返回错误：\(msg)"]
                    )
                }
            }

            guard line.hasPrefix("data:") else { continue }
            receivedSSEData = true
            var payload = String(line.dropFirst(5))
            if payload.first == " " {
                payload.removeFirst()
            }
            if payload == "[DONE]" { break }

            guard let payloadData = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]] else {
                continue
            }

            for choice in choices {
                // Streaming delta format
                if let delta = choice["delta"] as? [String: Any] {
                    if let content = delta["content"] as? String, !content.isEmpty {
                        onTextDelta(content)
                    }
                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for (offset, call) in toolCalls.enumerated() {
                            let index = (call["index"] as? Int) ?? offset
                            let id = call["id"] as? String
                            var name: String?
                            var args: String?
                            if let function = call["function"] as? [String: Any] {
                                name = function["name"] as? String
                                args = function["arguments"] as? String
                            }
                            onToolCallDelta(index, id, name, args)
                        }
                    }
                } else if let message = choice["message"] as? [String: Any] {
                    // Some providers return complete message in stream.
                    // Prefer delta when present to avoid duplicate argument accumulation.
                    if let content = message["content"] as? String, !content.isEmpty {
                        onTextDelta(content)
                    }
                    if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                        for (index, call) in toolCalls.enumerated() {
                            let id = call["id"] as? String
                            var name: String?
                            var args: String?
                            if let function = call["function"] as? [String: Any] {
                                name = function["name"] as? String
                                args = function["arguments"] as? String
                            }
                            onToolCallDelta(index, id, name, args)
                        }
                    }
                }
            }
        }

        if !receivedSSEData {
            let snippet = String(rawAccumulator.prefix(300))
            throw NSError(
                domain: "MCPChatRuntime",
                code: -23,
                userInfo: [NSLocalizedDescriptionKey: "\(providerLabel) 未返回有效响应。请检查网络连接或稍后重试。(\(snippet))"]
            )
        }
    }

    private func buildToolCalls(from builders: [Int: OpenAIToolCallBuilder]) -> [OpenAIToolCall] {
        builders.keys.sorted().compactMap { index in
            guard let builder = builders[index], !builder.name.isEmpty else { return nil }
            let callID = builder.id.isEmpty ? UUID().uuidString : builder.id

            // Always re-extract from the full accumulated argumentsRaw.
            // lastValidArgumentsRaw may hold a stale "{}" from FluxDart artifacts
            // before the real arguments arrived in subsequent chunks.
            let argumentsRaw = sanitizeArguments(builder.argumentsRaw)

            let rawObject: [String: Any] = [
                "id": callID,
                "type": "function",
                "function": [
                    "name": builder.name,
                    "arguments": argumentsRaw,
                ],
            ]
            return OpenAIToolCall(id: callID, name: builder.name, argumentsRaw: argumentsRaw, rawObject: rawObject)
        }
    }

    // MARK: - Anthropic loop (non-streaming)

    private func runAnthropicLoop(
        prompt: String,
        endpoint: URL,
        apiKey: String,
        model: String,
        tools: [MCPToolDefinition],
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var messages: [[String: Any]] = [
            [
                "role": "user",
                "content": [["type": "text", "text": prompt]],
            ]
        ]
        var fullText = ""

        for _ in 0..<10 {
            let response = try await callAnthropic(
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                messages: messages,
                tools: tools
            )

            if !response.text.isEmpty {
                fullText += response.text
                continuation.yield(.textDelta(response.text))
            }

            messages.append([
                "role": "assistant",
                "content": response.rawBlocks,
            ])

            if response.toolCalls.isEmpty {
                continuation.yield(.complete(text: fullText.trimmingCharacters(in: .whitespacesAndNewlines)))
                continuation.finish()
                return
            }

            var toolResults: [[String: Any]] = []
            for call in response.toolCalls {
                continuation.yield(.toolStart(callID: call.id, name: call.name, args: call.inputRaw))
                do {
                    let result = try await mcpClient.callTool(name: call.name, arguments: call.input)
                    continuation.yield(.toolResult(
                        callID: call.id,
                        name: call.name,
                        result: result.text,
                        isError: result.isError,
                        exitCode: result.isError ? 1 : 0
                    ))
                    toolResults.append([
                        "type": "tool_result",
                        "tool_use_id": call.id,
                        "content": result.text,
                        "is_error": result.isError,
                    ])
                } catch {
                    let message = error.localizedDescription
                    continuation.yield(.toolResult(
                        callID: call.id,
                        name: call.name,
                        result: message,
                        isError: true,
                        exitCode: 1
                    ))
                    toolResults.append([
                        "type": "tool_result",
                        "tool_use_id": call.id,
                        "content": "ERROR: \(message)",
                        "is_error": true,
                    ])
                }
            }

            messages.append([
                "role": "user",
                "content": toolResults,
            ])
        }

        continuation.yield(.complete(text: fullText.trimmingCharacters(in: .whitespacesAndNewlines)))
        continuation.finish()
    }

    private func callAnthropic(
        endpoint: URL,
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        tools: [MCPToolDefinition]
    ) async throws -> AnthropicResponsePayload {
        let toolDefs: [[String: Any]] = tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema.mapValues { $0.foundationValue },
            ]
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": messages,
            "temperature": 0.3,
        ]
        if !toolDefs.isEmpty {
            body["tools"] = toolDefs
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "MCPChatRuntime", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Anthropic response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "MCPChatRuntime", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["content"] as? [[String: Any]] else {
            throw NSError(domain: "MCPChatRuntime", code: -2, userInfo: [NSLocalizedDescriptionKey: "Anthropic payload decode failed"])
        }

        var textChunks: [String] = []
        var toolCalls: [AnthropicToolCall] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            if type == "text", let text = block["text"] as? String {
                textChunks.append(text)
            } else if type == "tool_use",
                      let id = block["id"] as? String,
                      let name = block["name"] as? String {
                let inputAny = block["input"] as? [String: Any] ?? [:]
                var mappedInput: [String: JSONValue] = [:]
                for (key, value) in inputAny {
                    mappedInput[key] = (try? JSONValue(any: value)) ?? .null
                }
                let inputData = try? JSONSerialization.data(withJSONObject: inputAny, options: [.prettyPrinted])
                let inputRaw = inputData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append(AnthropicToolCall(id: id, name: name, input: mappedInput, inputRaw: inputRaw))
            }
        }

        return AnthropicResponsePayload(
            text: textChunks.joined(separator: "\n"),
            toolCalls: toolCalls,
            rawBlocks: blocks
        )
    }

    // MARK: - Transport resolution

    private func resolveTransport(for providerType: LLMProviderType) async throws -> ProviderTransport {
        switch providerType {
        case .codeblogBackend:
            guard let token = CodeBlogTokenResolver.currentToken() else {
                throw NSError(domain: "MCPChatRuntime", code: -11, userInfo: [NSLocalizedDescriptionKey: "CodeBlog token not found."])
            }
            return try codeBlogCreditTransport(token: token)

        case .geminiDirect:
            guard let apiKey = KeychainManager.shared.retrieve(for: "gemini"),
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "MCPChatRuntime", code: -13, userInfo: [NSLocalizedDescriptionKey: "Gemini API key not found."])
            }
            guard let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions") else {
                throw NSError(domain: "MCPChatRuntime", code: -14, userInfo: [NSLocalizedDescriptionKey: "Gemini endpoint invalid."])
            }
            let model = GeminiModelPreference.load().primary.rawValue
            return .openAICompatible(
                endpoint: endpoint,
                headers: ["Authorization": "Bearer \(apiKey)"],
                model: model,
                providerLabel: "Gemini"
            )

        case .ollamaLocal(let endpointValue):
            guard let endpoint = LocalEndpointUtilities.chatCompletionsURL(baseURL: endpointValue) else {
                throw NSError(domain: "MCPChatRuntime", code: -15, userInfo: [NSLocalizedDescriptionKey: "Ollama endpoint invalid."])
            }
            let model = UserDefaults.standard.string(forKey: "llmLocalModelId")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let apiKey = UserDefaults.standard.string(forKey: "llmLocalAPIKey")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var headers: [String: String] = [:]
            if let apiKey, !apiKey.isEmpty {
                headers["Authorization"] = "Bearer \(apiKey)"
            }
            return .openAICompatible(
                endpoint: endpoint,
                headers: headers,
                model: (model?.isEmpty == false ? model! : "qwen2.5-coder:7b"),
                providerLabel: "Ollama"
            )

        case .thirdPartyAPI(let provider, let endpointValue, let model):
            let keychainKey = ThirdPartyProviderDefaults.keychainKey(for: provider)
            guard let apiKey = KeychainManager.shared.retrieve(for: keychainKey),
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "MCPChatRuntime", code: -16, userInfo: [NSLocalizedDescriptionKey: "Third-party API key not found."])
            }

            if provider.usesAnthropicFormat {
                guard let endpoint = LocalEndpointUtilities.anthropicMessagesURL(baseURL: endpointValue) else {
                    throw NSError(domain: "MCPChatRuntime", code: -17, userInfo: [NSLocalizedDescriptionKey: "Anthropic endpoint invalid."])
                }
                return .anthropic(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    model: model ?? provider.defaultModel,
                    providerLabel: provider.displayName
                )
            }

            guard let endpoint = LocalEndpointUtilities.chatCompletionsURL(baseURL: endpointValue) else {
                throw NSError(domain: "MCPChatRuntime", code: -18, userInfo: [NSLocalizedDescriptionKey: "OpenAI-compatible endpoint invalid."])
            }
            return .openAICompatible(
                endpoint: endpoint,
                headers: ["Authorization": "Bearer \(apiKey)"],
                model: model ?? provider.defaultModel,
                providerLabel: provider.displayName
            )

        case .chatGPTClaude:
            throw NSError(domain: "MCPChatRuntime", code: -19, userInfo: [NSLocalizedDescriptionKey: "ChatCLI route is handled outside MCP runtime."])
        }
    }

    private func codeBlogCreditTransport(token: String) throws -> ProviderTransport {
        guard let endpoint = URL(string: "https://codeblog.ai/api/v1/ai-credit/chat") else {
            throw NSError(domain: "MCPChatRuntime", code: -12, userInfo: [NSLocalizedDescriptionKey: "CodeBlog endpoint invalid."])
        }
        return .openAICompatible(
            endpoint: endpoint,
            headers: ["Authorization": "Bearer \(token)"],
            model: "claude-sonnet-4-6",
            providerLabel: "CodeBlog AI"
        )
    }

    // MARK: - Helpers

    private func parseArguments(_ raw: String) -> [String: JSONValue] {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return [:]
        }

        var mapped: [String: JSONValue] = [:]
        for (key, value) in object {
            mapped[key] = (try? JSONValue(any: value)) ?? .null
        }
        return mapped
    }

    /// Some API proxies (e.g. FluxDart) emit duplicate/partial argument chunks
    /// that produce concatenated JSON like `{}{"limit": 1}`.
    /// Extract the last valid JSON object from the accumulated string.
    private func sanitizeArguments(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }

        // Fast path: already valid JSON
        if isValidJSONObject(trimmed) {
            return trimmed
        }

        if let recovered = extractLastValidJSONObject(from: trimmed) {
            return recovered
        }

        return trimmed
    }

    private func mergeArgumentsChunk(existing: String, incoming: String) -> String {
        let incomingTrimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if incomingTrimmed.isEmpty { return existing }

        // If incoming is a complete valid JSON object with actual keys,
        // treat it as a full replacement (cumulative snapshot from some providers).
        // Skip bare "{}" — FluxDart sends it as an artifact before the real args.
        if incomingTrimmed != "{}" && isValidJSONObject(incomingTrimmed) {
            return incomingTrimmed
        }

        if existing.isEmpty { return incoming }
        if incoming.hasPrefix(existing) { return incoming } // cumulative snapshots
        if existing == incoming { return existing } // exact duplicate chunk
        if existing.hasSuffix(incoming) { return existing } // repeated tail chunk
        return existing + incoming
    }

    private func isValidJSONObject(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] else {
            return false
        }
        return true
    }

    private func extractLastValidJSONObject(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isValidJSONObject(trimmed) {
            return trimmed
        }

        var inString = false
        var isEscaped = false
        var depth = 0
        var startIndex: String.Index?
        var lastValid: String?
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "\"" {
                inString = true
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "{" {
                if depth == 0 {
                    startIndex = cursor
                }
                depth += 1
            } else if char == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start = startIndex {
                    let end = trimmed.index(after: cursor)
                    let candidate = String(trimmed[start..<end])
                    if isValidJSONObject(candidate) {
                        lastValid = candidate
                    }
                    startIndex = nil
                }
            }

            cursor = trimmed.index(after: cursor)
        }

        return lastValid
    }

    private func normalizedPreviewID(from arguments: [String: JSONValue]) -> String? {
        guard let rawValue = arguments["preview_id"]?.stringValue else { return nil }
        let previewValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previewValue.isEmpty else { return nil }

        let lowered = previewValue.lowercased()
        if lowered.contains("preview_id_from_previous_preview") || lowered.contains("the_preview_id") {
            return nil
        }
        guard previewValue.hasPrefix("pv_") else { return nil }
        return previewValue
    }

    private func argumentsJSONString(_ arguments: [String: JSONValue]) -> String? {
        let object = arguments.mapValues { $0.foundationValue }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func extractPreviewID(from text: String) -> String? {
        guard !text.isEmpty else { return nil }

        if let regex = try? NSRegularExpression(pattern: #"\[preview_id:\s*([^\]]+)\]"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let idRange = Range(match.range(at: 1), in: text) {
                let previewID = String(text[idRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !previewID.isEmpty { return previewID }
            }
        }

        if let regex = try? NSRegularExpression(pattern: #""preview_id"\s*:\s*"([^"]+)""#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let idRange = Range(match.range(at: 1), in: text) {
                let previewID = String(text[idRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !previewID.isEmpty { return previewID }
            }
        }

        return nil
    }
}
