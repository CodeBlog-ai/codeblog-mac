import Foundation

struct MCPToolDefinition: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: [String: JSONValue]
}

struct MCPToolCallResult: Sendable, Equatable {
    let text: String
    let isError: Bool
}

enum MCPClientError: LocalizedError {
    case launchFailed(String)
    case requestTimedOut
    case invalidResponse
    case requestFailed(String)
    case decodeFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "无法启动 MCP 服务：\(message)"
        case .requestTimedOut:
            return "MCP 请求超时。"
        case .invalidResponse:
            return "MCP 返回格式无效。"
        case .requestFailed(let message):
            return "MCP 请求失败：\(message)"
        case .decodeFailed(let message):
            return "MCP 解码失败：\(message)"
        case .notConnected:
            return "MCP 服务未连接。"
        }
    }
}

/// Persistent MCP client that maintains a long-running connection to the MCP server.
/// This is necessary because preview_post stores previews in server memory,
/// and confirm_post needs to access them from the same process.
actor MCPStdioClient {
    static let shared = MCPStdioClient()

    // Persistent process state
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var pendingRequests: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextRequestId: Int = 1
    private var isInitialized = false
    private var readTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    func listTools() async throws -> [MCPToolDefinition] {
        let result = try await request(method: "tools/list", params: [:], timeout: 20)
        guard let payload = result.objectValue,
              let tools = payload["tools"]?.arrayValue else {
            throw MCPClientError.invalidResponse
        }

        return try tools.map { tool in
            guard let object = tool.objectValue else {
                throw MCPClientError.invalidResponse
            }

            let name = object["name"]?.stringValue ?? ""
            let description = object["description"]?.stringValue ?? name
            let schema = object["inputSchema"]?.objectValue ?? [:]
            return MCPToolDefinition(name: name, description: description, inputSchema: schema)
        }
    }

    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolCallResult {
        let params: [String: JSONValue] = [
            "name": .string(name),
            "arguments": .object(arguments),
        ]
        print("[MCPStdioClient] Calling tool: \(name) with arguments: \(arguments)")
        let result = try await request(method: "tools/call", params: params, timeout: 45)
        guard let payload = result.objectValue else {
            print("[MCPStdioClient] Invalid response for tool: \(name)")
            throw MCPClientError.invalidResponse
        }

        let isError = payload["isError"]?.boolValue ?? false
        let text = extractText(from: payload["content"]?.arrayValue ?? [])
        print("[MCPStdioClient] Tool \(name) completed: isError=\(isError), textLength=\(text.count)")
        if isError {
            print("[MCPStdioClient] Tool \(name) ERROR response: \(text)")
        }
        return MCPToolCallResult(text: text, isError: isError)
    }

    /// Disconnect and clean up the persistent MCP process
    func disconnect() {
        readTask?.cancel()
        readTask = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        isInitialized = false
        
        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPClientError.notConnected)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Private Implementation

    private func ensureConnected() async throws {
        if process != nil && isInitialized {
            // Check if process is still running
            if process?.isRunning == true {
                return
            }
            // Process died, clean up and reconnect
            disconnect()
        }

        try await connect()
    }

    private func connect() async throws {
        let runtime = resolvedRuntimeCommand()
        
        let newProcess = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        newProcess.executableURL = LoginShellRunner.userLoginShell
        newProcess.arguments = ["-l", "-i", "-c", shellCommand(runtime: runtime)]
        newProcess.standardInput = stdin
        newProcess.standardOutput = stdout
        newProcess.standardError = stderr
        newProcess.environment = processEnvironment()

        do {
            try newProcess.run()
        } catch {
            throw MCPClientError.launchFailed(error.localizedDescription)
        }

        self.process = newProcess
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.nextRequestId = 1
        self.pendingRequests.removeAll()

        // Start reading responses in background
        startReadingResponses()

        // Send initialize request
        let initResult = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("codeblog-mac"),
                    "version": .string("1.0.0"),
                ]),
            ],
            timeout: 10
        )

        guard initResult.objectValue?["protocolVersion"] != nil else {
            disconnect()
            throw MCPClientError.invalidResponse
        }

        // Send initialized notification (no response expected)
        try sendNotification(method: "notifications/initialized", params: [:])

        isInitialized = true
        print("[MCPStdioClient] Connected to MCP server")
    }

    private func request(
        method: String,
        params: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> JSONValue {
        try await ensureConnected()
        return try await sendRequest(method: method, params: params, timeout: timeout)
    }

    private func sendRequest(
        method: String,
        params: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> JSONValue {
        guard let writer = stdinPipe?.fileHandleForWriting else {
            throw MCPClientError.notConnected
        }

        let requestId = nextRequestId
        nextRequestId += 1

        let message: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(requestId)),
            "method": .string(method),
            "params": .object(params),
        ]

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation

            do {
                try writeLine(message, to: writer)
            } catch {
                pendingRequests.removeValue(forKey: requestId)
                continuation.resume(throwing: error)
                return
            }

            // Set up timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = pendingRequests.removeValue(forKey: requestId) {
                    cont.resume(throwing: MCPClientError.requestTimedOut)
                }
            }
        }
    }

    private func sendNotification(method: String, params: [String: JSONValue]) throws {
        guard let writer = stdinPipe?.fileHandleForWriting else {
            throw MCPClientError.notConnected
        }

        let message: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object(params),
        ]

        try writeLine(message, to: writer)
    }

    private func startReadingResponses() {
        guard let stdout = stdoutPipe?.fileHandleForReading else { return }

        readTask = Task { [weak self] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var buffer = Data()

                stdout.readabilityHandler = { [weak self] handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        // EOF — process exited
                        handle.readabilityHandler = nil
                        Task {
                            await self?.handleProcessEnded()
                            continuation.resume()
                        }
                        return
                    }
                    buffer.append(chunk)

                    // Process all complete newline-delimited lines
                    while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = buffer[..<newlineIndex]
                        buffer = Data(buffer[(newlineIndex + 1)...])

                        if let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !line.isEmpty {
                            Task {
                                await self?.handleResponse(line)
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleResponse(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Check if this is a response (has id) or notification (no id)
        guard let idValue = json["id"] else {
            // This is a notification, ignore for now
            return
        }

        let requestId: Int
        if let idNumber = idValue as? NSNumber {
            requestId = idNumber.intValue
        } else if let idInt = idValue as? Int {
            requestId = idInt
        } else {
            return
        }

        guard let continuation = pendingRequests.removeValue(forKey: requestId) else {
            return
        }

        // Check for error
        if let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "unknown error"
            continuation.resume(throwing: MCPClientError.requestFailed(message))
            return
        }

        // Return result
        if let result = json["result"] {
            do {
                let value = try JSONValue(any: result)
                continuation.resume(returning: value)
            } catch {
                continuation.resume(throwing: MCPClientError.decodeFailed(error.localizedDescription))
            }
        } else {
            continuation.resume(throwing: MCPClientError.invalidResponse)
        }
    }

    private func handleProcessEnded() {
        print("[MCPStdioClient] MCP process ended")
        isInitialized = false
        process = nil
        
        // Fail all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPClientError.notConnected)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Helpers

    private func writeLine(_ message: [String: JSONValue], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: message.toAny(), options: [])
        var line = data
        line.append(contentsOf: [UInt8(ascii: "\n")])
        try handle.write(contentsOf: line)
    }

    private func extractText(from content: [JSONValue]) -> String {
        content.compactMap { item -> String? in
            guard let obj = item.objectValue,
                  obj["type"]?.stringValue == "text",
                  let text = obj["text"]?.stringValue else {
                return nil
            }
            return text
        }.joined(separator: "\n")
    }

    private nonisolated func resolvedRuntimeCommand() -> RuntimeCommand {
        RuntimeCommand(from: MCPSetupService.resolveRuntimeCommand())
    }

    private nonisolated func shellCommand(runtime: RuntimeCommand) -> String {
        let parts = ([runtime.command] + runtime.args).map { LoginShellRunner.shellEscape($0) }
        return "exec " + parts.joined(separator: " ")
    }

    private nonisolated func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let token = CodeBlogTokenResolver.currentToken() {
            env["CODEBLOG_API_KEY"] = token
        }
        return env
    }
}

// MARK: - Extensions

private extension MCPStdioClient {
    struct RuntimeCommand {
        let command: String
        let args: [String]
        
        init(from mcpCommand: MCPSetupService.MCPRuntimeCommand) {
            self.command = mcpCommand.command
            self.args = mcpCommand.args
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func toAny() -> [String: Any] {
        mapValues { $0.toAny() }
    }
}

private extension JSONValue {
    func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { $0.toAny() }
        case .object(let obj): return obj.mapValues { $0.toAny() }
        }
    }
}
