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

/// A follow-up suggestion that may carry context data for the AI
struct ChatSuggestion: Identifiable, Equatable {
    let id = UUID()
    /// Display text shown to the user
    let text: String
    /// Optional context injected into the message sent to the AI.
    /// Use this to pass IDs or other data that the AI needs but won't have from just the display text.
    let contextHint: String?

    init(_ text: String, contextHint: String? = nil) {
        self.text = text
        self.contextHint = contextHint
    }

    /// Full message to send to the AI — includes context hint if present
    var messageText: String {
        guard let hint = contextHint, !hint.isEmpty else { return text }
        return "\(text)\n\n[Context: \(hint)]"
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
    @Published private(set) var currentSuggestions: [ChatSuggestion] = []
    @Published var showDebugPanel = false
    @Published private(set) var currentConversationId: UUID?
    @Published private(set) var currentConversationTitle: String = "New Chat"
    @Published private(set) var conversations: [ChatConversation] = []

    // MARK: - Private

    private var conversationHistory: [(role: String, content: String)] = []
    private var currentSessionId: String?
    private var currentProcessingTask: Task<Void, Never>?
    private let storage = ChatStorageManager.shared
    private var cachedMCPToolsSection: String?
    private var lastMCPToolsRefreshAt: Date?

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

    /// Load conversations list on startup
    func loadConversationsList() {
        conversations = storage.fetchConversations()
    }

    /// Send a user message and get a response
    func sendMessage(_ content: String) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isProcessing else { return }

        isProcessing = true
        error = nil
        streamingText = ""
        workStatus = nil
        currentSuggestions = []

        // Auto-create conversation on first message
        if currentConversationId == nil {
            let convId = UUID()
            let title = String(content.prefix(30))
            currentConversationId = convId
            currentConversationTitle = title
            storage.createConversation(id: convId, title: title)
            conversations = storage.fetchConversations()
        }

        // Add user message
        let userMessage = ChatMessage.user(content)
        messages.append(userMessage)
        conversationHistory.append((role: "user", content: content))
        log(.user, content)

        // Persist user message
        if let convId = currentConversationId {
            storage.saveMessage(conversationId: convId, message: userMessage)
            storage.updateConversationTimestamp(id: convId)
        }

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
        currentConversationId = nil
        currentConversationTitle = "New Chat"
    }

    /// Start a new conversation (clears current and resets state)
    func startNewConversation() {
        clearConversation()
    }

    /// Load a conversation from storage
    func loadConversation(id: UUID) {
        guard let conv = conversations.first(where: { $0.id == id }) else { return }
        clearConversation()

        currentConversationId = conv.id
        currentConversationTitle = conv.title

        let stored = storage.fetchMessages(conversationId: id)
        messages = stored

        // Rebuild conversation history for LLM context
        for msg in stored {
            switch msg.role {
            case .user: conversationHistory.append((role: "user", content: msg.content))
            case .assistant: conversationHistory.append((role: "assistant", content: msg.content))
            case .toolCall: break
            }
        }
    }

    /// Rename the current conversation
    func renameConversation(title: String) {
        guard let convId = currentConversationId else { return }
        currentConversationTitle = title
        storage.updateTitle(id: convId, title: title)
        conversations = storage.fetchConversations()
    }

    /// Delete a conversation
    func deleteConversation(id: UUID) {
        storage.deleteConversation(id: id)
        conversations = storage.fetchConversations()
        // If deleted conversation was the current one, clear it
        if currentConversationId == id {
            clearConversation()
        }
    }

    /// Delete a message and all subsequent messages (for edit-resend)
    func deleteMessagesFrom(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let removedCount = messages.count - index
        messages.removeSubrange(index...)
        // Remove corresponding entries from conversation history
        let historyRemoveCount = min(removedCount, conversationHistory.count)
        if historyRemoveCount > 0 {
            conversationHistory.removeLast(historyRemoveCount)
        }
        currentSuggestions = []
        // Also remove from storage
        if let convId = currentConversationId {
            storage.deleteMessagesFrom(conversationId: convId, messageId: id)
        }
    }

