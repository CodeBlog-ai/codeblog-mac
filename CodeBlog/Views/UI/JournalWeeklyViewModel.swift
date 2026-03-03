import Foundation

@MainActor
final class JournalWeeklyViewModel: ObservableObject {
    @Published private(set) var summary: JournalWeeklySummary = .placeholder
    @Published private(set) var weekOffset: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    private let api = CodeBlogAPIService.shared
    private let cacheTTL: TimeInterval = 180

    private struct WeeklySnapshot {
        let cachedAt: Date
        let summary: JournalWeeklySummary
    }

    private struct WeeklySnapshotCacheDTO: Codable {
        let cachedAt: Date
        let summary: SummaryDTO

        init(snapshot: WeeklySnapshot) {
            self.cachedAt = snapshot.cachedAt
            self.summary = SummaryDTO(model: snapshot.summary)
        }

        func toSnapshot() -> WeeklySnapshot? {
            guard let summary = summary.toModel() else { return nil }
            return WeeklySnapshot(cachedAt: cachedAt, summary: summary)
        }
    }

    private struct SummaryDTO: Codable {
        let title: String
        let dateRange: String
        let description: String
        let disableForwardNavigation: Bool
        let days: [DayDTO]
        let digest: DigestDTO

        init(model: JournalWeeklySummary) {
            title = model.title
            dateRange = model.dateRange
            description = model.description
            disableForwardNavigation = model.disableForwardNavigation
            days = model.days.map(DayDTO.init)
            digest = DigestDTO(model: model.digest)
        }

        func toModel() -> JournalWeeklySummary? {
            let mappedDays = days.compactMap { $0.toModel() }
            guard mappedDays.count == days.count else { return nil }
            guard let digest = digest.toModel() else { return nil }
            return JournalWeeklySummary(
                title: title,
                dateRange: dateRange,
                description: description,
                disableForwardNavigation: disableForwardNavigation,
                days: mappedDays,
                digest: digest
            )
        }
    }

    private struct DigestDTO: Codable {
        let publishedReportDays: Int
        let totalEvents: Int
        let activeCategoryCount: Int
        let mostActiveDayLabel: String?
        let blankDays: Int
        let nextWeekSuggestion: String

        init(model: JournalWeeklyDigest) {
            publishedReportDays = model.publishedReportDays
            totalEvents = model.totalEvents
            activeCategoryCount = model.activeCategoryCount
            mostActiveDayLabel = model.mostActiveDayLabel
            blankDays = model.blankDays
            nextWeekSuggestion = model.nextWeekSuggestion
        }

        func toModel() -> JournalWeeklyDigest? {
            JournalWeeklyDigest(
                publishedReportDays: publishedReportDays,
                totalEvents: totalEvents,
                activeCategoryCount: activeCategoryCount,
                mostActiveDayLabel: mostActiveDayLabel,
                blankDays: blankDays,
                nextWeekSuggestion: nextWeekSuggestion
            )
        }
    }

    private struct DayDTO: Codable {
        let dayString: String
        let label: String
        let progress: Double?
        let isMuted: Bool
        let entry: EntryDTO?

        init(model: JournalWeeklyDay) {
            dayString = model.dayString
            label = model.label
            progress = model.progress.map { Double($0) }
            isMuted = model.isMuted
            entry = model.entry.map(EntryDTO.init)
        }

        func toModel() -> JournalWeeklyDay? {
            JournalWeeklyDay(
                dayString: dayString,
                label: label,
                progress: progress.map { CGFloat($0) },
                isMuted: isMuted,
                entry: entry?.toModel()
            )
        }
    }

    private struct EntryDTO: Codable {
        enum PositionDTO: String, Codable {
            case above
            case below
        }

        let summary: String
        let position: PositionDTO
        let icons: [String]
        let preferredWidth: Double

        init(model: JournalWeeklyEntry) {
            summary = model.summary
            position = model.position == .above ? .above : .below
            icons = model.icons.map { icon in
                Self.iconKey(for: icon)
            }
            preferredWidth = Double(model.preferredWidth)
        }

        func toModel() -> JournalWeeklyEntry {
            JournalWeeklyEntry(
                summary: summary,
                position: position == .above ? .above : .below,
                icons: icons.compactMap(Self.iconFromKey),
                preferredWidth: CGFloat(preferredWidth)
            )
        }

        private static func iconKey(for icon: JournalWeeklyIcon) -> String {
            switch icon.systemName {
            case "paintpalette.fill":
                return "figma"
            case "cart.fill":
                return "cart"
            case "rectangle.and.pencil.and.ellipsis":
                return "slides"
            case "play.rectangle.fill":
                return "video"
            case "book.fill":
                return "books"
            case "moon.stars.fill":
                return "moon"
            case "tv.fill":
                return "tv"
            default:
                return "books"
            }
        }

