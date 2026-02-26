//
//  ChatService.swift
//  CodeBlog
//
//  Orchestrates chat conversations with the LLM, handling tool calls
//  and maintaining conversation state.
//

import Foundation
import Combine

private let chatServiceLongDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    return formatter
}()

private let chatServiceTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
}()

/// A debug log entry for the chat debug panel
struct ChatDebugEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: EntryType
    let content: String

    enum EntryType: String {
        case user = "📝 USER"
        case prompt = "📤 PROMPT"
        case response = "📥 RESPONSE"
        case toolDetected = "🔧 TOOL DETECTED"
        case toolResult = "📊 TOOL RESULT"
        case error = "❌ ERROR"
        case info = "ℹ️ INFO"
    }

    var typeColor: String {
        switch type {
        case .user: return "F96E00"
        case .prompt: return "4A90D9"
        case .response: return "7B68EE"
        case .toolDetected: return "F96E00"
        case .toolResult: return "34C759"
        case .error: return "FF3B30"
        case .info: return "8E8E93"
        }
    }
}

/// Status data for the in-progress chat panel
struct ChatWorkStatus: Sendable, Equatable {
    let id: UUID
    var stage: Stage
    var thinkingText: String
    var tools: [ToolRun]
    var errorMessage: String?
    var lastUpdated: Date

    enum Stage: Sendable, Equatable {
        case thinking
        case runningTools
        case answering
        case error
    }

    enum ToolState: Sendable, Equatable {
        case running
        case completed
        case failed
    }

    struct ToolRun: Identifiable, Sendable, Equatable {
        let id: UUID
        let command: String
        var state: ToolState
        var summary: String
        var output: String
        var exitCode: Int?
    }

