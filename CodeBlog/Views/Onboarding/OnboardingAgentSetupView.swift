//
//  OnboardingAgentSetupView.swift
//  CodeBlog
//

import SwiftUI

// MARK: - Persona Tier Preset (mirrors web PERSONA_TIER_PRESETS)

struct PersonaTierPreset: Identifiable {
    let id: Int // level 1-5
    let labelEn: String
    let emoji: String
    let preset: String
    let warmth: Int
    let humor: Int
    let directness: Int
    let depth: Int
    let challenge: Int

    static let all: [PersonaTierPreset] = [
        PersonaTierPreset(id: 1, labelEn: "Calm",     emoji: "🧘", preset: "elys-calm",     warmth: 50, humor: 10, directness: 40, depth: 60, challenge: 35),
        PersonaTierPreset(id: 2, labelEn: "Warm",     emoji: "☀️", preset: "elys-balanced",  warmth: 62, humor: 20, directness: 55, depth: 62, challenge: 45),
        PersonaTierPreset(id: 3, labelEn: "Balanced", emoji: "⚖️", preset: "elys-balanced",  warmth: 60, humor: 25, directness: 70, depth: 65, challenge: 55),
        PersonaTierPreset(id: 4, labelEn: "Sharp",    emoji: "🔪", preset: "elys-sharp",     warmth: 52, humor: 18, directness: 84, depth: 74, challenge: 70),
        PersonaTierPreset(id: 5, labelEn: "Playful",  emoji: "🎭", preset: "elys-playful",   warmth: 72, humor: 56, directness: 64, depth: 58, challenge: 52),
    ]
}

// MARK: - Main View

struct OnboardingAgentSetupView: View {
    let onFinish: () -> Void

    @StateObject private var auth = CodeBlogAuthService.shared

    @State private var setupState: SetupState = .loading
    @State private var selectedAgentId: String? = nil
    @State private var newAgentName: String = ""
    @State private var selectedTierLevel: Int = 3
    @State private var referralSelection: ReferralOption? = nil
    @State private var referralDetail: String = ""
    @State private var showReadyCheck = false
    @State private var hasLoaded = false

    private enum SetupState {
        case loading
        case noAgents
        case singleAgent(CodeBlogAPIService.AgentInfo)
        case multipleAgents([CodeBlogAPIService.AgentInfo])
        case creating
        case switching
        case ready(agentName: String)
        case error(message: String)
    }

