import Foundation

@MainActor
final class AgentDailyViewModel: ObservableObject {
    struct AgentNote: Identifiable {
        let id: UUID
        let title: String
        let summary: String
        let time: String
        let cardType: String
        let previewId: String?
        let dayString: String
    }

    @Published private(set) var pendingReviews: [CodeBlogAPIService.NotificationItem] = []
    @Published private(set) var rejectedReviews: [CodeBlogAPIService.NotificationItem] = []
    @Published private(set) var approvedRules: [CodeBlogAPIService.AgentMemoryResponse.MemoryRule] = []
    @Published private(set) var rejectedRules: [CodeBlogAPIService.AgentMemoryResponse.MemoryRule] = []
    @Published private(set) var memoryProfile: CodeBlogAPIService.AgentMemoryResponse.MemoryProfile?
    @Published private(set) var memoryProfileV2: CodeBlogAPIService.AgentMemoryResponse.MemoryProfileV2?
    @Published private(set) var persona: CodeBlogAPIService.AgentPersonaResponse.Persona?
    @Published private(set) var activity: CodeBlogAPIService.AgentActivityResponse.Activity?
    @Published private(set) var notes: [AgentNote] = []
    @Published private(set) var postTitlesByID: [String: String] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastRemoteSyncAt: Date?
    @Published var reviewFeedbackMessage: String?
    @Published var errorMessage: String?

    private let api = CodeBlogAPIService.shared
    private let remoteCacheTTL: TimeInterval = 90
    private static let maxFetchedPostTitles = 14

    private struct RemoteSnapshot {
        let cachedAt: Date
        let pendingReviews: [CodeBlogAPIService.NotificationItem]
        let rejectedReviews: [CodeBlogAPIService.NotificationItem]
        let approvedRules: [CodeBlogAPIService.AgentMemoryResponse.MemoryRule]
        let rejectedRules: [CodeBlogAPIService.AgentMemoryResponse.MemoryRule]
        let memoryProfile: CodeBlogAPIService.AgentMemoryResponse.MemoryProfile?
        let memoryProfileV2: CodeBlogAPIService.AgentMemoryResponse.MemoryProfileV2?
        let persona: CodeBlogAPIService.AgentPersonaResponse.Persona?
        let postTitlesByID: [String: String]
    }

    private struct ActivitySnapshot {
        let cachedAt: Date
        let activity: CodeBlogAPIService.AgentActivityResponse.Activity
    }

