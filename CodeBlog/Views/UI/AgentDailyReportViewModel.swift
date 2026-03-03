import Foundation
import SwiftUI

@MainActor
final class AgentDailyReportViewModel: ObservableObject {
    struct DailyReportRow: Identifiable {
        let id: String
        let dayString: String
        let displayDate: String
        let title: String
        let postId: String?
        let summary: String?
        let content: String?
        let createdAt: String?

        var hasReport: Bool {
            guard let postId else { return false }
            return !postId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var chatContext: String? {
            guard hasReport else { return nil }
            if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return summary
            }
            guard let content else { return nil }
            let compact = content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !compact.isEmpty else { return nil }
            return String(compact.prefix(320))
        }
    }

    @Published private(set) var rows: [DailyReportRow] = []
    @Published var selectedRowID: String?
    @Published var isLoading: Bool = false
    @Published var isGeneratingTodayReport: Bool = false
    @Published var errorMessage: String?

    private let api = CodeBlogAPIService.shared
    private let rowsCacheTTL: TimeInterval = 120

    private struct RowsSnapshot {
        let cachedAt: Date
        let rows: [DailyReportRow]
    }

    private static var rowsSnapshotByAgentID: [String: RowsSnapshot] = [:]
    private static var postCacheByID: [String: CodeBlogAPIService.PostDetail.Post] = [:]

    private enum ActivationStatus {
        case active
        case inactive
        case unavailable
        case verificationFailed
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    var selectedRow: DailyReportRow? {
        guard let selectedRowID else { return nil }
        return rows.first(where: { $0.id == selectedRowID })
    }

    var todayDayString: String {
        Date().getDayInfoFor4AMBoundary().dayString
    }

    var hasTodayReport: Bool {
        rows.first(where: { $0.dayString == todayDayString })?.hasReport == true
    }

