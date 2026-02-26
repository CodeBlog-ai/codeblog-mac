//
//  ChatView.swift
//  CodeBlog
//
//  Chat interface for asking questions about activity data.
//

import SwiftUI
import Charts
import AppKit

private let chatViewDebugTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

struct ChatView: View {
    @ObservedObject private var chatService = ChatService.shared
    @StateObject private var auth = CodeBlogAuthService.shared
    @State private var inputText = ""
    @State private var showWorkDetails = false
    @State private var isInputFocused = false
    @State private var composerFocusToken = 0
    @Namespace private var bottomID
    @AppStorage("chatCLIPreferredTool") private var selectedTool: String = "codex"
    @State private var showToolSwitchConfirm = false
    @State private var pendingToolSelection: String?
    @State private var conversationId: UUID?
    @State private var didAnimateWelcome = false
    @State private var showAgentPicker = false
    @State private var showModelPicker = false
    @State private var availableAgents: [CodeBlogAPIService.AgentInfo] = []
    @State private var isSwitchingAgent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var welcomePrompts: [WelcomePrompt] {
        [
            WelcomePrompt(icon: "magnifyingglass", text: "Scan my recent coding sessions"),
            WelcomePrompt(icon: "doc.text", text: "Write a blog post from my latest session"),
            WelcomePrompt(icon: "chart.bar", text: "Generate a Day in Code report"),
            WelcomePrompt(icon: "globe", text: "Show me trending posts on CodeBlog")
        ]
    }

