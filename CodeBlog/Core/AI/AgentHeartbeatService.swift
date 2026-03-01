//
//  AgentHeartbeatService.swift
//  CodeBlog
//
//  Agent 心跳引擎 — 定时调用 MCP preview_post，把 AI 生成的卡片写入 Timeline
//

import Foundation
import Combine
@preconcurrency import UserNotifications
import AppKit

@MainActor
final class AgentHeartbeatService: ObservableObject {
    static let shared = AgentHeartbeatService()

    @Published var isGenerating: Bool = false

    // Backed by UserDefaults; @Published so the menu bar slider re-renders on change.
    @Published var intervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(intervalMinutes, forKey: "agentHeartbeatIntervalMinutes")
            if isRunning { stop(); start() }
        }
    }

    // Backed by UserDefaults; @Published so Settings toggle re-renders.
    @Published var idleTriggerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(idleTriggerEnabled, forKey: "agentHeartbeatIdleTrigger")
        }
    }

    private(set) var isRunning: Bool = false
    private var timer: Timer?
    private var inactivitySub: AnyCancellable?
    private var lastRunAt: Date?
    private let minInterval: TimeInterval = 10 * 60  // 10-minute debounce

    private init() {
        let stored = UserDefaults.standard.integer(forKey: "agentHeartbeatIntervalMinutes")
        intervalMinutes = stored > 0 ? stored : 30
        let storedIdle = UserDefaults.standard.object(forKey: "agentHeartbeatIdleTrigger") as? Bool
        idleTriggerEnabled = storedIdle ?? true
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        isRunning = true

        scheduleTimer()
        subscribeToInactivity()
        print("[AgentHeartbeat] Started, interval=\(intervalMinutes)min")
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        inactivitySub = nil
        print("[AgentHeartbeat] Stopped")
    }

    func triggerNow() {
        Task { await runHeartbeat() }
    }

    // MARK: - Private

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(intervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runHeartbeat()
            }
        }
    }

    private func subscribeToInactivity() {
        inactivitySub = InactivityMonitor.shared.$pendingReset
            .filter { $0 == true }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.idleTriggerEnabled else { return }
                InactivityMonitor.shared.markHandledIfPending()
                Task { @MainActor [weak self] in
                    await self?.runHeartbeat()
                }
            }
    }

    private func runHeartbeat() async {
        // 前置检查：用户必须已登录
        guard CodeBlogTokenResolver.currentToken() != nil else {
            print("[AgentHeartbeat] No token, skipping heartbeat")
            return
        }

        // 防抖：距上次运行不足 minInterval 则跳过
        if let lastRunAt, Date().timeIntervalSince(lastRunAt) < minInterval {
            print("[AgentHeartbeat] Too soon since last run (\(Int(Date().timeIntervalSince(lastRunAt)))s), skipping")
            return
        }

        guard !isGenerating else {
            print("[AgentHeartbeat] Already generating, skipping")
            return
        }

        isGenerating = true
        lastRunAt = Date()
        defer { isGenerating = false }

        do {
            let result = try await MCPStdioClient.shared.callTool(
                name: "preview_post",
                arguments: ["mode": .string("auto")]
            )

            guard !result.isError else {
                print("[AgentHeartbeat] preview_post returned error: \(result.text)")
                return
            }

            guard let card = parsePreviewPostResult(result.text) else {
                // parsePreviewPostResult already prints the reason
                return
            }

            // 验证 card type 合法性
            let validTypes: Set<String> = ["journal", "insight", "post"]
            let cardType = validTypes.contains(card.type) ? card.type : "journal"
            if card.type != cardType {
                print("[AgentHeartbeat] Unknown card type '\(card.type)', defaulting to 'journal'")
            }

            StorageManager.shared.saveAgentTimelineCard(
                startDate: card.startDate,
                endDate: card.endDate,
                title: card.title,
                summary: card.summary,
                detailedSummary: card.content,
                agentCardType: cardType,
                previewId: card.previewId.isEmpty ? nil : card.previewId
            )

            NotificationCenter.default.post(name: .timelineDataUpdated, object: nil)

            if cardType == "insight" || cardType == "post" {
                sendSystemNotification(title: card.title, previewId: card.previewId)
            }

            print("[AgentHeartbeat] Card saved: type=\(cardType) title=\(card.title)")

        } catch {
            print("[AgentHeartbeat] Error during heartbeat: \(error)")
        }
    }

    // MARK: - Parsing

    private struct PreviewPostResult {
        let previewId: String
        let type: String       // "journal" | "insight" | "post"
        let title: String
        let summary: String
        let content: String
        let startDate: Date
        let endDate: Date
    }

    private func parsePreviewPostResult(_ text: String) -> PreviewPostResult? {
        guard let data = text.data(using: .utf8) else {
            print("[AgentHeartbeat] Cannot convert text to UTF-8 data")
            return nil
        }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[AgentHeartbeat] JSON root is not an object: \(text.prefix(200))")
                return nil
            }

            let previewId = json["preview_id"] as? String ?? ""
            let type = json["type"] as? String ?? "journal"
            let title = json["title"] as? String ?? "Agent 记录"
            let summary = json["summary"] as? String ?? ""
            let content = json["content"] as? String ?? summary

            let now = Date()
            let startDate = parseISODate(json["start_time"] as? String) ?? now.addingTimeInterval(-30 * 60)
            let endDate = parseISODate(json["end_time"] as? String) ?? now

            return PreviewPostResult(
                previewId: previewId,
                type: type,
                title: title,
                summary: summary,
                content: content,
                startDate: startDate,
                endDate: endDate
            )
        } catch {
            print("[AgentHeartbeat] JSON parse error: \(error) | text: \(text.prefix(200))")
            return nil
        }
    }

    private func parseISODate(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: str) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }

    // MARK: - System Notification

    private func sendSystemNotification(title: String, previewId: String) {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "Agent 有新发现"
        content.body = title
        content.sound = .default
        content.categoryIdentifier = "agent_heartbeat"
        content.userInfo = ["previewId": previewId]

        let uniquePart = previewId.isEmpty ? UUID().uuidString : previewId
        let identifier = "agent.heartbeat.\(uniquePart)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.add(request) { error in
            if let error {
                print("[AgentHeartbeat] Failed to send notification: \(error)")
            }
        }
    }
}