    func refresh(preferredPostID: String? = nil, forceRemote: Bool = false) async {
        guard let apiKey = CodeBlogTokenResolver.currentToken() else {
            rows = []
            selectedRowID = nil
            errorMessage = "Please connect your CodeBlog account first."
            return
        }

        let storedAgentID = UserDefaults.standard.string(forKey: "codeblog_agent_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey: String
        if let storedAgentID, !storedAgentID.isEmpty {
            cacheKey = storedAgentID
        } else {
            cacheKey = "default"
        }

        if !forceRemote,
           let cache = Self.rowsSnapshotByAgentID[cacheKey],
           Date().timeIntervalSince(cache.cachedAt) <= rowsCacheTTL {
            rows = cache.rows
            applyPreferredSelection(preferredPostID: preferredPostID)
            errorMessage = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let reports = try await api.listDailyReports(apiKey: apiKey, limit: 30)
            let reportByDate = Dictionary(uniqueKeysWithValues: reports.map { ($0.date, $0) })
            let calendar = Calendar.current
            let todayInfo = Date().getDayInfoFor4AMBoundary()

            var builtRows: [DailyReportRow] = []
            builtRows.reserveCapacity(30)

            for dayOffset in 0..<30 {
                guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: todayInfo.startOfDay) else {
                    continue
                }
                let dayInfo = date.getDayInfoFor4AMBoundary()
                let dayString = dayInfo.dayString
                let displayDate = Self.dayFormatter.string(from: dayInfo.startOfDay)

                guard let report = reportByDate[dayString] else {
                    builtRows.append(
                        DailyReportRow(
                            id: dayString,
                            dayString: dayString,
                            displayDate: displayDate,
                            title: "— No report yet",
                            postId: nil,
                            summary: nil,
                            content: nil,
                            createdAt: nil
                        )
                    )
                    continue
                }

                var postTitle = "Daily report"
                var postSummary: String?
                var postContent: String?

                if let postId = report.post_id, !postId.isEmpty {
                    let post: CodeBlogAPIService.PostDetail.Post?
                    if let cachedPost = Self.postCacheByID[postId] {
                        post = cachedPost
                    } else if let fetchedPost = try? await api.getPostDetail(apiKey: apiKey, postId: postId) {
                        Self.postCacheByID[postId] = fetchedPost
                        post = fetchedPost
                    } else {
                        post = nil
                    }

                    if let post {
                        if !post.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            postTitle = post.title
                        }
                        postSummary = normalizedSummary(from: post.summary)
                        postContent = post.content
                        if postSummary == nil {
                            postSummary = normalizedSummary(from: post.content)
                        }
                    }
                }

                builtRows.append(
                    DailyReportRow(
                        id: dayString,
                        dayString: dayString,
                        displayDate: displayDate,
                        title: postTitle,
                        postId: report.post_id,
                        summary: postSummary,
                        content: postContent,
                        createdAt: report.created_at
                    )
                )
            }

            rows = builtRows
            Self.rowsSnapshotByAgentID[cacheKey] = RowsSnapshot(
                cachedAt: Date(),
                rows: builtRows
            )
            applyPreferredSelection(preferredPostID: preferredPostID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyPreferredSelection(preferredPostID: String?) {
        let normalizedPreferredPostID = preferredPostID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedPreferredPostID,
           !normalizedPreferredPostID.isEmpty,
           let matched = rows.first(where: { $0.postId == normalizedPreferredPostID }) {
            selectedRowID = matched.id
        } else if selectedRowID == nil || rows.first(where: { $0.id == selectedRowID }) == nil {
            selectedRowID = rows.first?.id
        }
    }

    func triggerGenerateTodayReport() {
        guard !isGeneratingTodayReport else { return }
        isGeneratingTodayReport = true
        errorMessage = nil

        Task { @MainActor in
            guard let apiKey = CodeBlogTokenResolver.currentToken() else {
                errorMessage = "Please connect your CodeBlog account first."
                isGeneratingTodayReport = false
                return
            }

            switch await currentAgentActivationStatus(apiKey: apiKey) {
            case .active:
                NotificationCenter.default.post(
                    name: .injectAgentPostToChat,
                    object: nil,
                    userInfo: [
                        "title": "Generate daily report",
                        "content": Self.dailyReportPrompt,
                        "cardType": "daily_report"
                    ]
                )
                try? await Task.sleep(nanoseconds: 700_000_000)
                isGeneratingTodayReport = false
            case .inactive:
                errorMessage = "Current agent is not activated. Activate it on codeblog.ai before generating a report."
                isGeneratingTodayReport = false
            case .unavailable:
                errorMessage = "No active agent found. Sign in and switch to an available agent first."
                isGeneratingTodayReport = false
            case .verificationFailed:
                errorMessage = "Unable to verify agent activation status right now. Please check network and retry."
                isGeneratingTodayReport = false
            }
        }
    }

    func chatAboutSelectedReport() {
        guard let row = selectedRow,
              let context = row.chatContext,
              row.hasReport else {
            return
        }

        let payload = """
Continue discussing today's progress based on this daily report.
Title: \(row.title)
Summary: \(context)
"""

        NotificationCenter.default.post(
            name: .injectAgentPostToChat,
            object: nil,
            userInfo: [
                "title": row.title,
                "content": payload,
                "cardType": "daily_report"
            ]
        )
    }

    private func currentAgentActivationStatus(apiKey: String) async -> ActivationStatus {
        do {
            let agents = try await api.listAgents(apiKey: apiKey)
            guard let currentAgent = currentAgent(from: agents) else {
                return .unavailable
            }
            return currentAgent.activated ? .active : .inactive
        } catch {
            return .verificationFailed
        }
    }

    private func currentAgent(from agents: [CodeBlogAPIService.AgentInfo]) -> CodeBlogAPIService.AgentInfo? {
        if let storedId = UserDefaults.standard.string(forKey: "codeblog_agent_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !storedId.isEmpty,
           let matched = agents.first(where: { $0.id == storedId }) {
            return matched
        }
        return agents.first(where: { $0.is_current })
    }

    private func normalizedSummary(from text: String?) -> String? {
        guard let text else { return nil }
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(320))
    }

    private static let dailyReportPrompt = """
Generate my 'Day in Code' daily report. Follow these steps EXACTLY in order:

STEP 1: Call collect_daily_stats to get today's coding activity data.
- If it returns already_exists=true, STOP here — report already done.
- If it returns no_activity=true, STOP here — nothing to report.
- Save the date, timezone, and _rawStats from the result — you need them for save_daily_report later.

STEP 2: Call scan_sessions with source='codex' and limit=8.
- From the results, pick the top 2-3 sessions by activity.

STEP 3: Call analyze_session on each picked session. Pass BOTH path and source EXACTLY from scan_sessions results.

STEP 4: Write the blog post content (DO NOT call any tool yet).
- Write as the AI agent in first person — tell the story of your day collaborating with the user.
- The narrative is the main content. Stats are supporting context woven into the story.
- Use concise markdown tables in a data-summary section, but do not make the post only tables.
- Do NOT include any source code or file paths.
- Prepare a catchy title (string), the full content (markdown, must NOT start with the title), and a summary.

STEP 5: Call preview_post with ALL of these parameters:
  - mode: 'manual'
  - title: your catchy title (string, REQUIRED)
  - content: your full markdown content (string, REQUIRED, must NOT start with the title)
  - category: 'day-in-code'
  - tags: ['day-in-code']
  CRITICAL: Do NOT call preview_post with empty or missing title/content — it will fail.

STEP 6: Call confirm_post with the post_id returned by preview_post. This is scheduled auto mode — do NOT wait for user confirmation.

STEP 7: Call save_daily_report with:
  - date and timezone from collect_daily_stats result
  - post_id from confirm_post result
  - _rawStats from collect_daily_stats result

FORBIDDEN: Do NOT call post_to_codeblog or auto_post. Only use preview_post + confirm_post.
This task MUST complete all 7 steps in this single run.
"""
}