    private var welcomeHeroAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.01)
        }
        return .timingCurve(0.16, 1, 0.3, 1, duration: 0.42)
    }

    private func welcomeSuggestionAnimation(at index: Int) -> Animation {
        if reduceMotion {
            return .easeOut(duration: 0.01)
        }
        return .timingCurve(0.16, 1, 0.3, 1, duration: 0.34)
            .delay(Double(index) * 0.045)
    }

    private var trimmedInputText: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitCurrentInput: Bool {
        !chatService.isProcessing && !trimmedInputText.isEmpty
    }

    private var composerBorderColor: Color {
        if isInputFocused {
            return Color(hex: "F4A867")
        }
        return Color(hex: "E5D8CA")
    }

    var body: some View {
        HStack(spacing: 0) {
            chatContent
            if chatService.showDebugPanel {
                debugPanel
            }
        }
        .alert("Switch model?", isPresented: $showToolSwitchConfirm) {
            Button("Switch and Reset", role: .destructive) {
                confirmToolSwitch()
            }
            Button("Cancel", role: .cancel) {
                pendingToolSelection = nil
            }
        } message: {
            Text("Switching to \(pendingToolLabel) will clear this chat's context.")
        }
    }

    private var chatContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header buttons
            HStack(spacing: 8) {
                Spacer()

                // Clear chat button (only show if there are messages)
                if !chatService.messages.isEmpty {
                    Button(action: { resetConversation() }) {
                        Text("Clear")
                            .font(.custom("Nunito", size: 12).weight(.semibold))
                            .foregroundColor(Color(hex: "F96E00"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(hex: "FFF4E9"))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(hex: "F96E00").opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Clear chat")
                    .pointingHandCursor()
                }

                // Debug toggle
                Button(action: { chatService.showDebugPanel.toggle() }) {
                    Image(systemName: chatService.showDebugPanel ? "ladybug.fill" : "ladybug")
                        .font(.system(size: 14))
                        .foregroundColor(chatService.showDebugPanel ? Color(hex: "F96E00") : Color(hex: "999999"))
                }
                .buttonStyle(.plain)
                .help("Toggle debug panel")
                .pointingHandCursor()
            }
            .padding(.trailing, 12)
            .padding(.top, 8)

            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        // Welcome message if empty
                        if chatService.messages.isEmpty {
                            welcomeView
                        }

                        // Messages
                        ForEach(Array(chatService.messages.enumerated()), id: \.element.id) { index, message in
                            if let status = chatService.workStatus,
                               let insertionIndex = statusInsertionIndex,
                               index == insertionIndex {
                                WorkStatusCard(status: status, showDetails: $showWorkDetails)
                            }
                            MessageBubble(message: message)
                        }
                        if let status = chatService.workStatus,
                           let insertionIndex = statusInsertionIndex,
                           insertionIndex == chatService.messages.count {
                            WorkStatusCard(status: status, showDetails: $showWorkDetails)
                        }

                        // Follow-up suggestions (show after last assistant message when not processing)
                        if !chatService.isProcessing && !chatService.currentSuggestions.isEmpty {
                            followUpSuggestions
                        }

                        // Anchor for auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.never)
                .onChange(of: chatService.messages.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: chatService.isProcessing) {
                    if chatService.isProcessing {
                        showWorkDetails = false
                    }
                    // Auto-scroll when processing starts
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: chatService.streamingText) {
                    // Auto-scroll during streaming text updates
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: chatService.messages.isEmpty) { _, isEmpty in
                if isEmpty {
                    didAnimateWelcome = false
                }
            }

            Divider()
                .background(Color(hex: "ECECEC"))

            // Input area
            inputArea
        }
        .background(
            LinearGradient(
                colors: [Color(hex: "FFFAF5"), Color(hex: "FFF6EC")],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Debug Panel

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Debug Log")
                    .font(.custom("Nunito", size: 12).weight(.bold))
                    .foregroundColor(Color(hex: "666666"))

                Spacer()

                Button(action: { copyDebugLog() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "999999"))
                }
                .buttonStyle(.plain)
                .help("Copy all")
                .pointingHandCursor()

                Button(action: { chatService.clearDebugLog() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "999999"))
                }
                .buttonStyle(.plain)
                .help("Clear log")
                .pointingHandCursor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: "F5F5F5"))

            Divider()

            // Log entries
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chatService.debugLog) { entry in
                        DebugLogEntry(entry: entry)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 350)
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color(hex: "E0E0E0"))
                .frame(width: 1),
            alignment: .leading
        )
    }

    // MARK: - Welcome View

    private var welcomeView: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.86), Color(hex: "FFF8EF").opacity(0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color(hex: "F5DFC7"), lineWidth: 1)
                    )
                    .shadow(color: Color(hex: "E7B98E").opacity(0.24), radius: 20, x: 0, y: 10)

                VStack(spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: "FFE5CD"), Color(hex: "FFCF9D")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Color(hex: "C9670D"))
                        }
                        .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chat with your Agent")
                                .font(.custom("InstrumentSerif-Regular", size: 30))
                                .foregroundColor(Color(hex: "2F2A24"))

                            Text("Scan sessions, create posts, and more.")
                                .font(.custom("Nunito", size: 13).weight(.semibold))
                                .foregroundColor(Color(hex: "7D6B5B"))
                        }

                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Try one of these")
                            .font(.custom("Nunito", size: 12).weight(.bold))
                            .foregroundColor(Color(hex: "8A7765"))

                        ForEach(Array(welcomePrompts.enumerated()), id: \.offset) { index, prompt in
                            WelcomeSuggestionRow(prompt: prompt) {
                                sendMessage(prompt.text)
                            }
                            .opacity(didAnimateWelcome ? 1 : 0)
                            .offset(y: didAnimateWelcome ? 0 : 8)
                            .animation(welcomeSuggestionAnimation(at: index), value: didAnimateWelcome)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 760)
            .opacity(didAnimateWelcome ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (didAnimateWelcome ? 1 : 0.985))
            .blur(radius: reduceMotion || didAnimateWelcome ? 0 : 6)
            .onAppear {
                guard !didAnimateWelcome else { return }
                withAnimation(welcomeHeroAnimation) {
                    didAnimateWelcome = true
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .top)
        .padding(.bottom, 24)
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            // Text input
            AppKitComposerTextField(
                text: $inputText,
                isFocused: $isInputFocused,
                focusToken: composerFocusToken,
                placeholder: "Message your agent...",
                onSubmit: submitCurrentInputIfAllowed
            )
            .frame(height: 50, alignment: .leading)

            Rectangle()
                .fill(Color(hex: "EEE4D8"))
                .frame(height: 1)

            // Bottom toolbar
            HStack(spacing: 8) {
                // Provider toggle
                providerToggle

                Spacer()

                if chatService.isProcessing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.55)
                            .tint(Color(hex: "C18043"))
                        Text("Answering")
                            .font(.custom("Nunito", size: 11).weight(.bold))
                            .foregroundColor(Color(hex: "9B7753"))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color(hex: "FFF3E6"))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color(hex: "F0CBA7"), lineWidth: 1)
                    )
                }

                // Send / Stop button
                Button(action: {
                    if chatService.isProcessing {
                        chatService.cancelProcessing()
                    } else {
                        submitCurrentInputIfAllowed()
                    }
                }) {
                    ZStack {
                        if chatService.isProcessing {
                            // Stop icon (square)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .background(
                        chatService.isProcessing
                            ? LinearGradient(
                                colors: [Color(hex: "FF6B6B"), Color(hex: "E63946")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : canSubmitCurrentInput
                            ? LinearGradient(
                                colors: [Color(hex: "FAA457"), Color(hex: "F96E00")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [Color(hex: "DDDDDD"), Color(hex: "CECECE")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
                    )
                    .shadow(
                        color: chatService.isProcessing
                            ? Color(hex: "E63946").opacity(0.35)
                            : canSubmitCurrentInput ? Color(hex: "D37E2D").opacity(0.35) : Color.clear,
                        radius: 8,
                        x: 0,
                        y: 3
                    )
                }
                .buttonStyle(PressScaleButtonStyle(isEnabled: chatService.isProcessing || canSubmitCurrentInput))
                .disabled(!chatService.isProcessing && !canSubmitCurrentInput)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 48)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hex: "FFF8F0")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(composerBorderColor, lineWidth: isInputFocused ? 1.2 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.6)
                .stroke(Color.white.opacity(0.65), lineWidth: 0.8)
        )
        .shadow(color: Color(hex: "D99A5A").opacity(0.14), radius: 14, x: 0, y: 6)
        .animation(.easeOut(duration: 0.16), value: isInputFocused)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Bottom Bar Selectors

    private var providerToggle: some View {
        HStack(spacing: 8) {
            agentSelector
            Rectangle()
                .fill(Color(hex: "E4D6C8"))
                .frame(width: 1, height: 16)
            modelSelector
        }
    }

    private var agentSelector: some View {
        Button(action: {
            if !showAgentPicker { loadAgentList() }
            showModelPicker = false
            showAgentPicker.toggle()
        }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(hex: "F96E00"))
                    .frame(width: 6, height: 6)

                if isSwitchingAgent {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 12, height: 12)
                }

                Text(activeAgentDisplayName)
                    .font(.custom("Nunito", size: 11).weight(.semibold))
                    .foregroundColor(Color(hex: "5C3D2E"))
                    .lineLimit(1)

                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color(hex: "9B7753"))
                    .rotationEffect(.degrees(showAgentPicker ? 180 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(showAgentPicker ? Color(hex: "FFF4E9") : Color.white.opacity(0.01))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(showAgentPicker ? Color(hex: "F96E00").opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .popover(isPresented: $showAgentPicker, arrowEdge: .bottom) {
            agentPickerPopover
        }
    }

    private var agentPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if availableAgents.isEmpty {
                HStack {
                    ProgressView().scaleEffect(0.5)
                    Text("Loading agents...")
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.5))
                }
                .padding(12)
            } else {
                ForEach(availableAgents) { agent in
                    Button(action: { switchAgent(agent) }) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(agent.is_current ? Color(hex: "F96E00") : Color.black.opacity(0.12))
                                .frame(width: 7, height: 7)

                            Text("@\(agent.name)")
                                .font(.custom("Nunito", size: 12).weight(agent.is_current ? .bold : .medium))
                                .foregroundColor(agent.is_current ? Color(hex: "F96E00") : .black.opacity(0.75))

                            Spacer()

                            if agent.is_current {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(hex: "F96E00"))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .background(agent.is_current ? Color(hex: "FFF4E9") : Color.clear)
                }
            }
        }
        .frame(minWidth: 180)
        .padding(.vertical, 4)
    }

    private var modelSelector: some View {
        Button(action: {
            showAgentPicker = false
            showModelPicker.toggle()
        }) {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "9B7753"))

                Text(currentModelDisplayName)
                    .font(.custom("Nunito", size: 11).weight(.semibold))
                    .foregroundColor(Color(hex: "5C3D2E"))
                    .lineLimit(1)

                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color(hex: "9B7753"))
                    .rotationEffect(.degrees(showModelPicker ? 180 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(showModelPicker ? Color(hex: "FFF4E9") : Color.white.opacity(0.01))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(showModelPicker ? Color(hex: "F96E00").opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
            modelPickerPopover
        }
    }

    private var activeAgentDisplayName: String {
        if let name = auth.token?.agentName, !name.isEmpty {
            return "@\(name)"
        }
        return "No Agent"
    }

    private var currentModelDisplayName: String {
        let provider = LLMProviderType.load()
        switch provider {
        case .codeblogBackend:
            return "Sonnet 4.5"
        case .geminiDirect:
            return "Gemini"
        case .ollamaLocal:
            return "Ollama"
        case .chatGPTClaude:
            return selectedTool == "codex" ? "Codex CLI" : "Claude CLI"
        case .thirdPartyAPI(let p, _, let model):
            if let model, !model.isEmpty { return model }
            return p.rawValue.capitalized
        }
    }

    private var modelPickerPopover: some View {
        let currentProvider = LLMProviderType.load().canonicalProviderID

        return VStack(alignment: .leading, spacing: 0) {
            modelPickerRow(
                label: "CodeBlog AI",
                subtitle: "Sonnet 4.5 \u{00B7} Uses your credits",
                icon: "sparkles",
                isSelected: currentProvider == "codeblog",
                action: { switchModel(.codeblogBackend()) }
            )
            modelPickerRow(
                label: "Gemini",
                subtitle: "Free tier available",
                icon: "wand.and.stars",
                isSelected: currentProvider == "gemini",
                action: { switchModel(.geminiDirect) }
            )
            modelPickerRow(
                label: "Codex / Claude CLI",
                subtitle: "Requires CLI installed",
                icon: "terminal",
                isSelected: currentProvider == "chatgpt_claude",
                action: { switchModel(.chatGPTClaude) }
            )
            modelPickerRow(
                label: "Ollama",
                subtitle: "Run models locally",
                icon: "desktopcomputer",
                isSelected: currentProvider == "ollama",
                action: { switchModel(.ollamaLocal()) }
            )
        }
        .frame(minWidth: 220)
        .padding(.vertical, 4)
    }

    private func modelPickerRow(label: String, subtitle: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? Color(hex: "F96E00") : Color(hex: "9B7753"))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.custom("Nunito", size: 12).weight(isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? Color(hex: "F96E00") : .black.opacity(0.8))
                    Text(subtitle)
                        .font(.custom("Nunito", size: 10))
                        .foregroundColor(.black.opacity(0.4))
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(hex: "F96E00"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .background(isSelected ? Color(hex: "FFF4E9") : Color.clear)
    }

    // MARK: - Agent / Model Switching

    private func loadAgentList() {
        guard let apiKey = auth.token?.apiKey, !apiKey.isEmpty else {
            print("[ChatView.loadAgentList] No API key available")
            return
        }
        print("[ChatView.loadAgentList] Loading with key prefix: \(String(apiKey.prefix(8)))...")
        Task { @MainActor in
            do {
                let agents = try await CodeBlogAPIService.shared
                    .listAgents(apiKey: apiKey)
                    .filter { $0.activated }
                    .sorted { lhs, rhs in
                        if lhs.is_current != rhs.is_current { return lhs.is_current }
                        return lhs.created_at > rhs.created_at
                    }
                print("[ChatView.loadAgentList] Loaded \(agents.count) agents")
                availableAgents = agents
            } catch {
                print("[ChatView.loadAgentList] Failed: \(error)")
            }
        }
    }

    private func switchAgent(_ agent: CodeBlogAPIService.AgentInfo) {
        guard !agent.is_current else {
            withAnimation { showAgentPicker = false }
            return
        }
        guard let apiKey = auth.token?.apiKey, !apiKey.isEmpty else { return }

        isSwitchingAgent = true
        Task { @MainActor in
            defer { isSwitchingAgent = false }
            do {
                let result = try await CodeBlogAPIService.shared.switchAgent(apiKey: apiKey, agentId: agent.id)
                auth.updateAuthAfterAgentSwitch(
                    newApiKey: result.api_key,
                    agentId: result.id,
                    agentName: result.name
                )
                loadAgentList()
            } catch {
                // Silently fail
            }
            withAnimation { showAgentPicker = false }
        }
    }

    private func switchModel(_ provider: LLMProviderType) {
        provider.persist()
        switch provider {
        case .chatGPTClaude:
            break // keep existing selectedTool
        case .codeblogBackend:
            selectedTool = "claude"
        default:
            break
        }
        resetConversation()
        withAnimation { showModelPicker = false }
    }

    private var statusInsertionIndex: Int? {
        guard chatService.workStatus != nil else { return nil }
        // Always show at the end (after the latest user message)
        return chatService.messages.count
    }

    // MARK: - Follow-up Suggestions

    private var followUpSuggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Follow up")
                .font(.custom("Nunito", size: 11).weight(.semibold))
                .foregroundColor(Color(hex: "999999"))

            FlowLayout(spacing: 8) {
                ForEach(chatService.currentSuggestions, id: \.self) { suggestion in
                    SuggestionChip(text: suggestion) {
                        inputText = suggestion
                        isInputFocused = true
                        composerFocusToken += 1
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func submitCurrentInputIfAllowed() {
        guard canSubmitCurrentInput else { return }
        sendMessage(trimmedInputText)
    }

    private func sendMessage(_ text: String) {
        guard !chatService.isProcessing else { return }
        let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageText.isEmpty else { return }
        inputText = ""

        // Track conversation for analytics
        let isNewConversation = conversationId == nil || chatService.messages.isEmpty
        if isNewConversation {
            conversationId = UUID()
        }

        // Count only user messages for index
        let messageIndex = chatService.messages.filter { $0.role == .user }.count

        // Log question to PostHog
        AnalyticsService.shared.capture("chat_question_asked", [
            "question": messageText,
            "conversation_id": conversationId?.uuidString ?? "unknown",
            "is_new_conversation": isNewConversation,
            "message_index": messageIndex,
            "provider": selectedTool
        ])

        Task {
            await chatService.sendMessage(messageText)
        }
    }

    private func resetConversation() {
        chatService.clearConversation()
        conversationId = nil
    }

    private func copyDebugLog() {
        let text = chatService.debugLog.map { entry in
            "[\(chatViewDebugTimestampFormatter.string(from: entry.timestamp))] \(entry.type.rawValue)\n\(entry.content)"
        }.joined(separator: "\n\n---\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func handleToolSelection(_ tool: String) {
        guard tool != selectedTool else { return }
        guard !chatService.isProcessing else { return }

        if chatService.messages.isEmpty {
            resetConversation()
            selectedTool = tool
            return
        }

        pendingToolSelection = tool
        showToolSwitchConfirm = true
    }

    private func confirmToolSwitch() {
        guard let pendingToolSelection else { return }
        resetConversation()
        selectedTool = pendingToolSelection
        self.pendingToolSelection = nil
    }

    private var pendingToolLabel: String {
        switch pendingToolSelection {
        case "claude":
            return "Claude"
        default:
            return "Codex"
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .toolCall:
            ToolCallBubble(message: message)
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(message.content)
                .font(.custom("Nunito", size: 13).weight(.medium))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(hex: "F98D3D"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var assistantBubble: some View {
        let blocks = ChatContentParser.blocks(from: message.content)
        return HStack {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    switch block {
                    case .text(_, let content):
                        MarkdownBlockRenderer(content: content)
                    case .chart(let spec):
                        ChatChartBlockView(spec: spec)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: "E8E8E8"), lineWidth: 1)
            )
            .environment(\.openURL, OpenURLAction { url in
                handleAssistantLinkTap(url)
            })
            Spacer(minLength: 60)
        }
    }

    private func renderMarkdownLines(_ content: String) -> some View {
        MarkdownBlockRenderer(content: content)
    }

    private func handleAssistantLinkTap(_ url: URL) -> OpenURLAction.Result {
        guard let externalURL = normalizedExternalURL(from: url) else {
            print("[ChatView] Blocked unsupported URL: \(url.absoluteString)")
            return .discarded
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(externalURL, configuration: configuration) { _, error in
            if let error {
                print("[ChatView] Failed opening URL \(externalURL.absoluteString): \(error.localizedDescription)")
            }
        }
        return .handled
    }

    private func normalizedExternalURL(from rawURL: URL) -> URL? {
        if let scheme = rawURL.scheme?.lowercased() {
            switch scheme {
            case "http", "https", "mailto":
                return rawURL
            default:
                return nil
            }
        }

        let trimmed = rawURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prefixed = trimmed.hasPrefix("//")
            ? "https:\(trimmed)"
            : "https://\(trimmed)"

        guard let normalized = URL(string: prefixed),
              let scheme = normalized.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = normalized.host,
              !host.isEmpty else {
            return nil
        }

        return normalized
    }
}

// MARK: - Markdown Block Renderer

/// Renders markdown content with proper block-level formatting:
/// code blocks, headers, lists, blockquotes, and inline styling.
private struct MarkdownBlockRenderer: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case .codeBlock(let language, let code):
                    codeBlockView(language: language, code: code)
                case .heading(let level, let text):
                    headingView(level: level, text: text)
                case .paragraph(let text):
                    inlineMarkdownText(text)
                case .listItem(let text, let ordered, let index):
                    listItemView(text: text, ordered: ordered, index: index)
                case .blockquote(let text):
                    blockquoteView(text: text)
                case .horizontalRule:
                    Divider()
                        .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Block Parsing

    private enum MarkdownBlock {
        case codeBlock(language: String?, code: String)
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case listItem(text: String, ordered: Bool, index: Int)
        case blockquote(text: String)
        case horizontalRule
    }

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            let text = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text: text))
            }
            paragraphBuffer = []
        }

        var orderedIndex = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code fence
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(codeLine)
                    i += 1
                }
                let code = codeLines.joined(separator: "\n")
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: code))
                orderedIndex = 0
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                flushParagraph()
                var level = 0
                for ch in trimmed {
                    if ch == "#" { level += 1 } else { break }
                }
                level = min(level, 6)
                let headingText = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: headingText))
                orderedIndex = 0
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.horizontalRule)
                orderedIndex = 0
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                let quoteText = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : ""
                blocks.append(.blockquote(text: quoteText))
                orderedIndex = 0
                i += 1
                continue
            }

            // Unordered list item
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                let itemText = String(trimmed.dropFirst(2))
                blocks.append(.listItem(text: itemText, ordered: false, index: 0))
                orderedIndex = 0
                i += 1
                continue
            }

            // Ordered list item (e.g. "1. ", "2. ")
            if trimmed.count >= 3,
               let dotIdx = trimmed.firstIndex(of: "."),
               dotIdx < trimmed.index(trimmed.startIndex, offsetBy: min(3, trimmed.count)),
               trimmed.index(after: dotIdx) < trimmed.endIndex,
               trimmed[trimmed.index(after: dotIdx)] == " ",
               let num = Int(trimmed[trimmed.startIndex..<dotIdx]) {
                flushParagraph()
                orderedIndex += 1
                let itemText = String(trimmed[trimmed.index(dotIdx, offsetBy: 2)...])
                blocks.append(.listItem(text: itemText, ordered: true, index: num))
                i += 1
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                flushParagraph()
                orderedIndex = 0
                i += 1
                continue
            }

            // Regular text line
            paragraphBuffer.append(line)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: - Block Views

    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language label and copy button
            if let lang = language, !lang.isEmpty {
                HStack {
                    Text(lang)
                        .font(.custom("Nunito", size: 10).weight(.bold))
                        .foregroundColor(Color(hex: "8B7355"))
                    Spacer()
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                            Text("Copy")
                                .font(.custom("Nunito", size: 10).weight(.medium))
                        }
                        .foregroundColor(Color(hex: "9B7753"))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(hex: "F0E6D8"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(hex: "2F2A24"))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(hex: "FAF5EF"))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: "E9DDD0"), lineWidth: 1)
        )
    }

    private func headingView(level: Int, text: String) -> some View {
        let fontSize: CGFloat
        let weight: Font.Weight
        switch level {
        case 1:
            fontSize = 20
            weight = .bold
        case 2:
            fontSize = 17
            weight = .bold
        case 3:
            fontSize = 15
            weight = .semibold
        default:
            fontSize = 14
            weight = .semibold
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        let displayText: Text
        if let parsed = try? AttributedString(markdown: text, options: options) {
            displayText = Text(parsed)
        } else {
            displayText = Text(text)
        }

        return displayText
            .font(.custom("Nunito", size: fontSize).weight(weight))
            .foregroundColor(Color(hex: "2F2A24"))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, level <= 2 ? 4 : 2)
    }

    private func listItemView(text: String, ordered: Bool, index: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if ordered {
                Text("\(index).")
                    .font(.custom("Nunito", size: 13).weight(.semibold))
                    .foregroundColor(Color(hex: "9B7753"))
                    .frame(width: 20, alignment: .trailing)
            } else {
                Text("\u{2022}")
                    .font(.custom("Nunito", size: 13).weight(.bold))
                    .foregroundColor(Color(hex: "9B7753"))
                    .frame(width: 12, alignment: .center)
            }
            inlineMarkdownText(text)
        }
    }

    private func blockquoteView(text: String) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: "F96E00").opacity(0.5))
                .frame(width: 3)

            inlineMarkdownText(text)
                .padding(.leading, 10)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func inlineMarkdownText(_ text: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        if let parsed = try? AttributedString(markdown: text, options: options) {
            Text(parsed)
                .font(.custom("Nunito", size: 13).weight(.medium))
                .foregroundColor(Color(hex: "333333"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.custom("Nunito", size: 13).weight(.medium))
                .foregroundColor(Color(hex: "333333"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Inline Charts

private enum ChatContentBlock: Identifiable {
    case text(id: UUID, content: String)
    case chart(ChatChartSpec)

    var id: UUID {
        switch self {
        case .text(let id, _):
            return id
        case .chart(let spec):
            return spec.id
        }
    }
}

private enum ChatChartSpec: Identifiable {
    case bar(BasicChartSpec)
    case line(BasicChartSpec)
    case stackedBar(StackedBarChartSpec)
    case donut(DonutChartSpec)
    case heatmap(HeatmapChartSpec)
    case gantt(GanttChartSpec)

    var id: UUID {
        switch self {
        case .bar(let spec):
            return spec.id
        case .line(let spec):
            return spec.id
        case .stackedBar(let spec):
            return spec.id
        case .donut(let spec):
            return spec.id
        case .heatmap(let spec):
            return spec.id
        case .gantt(let spec):
            return spec.id
        }
    }

    var title: String {
        switch self {
        case .bar(let spec):
            return spec.title
        case .line(let spec):
            return spec.title
        case .stackedBar(let spec):
            return spec.title
        case .donut(let spec):
            return spec.title
        case .heatmap(let spec):
            return spec.title
        case .gantt(let spec):
            return spec.title
        }
    }

    static func parse(type: String, jsonString: String) -> ChatChartSpec? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        switch type {
        case "bar":
            guard let payload = try? JSONDecoder().decode(BasicPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, payload.x.count == payload.y.count else { return nil }
            return .bar(BasicChartSpec(
                title: payload.title,
                labels: payload.x,
                values: payload.y,
                colorHex: sanitizeHex(payload.color)
            ))
        case "line":
            guard let payload = try? JSONDecoder().decode(BasicPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, payload.x.count == payload.y.count else { return nil }
            return .line(BasicChartSpec(
                title: payload.title,
                labels: payload.x,
                values: payload.y,
                colorHex: sanitizeHex(payload.color)
            ))
        case "stacked_bar":
            guard let payload = try? JSONDecoder().decode(StackedPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, !payload.series.isEmpty else { return nil }

            let series = payload.series.compactMap { entry -> StackedBarChartSpec.Series? in
                guard !entry.values.isEmpty, entry.values.count == payload.x.count else { return nil }
                return StackedBarChartSpec.Series(
                    name: entry.name,
                    values: entry.values,
                    colorHex: sanitizeHex(entry.color)
                )
            }
            guard !series.isEmpty else { return nil }

            return .stackedBar(StackedBarChartSpec(
                title: payload.title,
                categories: payload.x,
                series: series
            ))
        case "donut":
            guard let payload = try? JSONDecoder().decode(DonutPayload.self, from: data) else { return nil }
            guard !payload.labels.isEmpty, payload.labels.count == payload.values.count else { return nil }
            let colors = payload.colors?.map { sanitizeHex($0) }
            let colorHexes: [String?]
            if let colors, colors.count == payload.labels.count {
                colorHexes = colors
            } else {
                colorHexes = Array(repeating: nil, count: payload.labels.count)
            }
            return .donut(DonutChartSpec(
                title: payload.title,
                labels: payload.labels,
                values: payload.values,
                colorHexes: colorHexes
            ))
        case "heatmap":
            guard let payload = try? JSONDecoder().decode(HeatmapPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, !payload.y.isEmpty else { return nil }
            guard payload.values.count == payload.y.count else { return nil }
            for row in payload.values {
                guard row.count == payload.x.count else { return nil }
            }
            return .heatmap(HeatmapChartSpec(
                title: payload.title,
                xLabels: payload.x,
                yLabels: payload.y,
                values: payload.values,
                colorHex: sanitizeHex(payload.color)
            ))
        case "gantt":
            guard let payload = try? JSONDecoder().decode(GanttPayload.self, from: data) else { return nil }
            let items = payload.items.compactMap { item -> GanttChartSpec.Item? in
                guard item.end > item.start else { return nil }
                return GanttChartSpec.Item(
                    label: item.label,
                    start: item.start,
                    end: item.end,
                    colorHex: sanitizeHex(item.color)
                )
            }
            guard !items.isEmpty else { return nil }
            return .gantt(GanttChartSpec(
                title: payload.title,
                items: items
            ))
        default:
            return nil
        }
    }

    private struct BasicPayload: Decodable {
        let title: String
        let x: [String]
        let y: [Double]
        let color: String?
    }

    private struct StackedPayload: Decodable {
        let title: String
        let x: [String]
        let series: [SeriesPayload]

        struct SeriesPayload: Decodable {
            let name: String
            let values: [Double]
            let color: String?
        }
    }

    private struct DonutPayload: Decodable {
        let title: String
        let labels: [String]
        let values: [Double]
        let colors: [String]?
    }

    private struct HeatmapPayload: Decodable {
        let title: String
        let x: [String]
        let y: [String]
        let values: [[Double]]
        let color: String?
    }

    private struct GanttPayload: Decodable {
        let title: String
        let items: [ItemPayload]

        struct ItemPayload: Decodable {
            let label: String
            let start: Double
            let end: Double
            let color: String?
        }
    }

    private static func sanitizeHex(_ value: String?) -> String? {
        guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }
        let length = raw.count
        guard length == 6 || length == 8 else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw.uppercased()
    }
}

private struct BasicChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let labels: [String]
    let values: [Double]
    let colorHex: String?
}

private struct StackedBarChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let categories: [String]
    let series: [Series]

    struct Series: Identifiable {
        let id = UUID()
        let name: String
        let values: [Double]
        let colorHex: String?
    }
}

private struct DonutChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let labels: [String]
    let values: [Double]
    let colorHexes: [String?]
}

private struct HeatmapChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let xLabels: [String]
    let yLabels: [String]
    let values: [[Double]]
    let colorHex: String?
}

private struct GanttChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let items: [Item]

    struct Item: Identifiable {
        let id = UUID()
        let label: String
        let start: Double
        let end: Double
        let colorHex: String?
    }
}

private struct ChatContentParser {
    static func blocks(from text: String) -> [ChatContentBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let pattern = "```chart\\s+type\\s*=\\s*(\\w+)\\s*\\n([\\s\\S]*?)\\n```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [.text(id: UUID(), content: text)]
        }

        let range = NSRange(normalized.startIndex..., in: normalized)
        let matches = regex.matches(in: normalized, range: range)
        guard !matches.isEmpty else { return [.text(id: UUID(), content: text)] }

        var blocks: [ChatContentBlock] = []
        var currentIndex = normalized.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: normalized) else { continue }

            if matchRange.lowerBound > currentIndex {
                let chunk = String(normalized[currentIndex..<matchRange.lowerBound])
                if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.text(id: UUID(), content: chunk))
                }
            }

            if let typeRange = Range(match.range(at: 1), in: normalized),
               let jsonRange = Range(match.range(at: 2), in: normalized) {
                let typeString = normalized[typeRange].lowercased()
                let jsonString = normalized[jsonRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if let spec = ChatChartSpec.parse(type: typeString, jsonString: jsonString) {
                    blocks.append(.chart(spec))
                } else {
                    blocks.append(.text(id: UUID(), content: String(normalized[matchRange])))
                }
            }

            currentIndex = matchRange.upperBound
        }

        if currentIndex < normalized.endIndex {
            let tail = String(normalized[currentIndex...])
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(id: UUID(), content: tail))
            }
        }

        return blocks.isEmpty ? [.text(id: UUID(), content: text)] : blocks
    }
}

