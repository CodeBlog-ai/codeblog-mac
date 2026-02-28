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
    private enum ModelPickerMode {
        case providers
        case thirdPartyModels
    }

    private struct ThirdPartySelectionConfig {
        let provider: ThirdPartyProvider
        let endpoint: String
        let apiKey: String
        let selectedModel: String?
    }

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
    @State private var modelPickerMode: ModelPickerMode = .providers
    @State private var thirdPartyPickerConfig: ThirdPartySelectionConfig?
    @State private var thirdPartyModelOptions: [String] = []
    @State private var thirdPartyModelFetchError: String?
    @State private var thirdPartyManualModel: String = ""
    @State private var isFetchingThirdPartyModels = false
    @State private var codeblogCreditModel: String = ""
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
            fetchCodeBlogCreditModel()
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
            if !showModelPicker {
                modelPickerMode = .providers
            }
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
            return codeblogCreditModelShortName
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
        VStack(alignment: .leading, spacing: 0) {
            switch modelPickerMode {
            case .providers:
                providerPickerContent
            case .thirdPartyModels:
                thirdPartyModelPickerContent
            }
        }
        .frame(minWidth: 260)
        .padding(.vertical, 4)
    }

    private var providerPickerContent: some View {
        let currentProvider = LLMProviderType.load().canonicalProviderID

        return VStack(alignment: .leading, spacing: 0) {
            modelPickerRow(
                label: "CodeBlog AI",
                subtitle: "\(codeblogCreditModelShortName) \u{00B7} Uses your credits first",
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
                label: "Third-party",
                subtitle: thirdPartySubtitle(),
                icon: "network",
                isSelected: currentProvider == "thirdparty",
                action: { openThirdPartyModelPicker() }
            )
            modelPickerRow(
                label: "Ollama",
                subtitle: "Run models locally",
                icon: "desktopcomputer",
                isSelected: currentProvider == "ollama",
                action: { switchModel(.ollamaLocal()) }
            )
        }
    }

    private var thirdPartyModelPickerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: {
                    modelPickerMode = .providers
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "9B7753"))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Text(thirdPartyPickerHeaderTitle)
                    .font(.custom("Nunito", size: 12).weight(.bold))
                    .foregroundColor(Color(hex: "5C3D2E"))

                Spacer()

                Button(action: { reloadThirdPartyModels() }) {
                    if isFetchingThirdPartyModels {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "9B7753"))
                            .frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(isFetchingThirdPartyModels || thirdPartyPickerConfig == nil)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            if isFetchingThirdPartyModels {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Fetching models...")
                        .font(.custom("Nunito", size: 11))
                        .foregroundColor(.black.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else if !thirdPartyModelOptions.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(thirdPartyModelOptions, id: \.self) { model in
                            modelPickerRow(
                                label: model,
                                subtitle: "Use this model",
                                icon: "cpu",
                                isSelected: model == currentThirdPartyModel,
                                action: { applyThirdPartyModel(model) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else if let error = thirdPartyModelFetchError {
                Text(error)
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(Color(hex: "B55A1D"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Manual model ID")
                    .font(.custom("Nunito", size: 11).weight(.semibold))
                    .foregroundColor(Color(hex: "7F5B44"))

                TextField("e.g. gpt-4o-mini", text: $thirdPartyManualModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))

                Button(action: {
                    applyThirdPartyModel(thirdPartyManualModel)
                }) {
                    Text("Use this model")
                        .font(.custom("Nunito", size: 11).weight(.semibold))
                        .foregroundColor(Color(hex: "F96E00"))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(thirdPartyManualModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thirdPartyPickerConfig == nil)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
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
        modelPickerMode = .providers
        withAnimation { showModelPicker = false }
    }

    private var thirdPartyPickerHeaderTitle: String {
        if let config = thirdPartyPickerConfig {
            return "\(config.provider.displayName) Models"
        }
        return "Third-party Models"
    }

    private var currentThirdPartyModel: String {
        if let explicit = thirdPartyPickerConfig?.selectedModel,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return thirdPartyManualModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openThirdPartyModelPicker() {
        modelPickerMode = .thirdPartyModels
        guard let config = persistedThirdPartyConfig() else {
            thirdPartyPickerConfig = nil
            thirdPartyModelOptions = []
            thirdPartyManualModel = ""
            thirdPartyModelFetchError = "Configure third-party API in onboarding/settings first."
            return
        }

        thirdPartyPickerConfig = config
        thirdPartyManualModel = (config.selectedModel ?? config.provider.defaultModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        thirdPartyModelFetchError = nil
        reloadThirdPartyModels()
    }

    private func reloadThirdPartyModels() {
        guard let config = thirdPartyPickerConfig else { return }
        isFetchingThirdPartyModels = true
        thirdPartyModelFetchError = nil

        Task { @MainActor in
            do {
                guard let url = LocalEndpointUtilities.modelsURL(baseURL: config.endpoint) else {
                    isFetchingThirdPartyModels = false
                    thirdPartyModelFetchError = "Invalid third-party base URL."
                    return
                }

                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                if config.provider.usesAnthropicFormat {
                    request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                } else {
                    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                }

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    isFetchingThirdPartyModels = false
                    thirdPartyModelFetchError = "Model list request failed."
                    return
                }

                guard http.statusCode == 200 else {
                    isFetchingThirdPartyModels = false
                    thirdPartyModelFetchError = "Failed to fetch models (HTTP \(http.statusCode))."
                    return
                }

                let snippet = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(220)
                    .lowercased() ?? ""
                if snippet.contains("<!doctype html") || snippet.contains("<html") {
                    isFetchingThirdPartyModels = false
                    thirdPartyModelFetchError = "Endpoint returned HTML, please verify API base URL."
                    return
                }

                let models = parseThirdPartyModelIDs(from: data)
                thirdPartyModelOptions = models
                isFetchingThirdPartyModels = false

                if models.isEmpty {
                    thirdPartyModelFetchError = "No models returned. You can input model ID manually."
                } else if !thirdPartyManualModel.isEmpty,
                          !models.contains(thirdPartyManualModel) {
                    thirdPartyManualModel = models[0]
                }
            } catch {
                isFetchingThirdPartyModels = false
                thirdPartyModelFetchError = "Could not fetch models: \(error.localizedDescription)"
            }
        }
    }

    private func parseThirdPartyModelIDs(from data: Data) -> [String] {
        struct ModelItem: Decodable {
            let id: String
        }
        struct DataResponse: Decodable {
            let data: [ModelItem]?
        }
        struct ModelsResponse: Decodable {
            let models: [ModelItem]?
        }

        if let decoded = try? JSONDecoder().decode(DataResponse.self, from: data),
           let items = decoded.data {
            return items.map(\.id).sorted()
        }

        if let decoded = try? JSONDecoder().decode([ModelItem].self, from: data) {
            return decoded.map(\.id).sorted()
        }

        if let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded.sorted()
        }

        if let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data),
           let items = decoded.models {
            return items.map(\.id).sorted()
        }

        return []
    }

    private func applyThirdPartyModel(_ model: String) {
        guard let config = thirdPartyPickerConfig else { return }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        UserDefaults.standard.set(trimmed, forKey: ThirdPartyProviderDefaults.modelKey)
        thirdPartyManualModel = trimmed
        thirdPartyPickerConfig = ThirdPartySelectionConfig(
            provider: config.provider,
            endpoint: config.endpoint,
            apiKey: config.apiKey,
            selectedModel: trimmed
        )

        switchModel(.thirdPartyAPI(
            provider: config.provider,
            endpoint: config.endpoint,
            model: trimmed
        ))
    }

    private func persistedThirdPartyConfig() -> ThirdPartySelectionConfig? {
        guard let kindRaw = UserDefaults.standard.string(forKey: ThirdPartyProviderDefaults.providerKindKey),
              let kind = ThirdPartyProvider(rawValue: kindRaw) else {
            return nil
        }
        let endpoint = (UserDefaults.standard.string(forKey: ThirdPartyProviderDefaults.baseURLKey) ?? kind.defaultBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = UserDefaults.standard.string(forKey: ThirdPartyProviderDefaults.modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let keychainKey = ThirdPartyProviderDefaults.keychainKey(for: kind)
        let apiKey = KeychainManager.shared.retrieve(for: keychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !endpoint.isEmpty, let apiKey, !apiKey.isEmpty else {
            return nil
        }

        return ThirdPartySelectionConfig(
            provider: kind,
            endpoint: endpoint,
            apiKey: apiKey,
            selectedModel: model
        )
    }

    private func persistedThirdPartyProvider() -> LLMProviderType? {
        guard let config = persistedThirdPartyConfig() else {
            return nil
        }
        return .thirdPartyAPI(provider: config.provider, endpoint: config.endpoint, model: config.selectedModel)
    }

    private func thirdPartySubtitle() -> String {
        if let config = persistedThirdPartyConfig() {
            if let model = config.selectedModel, !model.isEmpty {
                return "\(config.provider.displayName) · \(model)"
            }
            return config.provider.displayName
        }
        return "Configure in onboarding/settings"
    }

    // MARK: - CodeBlog Credit Model

    private var codeblogCreditModelShortName: String {
        guard !codeblogCreditModel.isEmpty else { return "CodeBlog AI" }
        // "claude-sonnet-4-6" → "Sonnet 4.6"
        let name = codeblogCreditModel
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-", with: " ")
        let parts = name.split(separator: " ")
        if parts.count >= 2, let family = parts.first {
            let version = parts.dropFirst().joined(separator: ".")
            return "\(family.prefix(1).uppercased())\(family.dropFirst()) \(version)"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private func fetchCodeBlogCreditModel() {
        guard let token = CodeBlogTokenResolver.currentToken(),
              let url = URL(string: "https://codeblog.ai/api/v1/ai-credit/balance") else { return }

        Task { @MainActor in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = json["model"] as? String, !model.isEmpty else { return }

            codeblogCreditModel = model
        }
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