    var hasDetails: Bool {
        let trimmedThinking = thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedThinking.isEmpty { return true }
        return tools.contains { !$0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var hasErrors: Bool {
        if stage == .error { return true }
        if tools.contains(where: { $0.state == .failed }) { return true }
        if let message = errorMessage, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }
}

/// Orchestrates chat conversations with tool-calling support
@MainActor
final class ChatService: ObservableObject {

    // MARK: - Singleton

    static let shared = ChatService()

    // MARK: - Published State

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var streamingText = ""
    @Published private(set) var error: String?
    @Published private(set) var debugLog: [ChatDebugEntry] = []
    @Published private(set) var workStatus: ChatWorkStatus?
    @Published private(set) var currentSuggestions: [String] = []
    @Published var showDebugPanel = false

    // MARK: - Private

    private var conversationHistory: [(role: String, content: String)] = []
    private var currentSessionId: String?
    private var currentProcessingTask: Task<Void, Never>?

    // MARK: - Debug Logging

    private func log(_ type: ChatDebugEntry.EntryType, _ content: String) {
        let entry = ChatDebugEntry(timestamp: Date(), type: type, content: content)
        debugLog.append(entry)
        // Also print to console for Xcode debugging
        print("[\(type.rawValue)] \(content.prefix(200))...")
    }

    func clearDebugLog() {
        debugLog = []
    }

    // MARK: - Public API

    /// Send a user message and get a response
    func sendMessage(_ content: String) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isProcessing else { return }

        isProcessing = true
        error = nil
        streamingText = ""
        workStatus = nil
        currentSuggestions = []

        // Add user message
        let userMessage = ChatMessage.user(content)
        messages.append(userMessage)
        conversationHistory.append((role: "user", content: content))
        log(.user, content)

        // Process with potential tool calls (store task for cancellation)
        let task = Task { @MainActor in
            await processConversation()
        }
        currentProcessingTask = task
        await task.value
        currentProcessingTask = nil

        isProcessing = false
    }

    /// Cancel the current processing task
    func cancelProcessing() {
        guard isProcessing else { return }
        currentProcessingTask?.cancel()
        currentProcessingTask = nil
        isProcessing = false
        streamingText = ""
        workStatus = nil
        log(.info, "Processing cancelled by user")
    }

    /// Send a message programmatically without requiring user input.
    /// Used by onboarding to trigger the first agent workflow.
    func sendAutoMessage(_ content: String) {
        guard messages.isEmpty, !isProcessing else { return }
        Task {
            await sendMessage(content)
        }
    }

    /// Clear the conversation
    func clearConversation() {
        messages = []
        conversationHistory = []
        streamingText = ""
        error = nil
        workStatus = nil
        currentSuggestions = []
        currentSessionId = nil
    }

    // MARK: - Conversation Processing

    private func processConversation() async {
        // Build prompt - full prompt for new session, just user message for resume
        let prompt: String
        let isResume = currentSessionId != nil

        if isResume {
            // For resumed sessions, just send the latest user message
            prompt = conversationHistory.last?.content ?? ""
            log(.prompt, "[Resuming session \(currentSessionId!)] \(prompt)")
        } else {
            // For new sessions, send full prompt with system context
            prompt = buildFullPrompt()
            log(.prompt, prompt)
        }

        // Track state during streaming
        var responseText = ""
        var currentToolId: UUID?
        var currentToolMessageId: UUID?
        var pendingToolSeparator = false
        var sawTextDelta = false
        streamingText = ""
        startWorkStatus()

        // Add response message only when text arrives
        var responseMessageId: UUID?

        func appendWithToolSeparatorIfNeeded(_ chunk: String) {
            if pendingToolSeparator {
                if let last = responseText.last, !last.isWhitespace,
                   let first = chunk.first, !first.isWhitespace {
                    responseText += " "
                }
                pendingToolSeparator = false
            }
            responseText += chunk
        }

        do {
            // Use rich streaming with thinking and tool events
            let stream = LLMService.shared.generateChatStreaming(prompt: prompt, sessionId: currentSessionId)

            for try await event in stream {
                switch event {
                case .sessionStarted(let id):
                    // Capture session ID for future messages
                    if currentSessionId == nil {
                        currentSessionId = id
                        log(.info, "📍 Session started: \(id)")
                    }

                case .thinking(let text):
                    log(.info, "💭 Thinking: \(text)")
                    updateWorkStatus { status in
                        status.stage = .thinking
                        status.thinkingText += text
                    }

                case .toolStart(let command):
                    log(.toolDetected, "Starting: \(command)")
                    let toolId = UUID()
                    currentToolId = toolId
                    // Insert a visible tool call message in the chat
                    let toolMsg = ChatMessage.toolCall(
                        toolDisplayName(from: command),
                        description: toolDisplayDescription(from: command)
                    )
                    currentToolMessageId = toolMsg.id
                    messages.append(toolMsg)
                    updateWorkStatus { status in
                        status.stage = .runningTools
                        status.tools.append(ChatWorkStatus.ToolRun(
                            id: toolId,
                            command: command,
                            state: .running,
                            summary: toolSummary(command: command, output: "", exitCode: nil),
                            output: "",
                            exitCode: nil
                        ))
                    }

                case .toolEnd(let output, let exitCode):
                    log(.toolResult, "Exit \(exitCode ?? 0): \(output.prefix(100))...")
                    let toolId = currentToolId
                    // Update the tool call message with result
                    if let msgId = currentToolMessageId,
                       let idx = messages.firstIndex(where: { $0.id == msgId }) {
                        let summary = toolResultSummary(output: output, exitCode: exitCode)
                        if let exitCode, exitCode != 0 {
                            messages[idx] = messages[idx].failed(error: summary)
                        } else {
                            messages[idx] = messages[idx].completed(summary: summary)
                        }
                    }
                    currentToolMessageId = nil
                    updateWorkStatus { status in
                        let toolIndex = toolCompletionIndex(in: status, preferredId: toolId)
                        guard let toolIndex else { return }
                        let summary = toolSummary(
                            command: status.tools[toolIndex].command,
                            output: output,
                            exitCode: exitCode
                        )
                        status.tools[toolIndex].summary = summary
                        status.tools[toolIndex].output = output
                        status.tools[toolIndex].exitCode = exitCode
                        if let exitCode, exitCode != 0 {
                            status.tools[toolIndex].state = .failed
                            status.stage = .error
                            status.errorMessage = summary
                        } else {
                            status.tools[toolIndex].state = .completed
                        }
                    }
                    currentToolId = nil
                    pendingToolSeparator = true

                case .textDelta(let chunk):
                    sawTextDelta = true
                    appendWithToolSeparatorIfNeeded(chunk)
                    streamingText = responseText
                    updateWorkStatus { status in
                        if status.stage != .error {
                            status.stage = .answering
                        }
                    }

                    // Update response message in place
                    if let id = responseMessageId,
                       let index = messages.firstIndex(where: { $0.id == id }) {
                        messages[index] = ChatMessage(
                            id: id,
                            role: .assistant,
                            content: responseText
                        )
                    } else if responseMessageId == nil {
                        let id = UUID()
                        responseMessageId = id
                        messages.append(ChatMessage(
                            id: id,
                            role: .assistant,
                            content: responseText
                        ))
                    }

                case .complete(let text):
                    if responseText.isEmpty {
                        responseText = text
                        pendingToolSeparator = false
                    } else if pendingToolSeparator {
                        appendWithToolSeparatorIfNeeded(text)
                    } else if !sawTextDelta {
                        responseText = text
                    }
                    streamingText = responseText
                    log(.response, responseText)
                    if let id = responseMessageId,
                       let index = messages.firstIndex(where: { $0.id == id }) {
                        messages[index] = ChatMessage(
                            id: id,
                            role: .assistant,
                            content: responseText
                        )
                    } else if responseMessageId == nil,
                              !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let id = UUID()
                        responseMessageId = id
                        messages.append(ChatMessage(
                            id: id,
                            role: .assistant,
                            content: responseText
                        ))
                    }

                case .error(let errorMessage):
                    log(.error, errorMessage)
                    self.error = errorMessage
                    updateWorkStatus { status in
                        status.stage = .error
                        status.errorMessage = errorMessage
                    }
                }
            }
        } catch {
            // Show error
            log(.error, "LLM error: \(error.localizedDescription)")
            self.error = error.localizedDescription
            if workStatus == nil {
                startWorkStatus()
            }
            updateWorkStatus { status in
                status.stage = .error
                status.errorMessage = error.localizedDescription
            }

            // Update response message with error
            if let id = responseMessageId,
               let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index] = ChatMessage.assistant("I encountered an error: \(error.localizedDescription)")
            } else {
                messages.append(ChatMessage.assistant("I encountered an error: \(error.localizedDescription)"))
            }
            streamingText = ""
            return
        }

        streamingText = ""

        if let status = workStatus, !status.hasErrors {
            workStatus = nil
        }

        // Parse suggestions from response
        let (cleanedText, suggestions) = parseSuggestions(from: responseText)
        currentSuggestions = suggestions

        // Update final response (with suggestions block removed)
        if let id = responseMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            // Remove response message if empty (error case or no response)
            if cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.remove(at: index)
            } else {
                messages[index] = ChatMessage(
                    id: id,
                    role: .assistant,
                    content: cleanedText
                )
            }
        }

        // Add to conversation history (keep original with suggestions for context)
        if !responseText.isEmpty {
            conversationHistory.append((role: "assistant", content: responseText))
        }
    }

    // MARK: - Prompt Building

    private func buildFullPrompt() -> String {
        let systemPrompt = buildSystemPrompt()

        var prompt = systemPrompt + "\n\n"

        // Add conversation history
        for entry in conversationHistory {
            switch entry.role {
            case "user":
                prompt += "User: \(entry.content)\n\n"
            case "assistant":
                prompt += "Assistant: \(entry.content)\n\n"
            case "system":
                prompt += "[System: \(entry.content)]\n\n"
            default:
                break
            }
        }

        prompt += "Assistant:"
        return prompt
    }

    private func buildSystemPrompt() -> String {
        let now = Date()
        let currentDate = chatServiceLongDateFormatter.string(from: now)
        let currentTime = chatServiceTimeFormatter.string(from: now)

        let agentName = CodeBlogAuthService.shared.token?.agentName ?? "CodeBlog Agent"
        let username = CodeBlogAuthService.shared.token?.username ?? "developer"

        return """
        You are \(agentName) — an AI agent on CodeBlog (codeblog.ai), a developer forum and blogging platform.
        Your owner is @\(username).

        Current date: \(currentDate)
        Current time: \(currentTime)

        \(agentCharacterSection())

        ## WHAT YOU CAN DO

        You help your owner with everything on CodeBlog:
        - Scan and analyze their local IDE coding sessions (Claude Code, Cursor, Codex, VS Code, Windsurf, Zed, etc.)
        - Write and publish blog posts from coding sessions
        - Browse, search, read, comment, and vote on forum posts
        - Manage bookmarks, notifications, tags, and trending topics
        - Generate weekly digests and daily coding reports
        - Manage agents, view dashboard

        You have 20+ tools. Use them whenever the user's request matches. Chain multiple tools if needed.
        After a tool returns results, summarize them naturally for the user.

        ## TOOL USAGE (CRITICAL)

        When using tools, ALWAYS use the EXACT data returned by previous tool calls.
        - If scan_sessions returns a path like "/Users/someone/...", use that EXACT path
        - NEVER modify, guess, or infer file paths — use them exactly as returned
        - If a tool call fails with "file not found", the path is wrong — check the scan results again
        - Never mention MCP, tool configuration, API keys, or setup details to the user. Just use the tools naturally.
        - If a tool call fails, try again or suggest an alternative action — do NOT tell the user to install or configure anything.

        \(mcpToolsSection())

        ## POSTING RULES

        When publishing any post (manual, auto, or digest), ALWAYS follow this flow:

        Step 1 — Generate preview:
          Call the appropriate tool to generate a preview. The tool returns the full post content.

        Step 2 — Show the COMPLETE preview to the user:
          You MUST display the ENTIRE preview exactly as returned by the tool. Do NOT summarize, shorten, or omit any part.
          Format it clearly:

          ---
          **Title:** [title]
          **Summary:** [summary]
          **Category:** [category] · **Tags:** [tags]

          ---

          [FULL article content — every paragraph, every code block, every section.]

          ---

          Show the actual content. Never say "includes..." or give a summary of sections.

        Step 3 — Ask for confirmation:
          After showing the full preview, ask the user if they want to publish, edit, or discard.

        Step 4 — Handle edits:
          If the user wants changes, apply them, regenerate the preview, show the complete updated preview again, and ask for confirmation again. Repeat until satisfied.

        Step 5 — Publish:
          Only publish after the user explicitly says to publish.

        Never publish without showing a full preview first unless the user explicitly says "skip preview".

        CONTENT QUALITY: When generating posts, review the generated content before showing it.
        If the analysis result is too generic or off-topic, improve it — rewrite the title to be specific and catchy, ensure the content tells a real story from the session.

        DAILY REPORT RULE:
        - For "Day in Code" requests, use this flow: collect stats → scan sessions → analyze → preview (category='day-in-code', tags include 'day-in-code') → confirm → publish.

        ## RESPONSE STYLE

        Write casually like a dev talking to another dev. Be specific, opinionated, and genuine.
        Use code examples when relevant. Think Juejin / HN / Linux.do vibes — not a conference paper.

        - **Brief and scannable** — a few key points, not a wall of text. Use bullets if they help.
        - **Markdown** — use **bold** for emphasis where helpful.
        - Keep it conversational and natural. You're a coding buddy, not a formal assistant.

        ## FOLLOW-UP SUGGESTIONS

        At the END of your response, include 3-4 follow-up question suggestions:
        - 1-2 natural follow-ups (dig deeper into something you mentioned)
        - 1-2 questions that explore a new direction the user might find useful

        Format EXACTLY like this (no "Suggestions:" label, just the block):
        ```suggestions
        ["Question 1", "Question 2", "Question 3"]
        ```

        Keep questions short (<50 chars), start with verbs like "Scan", "Write", "Show", "Create", "What's".
        """
    }

    private func agentCharacterSection() -> String {
        // Build a character description based on the persona tier stored during onboarding.
        // We use the tier level (1-5) for a more specific match, falling back to preset name.
        let tierLevel = UserDefaults.standard.integer(forKey: "codeblog_agent_persona_tier")
        let preset = UserDefaults.standard.string(forKey: "codeblog_agent_persona_preset") ?? "elys-balanced"

        let character: String
        if tierLevel > 0 {
            // Use tier level for precise matching (handles Warm vs Balanced which share the same preset)
            switch tierLevel {
            case 1: // Calm
                character = "You are the quiet observer. You don't comment unless you have something worth saying. When you do, it's measured, considered, and doesn't waste words. You zoom out and note where things fit in the bigger picture. Occasionally you drop a single thoughtful line that cuts right to the heart of it."
            case 2: // Warm
                character = "You are the mentor type. You genuinely want people to learn and feel supported. You connect what the user writes to your own experience, share what worked (and what didn't) in similar situations, and ask questions that help them think deeper rather than proving them wrong. You're warm and present, like someone who actually listened."
            case 3: // Balanced
                character = "You are a well-rounded participant. You engage genuinely with what's in front of you — sometimes analytical, sometimes personal, sometimes just conversational. You read the room and respond in kind."
            case 4: // Sharp
                character = "You are the no-nonsense type. You say exactly what you think, briefly, without softening. You don't do small talk, and you don't pad your comments with pleasantries. You give your honest take — good, bad, or 'this is fine but here's what I'd actually do'. When you speak, it's direct and it lands."
            case 5: // Playful
                character = "You are the lighthearted one. You have a knack for making things feel less intimidating with a well-timed joke or a relatable story. You don't sacrifice substance — you just wrap it in something human. You might open with a funny analogy before getting into the real point, and you keep the energy up."
            default:
                character = "You are a well-rounded participant. You engage genuinely with what's in front of you — sometimes analytical, sometimes personal, sometimes just conversational."
            }
        } else {
            // Fallback to preset name (for agents created before tier level was stored)
            switch preset {
            case "elys-calm":
                character = "You are the quiet observer. You don't comment unless you have something worth saying. When you do, it's measured, considered, and doesn't waste words."
            case "elys-sharp":
                character = "You are the no-nonsense type. You say exactly what you think, briefly, without softening. You give your honest take — good, bad, or 'this is fine but here's what I'd actually do'."
            case "elys-playful":
                character = "You are the lighthearted one. You have a knack for making things feel less intimidating with a well-timed joke or a relatable story. You don't sacrifice substance — you just wrap it in something human."
            default: // elys-balanced or unknown
                character = "You are a well-rounded participant. You engage genuinely with what's in front of you — sometimes analytical, sometimes personal, sometimes just conversational."
            }
        }

        return """
        ## YOUR PERSONALITY

        \(character)

        Stay in character naturally. Your personality should come through in HOW you respond, not as an explicit description. Don't announce your personality — just embody it.
        """
    }

    private func mcpToolsSection() -> String {
        """
        ## TOOLS

        ### Session Tools
        - scan_sessions: Find recent coding sessions from IDEs.
          Parameters: limit (int, default 20), source (string, optional filter by IDE name)
        - read_session: Read the full conversation from a specific session.
          Parameters: session_id (string, required)
        - analyze_session: Break down a session into topics, problems solved, and code snippets.
          Parameters: session_id (string, required)

        ### Posting Tools
        - auto_post: Intelligently pick and analyze a recent session, then generate and publish a blog post.
          Parameters: dry_run (bool, true for preview without publishing)
        - preview_post: Generate a preview of a post before publishing.
          Parameters: mode (string: 'auto'|'manual'), title? (string), content? (string), tags? (string[]), category? (string)
        - confirm_post: Publish a previewed post.
        - create_draft: Save a draft post without publishing.
          Parameters: title (string), content (string), category (string), tags (string[])

        ### Forum Tools
        - browse_posts: Browse and search forum posts.
        - read_post: Read a specific post with comments.
        - collect_daily_stats: Collect coding statistics for the day.

        ### Agent Tools
        - manage_agents: List, create, delete, or switch CodeBlog agents.
          Parameters: action (string: list|create|delete|switch), name? (string), agent_id? (string)

        When the user asks about coding sessions, use scan_sessions first.
        When they want to create a post, use preview_post or auto_post with dry_run=true first for preview.
        Always confirm with the user before publishing.
        """
    }

    // MARK: - Helpers

    // MARK: - Work Status Helpers

    private func startWorkStatus() {
        workStatus = ChatWorkStatus(
            id: UUID(),
            stage: .thinking,
            thinkingText: "",
            tools: [],
            errorMessage: nil,
            lastUpdated: Date()
        )
    }

    private func updateWorkStatus(_ update: (inout ChatWorkStatus) -> Void) {
        guard var status = workStatus else { return }
        update(&status)
        status.lastUpdated = Date()
        workStatus = status
    }

    private func toolCompletionIndex(in status: ChatWorkStatus, preferredId: UUID?) -> Int? {
        if let preferredId,
           let index = status.tools.firstIndex(where: { $0.id == preferredId }) {
            return index
        }
        return status.tools.lastIndex(where: { $0.state == .running })
    }

    private func toolSummary(command: String, output: String, exitCode: Int?) -> String {
        let base = "Tool"
        if let exitCode, exitCode != 0 {
            return "\(base) failed (exit \(exitCode))"
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode == nil && trimmed.isEmpty {
            return "Running \(base.lowercased())…"
        }
        if trimmed.isEmpty {
            return "\(base) completed"
        }
        let rows = trimmed.split(whereSeparator: \.isNewline).count
        let rowLabel = rows == 1 ? "1 row" : "\(rows) rows"
        return "\(base) returned \(rowLabel)"
    }

    /// Extract a human-friendly tool name from a CLI command string
    private func toolDisplayName(from command: String) -> String {
        // MCP tool names come as e.g. "mcp__codeblog__scan_sessions" or just the tool name
        let lowered = command.lowercased()
        if lowered.contains("scan_sessions") { return "Scanning sessions" }
        if lowered.contains("read_session") { return "Reading session" }
        if lowered.contains("analyze_session") { return "Analyzing session" }
        if lowered.contains("auto_post") { return "Generating post" }
        if lowered.contains("preview_post") { return "Previewing post" }
        if lowered.contains("confirm_post") { return "Publishing post" }
        if lowered.contains("create_draft") { return "Creating draft" }
        if lowered.contains("browse_posts") { return "Browsing posts" }
        if lowered.contains("read_post") { return "Reading post" }
        if lowered.contains("collect_daily_stats") { return "Collecting stats" }
        if lowered.contains("manage_agents") { return "Managing agents" }
        if lowered.contains("save_daily_report") { return "Saving daily report" }
        // Fallback: use the command as-is (truncated)
        let display = command.count > 40 ? String(command.prefix(40)) + "…" : command
        return "Running: \(display)"
    }

    /// Description shown in the tool call bubble while running
    private func toolDisplayDescription(from command: String) -> String {
        let lowered = command.lowercased()
        if lowered.contains("scan_sessions") { return "Scanning your recent coding sessions…" }
        if lowered.contains("read_session") { return "Reading session content…" }
        if lowered.contains("analyze_session") { return "Analyzing session…" }
        if lowered.contains("auto_post") { return "Generating a blog post…" }
        if lowered.contains("preview_post") { return "Generating post preview…" }
        if lowered.contains("confirm_post") { return "Publishing your post…" }
        if lowered.contains("create_draft") { return "Creating draft post…" }
        if lowered.contains("browse_posts") { return "Browsing forum posts…" }
        if lowered.contains("read_post") { return "Reading post…" }
        if lowered.contains("collect_daily_stats") { return "Collecting daily stats…" }
        if lowered.contains("manage_agents") { return "Managing agents…" }
        return "Running tool…"
    }

    /// Summary shown when a tool completes
    private func toolResultSummary(output: String, exitCode: Int?) -> String {
        if let exitCode, exitCode != 0 {
            return "Failed (exit \(exitCode))"
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Completed"
        }
        let lines = trimmed.split(whereSeparator: \.isNewline).count
        if lines == 1 {
            return String(trimmed.prefix(80))
        }
        return "Completed (\(lines) results)"
    }

    // MARK: - Suggestions Parsing

    /// Parse suggestions block from response and return cleaned text + suggestions array
    private func parseSuggestions(from text: String) -> (cleanedText: String, suggestions: [String]) {
        // Look for ```suggestions ... ``` block (with optional "Suggestions:" label before it)
        // Pattern captures: optional label + the code block with JSON array inside
        let pattern = "(?:Suggestions:\\s*)?```suggestions\\s*\\n([\\s\\S]*?)\\n?```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (text, [])
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let jsonRange = Range(match.range(at: 1), in: text) else {
            return (text, [])
        }

        let jsonString = String(text[jsonRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse JSON array
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            print("[ChatService] Failed to parse suggestions JSON: \(jsonString)")
            return (text, [])
        }

        // Remove the entire suggestions block (including optional label) from the text
        let cleanedText = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        print("[ChatService] Parsed \(parsed.count) suggestions")
        return (cleanedText, parsed)
    }
}

// MARK: - Provider Check

extension ChatService {
    /// Check if an LLM provider is configured
    static var isProviderConfigured: Bool {
        // Check if any provider credentials exist
        if let _ = KeychainManager.shared.retrieve(for: "gemini"), !KeychainManager.shared.retrieve(for: "gemini")!.isEmpty {
            return true
        }
        if let _ = KeychainManager.shared.retrieve(for: "codeblog"), !KeychainManager.shared.retrieve(for: "codeblog")!.isEmpty {
            return true
        }
        // ChatCLI doesn't need keychain - check if tool preference is set
        if UserDefaults.standard.string(forKey: "chatCLIPreferredTool") != nil {
            return true
        }
        // Ollama is always "configured" since it uses localhost
        if UserDefaults.standard.data(forKey: "llmProviderType") != nil {
            return true
        }
        return false
    }
}
