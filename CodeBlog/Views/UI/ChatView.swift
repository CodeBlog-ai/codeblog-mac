//
//  ChatView.swift
//  CodeBlog
//
//  Chat interface for asking questions about activity data.
//

import SwiftUI
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
    @State private var didAnimateWelcome = false
    @State private var showAgentPicker = false
    @State private var showModelPicker = false
    @State private var availableAgents: [CodeBlogAPIService.AgentInfo] = []
    @State private var isSwitchingAgent = false
    @State private var showHistoryPopover = false
    @State private var isEditingTitle = false
    @State private var editingTitleText = ""
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
        .onAppear {
            chatService.loadConversationsList()
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
            // Header: [History] --- [Title] --- [New Chat +] [Debug]
            ZStack {
                // Center: Conversation title (truly centered)
                if isEditingTitle {
                    TextField("Chat title", text: $editingTitleText)
                        .font(.custom("Nunito", size: 13).weight(.semibold))
                        .foregroundColor(Color(hex: "4A4A4A"))
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 200)
                        .onSubmit {
                            chatService.renameConversation(title: editingTitleText)
                            isEditingTitle = false
                        }
                } else {
                    Text(chatService.currentConversationTitle)
                        .font(.custom("Nunito", size: 13).weight(.semibold))
                        .foregroundColor(Color(hex: "4A4A4A"))
                        .lineLimit(1)
                        .onTapGesture {
                            if chatService.currentConversationId != nil {
                                editingTitleText = chatService.currentConversationTitle
                                isEditingTitle = true
                            }
                        }
                }

                // Left + Right buttons
                HStack(spacing: 0) {
                    // Left: History button
                    Button(action: {
                        chatService.loadConversationsList()
                        showHistoryPopover.toggle()
                    }) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(Color(hex: "999999"))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Chat history")
                    .popover(isPresented: $showHistoryPopover, arrowEdge: .bottom) {
                        historyPopoverContent
                    }

                    Spacer()

                    // Right: New chat + Debug
                    HStack(spacing: 6) {
                        Button(action: {
                            chatService.startNewConversation()
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(hex: "999999"))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("New chat")

                        Button(action: { chatService.showDebugPanel.toggle() }) {
                            Image(systemName: chatService.showDebugPanel ? "ladybug.fill" : "ladybug")
                                .font(.system(size: 14))
                                .foregroundColor(chatService.showDebugPanel ? Color(hex: "F96E00") : Color(hex: "999999"))
                        }
                        .buttonStyle(.plain)
                        .help("Toggle debug panel")
                        .pointingHandCursor()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

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
                            MessageBubble(message: message) { messageId, newText in
                                editAndResend(messageId: messageId, text: newText)
                            }
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

    // MARK: - History Popover

    private var historyPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Chats")
                    .font(.custom("Nunito", size: 13).weight(.bold))
                    .foregroundColor(Color(hex: "4A4A4A"))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if chatService.conversations.isEmpty {
                Text("No conversations yet")
                    .font(.custom("Nunito", size: 12).weight(.medium))
                    .foregroundColor(Color(hex: "BBBBBB"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(chatService.conversations) { conv in
                            historyRow(conv: conv)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: chatService.conversations.map(\.id))
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 260)
        .padding(.bottom, 8)
    }

    private func historyRow(conv: ChatConversation) -> some View {
        let isActive = chatService.currentConversationId == conv.id

        return HistoryRowView(conv: conv, isActive: isActive) {
            chatService.loadConversation(id: conv.id)
            showHistoryPopover = false
        } onDelete: {
            withAnimation(.easeOut(duration: 0.25)) {
                chatService.deleteConversation(id: conv.id)
            }
        }
    }

    private func relativeTimeString(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
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

            ChatFlowLayout(spacing: 8) {
                ForEach(Array(chatService.currentSuggestions.enumerated()), id: \.element) { index, suggestion in
                    SuggestionChip(text: suggestion) {
                        sendMessage(suggestion)
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.7).delay(Double(index) * 0.08),
                        value: chatService.currentSuggestions.count
                    )
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
        let isNewConversation = chatService.currentConversationId == nil || chatService.messages.isEmpty

        // Count only user messages for index
        let messageIndex = chatService.messages.filter { $0.role == .user }.count

        // Log question to PostHog
        AnalyticsService.shared.capture("chat_question_asked", [
            "question": messageText,
            "conversation_id": chatService.currentConversationId?.uuidString ?? "unknown",
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
    }

    private func editAndResend(messageId: UUID, text: String) {
        guard !chatService.isProcessing else { return }
        chatService.deleteMessagesFrom(id: messageId)
        sendMessage(text)
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