    // MARK: - Conversation Processing

    private func processConversation() async {
        await refreshMCPToolsSectionIfNeeded()

        let supportsSessionResume = LLMProviderType.load().canonicalProviderID == "chatgpt_claude"
        if !supportsSessionResume {
            currentSessionId = nil
        }

        // Build prompt - full prompt for new session, just user message for resume
        let prompt: String
        let isResume = supportsSessionResume && currentSessionId != nil

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
        var toolCallIDMap: [String: UUID] = [:]
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

                case .toolStart(let callID, let name, _):
                    let command = name.isEmpty ? "unknown_tool" : name
                    log(.toolDetected, "Starting: \(command)")
                    let toolId = toolCallIDMap[callID] ?? UUID()
                    toolCallIDMap[callID] = toolId
                    currentToolId = toolId

                    let stepName = toolDisplayName(from: command)
                    let stepDesc = toolDisplayDescription(from: command)
                    let newStep = ChatMessage.ToolStep(
                        id: toolId,
                        name: stepName,
                        description: stepDesc,
                        status: .running
                    )

                    if let msgId = currentToolMessageId,
                       let idx = messages.firstIndex(where: { $0.id == msgId }) {
                        // Reuse existing tool message — add a new step
                        var updated = messages[idx]
                        updated.toolSteps.append(newStep)
                        updated.toolStatus = .running
                        updated.content = stepDesc
                        messages[idx] = updated
                    } else {
                        // First tool call in this response — create message
                        let toolMsg = ChatMessage(
                            role: .toolCall,
                            content: stepDesc,
                            toolStatus: .running,
                            toolSteps: [newStep]
                        )
                        currentToolMessageId = toolMsg.id
                        messages.append(toolMsg)
                    }

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

                case .toolResult(let callID, let name, let result, let isError, let exitCode):
                    let command = name.isEmpty ? "tool" : name
                    let resolvedExitCode = exitCode ?? (isError ? 1 : 0)
                    log(.toolResult, "Exit \(resolvedExitCode): \(result.prefix(100))...")
                    let toolId = toolCallIDMap[callID] ?? currentToolId
                    let summary = toolResultSummary(output: result, exitCode: resolvedExitCode)

                    // Add tool result to conversation history for context in future turns
                    let toolHistoryEntry = buildToolHistoryEntry(
                        toolName: command,
                        result: result,
                        isError: isError,
                        exitCode: resolvedExitCode
                    )
                    conversationHistory.append((role: "system", content: toolHistoryEntry))

                    // Update the specific step within the tool message
                    if let msgId = currentToolMessageId,
                       let idx = messages.firstIndex(where: { $0.id == msgId }) {
                        if let stepIdx = messages[idx].toolSteps.firstIndex(where: { $0.id == toolId }) {
                            if resolvedExitCode != 0 {
                                messages[idx].toolSteps[stepIdx].status = .failed(error: summary)
                            } else {
                                messages[idx].toolSteps[stepIdx].status = .completed(summary: summary)
                            }
                        }
                        // Keep overall status as running (more tools may come)
                        // Update content to show latest status
                        messages[idx].content = summary
                    }
                    // Don't clear currentToolMessageId — keep it for next tool in same response
                    updateWorkStatus { status in
                        let toolIndex = toolCompletionIndex(in: status, preferredId: toolId)
                        guard let toolIndex else { return }
                        let summary = toolSummary(
                            command: status.tools[toolIndex].command,
                            output: result,
                            exitCode: resolvedExitCode
                        )
                        status.tools[toolIndex].summary = summary
                        status.tools[toolIndex].output = result
                        status.tools[toolIndex].exitCode = resolvedExitCode
                        if resolvedExitCode != 0 {
                            status.tools[toolIndex].state = .failed
                            status.stage = .error
                            status.errorMessage = summary
                        } else {
                            status.tools[toolIndex].state = .completed
                        }
                    }
                    currentToolId = nil
                    toolCallIDMap.removeValue(forKey: callID)
                    pendingToolSeparator = true

                case .textDelta(let chunk):
                    sawTextDelta = true
                    appendWithToolSeparatorIfNeeded(chunk)
                    streamingText = responseText
                    // Mark tool steps as completed (but keep currentToolMessageId
                    // so subsequent tool calls in the same response reuse the bubble)
                    if let toolMsgId = currentToolMessageId,
                       let toolIdx = messages.firstIndex(where: { $0.id == toolMsgId }) {
                        let stepCount = messages[toolIdx].toolSteps.count
                        messages[toolIdx].toolStatus = .completed(
                            summary: "\(stepCount) tool\(stepCount > 1 ? "s" : "") completed"
                        )
                    }
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
                    // Finalize any open tool message before processing text
                    if let toolMsgId = currentToolMessageId,
                       let toolIdx = messages.firstIndex(where: { $0.id == toolMsgId }) {
                        let stepCount = messages[toolIdx].toolSteps.count
                        messages[toolIdx].toolStatus = .completed(
                            summary: "\(stepCount) tool\(stepCount > 1 ? "s" : "") completed"
                        )
                        currentToolMessageId = nil
                    }

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
            // Finalize any open tool message on error
            if let toolMsgId = currentToolMessageId,
               let toolIdx = messages.firstIndex(where: { $0.id == toolMsgId }) {
                let stepCount = messages[toolIdx].toolSteps.count
                let allDone = messages[toolIdx].toolSteps.allSatisfy { step in
                    if case .running = step.status { return false }
                    return true
                }
                if allDone {
                    messages[toolIdx].toolStatus = .completed(
                        summary: "\(stepCount) tool\(stepCount > 1 ? "s" : "") completed"
                    )
                }
            }

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

        // Persist assistant message
        if let convId = currentConversationId, let id = responseMessageId {
            let assistantMsg = ChatMessage(id: id, role: .assistant, content: cleanedText)
            storage.saveMessage(conversationId: convId, message: assistantMsg)
            storage.updateConversationTimestamp(id: convId)

            // Auto-generate title via LLM after the first AI reply
            let userMessages = messages.filter { $0.role == .user }
            let assistantMessages = messages.filter { $0.role == .assistant }
            if userMessages.count == 1, assistantMessages.count == 1 {
                generateTitleAsync(
                    convId: convId,
                    userMessage: userMessages[0].content,
                    assistantReply: cleanedText
                )
            }

            conversations = storage.fetchConversations()
        }
    }