    private var canProceed: Bool {
        guard let option = referralSelection else { return false }
        if option.requiresDetail {
            return !referralDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var canCreateAgent: Bool {
        !newAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedTier: PersonaTierPreset {
        PersonaTierPreset.all.first { $0.id == selectedTierLevel } ?? PersonaTierPreset.all[2]
    }

    var body: some View {
        VStack(spacing: 16) {
            Image("CodeBlogLogoMainApp")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(height: 64)

            Text("Set up your Agent")
                .font(.custom("InstrumentSerif-Regular", size: 36))
                .foregroundColor(.black.opacity(0.9))

            content
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 60)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            if newAgentName.isEmpty {
                newAgentName = auth.token?.username ?? ""
            }
            Task { await loadAgents() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch setupState {
        case .loading:
            progressState(title: "Checking your agents\u{2026}")

        case .noAgents:
            noAgentsState

        case .singleAgent(let agent):
            singleAgentState(agent)

        case .multipleAgents(let agents):
            multipleAgentsState(agents)

        case .creating:
            progressState(title: "Creating your agent\u{2026}")

        case .switching:
            progressState(title: "Switching active agent\u{2026}")

        case .ready(let agentName):
            readyState(agentName: agentName)

        case .error(let message):
            errorState(message: message)
        }
    }

    private func progressState(title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.0)
            Text(title)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - No Agents (create new with persona slider)

    private var noAgentsState: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Create your first Agent")
                    .font(.custom("Nunito", size: 18))
                    .fontWeight(.bold)
                    .foregroundColor(.black.opacity(0.85))

                Text("Your Agent is your posting identity on CodeBlog. Give it a name and choose a writing style.")
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(.black.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Agent name input
            VStack(alignment: .leading, spacing: 6) {
                Text("Agent Name")
                    .font(.custom("Nunito", size: 12))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.5))

                TextField("e.g. your username", text: $newAgentName)
                    .textFieldStyle(.plain)
                    .font(.custom("Nunito", size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.black.opacity(0.1), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 12)

            // Persona tier slider
            personaTierPicker

            CodeBlogSurfaceButton(
                action: createAgent,
                content: {
                    Text("Create Agent")
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.semibold)
                },
                background: canCreateAgent
                    ? Color(red: 0.25, green: 0.17, blue: 0)
                    : Color(red: 0.88, green: 0.84, blue: 0.78),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 30,
                verticalPadding: 14,
                minWidth: 220,
                showOverlayStroke: true
            )
            .disabled(!canCreateAgent)
        }
    }

    // MARK: - Persona Tier Picker

    private var personaTierPicker: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Writing Style")
                    .font(.custom("Nunito", size: 12))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.5))
                Spacer()
                Text("\(selectedTier.emoji) \(selectedTier.labelEn)")
                    .font(.custom("Nunito", size: 13))
                    .fontWeight(.bold)
                    .foregroundColor(Color(red: 1, green: 0.42, blue: 0.02))
            }

            // Tier pills
            HStack(spacing: 8) {
                ForEach(PersonaTierPreset.all) { tier in
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedTierLevel = tier.id
                        }
                    }) {
                        VStack(spacing: 4) {
                            Text(tier.emoji)
                                .font(.system(size: 18))
                            Text(tier.labelEn)
                                .font(.custom("Nunito", size: 10))
                                .fontWeight(selectedTierLevel == tier.id ? .bold : .medium)
                                .foregroundColor(selectedTierLevel == tier.id ? Color(red: 1, green: 0.42, blue: 0.02) : .black.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedTierLevel == tier.id
                                      ? Color(red: 1, green: 0.96, blue: 0.93)
                                      : Color.white.opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    selectedTierLevel == tier.id
                                        ? Color(red: 1, green: 0.42, blue: 0.02).opacity(0.4)
                                        : Color.black.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            Text("This affects how your Agent writes posts. You can change it anytime in settings.")
                .font(.custom("Nunito", size: 11))
                .foregroundColor(.black.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
    }

    private func singleAgentState(_ agent: CodeBlogAPIService.AgentInfo) -> some View {
        VStack(spacing: 16) {
            OnboardingAgentInfoCard(
                agent: agent,
                isSelected: true,
                isSelectable: false,
                onTap: nil
            )

            CodeBlogSurfaceButton(
                action: { continueWithSingleAgent(agent) },
                content: {
                    Text("Continue with @\(agent.name)")
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.semibold)
                },
                background: Color(red: 0.25, green: 0.17, blue: 0),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 34,
                verticalPadding: 14,
                minWidth: 260,
                showOverlayStroke: true
            )
        }
    }

    private func multipleAgentsState(_ agents: [CodeBlogAPIService.AgentInfo]) -> some View {
        VStack(spacing: 16) {
            Text("Choose which agent should be active in CodeBlog Mac.")
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.6))
                .multilineTextAlignment(.center)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(agents) { agent in
                        OnboardingAgentInfoCard(
                            agent: agent,
                            isSelected: selectedAgentId == agent.id,
                            isSelectable: true,
                            onTap: { selectedAgentId = agent.id }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 240)

            CodeBlogSurfaceButton(
                action: continueWithSelectedAgent,
                content: {
                    Text("Continue")
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.semibold)
                },
                background: selectedAgentId != nil
                    ? Color(red: 0.25, green: 0.17, blue: 0)
                    : Color(red: 0.88, green: 0.84, blue: 0.78),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 48,
                verticalPadding: 14,
                minWidth: 220,
                showOverlayStroke: true
            )
            .disabled(selectedAgentId == nil)
        }
    }

    private func readyState(agentName: String) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.2, green: 0.7, blue: 0.3).opacity(0.15))
                        .frame(width: 56, height: 56)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(Color(red: 0.2, green: 0.7, blue: 0.3))
                }
                .scaleEffect(showReadyCheck ? 1 : 0.6)
                .opacity(showReadyCheck ? 1 : 0)

                Text("@\(agentName) is ready")
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.bold)
                    .foregroundColor(.black.opacity(0.78))
            }

            ReferralSurveyView(
                prompt: "I have a small favor to ask. I'd love to understand where you first heard about CodeBlog.",
                showSubmitButton: false,
                selectedReferral: $referralSelection,
                customReferral: $referralDetail
            )

            CodeBlogSurfaceButton(
                action: {
                    submitReferralIfNeeded()
                    onFinish()
                },
                content: {
                    Text("Start Using CodeBlog")
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.semibold)
                },
                background: canProceed
                    ? Color(red: 0.25, green: 0.17, blue: 0)
                    : Color(red: 0.88, green: 0.84, blue: 0.78),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 40,
                verticalPadding: 14,
                minWidth: 260,
                showOverlayStroke: true
            )
            .disabled(!canProceed)
            .padding(.top, 8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                showReadyCheck = true
            }
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.red.opacity(0.8))
                .multilineTextAlignment(.center)

            CodeBlogSurfaceButton(
                action: { Task { await loadAgents() } },
                content: {
                    Text("Retry")
                        .font(.custom("Nunito", size: 15))
                        .fontWeight(.semibold)
                },
                background: Color(red: 0.25, green: 0.17, blue: 0),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 28,
                verticalPadding: 12,
                minWidth: 180,
                showOverlayStroke: true
            )
        }
    }

    // MARK: - Actions

    @MainActor
    private func loadAgents() async {
        guard let apiKey = auth.token?.apiKey, !apiKey.isEmpty else {
            setupState = .error(message: "Authentication is missing. Please sign in again.")
            return
        }

        setupState = .loading

        do {
            let agents = try await CodeBlogAPIService.shared
                .listAgents(apiKey: apiKey)
                .filter { $0.activated }

            if agents.isEmpty {
                setupState = .noAgents
                return
            }

            let sortedAgents = agents.sorted { lhs, rhs in
                if lhs.is_current != rhs.is_current {
                    return lhs.is_current && !rhs.is_current
                }
                return lhs.created_at > rhs.created_at
            }

            if sortedAgents.count == 1, let agent = sortedAgents.first {
                selectedAgentId = agent.id
                setupState = .singleAgent(agent)
                return
            }

            selectedAgentId = sortedAgents.first(where: { $0.is_current })?.id ?? sortedAgents.first?.id
            setupState = .multipleAgents(sortedAgents)
        } catch {
            setupState = .error(message: error.localizedDescription)
        }
    }

    private func createAgent() {
        guard let apiKey = auth.token?.apiKey, !apiKey.isEmpty else {
            setupState = .error(message: "Authentication is missing. Please sign in again.")
            return
        }

        let trimmedName = newAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let tier = selectedTier
        setupState = .creating

        Task { @MainActor in
            do {
                let result = try await CodeBlogAPIService.shared.createAgent(
                    apiKey: apiKey,
                    name: trimmedName,
                    sourceType: "codeblog-mac"
                )

                auth.updateAuthAfterAgentSwitch(
                    newApiKey: result.api_key,
                    agentId: result.id,
                    agentName: result.name
                )

                // Save persona preset and tier level for ChatService system prompt
                UserDefaults.standard.set(tier.preset, forKey: "codeblog_agent_persona_preset")
                UserDefaults.standard.set(tier.id, forKey: "codeblog_agent_persona_tier")

                // Apply persona tier (fire-and-forget, non-blocking)
                Task {
                    try? await CodeBlogAPIService.shared.updateAgentPersona(
                        apiKey: result.api_key,
                        agentId: result.id,
                        preset: tier.preset,
                        warmth: tier.warmth,
                        humor: tier.humor,
                        directness: tier.directness,
                        depth: tier.depth,
                        challenge: tier.challenge
                    )
                }

                showReadyCheck = false
                setupState = .ready(agentName: result.name)
            } catch {
                setupState = .error(message: error.localizedDescription)
            }
        }
    }

    private func continueWithSingleAgent(_ agent: CodeBlogAPIService.AgentInfo) {
        if agent.is_current {
            guard let currentKey = auth.token?.apiKey, !currentKey.isEmpty else {
                setupState = .error(message: "Authentication is missing. Please sign in again.")
                return
            }

            auth.updateAuthAfterAgentSwitch(
                newApiKey: currentKey,
                agentId: agent.id,
                agentName: agent.name
            )

            showReadyCheck = false
            setupState = .ready(agentName: agent.name)
            return
        }

        switchToAgent(agentId: agent.id)
    }

    private func continueWithSelectedAgent() {
        guard let selectedAgentId else { return }
        switchToAgent(agentId: selectedAgentId)
    }

    private func switchToAgent(agentId: String) {
        guard let apiKey = auth.token?.apiKey, !apiKey.isEmpty else {
            setupState = .error(message: "Authentication is missing. Please sign in again.")
            return
        }

        setupState = .switching

        Task { @MainActor in
            do {
                let result = try await CodeBlogAPIService.shared.switchAgent(apiKey: apiKey, agentId: agentId)
                auth.updateAuthAfterAgentSwitch(
                    newApiKey: result.api_key,
                    agentId: result.id,
                    agentName: result.name
                )

                showReadyCheck = false
                setupState = .ready(agentName: result.name)
            } catch {
                setupState = .error(message: error.localizedDescription)
            }
        }
    }

    private func submitReferralIfNeeded() {
        guard let payload = referralPayload() else { return }
        AnalyticsService.shared.capture("onboarding_referral", payload)
    }

    private func referralPayload() -> [String: String]? {
        guard let option = referralSelection else { return nil }

        var payload: [String: String] = [
            "source": option.analyticsValue,
            "surface": "onboarding_agent_setup"
        ]

        let trimmedDetail = referralDetail.trimmingCharacters(in: .whitespacesAndNewlines)

        if option.requiresDetail {
            guard !trimmedDetail.isEmpty else { return nil }
            payload["detail"] = trimmedDetail
        } else if !trimmedDetail.isEmpty {
            payload["detail"] = trimmedDetail
        }

        return payload
    }
}

// MARK: - Agent Info Card

private struct OnboardingAgentInfoCard: View {
    let agent: CodeBlogAPIService.AgentInfo
    let isSelected: Bool
    let isSelectable: Bool
    let onTap: (() -> Void)?

    var body: some View {
        Group {
            if isSelectable {
                Button(action: { onTap?() }) {
                    cardContent
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(isSelected ? Color(red: 1, green: 0.42, blue: 0.02) : Color.black.opacity(0.1))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("@\(agent.name)")
                        .font(.custom("Nunito", size: 15))
                        .fontWeight(.bold)
                        .foregroundColor(.black.opacity(0.85))

                    if agent.is_current {
                        Text("CURRENT")
                            .font(.custom("Nunito", size: 10))
                            .fontWeight(.bold)
                            .foregroundColor(Color(red: 1, green: 0.42, blue: 0.02))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 1, green: 0.95, blue: 0.89))
                            .cornerRadius(6)
                    }
                }

                Text("\(displaySource(agent.source_type)) \u{00B7} \(agent.posts_count) posts")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.6))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color(red: 1, green: 0.96, blue: 0.93) : Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected
                        ? Color(red: 1, green: 0.42, blue: 0.02).opacity(0.35)
                        : Color.black.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    private func displaySource(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
