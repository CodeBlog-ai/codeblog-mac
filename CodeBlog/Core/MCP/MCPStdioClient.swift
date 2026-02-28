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
        }
    }
}

actor MCPStdioClient {
    static let shared = MCPStdioClient()

    private struct RuntimeCommand {
        let command: String
        let args: [String]
    }

    private init() {}

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
        let result = try await request(method: "tools/call", params: params, timeout: 45)
        guard let payload = result.objectValue else {
            throw MCPClientError.invalidResponse
        }

        let isError = payload["isError"]?.boolValue ?? false
        let text = extractText(from: payload["content"]?.arrayValue ?? [])
        return MCPToolCallResult(text: text, isError: isError)
    }

    private func request(
        method: String,
        params: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> JSONValue {
        let runtime = resolvedRuntimeCommand()
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = LoginShellRunner.userLoginShell
        process.arguments = ["-l", "-i", "-c", shellCommand(runtime: runtime)]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = processEnvironment()

        do {
            try process.run()
        } catch {
            throw MCPClientError.launchFailed(error.localizedDescription)
        }

        let initMessage: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("codeblog-mac"),
                    "version": .string("1.0.0"),
                ]),
            ]),
        ]

        let initializedMessage: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized"),
            "params": .object([:]),
        ]

        let requestMessage: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(2),
            "method": .string(method),
            "params": .object(params),
        ]

        let writer = stdinPipe.fileHandleForWriting
        try writeLine(initMessage, to: writer)
        try writeLine(initializedMessage, to: writer)
        try writeLine(requestMessage, to: writer)
        try writer.close()

        // Drain stdout/stderr concurrently while the process is running.
        // This prevents child-process deadlocks when output exceeds pipe buffer size.
        let ioGroup = DispatchGroup()
        let ioLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutHandle.readDataToEndOfFile()
            ioLock.lock()
            stdoutData = data
            ioLock.unlock()
            ioGroup.leave()
        }

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrHandle.readDataToEndOfFile()
            ioLock.lock()
            stderrData = data
            ioLock.unlock()
            ioGroup.leave()
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            semaphore.signal()
        }

        let wait = semaphore.wait(timeout: .now() + timeout)
        if wait == .timedOut {
            process.terminate()
            let terminatedInTime = semaphore.wait(timeout: .now() + 2) == .success
            if !terminatedInTime, process.isRunning {
                process.interrupt()
            }
            _ = ioGroup.wait(timeout: .now() + 2)
            throw MCPClientError.requestTimedOut
        }

        let outputCollected = ioGroup.wait(timeout: .now() + 2) == .success
        if !outputCollected {
            throw MCPClientError.requestFailed("Failed to collect MCP process output.")
        }

        ioLock.lock()
        let stdoutPayload = stdoutData
        let stderrPayload = stderrData
        ioLock.unlock()

        let stderrText = String(data: stderrPayload, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            throw MCPClientError.requestFailed(stderrText.isEmpty ? "MCP process exited with \(process.terminationStatus)." : stderrText)
        }

        guard let stdoutText = String(data: stdoutPayload, encoding: .utf8) else {
            throw MCPClientError.decodeFailed("无法读取 stdout")
        }

        for line in stdoutText.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let error = raw["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "unknown error"
                throw MCPClientError.requestFailed(message)
            }

            guard let id = raw["id"] as? NSNumber, id.intValue == 2 else { continue }
            guard let result = raw["result"] else { throw MCPClientError.invalidResponse }
            return try JSONValue(any: result)
        }

        throw MCPClientError.invalidResponse
    }

    private func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let apiKey = CodeBlogTokenResolver.currentToken() {
            env["CODEBLOG_API_KEY"] = apiKey
        }
        return env
    }

    private func resolvedRuntimeCommand() -> RuntimeCommand {
        if let bundled = bundledExecutablePath() {
            return RuntimeCommand(command: bundled, args: [])
        }
        if LoginShellRunner.isInstalled("codeblog-mcp") {
            return RuntimeCommand(command: "codeblog-mcp", args: [])
        }
        if LoginShellRunner.isInstalled("npx") {
            return RuntimeCommand(command: "npx", args: ["-y", "codeblog-mcp"])
        }
        return RuntimeCommand(command: "codeblog-mcp", args: [])
    }

    private func bundledExecutablePath() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }
        let candidates = [
            resourceURL.appendingPathComponent("mcp-runtime/codeblog-mcp").path,
            resourceURL.appendingPathComponent("mcp-runtime/bin/codeblog-mcp").path,
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func shellCommand(runtime: RuntimeCommand) -> String {
        let parts = ([runtime.command] + runtime.args).map { LoginShellRunner.shellEscape($0) }
        return "exec \(parts.joined(separator: " "))"
    }

    private func writeLine(_ payload: [String: JSONValue], to handle: FileHandle) throws {
        let object = payload.mapValues { $0.foundationValue }
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private func extractText(from content: [JSONValue]) -> String {
        var chunks: [String] = []
        for entry in content {
            guard let object = entry.objectValue else { continue }
            guard object["type"]?.stringValue == "text" else { continue }
            if let text = object["text"]?.stringValue {
                chunks.append(text)
            }
        }
        return chunks.joined(separator: "\n")
    }
}
