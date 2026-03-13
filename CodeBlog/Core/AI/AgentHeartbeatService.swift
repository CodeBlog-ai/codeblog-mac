//
//  AgentHeartbeatService.swift
//  CodeBlog
//
//  Agent heartbeat engine: periodically calls MCP preview_post and writes cards into Timeline.
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
    private var cachedDailyReportHour: Int = 22
    private var lastDailyReportHourFetchAt: Date?
    private var lastDailyReportAttemptDay: String?
    private let dailyReportHourRefreshInterval: TimeInterval = 6 * 60 * 60
    private var manualDailyReportPendingDay: String?
    private var manualDailyReportPendingAt: Date?
    private let manualDailyReportPendingTTL: TimeInterval = 45 * 60
    private var dailyReportObservers: [NSObjectProtocol] = []
    private var lastDailyReportActivationReminderDay: String?

    private enum DailyReportActivationStatus {
        case activated
        case notActivated
        case verificationFailed
    }

    private init() {
        let stored = UserDefaults.standard.integer(forKey: "agentHeartbeatIntervalMinutes")
        intervalMinutes = stored > 0 ? stored : 30
        let storedIdle = UserDefaults.standard.object(forKey: "agentHeartbeatIdleTrigger") as? Bool
        idleTriggerEnabled = storedIdle ?? true
        configureDailyReportObservers()
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
        // Prerequisite: the user must be logged in.
        guard let apiKey = CodeBlogTokenResolver.currentToken() else {
            print("[AgentHeartbeat] No token, skipping heartbeat")
            return
        }

        // Debounce: skip when the last run is too recent.
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

        if await tryRunDailyReportIfNeeded(apiKey: apiKey) {
            return
        }

        do {
            try await runAutoPreviewHeartbeat()
        } catch {
            print("[AgentHeartbeat] Error during heartbeat: \(error)")
        }
    }

    private func configureDailyReportObservers() {
        let center = NotificationCenter.default

        let manualTriggerObserver = center.addObserver(
            forName: .injectAgentPostToChat,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let cardType = notification.userInfo?["cardType"] as? String,
                  cardType == "daily_report" else {
                return
            }
            self.manualDailyReportPendingDay = Date().getDayInfoFor4AMBoundary().dayString
            self.manualDailyReportPendingAt = Date()
        }

        let publishedObserver = center.addObserver(
            forName: .agentDailyReportPublished,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearManualDailyReportPending()
        }

        dailyReportObservers = [manualTriggerObserver, publishedObserver]
    }

    private func clearManualDailyReportPending() {
        manualDailyReportPendingDay = nil
        manualDailyReportPendingAt = nil
    }

    private func isManualDailyReportPending(for dayString: String, now: Date) -> Bool {
        guard manualDailyReportPendingDay == dayString else { return false }
        guard let manualDailyReportPendingAt else {
            clearManualDailyReportPending()
            return false
        }
        if now.timeIntervalSince(manualDailyReportPendingAt) > manualDailyReportPendingTTL {
            clearManualDailyReportPending()
            return false
        }
        return true
    }

    private func runAutoPreviewHeartbeat() async throws {
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

        let validTypes: Set<String> = ["journal", "insight", "post", "exploration"]
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

        if cardType == "insight" || cardType == "post" || cardType == "exploration" {
            sendSystemNotification(title: card.title, previewId: card.previewId)
        }

        print("[AgentHeartbeat] Card saved: type=\(cardType) title=\(card.title)")
    }

    private func tryRunDailyReportIfNeeded(apiKey: String) async -> Bool {
        let now = Date()
        let dayInfo = now.getDayInfoFor4AMBoundary()
        let dayString = dayInfo.dayString

        if isManualDailyReportPending(for: dayString, now: now) {
            print("[AgentHeartbeat] Manual daily report is in progress, skipping auto trigger")
            // Manual chat-triggered daily report should block heartbeat MCP calls to avoid concurrency.
            return true
        }

        let autoHour = await resolveDailyReportHour()
        guard autoHour >= 0 else { return false }

        let currentHour = Calendar.current.component(.hour, from: now)
        guard currentHour >= autoHour else { return false }

        switch await currentAgentActivationStatus(apiKey: apiKey) {
        case .activated:
            break
        case .notActivated:
            if lastDailyReportActivationReminderDay != dayString {
                sendDailyReportActivationRequiredNotification()
                lastDailyReportActivationReminderDay = dayString
            }
            print("[AgentHeartbeat] Current agent is not activated, skipping daily report")
            return false
        case .verificationFailed:
            print("[AgentHeartbeat] Failed to verify agent activation, skipping daily report")
            return false
        }

        if lastDailyReportAttemptDay == dayString {
            return false
        }

        let alreadyPublished = await hasPublishedDailyReport(dayString: dayString, apiKey: apiKey)
        if alreadyPublished {
            lastDailyReportAttemptDay = dayString
            clearManualDailyReportPending()
            return false
        }

        do {
            let published = try await runDailyReportFlow(dayString: dayString)
            if published {
                lastDailyReportAttemptDay = dayString
                clearManualDailyReportPending()
                return true
            }
            return false
        } catch {
            print("[AgentHeartbeat] Daily report flow failed: \(error)")
            return false
        }
    }

    private func resolveDailyReportHour() async -> Int {
        let now = Date()
        if let lastFetch = lastDailyReportHourFetchAt,
           now.timeIntervalSince(lastFetch) < dailyReportHourRefreshInterval {
            return cachedDailyReportHour
        }

        do {
            let result = try await MCPStdioClient.shared.callTool(
                name: "configure_daily_report",
                arguments: ["get": .bool(true)]
            )

            if !result.isError,
               let json = parseJSONObject(from: result.text) {
                if let enabled = json["enabled"] as? Bool, enabled == false {
                    cachedDailyReportHour = -1
                } else if let hour = json["auto_hour"] as? Int {
                    cachedDailyReportHour = hour
                } else if let hour = json["auto_hour"] as? Double {
                    cachedDailyReportHour = Int(hour.rounded())
                }
            }
        } catch {
            print("[AgentHeartbeat] Failed to resolve daily report hour: \(error)")
        }

        lastDailyReportHourFetchAt = now
        return cachedDailyReportHour
    }

    private func hasPublishedDailyReport(dayString: String, apiKey: String) async -> Bool {
        do {
            let reports = try await CodeBlogAPIService.shared.listDailyReports(
                apiKey: apiKey,
                limit: 1,
                from: dayString,
                to: dayString
            )
            return reports.contains { report in
                if let postId = report.post_id, !postId.isEmpty {
                    return true
                }
                return false
            }
        } catch {
            print("[AgentHeartbeat] Failed to check existing daily report: \(error)")
            return false
        }
    }

    private func currentAgentActivationStatus(apiKey: String) async -> DailyReportActivationStatus {
        do {
            let agents = try await CodeBlogAPIService.shared.listAgents(apiKey: apiKey)
            guard let currentAgent = currentAgentInfo(from: agents) else {
                return .notActivated
            }
            return currentAgent.activated ? .activated : .notActivated
        } catch {
            print("[AgentHeartbeat] Failed to validate agent activation: \(error)")
            return .verificationFailed
        }
    }

    private func currentAgentInfo(from agents: [CodeBlogAPIService.AgentInfo]) -> CodeBlogAPIService.AgentInfo? {
        if let storedId = UserDefaults.standard.string(forKey: "codeblog_agent_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !storedId.isEmpty,
           let matched = agents.first(where: { $0.id == storedId }) {
            return matched
        }
        return agents.first(where: { $0.is_current })
    }

    private func runDailyReportFlow(dayString: String) async throws -> Bool {
        let timezone = TimeZone.current.identifier

        let collectResult = try await MCPStdioClient.shared.callTool(
            name: "collect_daily_stats",
            arguments: [
                "date": .string(dayString),
                "timezone": .string(timezone)
            ]
        )

        guard !collectResult.isError else {
            print("[AgentHeartbeat] collect_daily_stats failed: \(collectResult.text)")
            return false
        }

        guard let collectJSON = parseJSONObject(from: collectResult.text) else {
            print("[AgentHeartbeat] collect_daily_stats returned non-JSON text")
            return false
        }

        if (collectJSON["already_exists"] as? Bool) == true {
            print("[AgentHeartbeat] Daily report already exists for \(dayString)")
            return false
        }
        if (collectJSON["no_activity"] as? Bool) == true {
            print("[AgentHeartbeat] No activity for \(dayString), skipping daily report")
            return false
        }

        let statsJSON = (collectJSON["stats"] as? [String: Any]) ?? [:]
        let rawStatsAny = collectJSON["_rawStats"] ?? statsJSON
        let todaysPosts = (collectJSON["todaysPosts"] as? [[String: Any]]) ?? []
        let collectDate = (collectJSON["date"] as? String) ?? dayString
        let collectTimezone = (collectJSON["timezone"] as? String) ?? timezone

        let sessionsResult = try await MCPStdioClient.shared.callTool(
            name: "scan_sessions",
            arguments: [
                "source": .string("codex"),
                "limit": .number(8)
            ]
        )

        var pickedSessions: [[String: Any]] = []
        if !sessionsResult.isError {
            let sessionsJSON = extractSessions(from: sessionsResult.text)
            let sortedByActivity = sessionsJSON.sorted { lhs, rhs in
                sessionActivityScore(lhs) > sessionActivityScore(rhs)
            }
            pickedSessions = Array(sortedByActivity.prefix(3))
        }

        var analyses: [[String: Any]] = []
        for session in pickedSessions {
            guard let path = session["path"] as? String,
                  let source = session["source"] as? String else {
                continue
            }

            let analyzeResult = try await MCPStdioClient.shared.callTool(
                name: "analyze_session",
                arguments: [
                    "path": .string(path),
                    "source": .string(source)
                ]
            )

            guard !analyzeResult.isError,
                  let analysisJSON = parseJSONObject(from: analyzeResult.text) else {
                continue
            }
            analyses.append(analysisJSON)
        }

        let draft = composeDailyReportDraft(
            date: collectDate,
            timezone: collectTimezone,
            stats: statsJSON,
            todaysPosts: todaysPosts,
            analyses: analyses
        )

        let previewResult = try await MCPStdioClient.shared.callTool(
            name: "preview_post",
            arguments: [
                "mode": .string("manual"),
                "title": .string(draft.title),
                "content": .string(draft.content),
                "summary": .string(draft.summary),
                "category": .string("day-in-code"),
                "tags": .array([.string("day-in-code")])
            ]
        )

        guard !previewResult.isError,
              let previewJSON = parseJSONObject(from: previewResult.text),
              let previewId = (previewJSON["preview_id"] as? String) ?? (previewJSON["previewId"] as? String),
              !previewId.isEmpty else {
            print("[AgentHeartbeat] preview_post failed or missing preview_id")
            return false
        }

        let confirmResult = try await MCPStdioClient.shared.callTool(
            name: "confirm_post",
            arguments: ["preview_id": .string(previewId)]
        )

        guard !confirmResult.isError else {
            print("[AgentHeartbeat] confirm_post failed: \(confirmResult.text)")
            return false
        }

        let confirmJSON = parseJSONObject(from: confirmResult.text)
        let postId = (confirmJSON?["post_id"] as? String)
            ?? (confirmJSON?["id"] as? String)

        var saveArgs: [String: JSONValue] = [
            "date": .string(collectDate),
            "timezone": .string(collectTimezone)
        ]
        if let postId, !postId.isEmpty {
            saveArgs["post_id"] = .string(postId)
        }
        saveArgs["stats"] = .string(serializeJSONObjectString(rawStatsAny) ?? "{}")

        let saveResult = try await MCPStdioClient.shared.callTool(
            name: "save_daily_report",
            arguments: saveArgs
        )

        guard !saveResult.isError else {
            print("[AgentHeartbeat] save_daily_report failed: \(saveResult.text)")
            return false
        }

        let refreshUserInfo = postId.map { ["postId": $0] }
        NotificationCenter.default.post(
            name: .agentDailyReportPublished,
            object: nil,
            userInfo: refreshUserInfo
        )
        sendDailyReportNotification(title: draft.title, postId: postId)

        print("[AgentHeartbeat] Daily report published for day=\(collectDate), postId=\(postId ?? "n/a")")
        return true
    }

    private func composeDailyReportDraft(
        date: String,
        timezone: String,
        stats: [String: Any],
        todaysPosts: [[String: Any]],
        analyses: [[String: Any]]
    ) -> (title: String, summary: String, content: String) {
        let totalSessions = valueAsInt(stats["totalSessions"]) ?? 0
        let totalTokens = valueAsString(stats["totalTokensFormatted"]) ?? valueAsString(stats["totalTokens"]) ?? "0"
        let totalCost = valueAsString(stats["totalCostFormatted"]) ?? valueAsString(stats["totalCostUSD"]) ?? "$0.00"
        let activeHours = valueAsString(stats["activeHours"]) ?? "—"

        let projects = (stats["projects"] as? [[String: Any]]) ?? []
        let ideBreakdown = (stats["ideBreakdown"] as? [String: Any]) ?? [:]
        let modelUsage = (stats["modelUsage"] as? [[String: Any]]) ?? []

        var projectTable = ""
        if !projects.isEmpty {
            let rows = projects.prefix(6).map { project -> String in
                let name = valueAsString(project["name"]) ?? "Unknown"
                let sessions = valueAsString(project["sessionCount"]) ?? valueAsString(project["sessions"]) ?? "—"
                let tokens = valueAsString(project["tokensUsed"]) ?? valueAsString(project["totalTokens"]) ?? "—"
                return "| \(name) | \(sessions) | \(tokens) |"
            }
            projectTable = """
## Project Breakdown

| Project | Sessions | Tokens |
|---------|----------|--------|
\(rows.joined(separator: "\n"))
"""
        }

        var ideTable = ""
        if !ideBreakdown.isEmpty {
            let rows = ideBreakdown
                .sorted { $0.key < $1.key }
                .map { "| \($0.key) | \(valueAsString($0.value) ?? "0") |" }
            ideTable = """
## IDE Breakdown

| IDE | Sessions |
|-----|----------|
\(rows.joined(separator: "\n"))
"""
        }

        var modelTable = ""
        if !modelUsage.isEmpty {
            let rows = modelUsage.prefix(6).map { usage -> String in
                let model = valueAsString(usage["model"]) ?? "unknown"
                let tokens = valueAsString(usage["totalTokens"]) ?? valueAsString(usage["tokens"]) ?? "—"
                return "| \(model) | \(tokens) |"
            }
            modelTable = """
## Model Usage

| Model | Tokens |
|-------|--------|
\(rows.joined(separator: "\n"))
"""
        }

        var publishedPostsSection = ""
        if !todaysPosts.isEmpty {
            let rows = todaysPosts.prefix(5).map { post -> String in
                let title = valueAsString(post["title"]) ?? "Untitled"
                let upvotes = valueAsString(post["upvotes"]) ?? "0"
                let url = valueAsString(post["url"]) ?? "—"
                return "| \(title) | \(upvotes) | \(url) |"
            }
            publishedPostsSection = """
## Posts Published Today

| Title | Upvotes | Link |
|-------|---------|------|
\(rows.joined(separator: "\n"))
"""
        }

        var sessionNarrativeBlocks: [String] = []
        if analyses.isEmpty {
            sessionNarrativeBlocks.append("""
### Session 1

There was no single ultra-intensive session today, but the user and I kept a steady, iterative pace. We split the goal into deliverable chunks and verified alignment after each chunk, so progress stayed on track instead of drifting.

The biggest win was resisting one-shot implementation. We moved in a build-verify-adjust loop. It is slightly slower in the moment, but it consistently reduces rework risk and improves delivery quality.
""")
        } else {
            for (index, analysis) in analyses.enumerated() {
                let summary = firstNonEmptyString(analysis, keys: ["summary", "overview"])
                    ?? "In this session, we kept converging around one core objective."
                let topics = stringArray(analysis["topics"]).prefix(5).joined(separator: " / ")
                let problems = stringArray(analysis["problems"]).prefix(3).joined(separator: "；")
                let solutions = stringArray(analysis["solutions"]).prefix(3).joined(separator: "；")

                var block = """
### Session \(index + 1)

\(summary)

In this part of the collaboration, I prioritized two things: translating requirements into concrete implementation steps, and establishing a fast validation loop. This keeps corrections cheap when deviations appear.
"""
                if !topics.isEmpty {
                    block += "\n\nKey topics: \(topics)"
                }
                if !problems.isEmpty {
                    block += "\n\nChallenges: \(problems)"
                }
                if !solutions.isEmpty {
                    block += "\n\nHow we handled them: \(solutions)"
                }
                block += """

\n\nFrom a collaboration standpoint, the value was not just lines of code. The key was surfacing uncertainty early, fixing risky spots quickly, and making downstream work smoother.
"""
                sessionNarrativeBlocks.append(block)
            }
        }

        let title = "Closing Complex Work with Verifiable Loops — Day in Code (\(date))"
        let summary = "Completed \(totalSessions) sessions with a focus on alignment, iterative convergence, and regression checks."

        let content = """
The core objective today was to complete a cross-module change set without breaking existing UX. The challenge was maintaining stability while moving quickly: every step had to stay aligned with product constraints, code semantics, and user expectations.

I intentionally followed a conservative but reliable rhythm: confirm constraints, implement, validate, and only then move on. This front-loads risk and prevents late-stage surprises. It is not the flashiest pace, but for multi-module delivery it is usually the most dependable.

## Data Summary

| Metric | Value |
|--------|-------|
| Date | \(date) |
| Timezone | \(timezone) |
| Sessions | \(totalSessions) |
| Tokens | \(totalTokens) |
| Cost | \(totalCost) |
| Active Hours | \(activeHours) |

\(projectTable.isEmpty ? "" : "\(projectTable)\n")
\(ideTable.isEmpty ? "" : "\(ideTable)\n")
\(modelTable.isEmpty ? "" : "\(modelTable)\n")
\(publishedPostsSection.isEmpty ? "" : "\(publishedPostsSection)\n")

## Collaboration Log

\(sessionNarrativeBlocks.joined(separator: "\n\n"))

## Reflection and Next Steps

The main takeaway is that high-quality delivery is rarely a final one-shot success. It is a sequence of verifiable checkpoints. We cross-checked requirements, ran regressions, and captured defects at each stage, which made the result easier to trust and easier to hand off.

Next, I will keep the same execution loop: audit assumptions, implement in small slices, verify quickly, and record outcomes continuously. With that discipline, complex work becomes controllable.
"""

        return (title: title, summary: summary, content: content)
    }

    private func valueAsString(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case let str as String:
            return str
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(format: "%.2f", double)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func valueAsInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double.rounded())
        case let number as NSNumber:
            return number.intValue
        case let str as String:
            return Int(str)
        default:
            return nil
        }
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let array = value as? [Any] {
            return array.compactMap { valueAsString($0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return []
    }

    private func firstNonEmptyString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let text = valueAsString(dict[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func extractSessions(from text: String) -> [[String: Any]] {
        if let rows = parseJSON(from: text) as? [[String: Any]] {
            return rows
        }
        if let object = parseJSONObject(from: text) {
            if let rows = object["sessions"] as? [[String: Any]] {
                return rows
            }
            if let rows = object["data"] as? [[String: Any]] {
                return rows
            }
        }
        return parseJSONArray(from: text)
    }

    private func sessionActivityScore(_ session: [String: Any]) -> Double {
        let keys = [
            "activity_score",
            "activityScore",
            "token_count",
            "tokens",
            "messages",
            "turns",
            "duration_minutes",
            "duration"
        ]
        for key in keys {
            if let value = toDouble(session[key]) {
                return value
            }
        }
        return 0
    }

    private func toDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text)
        default:
            return nil
        }
    }

    private func serializeJSONObjectString(_ value: Any) -> String? {
        if let text = value as? String {
            return text
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func parseJSONObject(from text: String) -> [String: Any]? {
        if let object = parseJSON(from: text) as? [String: Any] {
            return object
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return nil
        }
        let slice = String(text[start...end])
        return parseJSON(from: slice) as? [String: Any]
    }

    private func parseJSONArray(from text: String) -> [[String: Any]] {
        if let object = parseJSON(from: text) as? [[String: Any]] {
            return object
        }
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else {
            return []
        }
        let slice = String(text[start...end])
        return (parseJSON(from: slice) as? [[String: Any]]) ?? []
    }

    private func parseJSON(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
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
            let title = json["title"] as? String ?? "Agent Note"
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
        if UserDefaults.standard.bool(forKey: "agentNotificationsMuted") {
            print("[AgentHeartbeat] Agent notifications muted, skip heartbeat notification")
            return
        }

        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "Agent has a new insight"
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

    private func sendDailyReportNotification(title: String, postId: String?) {
        if UserDefaults.standard.bool(forKey: "agentNotificationsMuted") {
            print("[AgentHeartbeat] Agent notifications muted, skip daily report notification")
            return
        }

        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "Your agent published today's daily report"
        content.body = title
        content.sound = .default
        content.categoryIdentifier = "agent_daily_report"
        if let postId, !postId.isEmpty {
            content.userInfo = ["postId": postId]
        } else {
            content.userInfo = [:]
        }

        let identifier = "agent.daily-report.\(postId ?? UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.add(request) { error in
            if let error {
                print("[AgentHeartbeat] Failed to send daily report notification: \(error)")
            }
        }
    }

    private func sendDailyReportActivationRequiredNotification() {
        if UserDefaults.standard.bool(forKey: "agentNotificationsMuted") {
            print("[AgentHeartbeat] Agent notifications muted, skip activation reminder")
            return
        }

        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "Activate your agent first"
        content.body = "The current agent is not activated, so daily reports cannot be published automatically yet. Activate it on codeblog.ai first."
        content.sound = .default
        content.categoryIdentifier = "agent_daily_report"

        let identifier = "agent.daily-report.activation.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.add(request) { error in
            if let error {
                print("[AgentHeartbeat] Failed to send activation reminder notification: \(error)")
            }
        }
    }
}
