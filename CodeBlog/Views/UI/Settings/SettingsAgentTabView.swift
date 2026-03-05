//
//  SettingsAgentTabView.swift
//  CodeBlog
//
//  Settings > Agent tab
//

import SwiftUI

struct SettingsAgentTabView: View {
    @ObservedObject private var heartbeat = AgentHeartbeatService.shared
    @StateObject private var autonomousSettings = AgentSettingsViewModel()

    @AppStorage("agentNotificationsMuted") private var agentNotificationsMuted = false
    @AppStorage("aiProviderAutoSyncEnabled") private var aiProviderAutoSyncEnabled = true

    @State private var lastSyncDate: Date? = AIProviderSyncService.shared.lastSyncDate
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var syncSuccess = false

    private let intervalOptions = [15, 30, 60, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            heartbeatCard
            autonomousCard
            notificationsCard
            aiSyncCard
        }
        .task {
            await autonomousSettings.loadIfNeeded()
        }
    }

    private var heartbeatCard: some View {
        SettingsCard(title: "Agent Heartbeat", subtitle: "How often the local agent scans your coding session") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan interval")
                        .font(.custom("Nunito", size: 13).weight(.semibold))
                        .foregroundColor(.black.opacity(0.7))

                    Picker("Interval", selection: Binding(
                        get: { heartbeat.intervalMinutes },
                        set: { heartbeat.intervalMinutes = $0 }
                    )) {
                        ForEach(intervalOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Idle trigger")
                            .font(.custom("Nunito", size: 13).weight(.semibold))
                            .foregroundColor(.black.opacity(0.7))
                        Text("Run one extra scan when you return from idle.")
                            .font(.custom("Nunito", size: 11))
                            .foregroundColor(.black.opacity(0.4))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { heartbeat.idleTriggerEnabled },
                        set: { heartbeat.idleTriggerEnabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(heartbeat.isRunning ? Color(hex: "34C759") : Color(hex: "AAAAAA"))
                        .frame(width: 8, height: 8)
                    Text(heartbeat.isRunning ? (heartbeat.isGenerating ? "Generating card..." : "Running") : "Paused")
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.5))
                    Spacer()
                    Button("Scan now") {
                        heartbeat.triggerNow()
                    }
                    .buttonStyle(.plain)
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(Color(hex: "F96E00"))
                    .disabled(!heartbeat.isRunning || heartbeat.isGenerating)
                    .pointingHandCursor()
                }
            }
        }
    }

    private var autonomousCard: some View {
        SettingsCard(title: "Autonomous Agent (Web)", subtitle: "Configure cloud-side autonomous behavior for the current agent") {
            VStack(alignment: .leading, spacing: 14) {
                if autonomousSettings.isLoading && !autonomousSettings.hasLoaded {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading autonomous settings...")
                            .font(.custom("Nunito", size: 12))
                            .foregroundColor(.black.opacity(0.55))
                    }
                } else if let loadError = autonomousSettings.loadError {
                    Text(loadError)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(Color(hex: "D64545"))
                    HStack {
                        CodeBlogSurfaceButton(
                            action: { Task { await autonomousSettings.reload() } },
                            content: {
                                Text("Retry")
                                    .font(.custom("Nunito", size: 12))
                                    .fontWeight(.semibold)
                            },
                            background: Color.white,
                            foreground: Color(red: 0.25, green: 0.17, blue: 0),
                            borderColor: Color(hex: "FFE0A5"),
                            cornerRadius: 8,
                            horizontalPadding: 12,
                            verticalPadding: 7,
                            showOverlayStroke: true
                        )
                        Spacer()
                    }
                }

                if autonomousSettings.hasLoaded {
                    if !autonomousSettings.currentAgentName.isEmpty {
                        Text("Current agent: \(autonomousSettings.currentAgentName)")
                            .font(.custom("Nunito", size: 12))
                            .foregroundColor(.black.opacity(0.5))
                    }

                    if !autonomousSettings.agentActivated {
                        Text("This agent is not activated on web yet. Autonomous runs will stay paused until activation is complete.")
                            .font(.custom("Nunito", size: 11.5))
                            .foregroundColor(Color(hex: "B26A1D"))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle(isOn: $autonomousSettings.autonomousEnabled) {
                        Text("Enable autonomous mode")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(.black.opacity(0.72))
                    }
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Autonomous rules")
                            .font(.custom("Nunito", size: 13))
                            .fontWeight(.semibold)
                            .foregroundColor(.black.opacity(0.72))

                        TextEditor(text: $autonomousSettings.autonomousRules)
                            .font(.custom("Nunito", size: 12))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 90)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.85))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color(hex: "FFE0A5"), lineWidth: 1)
                                    )
                            )

                        Text("Focus guidance that helps the agent decide what to do while running in the background.")
                            .font(.custom("Nunito", size: 11))
                            .foregroundColor(.black.opacity(0.42))
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Run every (minutes)")
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.55))
                            TextField("30", text: $autonomousSettings.autonomousRunEveryMinutesText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Daily token limit")
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.55))
                            TextField("100000", text: $autonomousSettings.autonomousDailyTokenLimitText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                        }
                    }

                    HStack(spacing: 16) {
                        Text("Daily tokens used: \(autonomousSettings.autonomousDailyTokensUsed)")
                            .font(.custom("Nunito", size: 12))
                            .foregroundColor(.black.opacity(0.5))

                        if let pausedReason = autonomousSettings.autonomousPausedReason, !pausedReason.isEmpty {
                            Text("Paused reason: \(pausedReason)")
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(Color(hex: "B64C38"))
                        }
                    }

                    HStack(spacing: 10) {
                        CodeBlogSurfaceButton(
                            action: { Task { await autonomousSettings.save() } },
                            content: {
                                HStack(spacing: 8) {
                                    if autonomousSettings.isSaving {
                                        ProgressView()
                                            .scaleEffect(0.75)
                                    } else {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    Text(autonomousSettings.isSaving ? "Saving..." : "Save autonomous settings")
                                        .font(.custom("Nunito", size: 12))
                                        .fontWeight(.semibold)
                                }
                            },
                            background: Color(red: 0.25, green: 0.17, blue: 0),
                            foreground: .white,
                            borderColor: .clear,
                            cornerRadius: 8,
                            horizontalPadding: 14,
                            verticalPadding: 8,
                            showOverlayStroke: true
                        )
                        .disabled(autonomousSettings.isSaving || autonomousSettings.isLoading)

                        CodeBlogSurfaceButton(
                            action: { Task { await autonomousSettings.reload() } },
                            content: {
                                Text("Reload")
                                    .font(.custom("Nunito", size: 12))
                                    .fontWeight(.semibold)
                            },
                            background: Color.white,
                            foreground: Color(red: 0.25, green: 0.17, blue: 0),
                            borderColor: Color(hex: "FFE0A5"),
                            cornerRadius: 8,
                            horizontalPadding: 12,
                            verticalPadding: 8,
                            showOverlayStroke: true
                        )
                        .disabled(autonomousSettings.isLoading || autonomousSettings.isSaving)
                    }

                    if let successMessage = autonomousSettings.saveSuccessMessage {
                        Text(successMessage)
                            .font(.custom("Nunito", size: 11.5))
                            .foregroundColor(Color(hex: "2E8B57"))
                    }

                    if let saveError = autonomousSettings.saveError {
                        Text(saveError)
                            .font(.custom("Nunito", size: 11.5))
                            .foregroundColor(Color(hex: "D64545"))
                    }
                }
            }
        }
    }

    private var notificationsCard: some View {
        SettingsCard(title: "Agent notifications", subtitle: "Control macOS system notifications for agent events") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $agentNotificationsMuted) {
                    Text("Mute agent system notifications")
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.72))
                }
                .toggleStyle(.switch)

                Text("When enabled, heartbeat and daily report banners are silent. Journal reminder notifications stay enabled.")
                    .font(.custom("Nunito", size: 11.5))
                    .foregroundColor(.black.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aiSyncCard: some View {
        SettingsCard(title: "AI Provider Sync", subtitle: "Keep your web AI provider aligned with this mac client") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $aiProviderAutoSyncEnabled) {
                    Text("Auto sync on app launch")
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.72))
                }
                .toggleStyle(.switch)

                HStack(spacing: 6) {
                    if let date = lastSyncDate {
                        Text("Last synced: \(relativeTimeString(date))")
                            .font(.custom("Nunito", size: 12))
                            .foregroundColor(.black.opacity(0.45))
                    } else {
                        Text("Not synced yet")
                            .font(.custom("Nunito", size: 12))
                            .foregroundColor(.black.opacity(0.45))
                    }
                    Spacer()
                    Button {
                        Task { await performSync() }
                    } label: {
                        HStack(spacing: 4) {
                            if isSyncing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }
                            Text(isSyncing ? "Syncing..." : "Sync now")
                        }
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(syncSuccess ? Color(hex: "34C759") : Color(hex: "F96E00"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(hex: "F96E00").opacity(0.08))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSyncing)
                    .pointingHandCursor()
                }

                if let error = syncError {
                    Text(error)
                        .font(.custom("Nunito", size: 11))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(2)
                }

                if !AIProviderSyncService.shared.isSyncable {
                    Text("Current provider (Ollama / ChatGPT / CodeBlog Backend) is not syncable to web.")
                        .font(.custom("Nunito", size: 11))
                        .foregroundColor(.black.opacity(0.4))
                }
            }
        }
    }

    private func performSync() async {
        isSyncing = true
        syncError = nil
        syncSuccess = false
        defer { isSyncing = false }

        do {
            try await AIProviderSyncService.shared.pushToWeb()
            lastSyncDate = AIProviderSyncService.shared.lastSyncDate
            syncSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                syncSuccess = false
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func relativeTimeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

@MainActor
final class AgentSettingsViewModel: ObservableObject {
    @Published var hasLoaded = false
    @Published var isLoading = false
    @Published var isSaving = false

    @Published var loadError: String?
    @Published var saveError: String?
    @Published var saveSuccessMessage: String?

    @Published var currentAgentName = ""
    @Published var agentActivated = false
    @Published var autonomousEnabled = false
    @Published var autonomousRules = ""
    @Published var autonomousRunEveryMinutesText = "30"
    @Published var autonomousDailyTokenLimitText = "100000"
    @Published var autonomousDailyTokensUsed = 0
    @Published var autonomousPausedReason: String?

    private var currentAgentId: String?

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        saveError = nil
        saveSuccessMessage = nil
        defer { isLoading = false }

        guard let apiKey = CodeBlogTokenResolver.currentToken() else {
            loadError = "Sign in to load autonomous settings."
            return
        }

        do {
            let agents = try await CodeBlogAPIService.shared.listAgents(apiKey: apiKey)
            guard let currentAgent = resolveCurrentAgent(from: agents) else {
                loadError = "No agent found for this account."
                return
            }

            let detail = try await CodeBlogAPIService.shared.getAgentDetail(apiKey: apiKey, agentId: currentAgent.id)
            apply(detail)
            hasLoaded = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    func save() async {
        guard !isSaving else { return }
        saveError = nil
        saveSuccessMessage = nil

        guard let apiKey = CodeBlogTokenResolver.currentToken() else {
            saveError = "Sign in to save autonomous settings."
            return
        }

        guard let agentId = currentAgentId else {
            saveError = "No active agent loaded."
            return
        }

        let runEveryValue = autonomousRunEveryMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenLimitValue = autonomousDailyTokenLimitText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runEveryMinutes = Int(runEveryValue), (15...720).contains(runEveryMinutes) else {
            saveError = "Run every must be between 15 and 720 minutes."
            return
        }
        guard let dailyTokenLimit = Int(tokenLimitValue), (1000...2_000_000).contains(dailyTokenLimit) else {
            saveError = "Daily token limit must be between 1000 and 2000000."
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let updated = try await CodeBlogAPIService.shared.updateAgentAutonomous(
                apiKey: apiKey,
                agentId: agentId,
                autonomousEnabled: autonomousEnabled,
                autonomousRules: autonomousRules.trimmingCharacters(in: .whitespacesAndNewlines),
                autonomousRunEveryMinutes: runEveryMinutes,
                autonomousDailyTokenLimit: dailyTokenLimit
            )
            apply(updated)
            saveSuccessMessage = "Autonomous settings saved."
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func apply(_ detail: CodeBlogAPIService.AgentDetail) {
        currentAgentId = detail.id
        currentAgentName = detail.name
        agentActivated = detail.activated
        autonomousEnabled = detail.autonomousEnabled
        autonomousRules = detail.autonomousRules ?? ""
        autonomousRunEveryMinutesText = String(detail.autonomousRunEveryMinutes ?? 30)
        autonomousDailyTokenLimitText = String(detail.autonomousDailyTokenLimit ?? 100000)
        autonomousDailyTokensUsed = detail.autonomousDailyTokensUsed ?? 0
        autonomousPausedReason = detail.autonomousPausedReason
    }

    private func resolveCurrentAgent(
        from agents: [CodeBlogAPIService.AgentInfo]
    ) -> CodeBlogAPIService.AgentInfo? {
        if let current = agents.first(where: { $0.is_current }) {
            return current
        }

        if let storedId = UserDefaults.standard.string(forKey: "codeblog_agent_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !storedId.isEmpty,
           let matched = agents.first(where: { $0.id == storedId }) {
            return matched
        }

        return agents.first
    }
}
