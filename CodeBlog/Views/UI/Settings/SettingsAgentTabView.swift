//
//  SettingsAgentTabView.swift
//  CodeBlog
//
//  Settings > Agent tab：心跳间隔、空闲触发、AI 配置同步
//

import SwiftUI

struct SettingsAgentTabView: View {
    @ObservedObject private var heartbeat = AgentHeartbeatService.shared

    @State private var lastSyncDate: Date? = AIProviderSyncService.shared.lastSyncDate
    @State private var isSyncing = false
    @State private var syncError: String? = nil
    @State private var syncSuccess = false

    // 心跳间隔 options
    private let intervalOptions = [15, 30, 60, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            heartbeatCard
            aiSyncCard
            debugCard
        }
    }

    // MARK: - Heartbeat Card

    private var heartbeatCard: some View {
        SettingsCard(title: "Agent Heartbeat", subtitle: "How often the Agent scans your coding session") {
            VStack(alignment: .leading, spacing: 16) {
                // Interval segmented control
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan interval")
                        .font(.custom("Nunito", size: 13).weight(.semibold))
                        .foregroundColor(.black.opacity(0.7))

                    Picker("Interval", selection: Binding(
                        get: { heartbeat.intervalMinutes },
                        set: { heartbeat.intervalMinutes = $0 }
                    )) {
                        ForEach(intervalOptions, id: \.self) { min in
                            Text("\(min) min").tag(min)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }

                // Idle trigger toggle
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Idle trigger")
                            .font(.custom("Nunito", size: 13).weight(.semibold))
                            .foregroundColor(.black.opacity(0.7))
                        Text("Also scan when you return from an idle period")
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

                // Status
                HStack(spacing: 8) {
                    Circle()
                        .fill(heartbeat.isRunning ? Color(hex: "34C759") : Color(hex: "AAAAAA"))
                        .frame(width: 8, height: 8)
                    Text(heartbeat.isRunning ? (heartbeat.isGenerating ? "Generating card…" : "Running") : "Paused")
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.5))
                    Spacer()
                    // Manual trigger button
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

    // MARK: - AI Sync Card

    private var aiSyncCard: some View {
        SettingsCard(title: "AI Provider Sync", subtitle: "Keep your web AI config in sync with the mac client") {
            VStack(alignment: .leading, spacing: 14) {
                // Sync status
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
                    // Sync button
                    Button {
                        Task { await performSync() }
                    } label: {
                        HStack(spacing: 4) {
                            if isSyncing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }
                            Text(isSyncing ? "Syncing…" : "Sync now")
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

    // MARK: - Helpers

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

    // MARK: - Debug Card (临时测试用，正式发布前可删除)

    private var debugCard: some View {
        SettingsCard(title: "🛠 Debug: Inject Test Cards", subtitle: "Temporarily inject fake Agent cards to verify Timeline UI") {
            VStack(alignment: .leading, spacing: 12) {
                Text("点击按钮向 Timeline 注入测试卡，刷新 Timeline 页面即可看到效果。")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.5))

                HStack(spacing: 8) {
                    debugInjectButton(label: "📝 Journal", type: "journal")
                    debugInjectButton(label: "💡 Insight", type: "insight")
                    debugInjectButton(label: "✦ Post", type: "post")

                    Spacer()

                    Button("清除全部测试卡") {
                        debugClearTestCards()
                    }
                    .buttonStyle(.plain)
                    .font(.custom("Nunito", size: 11))
                    .foregroundColor(.red.opacity(0.7))
                    .pointingHandCursor()
                }
            }
        }
    }

    private func debugInjectButton(label: String, type: String) -> some View {
        Button(label) {
            debugInjectCard(type: type)
        }
        .buttonStyle(.plain)
        .font(.custom("Nunito", size: 12).weight(.semibold))
        .foregroundColor(type == "journal" ? Color(hex: "9B7753") : Color(hex: "F96E00"))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background((type == "journal" ? Color(hex: "9B7753") : Color(hex: "F96E00")).opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((type == "journal" ? Color(hex: "9B7753") : Color(hex: "F96E00")).opacity(0.3), lineWidth: 0.5)
        )
        .pointingHandCursor()
    }

    private func debugInjectCard(type: String) {
        let now = Date()
        // 三种类型时间错开，确保在 Timeline 上各自独立显示
        let offsets: [String: TimeInterval] = [
            "journal": -3 * 3600,   // 3 小时前
            "insight": -2 * 3600,   // 2 小时前
            "post":    -1 * 3600    // 1 小时前
        ]
        let offset = offsets[type] ?? -3600
        let start = now.addingTimeInterval(offset - 45 * 60)
        let end   = now.addingTimeInterval(offset)
        let titles = [
            "journal": "调试：Journal 测试卡（普通记录）",
            "insight": "调试：Insight 测试卡（Agent 发现）",
            "post":    "调试：Post 测试卡（待发布内容）"
        ]
        let summaries = [
            "journal": "这是一条普通 Journal 记录，用于测试 Timeline 卡片 UI 样式。",
            "insight": "Agent 发现你今天完成了一个重要功能，代码质量很高，值得记录。",
            "post":    "今天实现了 Agent Heartbeat 机制，定时扫描并生成 Timeline 卡片，支持三种类型。"
        ]
        let details = [
            "journal": "详细内容：普通 journal 卡片，棕色调，无 action row。",
            "insight": "详细内容：**Insight 卡片** 高亮橙色，带「继续聊」和「整理成帖子」按钮。",
            "post":    "详细内容：**Post 卡片** 橙色调，带「发布」「继续聊」「跳过」按钮。\n\n支持 Markdown **加粗** 和 `代码` 格式。"
        ]
        _ = StorageManager.shared.saveAgentTimelineCard(
            startDate: start,
            endDate: end,
            title: titles[type] ?? "Test Card",
            summary: summaries[type] ?? "",
            detailedSummary: details[type] ?? "",
            agentCardType: type,
            previewId: type == "post" ? "debug-preview-\(UUID().uuidString.prefix(8))" : nil
        )
        NotificationCenter.default.post(name: .timelineDataUpdated, object: nil)
    }

    private func debugClearTestCards() {
        // 软删除所有 category=Agent 的 debug 测试卡
        // 通过 title 前缀匹配
        StorageManager.shared.debugDeleteAgentCards()
        NotificationCenter.default.post(name: .timelineDataUpdated, object: nil)
    }
}