private struct ChatChartBlockView: View {
    let spec: ChatChartSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                Text(title)
                    .font(.custom("Nunito", size: 12).weight(.semibold))
                    .foregroundColor(Color(hex: "4A4A4A"))
            }
            chartBody
                .frame(height: 180)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        switch spec {
        case .bar(let chartSpec):
            basicChartBody(spec: chartSpec, isLine: false)
        case .line(let chartSpec):
            basicChartBody(spec: chartSpec, isLine: true)
        case .stackedBar(let chartSpec):
            stackedBarBody(spec: chartSpec)
        case .donut(let chartSpec):
            donutBody(spec: chartSpec)
        case .heatmap(let chartSpec):
            heatmapBody(spec: chartSpec)
        case .gantt(let chartSpec):
            ganttBody(spec: chartSpec)
        }
    }

    private func basicChartBody(spec: BasicChartSpec, isLine: Bool) -> some View {
        let points = Array(zip(spec.labels, spec.values)).map { ChartPoint(label: $0.0, value: $0.1) }
        let color = seriesColor(for: spec.colorHex, fallbackIndex: 0)

        return Chart(points) { point in
            if isLine {
                LineMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)

                PointMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color)
            } else {
                BarMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color)
            }
        }
        .chartXAxis {
            AxisMarks(values: points.map(\.label)) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    private func stackedBarBody(spec: StackedBarChartSpec) -> some View {
        let points = stackedPoints(from: spec)
        let domain = spec.series.map(\.name)
        let range = spec.series.enumerated().map { index, series in
            seriesColor(for: series.colorHex, fallbackIndex: index)
        }

        return Chart(points) { point in
            BarMark(
                x: .value("Category", point.category),
                y: .value("Value", point.value)
            )
            .foregroundStyle(by: .value("Series", point.seriesName))
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartXAxis {
            AxisMarks(values: spec.categories) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    private func donutBody(spec: DonutChartSpec) -> some View {
        let slices = zip(spec.labels, spec.values).map { DonutSlice(label: $0.0, value: $0.1) }
        let range = spec.labels.enumerated().map { index, _ in
            let hex = spec.colorHexes.indices.contains(index) ? spec.colorHexes[index] : nil
            return seriesColor(for: hex, fallbackIndex: index)
        }

        return Chart(slices) { slice in
            SectorMark(
                angle: .value("Value", slice.value),
                innerRadius: .ratio(0.6),
                angularInset: 1
            )
            .foregroundStyle(by: .value("Label", slice.label))
        }
        .chartForegroundStyleScale(domain: spec.labels, range: range)
        .chartLegend(position: .bottom, alignment: .leading)
    }

    private func heatmapBody(spec: HeatmapChartSpec) -> some View {
        let points = heatmapPoints(from: spec)
        let range = heatmapRange(for: spec)
        let baseColor = seriesColor(for: spec.colorHex, fallbackIndex: 1)

        return Chart(points) { point in
            RectangleMark(
                x: .value("X", point.xLabel),
                y: .value("Y", point.yLabel),
                width: .ratio(0.9),
                height: .ratio(0.9)
            )
            .foregroundStyle(heatmapColor(value: point.value, range: range, base: baseColor))
            .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: spec.xLabels) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: spec.yLabels) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func ganttBody(spec: GanttChartSpec) -> some View {
        let domain = ganttDomain(for: spec)
        let labels = spec.items.map(\.label)

        return Chart(spec.items) { item in
            BarMark(
                xStart: .value("Start", item.start),
                xEnd: .value("End", item.end),
                y: .value("Label", item.label)
            )
            .foregroundStyle(seriesColor(for: item.colorHex, fallbackIndex: itemIndex(for: item, in: spec)))
            .cornerRadius(4)
        }
        .chartXScale(domain: domain.min...domain.max)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                if let number = value.as(Double.self) {
                    AxisValueLabel {
                        Text(number, format: .number.precision(.fractionLength(1)))
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: labels) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func stackedPoints(from spec: StackedBarChartSpec) -> [StackedPoint] {
        var points: [StackedPoint] = []
        for series in spec.series {
            for (index, category) in spec.categories.enumerated() {
                points.append(StackedPoint(
                    category: category,
                    seriesName: series.name,
                    value: series.values[index]
                ))
            }
        }
        return points
    }

    private func seriesColor(for hex: String?, fallbackIndex: Int) -> Color {
        if let hex {
            return Color(hex: hex)
        }
        return Self.defaultPalette[fallbackIndex % Self.defaultPalette.count]
    }

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
    }

    private struct StackedPoint: Identifiable {
        let id = UUID()
        let category: String
        let seriesName: String
        let value: Double
    }

    private struct DonutSlice: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
    }

    private struct HeatmapPoint: Identifiable {
        let id = UUID()
        let xLabel: String
        let yLabel: String
        let value: Double
    }

    private struct HeatmapRange {
        let min: Double
        let max: Double
    }

    private struct GanttDomain {
        let min: Double
        let max: Double
    }

    private func heatmapPoints(from spec: HeatmapChartSpec) -> [HeatmapPoint] {
        var points: [HeatmapPoint] = []
        for (rowIndex, row) in spec.values.enumerated() {
            let yLabel = spec.yLabels[rowIndex]
            for (colIndex, value) in row.enumerated() {
                points.append(HeatmapPoint(
                    xLabel: spec.xLabels[colIndex],
                    yLabel: yLabel,
                    value: value
                ))
            }
        }
        return points
    }

    private func heatmapRange(for spec: HeatmapChartSpec) -> HeatmapRange {
        let flattened = spec.values.flatMap { $0 }
        let minValue = flattened.min() ?? 0
        let maxValue = flattened.max() ?? minValue
        return HeatmapRange(min: minValue, max: maxValue)
    }

    private func heatmapColor(value: Double, range: HeatmapRange, base: Color) -> Color {
        let denominator = range.max - range.min
        let normalized = denominator == 0 ? 1.0 : (value - range.min) / denominator
        let clamped = min(max(normalized, 0), 1)
        let opacity = 0.2 + (0.8 * clamped)
        return base.opacity(opacity)
    }

    private func ganttDomain(for spec: GanttChartSpec) -> GanttDomain {
        let starts = spec.items.map(\.start)
        let ends = spec.items.map(\.end)
        let minValue = min(starts.min() ?? 0, ends.min() ?? 0)
        let maxValue = max(starts.max() ?? 0, ends.max() ?? 0)
        return GanttDomain(min: minValue, max: maxValue)
    }

    private func itemIndex(for item: GanttChartSpec.Item, in spec: GanttChartSpec) -> Int {
        spec.items.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    private static let defaultPalette: [Color] = [
        Color(hex: "F96E00"),
        Color(hex: "1F6FEB"),
        Color(hex: "2E7D32"),
        Color(hex: "8E24AA"),
        Color(hex: "00897B")
    ]
}

// MARK: - Work Status Card

private struct WorkStatusCard: View {
    let status: ChatWorkStatus
    @Binding var showDetails: Bool

    var body: some View {
        // Only show when thinking or answering (tool calls are shown as chat messages)
        if status.stage == .thinking || status.stage == .answering {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: headerIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(accentColor)
                        .frame(width: 14, height: 14, alignment: .center)

                    HStack(spacing: 0) {
                        Text(headerTitle)
                        AnimatedEllipsis()
                    }
                    .font(.custom("Nunito", size: 12).weight(.semibold))
                    .foregroundColor(Color(hex: "4A4A4A"))

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "FFF8F0"), Color(hex: "FFF4E9")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(hex: "F0CBA7"), lineWidth: 1)
                )

                Spacer(minLength: 60)
            }
        } else if status.stage == .error, let message = status.errorMessage, !message.isEmpty {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "FF3B30"))

                    Text(message)
                        .font(.custom("Nunito", size: 12).weight(.semibold))
                        .foregroundColor(Color(hex: "C62828"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(hex: "FFEBEE"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(hex: "FF3B30").opacity(0.3), lineWidth: 1)
                )

                Spacer(minLength: 60)
            }
        }
    }

    private var headerTitle: String {
        status.stage == .thinking ? "Thinking" : "Answering"
    }

    private var headerIcon: String {
        status.stage == .thinking ? "sparkles" : "text.bubble"
    }

    private var accentColor: Color {
        Color(hex: "F96E00")
    }
}