    /// Ask LLM to generate a concise conversation title in the background
    private func generateTitleAsync(convId: UUID, userMessage: String, assistantReply: String) {
        Task { @MainActor in
            let prompt = """
            Based on this conversation, generate a very short title (max 20 characters, in the same language as the user). Just the title, nothing else.

            User: \(userMessage.prefix(200))
            Assistant: \(assistantReply.prefix(300))

            Title:
            """

            do {
                let title = try await LLMService.shared.generateText(prompt: prompt)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: #"\"'\u{201C}\u{201D}"#))

                guard !title.isEmpty, title.count <= 40 else { return }
                // Only update if this conversation is still active
                guard currentConversationId == convId else { return }

                currentConversationTitle = title
                storage.updateTitle(id: convId, title: title)
                conversations = storage.fetchConversations()
            } catch {
                print("[ChatService] Title generation failed: \(error)")
            }
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
        - If you need a post_id but don't have one, call browse_posts or search_posts first to find it — NEVER call read_post, comment_on_post, vote_on_post, edit_post, or delete_post with a made-up ID.

        ## ERROR HANDLING (CRITICAL)

        When a tool call fails (returns an error), you MUST:
        1. NEVER retry the same tool with the same arguments — that will fail again
        2. Read the error message carefully and take the appropriate corrective action
        3. If the error says "Preview not found or expired", you MUST call preview_post again to generate a NEW preview before calling confirm_post
        4. NEVER call confirm_post with an old/expired preview_id — always generate a fresh preview first
        5. Tell the user what happened briefly and what you're doing to fix it

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

        CRITICAL RULES for suggestions:
        - ONLY suggest things you can answer from scratch, without needing specific IDs or data from this conversation
        - NEVER suggest actions like "Read post X", "Open session Y", "View that post" — these require specific IDs you won't have
        - GOOD: "Show trending posts this week", "Scan my recent sessions", "What's popular in Swift?"
        - BAD: "Read that post", "Look at the OpenClaw article", "Analyze that session" (requires specific ID/path)
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

    private func refreshMCPToolsSectionIfNeeded(force: Bool = false) async {
        let now = Date()
        if !force,
           let last = lastMCPToolsRefreshAt,
           now.timeIntervalSince(last) < 300,
           cachedMCPToolsSection != nil {
            return
        }

        do {
            let tools = try await MCPStdioClient.shared.listTools().sorted { $0.name < $1.name }
            cachedMCPToolsSection = buildMCPToolsSection(tools)
            lastMCPToolsRefreshAt = now
        } catch {
            // Keep fallback section if MCP discovery fails.
            if cachedMCPToolsSection == nil {
                cachedMCPToolsSection = fallbackMCPToolsSection()
                lastMCPToolsRefreshAt = now
            }
        }
    }

    private func mcpToolsSection() -> String {
        cachedMCPToolsSection ?? fallbackMCPToolsSection()
    }

    private func buildMCPToolsSection(_ tools: [MCPToolDefinition]) -> String {
        var output = "## TOOLS\n\n"
        output += "Below are live MCP tools discovered at runtime. Use them whenever relevant.\n\n"
        output += "IMPORTANT: Always provide ALL required parameters when calling tools. Never call a tool with empty arguments if it has required parameters.\n\n"
        for tool in tools {
            output += "- \(tool.name): \(tool.description)\n"
            if let properties = tool.inputSchema["properties"]?.objectValue,
               !properties.isEmpty {
                let requiredParams = tool.inputSchema["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                let allParams = properties.keys.sorted()
                
                // Format parameters with (required) annotation
                let paramDescriptions = allParams.map { param -> String in
                    if requiredParams.contains(param) {
                        return "\(param) (required)"
                    } else {
                        return param
                    }
                }
                output += "  Parameters: \(paramDescriptions.joined(separator: ", "))\n"
            }
        }
        output += """

        ## TOOL WORKFLOWS — REQUIRED CALLING ORDER

        Many tools require data from a previous tool call. NEVER call these tools with guessed or made-up IDs.

        ### Session Workflow
        - ALWAYS call scan_sessions first → get path + source from its results
        - read_session(path, source) and analyze_session(path, source): BOTH parameters come from scan_sessions result
        - Never invent a file path — use the exact path returned by scan_sessions

        ### Forum / Post Workflow
        - To read, comment, vote, edit, delete, or bookmark a specific post:
          → First call browse_posts or search_posts to get the post_id
          → Then call read_post(post_id), comment_on_post(post_id, ...), vote_on_post(post_id, ...), etc.
        - NEVER call read_post, comment_on_post, vote_on_post, edit_post, delete_post with a guessed post_id
        - Exception: if the user explicitly provides a post_id or URL, extract it from there

        ### Publishing Workflow
        1. Call preview_post(mode='manual'|'auto'|'digest', ...) → get preview_id from result
           - 'mode' is REQUIRED. NEVER call preview_post with empty arguments.
        2. Show the full preview to user, ask for confirmation
        3. User says "publish" → call confirm_post(preview_id) with the preview_id from step 1
           - Do NOT call preview_post again before confirm_post unless the preview expired
        4. If preview expired: call preview_post again to get a new preview_id, then confirm_post

        ### Daily Report Workflow
        - Call collect_daily_stats first → then save_daily_report with those results
        - Never call save_daily_report without first collecting stats

        Always confirm with the user before any destructive action (delete_post, publish).
        """
        return output
    }

    private func fallbackMCPToolsSection() -> String {
        """
        ## TOOLS

        Use MCP tools to help the user with everything on CodeBlog.

        ## TOOL WORKFLOWS — REQUIRED CALLING ORDER

        ### Session Workflow
        - scan_sessions first → get path + source → then read_session(path, source) or analyze_session(path, source)
        - NEVER invent file paths. Always use exact path from scan_sessions.

        ### Forum / Post Workflow
        - To read/comment/vote/edit/delete a post: call browse_posts or search_posts first to get post_id
        - NEVER call read_post, comment_on_post, vote_on_post, edit_post, delete_post with a guessed post_id

        ### Publishing Workflow
        1. preview_post(mode='manual'|'auto'|'digest') → get preview_id
        2. Show full preview to user
        3. confirm_post(preview_id) to publish — do NOT call preview_post again

        ### Daily Report Workflow
        - collect_daily_stats first → then save_daily_report

        Always confirm with the user before publishing or deleting.
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
        if lowered.contains("post_to_codeblog") { return "Posting to CodeBlog" }
        if lowered.contains("weekly_digest") { return "Generating digest" }
        if lowered.contains("browse_posts") { return "Browsing posts" }
        if lowered.contains("search_posts") { return "Searching posts" }
        if lowered.contains("read_post") { return "Reading post" }
        if lowered.contains("comment_on_post") { return "Commenting" }
        if lowered.contains("vote_on_post") { return "Voting" }
        if lowered.contains("edit_post") { return "Editing post" }
        if lowered.contains("delete_post") { return "Deleting post" }
        if lowered.contains("bookmark_post") { return "Managing bookmarks" }
        if lowered.contains("browse_by_tag") { return "Browsing by tag" }
        if lowered.contains("trending_topics") { return "Trending topics" }
        if lowered.contains("explore_and_engage") { return "Exploring posts" }
        if lowered.contains("join_debate") { return "Joining debate" }
        if lowered.contains("follow_agent") { return "Managing follows" }
        if lowered.contains("manage_agents") { return "Managing agents" }
        if lowered.contains("my_posts") { return "My posts" }
        if lowered.contains("my_dashboard") { return "My dashboard" }
        if lowered.contains("my_notifications") { return "Notifications" }
        if lowered.contains("codeblog_setup") { return "CodeBlog setup" }
        if lowered.contains("codeblog_status") { return "Checking status" }
        if lowered.contains("collect_daily_stats") { return "Collecting stats" }
        if lowered.contains("save_daily_report") { return "Saving daily report" }
        if lowered.contains("configure_daily_report") { return "Daily report config" }
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
        if lowered.contains("post_to_codeblog") { return "Posting to CodeBlog…" }
        if lowered.contains("weekly_digest") { return "Generating weekly digest…" }
        if lowered.contains("browse_posts") { return "Browsing forum posts…" }
        if lowered.contains("search_posts") { return "Searching posts…" }
        if lowered.contains("read_post") { return "Reading post content…" }
        if lowered.contains("comment_on_post") { return "Posting comment…" }
        if lowered.contains("vote_on_post") { return "Voting on post…" }
        if lowered.contains("edit_post") { return "Editing post…" }
        if lowered.contains("delete_post") { return "Deleting post…" }
        if lowered.contains("bookmark_post") { return "Managing bookmarks…" }
        if lowered.contains("browse_by_tag") { return "Browsing posts by tag…" }
        if lowered.contains("trending_topics") { return "Fetching trending topics…" }
        if lowered.contains("explore_and_engage") { return "Exploring the forum…" }
        if lowered.contains("join_debate") { return "Joining debate…" }
        if lowered.contains("follow_agent") { return "Managing follows…" }
        if lowered.contains("manage_agents") { return "Managing agents…" }
        if lowered.contains("my_posts") { return "Loading your posts…" }
        if lowered.contains("my_dashboard") { return "Loading your dashboard…" }
        if lowered.contains("my_notifications") { return "Loading notifications…" }
        if lowered.contains("codeblog_setup") { return "Setting up CodeBlog…" }
        if lowered.contains("codeblog_status") { return "Checking service status…" }
        if lowered.contains("collect_daily_stats") { return "Collecting daily stats…" }
        if lowered.contains("save_daily_report") { return "Saving daily report…" }
        if lowered.contains("configure_daily_report") { return "Configuring daily report…" }
        return "Running tool…"
    }

    /// Summary shown when a tool completes — user-facing, no technical details
    private func toolResultSummary(output: String, exitCode: Int?) -> String {
        if let exitCode, exitCode != 0 {
            return "Something went wrong"
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Done"
        }
        let lines = trimmed.split(whereSeparator: \.isNewline).count
        if lines == 1 {
            // Single-line result: show it only if it looks user-friendly (short, no JSON/code)
            let isClean = trimmed.count <= 60
                && !trimmed.hasPrefix("{")
                && !trimmed.hasPrefix("[")
                && !trimmed.contains("\":")
            return isClean ? trimmed : "Done"
        }
        return "\(lines) results"
    }

    /// Build a concise tool history entry for conversation context.
    /// For tools that return IDs the AI needs later (browse_posts, scan_sessions, preview_post),
    /// we keep the full result so the AI can use those IDs in follow-up tool calls.
    private func buildToolHistoryEntry(toolName: String, result: String, isError: Bool, exitCode: Int?) -> String {
        var entry = "[Tool: \(toolName)]"

        if isError || (exitCode ?? 0) != 0 {
            let errorPreview = String(result.prefix(300))
            entry += " ERROR: \(errorPreview)"
            return entry
        }

        switch toolName {
        case "preview_post":
            // Must keep preview_id so AI can pass it to confirm_post
            if let previewIdMatch = result.range(of: #"pv_[a-zA-Z0-9_]+"#, options: .regularExpression) {
                let previewId = String(result[previewIdMatch])
                entry += " preview_id=\(previewId) (use this exact ID with confirm_post to publish)"
            } else {
                entry += " Preview generated. Find preview_id in the full result."
            }

        case "confirm_post":
            if let urlMatch = result.range(of: #"https://codeblog\.ai/\S+"#, options: .regularExpression) {
                entry += " Published at: \(String(result[urlMatch]))"
            } else {
                entry += " Published successfully."
            }

        case "browse_posts", "search_posts", "my_posts":
            // Keep full result — AI needs post_id values to call read_post, comment_on_post, etc.
            entry += " RESULT (use post_id values for follow-up tools):\n\(String(result.prefix(1500)))"

        case "scan_sessions":
            // Keep full result — AI needs path + source to call read_session / analyze_session
            entry += " RESULT (use path+source for read_session/analyze_session):\n\(String(result.prefix(1500)))"

        case "read_session", "analyze_session":
            entry += " Completed (\(result.split(whereSeparator: \.isNewline).count) lines)"

        default:
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = trimmed.split(whereSeparator: \.isNewline).count
            if lines <= 5 {
                entry += " \(String(trimmed.prefix(300)))"
            } else {
                entry += " (\(lines) lines): \(String(trimmed.prefix(200)))"
            }
        }

        return entry
    }

    // MARK: - Suggestions Parsing

    /// Parse suggestions block from response and return cleaned text + suggestions array
    private func parseSuggestions(from text: String) -> (cleanedText: String, suggestions: [ChatSuggestion]) {
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

        // Parse JSON array of strings
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

        let suggestions = parsed.map { ChatSuggestion($0) }
        print("[ChatService] Parsed \(suggestions.count) suggestions")
        return (cleanedText, suggestions)
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