        private static func iconFromKey(_ key: String) -> JournalWeeklyIcon? {
            switch key {
            case "figma":
                return .figma
            case "cart":
                return .cart
            case "slides":
                return .slides
            case "video":
                return .video
            case "books":
                return .books
            case "moon":
                return .moon
            case "tv":
                return .tv
            default:
                return nil
            }
        }
    }

    private static var weeklySnapshotByKey: [String: WeeklySnapshot] = [:]
    private static var didLoadDiskCache = false
    private static let diskCacheFileURL: URL = {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return directory
            .appendingPathComponent("CodeBlog", isDirectory: true)
            .appendingPathComponent("journal-week-cache-v1.json", isDirectory: false)
    }()
    private var prefetchTasksByOffset: [Int: Task<Void, Never>] = [:]

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter
    }()

    func refresh(forceRemote: Bool = false) async {
        loadDiskCacheIfNeeded()

        guard let apiKey = CodeBlogTokenResolver.currentToken() else {
            summary = JournalWeeklySummary(
                title: "Week in review",
                dateRange: "Sign in to load reports",
                description: "Connect your CodeBlog account to load weekly agent reports and activity.",
                disableForwardNavigation: true,
                days: JournalWeeklyDay.placeholder,
                digest: .placeholder
            )
            errorMessage = "Please connect your CodeBlog account first."
            return
        }

        guard let agentId = await resolveAgentId(apiKey: apiKey) else {
            errorMessage = "No active Agent selected."
            return
        }

        let timezone = TimeZone.current.identifier
        let week = currentWeekRange(offset: weekOffset)
        let weekStartDay = week.days.first?.getDayInfoFor4AMBoundary().dayString ?? Date().getDayInfoFor4AMBoundary().dayString
        let cacheKey = makeCacheKey(agentId: agentId, timezone: timezone, weekStartDay: weekStartDay)

        if let cached = Self.weeklySnapshotByKey[cacheKey] {
            summary = cached.summary
            errorMessage = nil
            if !forceRemote, isFresh(snapshot: cached) {
                return
            }
        } else {
            summary = loadingSummary(for: week, disableForwardNavigation: weekOffset >= 0)
            errorMessage = nil
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let snapshot = try await buildSnapshot(
                for: weekOffset,
                apiKey: apiKey,
                agentId: agentId,
                timezone: timezone
            )
            summary = snapshot.summary
            Self.weeklySnapshotByKey[snapshot.cacheKey] = WeeklySnapshot(
                cachedAt: snapshot.cachedAt,
                summary: snapshot.summary
            )
            persistDiskCache()
            errorMessage = nil
            prefetchNeighborWeeks(
                around: weekOffset,
                apiKey: apiKey,
                agentId: agentId,
                timezone: timezone
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigatePreviousWeek() {
        weekOffset -= 1
    }

    func navigateNextWeek() {
        guard weekOffset < 0 else { return }
        weekOffset += 1
    }

    func primeCurrentWeekSummary() {
        loadDiskCacheIfNeeded()

        let week = currentWeekRange(offset: weekOffset)
        let timezone = TimeZone.current.identifier
        let weekStartDay = week.days.first?.getDayInfoFor4AMBoundary().dayString ?? Date().getDayInfoFor4AMBoundary().dayString
        let agentId = UserDefaults.standard.string(forKey: "codeblog_agent_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let agentId,
           !agentId.isEmpty,
           let cached = Self.weeklySnapshotByKey[makeCacheKey(agentId: agentId, timezone: timezone, weekStartDay: weekStartDay)] {
            summary = cached.summary
            errorMessage = nil
            return
        }

        summary = loadingSummary(for: week, disableForwardNavigation: weekOffset >= 0)
        errorMessage = nil
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

    private func currentWeekRange(offset: Int) -> (start: Date, end: Date, days: [Date]) {
        let today = Date().getDayInfoFor4AMBoundary().startOfDay
        let shifted = Calendar.current.date(byAdding: .day, value: offset * 7, to: today) ?? today
        let interval = Calendar.current.dateInterval(of: .weekOfYear, for: shifted)
        let start = interval?.start ?? shifted
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        let days = (0..<7).compactMap { index in
            Calendar.current.date(byAdding: .day, value: index, to: start)
        }
        return (start, end, days)
    }

    private func makeWeeklyEntry(
        report: CodeBlogAPIService.DailyReport?,
        dayString: String,
        activityTotal: Int,
        activityRows: [CodeBlogAPIService.AgentActivityResponse.Activity.Row],
        dayDate: Date,
        index: Int
    ) -> JournalWeeklyEntry? {
        let position: JournalWeeklyEntry.Position = index.isMultiple(of: 2) ? .below : .above

        if let report, report.post_id != nil {
            let sessions = extractInt(from: report.stats?["totalSessions"])
            let tokens = extractInt(from: report.stats?["totalTokens"])
            var lines: [String] = []
            lines.append("Published daily report on codeblog.ai.")
            if sessions > 0 {
                lines.append("Tracked \(sessions) coding session(s).")
            }
            if tokens > 0 {
                lines.append("Used \(tokens) tokens.")
            }
            if activityTotal > 0 {
                lines.append("Recorded \(activityTotal) agent events.")
            }
            return JournalWeeklyEntry(
                summary: lines.joined(separator: " "),
                position: position,
                icons: iconsForRows(activityRows),
                preferredWidth: 225
            )
        }

        if activityTotal > 0 {
            let dominant = activityRows
                .sorted { $0.total_events > $1.total_events }
                .first { $0.total_events > 0 }?.label ?? "activity"
            return JournalWeeklyEntry(
                summary: "No published report yet. Logged \(activityTotal) agent events, mainly \(dominant.lowercased()).",
                position: position,
                icons: iconsForRows(activityRows),
                preferredWidth: 225
            )
        }

        let isFuture = dayDate > Date().getDayInfoFor4AMBoundary().startOfDay
        if isFuture {
            return nil
        }

        return JournalWeeklyEntry(
            summary: "No daily report or agent activity recorded for \(dayString).",
            position: position,
            icons: [],
            preferredWidth: 215
        )
    }

    private func iconsForRows(
        _ rows: [CodeBlogAPIService.AgentActivityResponse.Activity.Row]
    ) -> [JournalWeeklyIcon] {
        let sorted = rows
            .filter { $0.total_events > 0 }
            .sorted { $0.total_events > $1.total_events }
        var icons: [JournalWeeklyIcon] = []
        for row in sorted.prefix(2) {
            switch row.key {
            case "browse":
                icons.append(.books)
            case "review":
                icons.append(.slides)
            case "comment":
                icons.append(.video)
            case "vote":
                icons.append(.moon)
            case "post":
                icons.append(.figma)
            case "chat":
                icons.append(.tv)
            default:
                continue
            }
        }
        if icons.isEmpty {
            return [.books]
        }
        return icons
    }

    private func extractInt(from value: CodeBlogAPIService.JSONValue?) -> Int {
        guard let value else { return 0 }
        switch value {
        case .number(let number):
            return Int(number.rounded())
        case .string(let text):
            return Int(text) ?? 0
        default:
            return 0
        }
    }

    private func dayFrom(dayString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        return formatter.date(from: dayString)
    }

    private func weeklySuggestion(reportDays: Int, totalEvents: Int, blankDays: Int) -> String {
        if totalEvents == 0 {
            return "Kick off next week by syncing with Agent once in the morning and once before wrap-up so the timeline has real signals."
        }
        if reportDays < 3 {
            return "Aim to publish at least three daily reports next week to keep momentum visible and reduce blank days."
        }
        if blankDays > 2 {
            return "There are several blank days; try a lightweight end-of-day check-in to keep continuity."
        }
        return "Strong cadence this week. Keep the same rhythm and use memory tuning when your collaboration style drifts."
    }

    private func isFresh(snapshot: WeeklySnapshot) -> Bool {
        Date().timeIntervalSince(snapshot.cachedAt) <= cacheTTL
    }

    private func buildSnapshot(
        for offset: Int,
        apiKey: String,
        agentId: String,
        timezone: String
    ) async throws -> (cacheKey: String, summary: JournalWeeklySummary, cachedAt: Date) {
        let week = currentWeekRange(offset: offset)
        let weekStartDay = week.days.first?.getDayInfoFor4AMBoundary().dayString ?? Date().getDayInfoFor4AMBoundary().dayString
        let cacheKey = makeCacheKey(agentId: agentId, timezone: timezone, weekStartDay: weekStartDay)
        let fromDay = week.days.first?.getDayInfoFor4AMBoundary().dayString ?? weekStartDay
        let toDay = week.days.last?.getDayInfoFor4AMBoundary().dayString ?? weekStartDay

        let reports = try await api.listDailyReports(
            apiKey: apiKey,
            limit: 50,
            from: fromDay,
            to: toDay
        )
        let reportsByDay = Dictionary(uniqueKeysWithValues: reports.map { ($0.date, $0) })
        let dayStrings = week.days.map { $0.getDayInfoFor4AMBoundary().dayString }
        let activityByDay = await fetchActivitiesByDay(
            apiKey: apiKey,
            agentId: agentId,
            timezone: timezone,
            dayStrings: dayStrings
        )

        var days: [JournalWeeklyDay] = []
        days.reserveCapacity(week.days.count)

        var reportDays = 0
        var totalSessions = 0
        var activityTotalsByDay: [String: Int] = [:]
        var activityRowsByDay: [String: [CodeBlogAPIService.AgentActivityResponse.Activity.Row]] = [:]

        for date in week.days {
            let dayString = date.getDayInfoFor4AMBoundary().dayString
            let activity = activityByDay[dayString] ?? nil
            if let activity {
                let eventCount = activity.activity.totals.reduce(0) { $0 + $1.total_events }
                activityTotalsByDay[dayString] = eventCount
                activityRowsByDay[dayString] = activity.activity.rows
            } else {
                activityTotalsByDay[dayString] = 0
                activityRowsByDay[dayString] = []
            }

            if let report = reportsByDay[dayString],
               report.post_id != nil {
                reportDays += 1
                totalSessions += extractInt(from: report.stats?["totalSessions"])
            }
        }

        for (index, date) in week.days.enumerated() {
            let dayString = date.getDayInfoFor4AMBoundary().dayString
            let report = reportsByDay[dayString]
            let dayLabel = Self.dayLabelFormatter.string(from: date)
            let progress = CGFloat(index) / CGFloat(max(week.days.count - 1, 1))
            let isWeekend = Calendar.current.isDateInWeekend(date)
            let activityTotal = activityTotalsByDay[dayString] ?? 0
            let activityRows = activityRowsByDay[dayString] ?? []
            let entry = makeWeeklyEntry(
                report: report,
                dayString: dayString,
                activityTotal: activityTotal,
                activityRows: activityRows,
                dayDate: date,
                index: index
            )

            days.append(
                JournalWeeklyDay(
                    dayString: dayString,
                    label: dayLabel,
                    progress: progress,
                    isMuted: isWeekend,
                    entry: entry
                )
            )
        }

        let totalEvents = activityTotalsByDay.values.reduce(0, +)
        let activeCategoryCount = Set(
            activityRowsByDay.values
                .flatMap { rows in rows.filter { $0.total_events > 0 }.map(\.key) }
        ).count
        let nonFutureDays = week.days.filter { $0 <= Date().getDayInfoFor4AMBoundary().startOfDay }
        let blankDays = nonFutureDays.reduce(0) { count, dayDate in
            let dayString = dayDate.getDayInfoFor4AMBoundary().dayString
            let report = reportsByDay[dayString]
            let activityCount = activityTotalsByDay[dayString] ?? 0
            let hasPublishedReport = report?.post_id?.isEmpty == false
            return (!hasPublishedReport && activityCount == 0) ? count + 1 : count
        }
        let mostActiveDayString = activityTotalsByDay
            .filter { $0.value > 0 }
            .max(by: { $0.value < $1.value })?
            .key
        let mostActiveDayLabel: String? = {
            guard
                let mostActiveDayString,
                let date = dayFrom(dayString: mostActiveDayString)
            else {
                return nil
            }
            return Self.dayLabelFormatter.string(from: date)
        }()
        let suggestion = weeklySuggestion(
            reportDays: reportDays,
            totalEvents: totalEvents,
            blankDays: blankDays
        )
        let rangeText = "\(Self.titleFormatter.string(from: week.start)) – \(Self.titleFormatter.string(from: week.end))"
        let description = "Published reports on \(reportDays) day(s), with \(totalSessions) tracked coding sessions and \(totalEvents) agent events this week."
        let built = JournalWeeklySummary(
            title: "Agent week in review",
            dateRange: rangeText,
            description: description,
            disableForwardNavigation: offset >= 0,
            days: days,
            digest: JournalWeeklyDigest(
                publishedReportDays: reportDays,
                totalEvents: totalEvents,
                activeCategoryCount: activeCategoryCount,
                mostActiveDayLabel: mostActiveDayLabel,
                blankDays: blankDays,
                nextWeekSuggestion: suggestion
            )
        )

        return (cacheKey: cacheKey, summary: built, cachedAt: Date())
    }

    private func prefetchNeighborWeeks(
        around offset: Int,
        apiKey: String,
        agentId: String,
        timezone: String
    ) {
        let targetOffsets = [
            offset - 1,
            offset - 2,
            offset - 3,
            offset + 1
        ].filter { $0 <= 0 }
        for targetOffset in targetOffsets {
            if prefetchTasksByOffset[targetOffset] != nil {
                continue
            }

            let week = currentWeekRange(offset: targetOffset)
            let weekStartDay = week.days.first?.getDayInfoFor4AMBoundary().dayString ?? Date().getDayInfoFor4AMBoundary().dayString
            let targetCacheKey = makeCacheKey(agentId: agentId, timezone: timezone, weekStartDay: weekStartDay)
            if let cached = Self.weeklySnapshotByKey[targetCacheKey], isFresh(snapshot: cached) {
                continue
            }

            prefetchTasksByOffset[targetOffset] = Task {
                defer { prefetchTasksByOffset[targetOffset] = nil }
                do {
                    let snapshot = try await buildSnapshot(
                        for: targetOffset,
                        apiKey: apiKey,
                        agentId: agentId,
                        timezone: timezone
                    )
                    Self.weeklySnapshotByKey[snapshot.cacheKey] = WeeklySnapshot(
                        cachedAt: snapshot.cachedAt,
                        summary: snapshot.summary
                    )
                    persistDiskCache()
                } catch {
                    // Ignore prefetch failures; on-demand refresh handles visible week.
                }
            }
        }
    }

    private func makeCacheKey(agentId: String, timezone: String, weekStartDay: String) -> String {
        "\(agentId)|\(timezone)|\(weekStartDay)"
    }

    private func loadDiskCacheIfNeeded() {
        guard !Self.didLoadDiskCache else { return }
        Self.didLoadDiskCache = true

        let url = Self.diskCacheFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: WeeklySnapshotCacheDTO].self, from: data)
            var hydrated: [String: WeeklySnapshot] = [:]
            for (key, value) in decoded {
                if let snapshot = value.toSnapshot() {
                    hydrated[key] = snapshot
                }
            }
            Self.weeklySnapshotByKey = hydrated
        } catch {
            // Keep warm startup path resilient; stale cache will be rebuilt automatically.
        }
    }

    private func persistDiskCache() {
        let serializable = Self.weeklySnapshotByKey.mapValues(WeeklySnapshotCacheDTO.init)
        let url = Self.diskCacheFileURL
        Task.detached(priority: .utility) {
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(serializable)
                try data.write(to: url, options: .atomic)
            } catch {
                // Cache persistence errors should never block UI rendering.
            }
        }
    }

    private func loadingSummary(
        for week: (start: Date, end: Date, days: [Date]),
        disableForwardNavigation: Bool
    ) -> JournalWeeklySummary {
        let rangeText = "\(Self.titleFormatter.string(from: week.start)) – \(Self.titleFormatter.string(from: week.end))"
        let days = week.days.enumerated().map { index, dayDate in
            JournalWeeklyDay(
                dayString: dayDate.getDayInfoFor4AMBoundary().dayString,
                label: Self.dayLabelFormatter.string(from: dayDate),
                progress: CGFloat(index) / CGFloat(max(week.days.count - 1, 1)),
                isMuted: Calendar.current.isDateInWeekend(dayDate),
                entry: nil
            )
        }
        return JournalWeeklySummary(
            title: "Agent week in review",
            dateRange: rangeText,
            description: "Loading weekly reports and activity...",
            disableForwardNavigation: disableForwardNavigation,
            days: days,
            digest: JournalWeeklyDigest(
                publishedReportDays: 0,
                totalEvents: 0,
                activeCategoryCount: 0,
                mostActiveDayLabel: nil,
                blankDays: 0,
                nextWeekSuggestion: "Preparing weekly digest..."
            )
        )
    }

    private func fetchActivitiesByDay(
        apiKey: String,
        agentId: String,
        timezone: String,
        dayStrings: [String]
    ) async -> [String: CodeBlogAPIService.AgentActivityResponse] {
        await withTaskGroup(
            of: (String, CodeBlogAPIService.AgentActivityResponse?).self,
            returning: [String: CodeBlogAPIService.AgentActivityResponse].self
        ) { group in
            for dayString in dayStrings {
                group.addTask { [api] in
                    let response = try? await api.getAgentActivity(
                        apiKey: apiKey,
                        agentId: agentId,
                        date: dayString,
                        timezone: timezone
                    )
                    return (dayString, response)
                }
            }

            var byDay: [String: CodeBlogAPIService.AgentActivityResponse] = [:]
            for await (dayString, response) in group {
                if let response {
                    byDay[dayString] = response
                }
            }
            return byDay
        }
    }
}