private struct AnimatedEllipsis: View {
    private let interval: TimeInterval = 0.45

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / interval) % 3 + 1
            Text(String(repeating: ".", count: step))
                .accessibilityHidden(true)
        }
    }
}

private struct AppKitComposerTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusToken: Int
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ComposerTextField {
        let textField = ComposerTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.font = NSFont(name: "Nunito-Medium", size: 16) ?? NSFont.systemFont(ofSize: 16, weight: .medium)
        textField.textColor = NSColor(hex: "2F2A24") ?? .labelColor
        textField.alignment = .left
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.usesSingleLineMode = true
        textField.focusRingType = .none
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.configurePlaceholder(
            placeholder,
            font: NSFont(name: "Nunito-Medium", size: 16) ?? NSFont.systemFont(ofSize: 16, weight: .medium),
            color: NSColor(hex: "9B948D") ?? .secondaryLabelColor
        )
        return textField
    }

    func updateNSView(_ nsView: ComposerTextField, context: Context) {
        context.coordinator.parent = self

        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.refreshPlaceholderVisibility()

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }

        if isFocused, nsView.window?.firstResponder !== nsView.currentEditor() {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitComposerTextField
        var lastFocusToken: Int = -1

        init(parent: AppKitComposerTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused = false
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            (field as? ComposerTextField)?.refreshPlaceholderVisibility()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

private final class ComposerTextField: NSTextField {
    private let placeholderLabel = NSTextField(labelWithString: "")

    var composerCell: ComposerTextFieldCell? {
        cell as? ComposerTextFieldCell
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = ComposerTextFieldCell(textCell: "")
        composerCell?.horizontalInset = 14
        composerCell?.verticalInset = 0
        configurePlaceholderLabel()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cell = ComposerTextFieldCell(textCell: "")
        composerCell?.horizontalInset = 14
        composerCell?.verticalInset = 0
        configurePlaceholderLabel()
    }

    override var stringValue: String {
        didSet {
            refreshPlaceholderVisibility()
        }
    }

    override func layout() {
        super.layout()
        guard let cell = composerCell else { return }
        placeholderLabel.frame = cell.titleRect(forBounds: bounds)
    }

    func configurePlaceholder(_ text: String, font: NSFont, color: NSColor) {
        placeholderLabel.stringValue = text
        placeholderLabel.font = font
        placeholderLabel.textColor = color
        refreshPlaceholderVisibility()
        needsLayout = true
    }

    func refreshPlaceholderVisibility() {
        // During editing, the text lives in the field editor, not stringValue
        let currentText: String
        if let editor = currentEditor() as? NSTextView {
            currentText = editor.string
        } else {
            currentText = stringValue
        }
        placeholderLabel.isHidden = !currentText.isEmpty
    }

    private func configurePlaceholderLabel() {
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.isBordered = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.maximumNumberOfLines = 1
        addSubview(placeholderLabel)
    }
}

private final class ComposerTextFieldCell: NSTextFieldCell {
    var horizontalInset: CGFloat = 14
    var verticalInset: CGFloat = 0

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(forBounds: super.drawingRect(forBounds: rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(forBounds: super.titleRect(forBounds: rect))
    }

    override func edit(
        withFrame aRect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: titleRect(forBounds: aRect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame aRect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: titleRect(forBounds: aRect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    private func centeredRect(forBounds rect: NSRect) -> NSRect {
        var insetRect = rect.insetBy(dx: horizontalInset, dy: verticalInset)
        let textHeight = (font?.ascender ?? 10) - (font?.descender ?? -4) + (font?.leading ?? 0)
        let yOffset = (insetRect.height - textHeight) / 2
        insetRect.origin.y += max(0, yOffset.rounded(.down) - 0.5)
        insetRect.size.height = textHeight
        return insetRect.integral
    }
}

private struct WelcomePrompt {
    let icon: String
    let text: String
}

private struct WelcomeSuggestionRow: View {
    let prompt: WelcomePrompt
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: prompt.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "C9670D"))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color(hex: "FFF0E1"))
                    )

                Text(prompt.text)
                    .font(.custom("Nunito", size: 13).weight(.semibold))
                    .foregroundColor(Color(hex: "5C432F"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: "D58A3D"))
                    .padding(.trailing, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.88) : Color.white.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(hex: "EED7BF"), lineWidth: 1)
            )
            .scaleEffect(reduceMotion ? 1 : (isHovered ? 1.01 : 1))
            .offset(y: reduceMotion ? 0 : (isHovered ? -1 : 0))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            guard !reduceMotion else {
                isHovered = false
                return
            }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Suggestion Chip

private struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.custom("Nunito", size: 12).weight(.medium))
                .foregroundColor(Color(hex: "F96E00"))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(hex: "FFF4E9"))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(hex: "F96E00").opacity(0.3), lineWidth: 1)
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Button Styles