    private static var remoteSnapshotByAgentID: [String: RemoteSnapshot] = [:]
    private static var activitySnapshotByKey: [String: ActivitySnapshot] = [:]
    private static var refreshTaskByActivityKey: [String: Task<CodeBlogAPIService.AgentActivityResponse.Activity?, Never>] = [:]
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        return formatter
    }()

    func loadCached(for date: Date) {
        let dayString = date.getDayInfoFor4AMBoundary().dayString
        let timezone = TimeZone.current.identifier
        let localNotes = StorageManager.shared
            .fetchTimelineCards(forDay: dayString)
            .filter { $0.category.caseInsensitiveCompare("Agent") == .orderedSame }
            .map {
                AgentNote(
                    id: $0.id,
                    title: $0.title,
                    summary: $0.summary,
                    time: "\($0.startTimestamp) - \($0.endTimestamp)",
                    cardType: $0.agentCardType ?? "journal",
                    previewId: $0.previewId,
                    dayString: dayString
                )
            }
        notes = localNotes

        guard let agentId = UserDefaults.standard.string(forKey: "codeblog_agent_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !agentId.isEmpty else {
            pendingReviews = []
            rejectedReviews = []
            approvedRules = []
            rejectedRules = []
            memoryProfile = nil
            memoryProfileV2 = nil
            persona = nil
            activity = nil
            postTitlesByID = [:]
            lastRemoteSyncAt = nil
            errorMessage = nil
            return
        }

        if let cached = Self.remoteSnapshotByAgentID[agentId] {
            pendingReviews = cached.pendingReviews
            rejectedReviews = cached.rejectedReviews
            approvedRules = cached.approvedRules
            rejectedRules = cached.rejectedRules
            memoryProfile = cached.memoryProfile
            memoryProfileV2 = cached.memoryProfileV2
            persona = cached.persona
            postTitlesByID = cached.postTitlesByID
            lastRemoteSyncAt = cached.cachedAt
        } else {
            pendingReviews = []
            rejectedReviews = []
            approvedRules = []
            rejectedRules = []
            memoryProfile = nil
            memoryProfileV2 = nil
            persona = nil
            postTitlesByID = [:]
            lastRemoteSyncAt = nil
        }

        let activityKey = Self.activityCacheKey(
            agentId: agentId,
            dayString: dayString,
            timezone: timezone
        )
        activity = Self.activitySnapshotByKey[activityKey]?.activity
        errorMessage = nil
    }

    func refresh(for date: Date, forceRemote: Bool = false) async {
        let dayString = date.getDayInfoFor4AMBoundary().dayString
        let timezone = TimeZone.current.identifier
        let localNotes = StorageManager.shared
            .fetchTimelineCards(forDay: dayString)
            .filter { $0.category.caseInsensitiveCompare("Agent") == .orderedSame }
            .map {
                AgentNote(
                    id: $0.id,
                    title: $0.title,
                    summary: $0.summary,
                    time: "\($0.startTimestamp) - \($0.endTimestamp)",
                    cardType: $0.agentCardType ?? "journal",
                    previewId: $0.previewId,
                    dayString: dayString
                )
            }
        notes = localNotes

        guard let apiKey = CodeBlogTokenResolver.currentToken() else {
            pendingReviews = []
            rejectedReviews = []
            approvedRules = []
            rejectedRules = []
            memoryProfile = nil
            memoryProfileV2 = nil
            persona = nil
            activity = nil
            postTitlesByID = [:]
            errorMessage = "Please connect your CodeBlog account first."
            return
        }

        guard let agentId = await resolveAgentId(apiKey: apiKey) else {
            pendingReviews = []
            rejectedReviews = []
            approvedRules = []
            rejectedRules = []
            memoryProfile = nil
            memoryProfileV2 = nil
            persona = nil
            activity = nil
            postTitlesByID = [:]
            errorMessage = "No active Agent selected."
            return
        }

        let activityKey = Self.activityCacheKey(
            agentId: agentId,
            dayString: dayString,
            timezone: timezone
        )
        let remoteCachedSnapshot = Self.remoteSnapshotByAgentID[agentId]

        if !forceRemote {
            if let cached = Self.remoteSnapshotByAgentID[agentId],
               Date().timeIntervalSince(cached.cachedAt) <= remoteCacheTTL {
                pendingReviews = cached.pendingReviews
                rejectedReviews = cached.rejectedReviews
                approvedRules = cached.approvedRules
                rejectedRules = cached.rejectedRules
                memoryProfile = cached.memoryProfile
                memoryProfileV2 = cached.memoryProfileV2
                persona = cached.persona
                postTitlesByID = cached.postTitlesByID
                lastRemoteSyncAt = cached.cachedAt
            }

            if let cachedActivity = Self.activitySnapshotByKey[activityKey],
               Date().timeIntervalSince(cachedActivity.cachedAt) <= remoteCacheTTL {
                activity = cachedActivity.activity
                errorMessage = nil
                prefetchAdjacentActivityDays(
                    apiKey: apiKey,
                    agentId: agentId,
                    centerDayString: dayString,
                    timezone: timezone
                )
                return
            }
        }

        isLoading = true
        defer { isLoading = false }

        let notificationsResult = await fetchResult {
            try await self.api.listNotifications(apiKey: apiKey, limit: 50)
        }
        let memoryResult = await fetchResult {
            try await self.api.getAgentMemory(apiKey: apiKey, agentId: agentId)
        }
        let personaResult = await fetchResult {
            try await self.api.getAgentPersona(apiKey: apiKey, agentId: agentId)
        }

        var criticalErrors: [String] = []

        switch notificationsResult {
        case .success(let notifications):
            pendingReviews = notifications.notifications.filter {
                $0.type == "agent_event"
                && $0.event_kind == "content"
                && $0.agent_review_status == nil
            }
            rejectedReviews = notifications.notifications.filter {
                $0.type == "agent_event"
                && $0.event_kind == "content"
                && $0.agent_review_status == "rejected"
            }
            let seededTitles = seedPostTitles(from: pendingReviews + rejectedReviews)
            postTitlesByID = await resolvePostTitles(
                apiKey: apiKey,
                notifications: pendingReviews + rejectedReviews,
                existingTitles: seededTitles
            )
        case .failure(let error):
            if remoteCachedSnapshot == nil {
                pendingReviews = []
                rejectedReviews = []
                postTitlesByID = [:]
            }
            criticalErrors.append(error.localizedDescription)
        }

        switch memoryResult {
        case .success(let memory):
            approvedRules = memory.approved_rules
            rejectedRules = memory.rejected_rules
            memoryProfile = memory.memory_profile
            memoryProfileV2 = memory.memory_profile_v2
        case .failure(let error):
            if remoteCachedSnapshot == nil {
                approvedRules = []
                rejectedRules = []
                memoryProfile = nil
                memoryProfileV2 = nil
            }
            criticalErrors.append(error.localizedDescription)
        }

        switch personaResult {
        case .success(let personaData):
            persona = personaData.persona
        case .failure(let error):
            if remoteCachedSnapshot == nil {
                persona = nil
            }
            criticalErrors.append(error.localizedDescription)
        }

        if case .success = notificationsResult,
           case .success = memoryResult,
           case .success = personaResult {
            Self.remoteSnapshotByAgentID[agentId] = RemoteSnapshot(
                cachedAt: Date(),
                pendingReviews: pendingReviews,
                rejectedReviews: rejectedReviews,
                approvedRules: approvedRules,
                rejectedRules: rejectedRules,
                memoryProfile: memoryProfile,
                memoryProfileV2: memoryProfileV2,
                persona: persona,
                postTitlesByID: postTitlesByID
            )
            lastRemoteSyncAt = Self.remoteSnapshotByAgentID[agentId]?.cachedAt
        }

        let activityResult = await fetchResult {
            try await self.api.getAgentActivity(
                apiKey: apiKey,
                agentId: agentId,
                date: dayString,
                timezone: timezone
            )
        }
        switch activityResult {
        case .success(let activityData):
            activity = activityData.activity
            Self.activitySnapshotByKey[activityKey] = ActivitySnapshot(
                cachedAt: Date(),
                activity: activityData.activity
            )
        case .failure:
            if Self.activitySnapshotByKey[activityKey] == nil {
                activity = nil
            }
            // Activity failure is timeline-only degradation; do not surface as card-level error.
        }

        if criticalErrors.isEmpty {
            errorMessage = nil
        } else {
            errorMessage = criticalErrors[0]
        }

        prefetchAdjacentActivityDays(
            apiKey: apiKey,
            agentId: agentId,
            centerDayString: dayString,
            timezone: timezone
        )
    }

    func postTitle(for notification: CodeBlogAPIService.NotificationItem) -> String? {
        if let prefilled = notification.comment_post_title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prefilled.isEmpty {
            return prefilled
        }
        guard let postID = postReferenceID(for: notification) else { return nil }
        return postTitlesByID[postID]
    }

    private func postReferenceID(for notification: CodeBlogAPIService.NotificationItem) -> String? {
        let primary = notification.comment_post_id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let primary, !primary.isEmpty {
            return primary
        }
        let fallback = notification.post_id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    private func resolvePostTitles(
        apiKey: String,
        notifications: [CodeBlogAPIService.NotificationItem],
        existingTitles: [String: String]
    ) async -> [String: String] {
        var titles = existingTitles
        let postIDs = notifications
            .compactMap { postReferenceID(for: $0) }
            .reduce(into: [String]()) { acc, id in
                guard !acc.contains(id) else { return }
                acc.append(id)
            }

        for postID in postIDs.prefix(Self.maxFetchedPostTitles) where titles[postID] == nil {
            guard let post = try? await api.getPostDetail(apiKey: apiKey, postId: postID) else {
                continue
            }
            let normalized = post.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            titles[postID] = normalized
        }
        return titles
    }

    private func seedPostTitles(
        from notifications: [CodeBlogAPIService.NotificationItem]
    ) -> [String: String] {
        var seeded = postTitlesByID
        for notification in notifications {
            guard let postID = postReferenceID(for: notification),
                  let title = notification.comment_post_title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                continue
            }
            seeded[postID] = title
        }
        return seeded
    }

    private func resolveAgentId(apiKey: String) async -> String? {
        if let stored = UserDefaults.standard.string(forKey: "codeblog_agent_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }

        do {
            let agents = try await api.listAgents(apiKey: apiKey)
            guard let current = agents.first(where: { $0.is_current }) ?? agents.first else {
                return nil
            }
            UserDefaults.standard.set(current.id, forKey: "codeblog_agent_id")
            return current.id
        } catch {
            return nil
        }
    }

    func review(notificationId: String, action: String, note: String? = nil) async {
        guard let apiKey = CodeBlogTokenResolver.currentToken() else { return }
        do {
            let result = try await api.reviewNotification(
                apiKey: apiKey,
                notificationId: notificationId,
                action: action,
                note: note
            )
            let actionText = action == "approve" ? "Approved" : "Rejected"
            var parts: [String] = [actionText]
            if let learned = result.learned_rules_count, learned > 0 {
                parts.append("Learned \(learned) rule(s)")
            }
            if let confidence = result.agent_style_confidence {
                parts.append("Confidence \(Int((confidence * 100).rounded()))%")
            }
            if let mode = result.agent_persona_mode, !mode.isEmpty {
                parts.append("Mode \(mode)")
            }
            reviewFeedbackMessage = parts.joined(separator: " · ")
            errorMessage = nil
        } catch {
            errorMessage = friendlyReviewErrorMessage(error)
        }
    }

    func undoReview(notificationId: String) async {
        guard let apiKey = CodeBlogTokenResolver.currentToken() else { return }
        do {
            _ = try await api.undoNotificationReview(apiKey: apiKey, notificationId: notificationId)
            reviewFeedbackMessage = "Review action reverted"
            errorMessage = nil
        } catch {
            errorMessage = friendlyReviewErrorMessage(error)
        }
    }

    private func friendlyReviewErrorMessage(_ error: Error) -> String {
        let raw = error.localizedDescription
        if raw.localizedCaseInsensitiveContains("unauthorized") {
            return "Review API rejected Bearer auth. Confirm backend Bearer review support is deployed."
        }
        return raw
    }

    private func prefetchAdjacentActivityDays(
        apiKey: String,
        agentId: String,
        centerDayString: String,
        timezone: String
    ) {
        let candidateDays = [
            dayString(byAdding: -1, to: centerDayString),
            dayString(byAdding: 1, to: centerDayString)
        ]
        .compactMap { $0 }

        for day in candidateDays {
            let key = Self.activityCacheKey(agentId: agentId, dayString: day, timezone: timezone)
            if let cached = Self.activitySnapshotByKey[key],
               Date().timeIntervalSince(cached.cachedAt) <= remoteCacheTTL {
                continue
            }
            if Self.refreshTaskByActivityKey[key] != nil {
                continue
            }

            let task = Task<CodeBlogAPIService.AgentActivityResponse.Activity?, Never> {
                defer {
                    Task { @MainActor in
                        Self.refreshTaskByActivityKey[key] = nil
                    }
                }
                guard let response = try? await self.api.getAgentActivity(
                    apiKey: apiKey,
                    agentId: agentId,
                    date: day,
                    timezone: timezone
                ) else {
                    return nil
                }
                await MainActor.run {
                    Self.activitySnapshotByKey[key] = ActivitySnapshot(
                        cachedAt: Date(),
                        activity: response.activity
                    )
                }
                return response.activity
            }
            Self.refreshTaskByActivityKey[key] = task
        }
    }

    private static func activityCacheKey(agentId: String, dayString: String, timezone: String) -> String {
        "\(agentId)|\(dayString)|\(timezone)"
    }

    private func fetchResult<T>(
        operation: @escaping @MainActor () async throws -> T
    ) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private func dayString(byAdding offset: Int, to dayString: String) -> String? {
        guard let baseDate = Self.dayFormatter.date(from: dayString) else {
            return nil
        }
        let noonDate = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: baseDate) ?? baseDate
        guard let shifted = Calendar.current.date(byAdding: .day, value: offset, to: noonDate) else {
            return nil
        }
        return shifted.getDayInfoFor4AMBoundary().dayString
    }
}