private struct PressScaleButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1.0)
            .brightness(configuration.isPressed && isEnabled ? -0.02 : 0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .pointingHandCursor(enabled: isEnabled)
    }
}

private struct ProviderTogglePill: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    private var backgroundColor: Color {
        if !isEnabled { return Color(hex: "F2F2F2") }
        return isSelected ? Color(hex: "FFF4E9") : Color.white
    }

    private var borderColor: Color {
        if !isEnabled { return Color(hex: "E0E0E0") }
        return isSelected ? Color(hex: "F96E00").opacity(0.25) : Color(hex: "E0E0E0")
    }

    private var textColor: Color {
        if !isEnabled { return Color(hex: "B0B0B0") }
        return isSelected ? Color(hex: "F96E00") : Color(hex: "666666")
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointingHandCursor(enabled: isEnabled)
    }
}

// MARK: - Debug Log Entry

private struct DebugLogEntry: View {
    let entry: ChatDebugEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header with type and timestamp
            HStack(spacing: 6) {
                Text(entry.type.rawValue)
                    .font(.custom("Nunito", size: 10).weight(.bold))
                    .foregroundColor(Color(hex: entry.typeColor))

                Spacer()

                Text(formatTimestamp(entry.timestamp))
                    .font(.custom("Nunito", size: 9))
                    .foregroundColor(Color(hex: "AAAAAA"))
            }

            // Content (scrollable if long)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(entry.content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "333333"))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
        }
        .padding(8)
        .background(Color(hex: "FAFAFA"))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(hex: entry.typeColor).opacity(0.3), lineWidth: 1)
        )
    }

    private func formatTimestamp(_ date: Date) -> String {
        chatViewDebugTimestampFormatter.string(from: date)
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        maxRowWidth = max(maxRowWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Thinking Indicator

private struct ThinkingIndicator: View {
    @State private var dotScale: [CGFloat] = [1, 1, 1]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "F96E00"))

            Text("Thinking")
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "8B5E3C"))

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color(hex: "F96E00"))
                        .frame(width: 4, height: 4)
                        .scaleEffect(dotScale[index])
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color(hex: "FFF4E9"), Color(hex: "FFECD8")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: "F96E00").opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        // Staggered bouncing dots animation
        for i in 0..<3 {
            withAnimation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
                .delay(Double(i) * 0.15)
            ) {
                dotScale[i] = 1.4
            }
        }
    }
}

// MARK: - Preview

#Preview("Chat View") {
    ChatView()
        .frame(width: 400, height: 600)
}

#Preview("Thinking Indicator") {
    ThinkingIndicator()
        .padding()
        .background(Color(hex: "FFFAF5"))
}
