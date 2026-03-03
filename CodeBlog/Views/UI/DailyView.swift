import SwiftUI
import Foundation
import AppKit
import CryptoKit

private let dailyTodayDisplayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "'Today,' MMMM d"
    return formatter
}()

private let dailyOtherDayDisplayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter
}()

private enum DailyGridConfig {
    static let visibleStartMinute: Double = 9 * 60
    static let visibleEndMinute: Double = 21 * 60
    static let slotDurationMinutes: Double = 15
    static let fallbackCategoryNames = ["Research", "Design", "Alignment", "Testing", "General"]
    static let fallbackColorHexes = ["5E90D9", "A166DB", "4BBFB7", "F38565", "8B8480"]
    static let agentCategoryNames = ["Browse", "Review", "Comment", "Vote", "Post", "Chat"]
    static let agentColorHexes = ["5E90D9", "A166DB", "4BBFB7", "F38565", "F96E00", "8B8480"]
}

private enum DailyStandupCopyState: Equatable {
    case idle
    case syncing
    case copied
}

struct DailyView: View {
    @AppStorage("isDailyUnlocked") private var isUnlocked: Bool = false
    @AppStorage("useAgentDailyDataView") private var useAgentDailyDataView: Bool = true
    @AppStorage("agentNotificationsMuted") private var agentNotificationsMuted: Bool = false
    @Binding var selectedDate: Date
    @EnvironmentObject private var categoryStore: CategoryStore
    @Environment(\.openURL) private var openURL

    @State private var accessCode: String = ""
    @State private var attempts: Int = 0
    @State private var workflowRows: [DailyWorkflowGridRow] = []
    @State private var workflowTotals: [DailyWorkflowTotalItem] = []
    @State private var workflowStats: [DailyWorkflowStatChip] = DailyWorkflowStatChip.placeholder
    @State private var workflowWindow: DailyWorkflowTimelineWindow = .placeholder
    @State private var workflowLoadTask: Task<Void, Never>? = nil
    @State private var standupDraft: DailyStandupDraft = .default
    @State private var loadedStandupDraftDay: String? = nil
    @State private var standupDraftSaveTask: Task<Void, Never>? = nil
    @State private var standupCopyState: DailyStandupCopyState = .idle
    @State private var standupCopyResetTask: Task<Void, Never>? = nil
    @StateObject private var agentDailyViewModel = AgentDailyViewModel()
    @State private var isApplyingAgentDraft: Bool = false
    @State private var agentActiveMode: DailyModeToggle.ActiveMode = .highlights
    @State private var agentNotificationsTitle: String = "Notifications"
    @State private var agentNotificationsItems: [DailyBulletItem] = []
    @State private var agentNotesTitle: String = "Agent notes"
    @State private var agentNotesItems: [DailyBulletItem] = []
    @State private var agentMemoryTitle: String = "Agent memory"
    @State private var agentMemoryItems: [DailyBulletItem] = []
    @State private var agentPendingReviewEntries: [AgentReviewEntry] = []
    @State private var agentRejectedReviewEntries: [AgentReviewEntry] = []
    @State private var reviewActionInFlight: Set<String> = []
    @State private var showsAgentEventsPanel: Bool = false
    @State private var highlightedAgentEvent: AgentActivityHighlight?

    private let requiredCodeHash = "6979ce2825cb3f440f987bbc487d62087c333abb99b56062c561ca557392d960"
    private let betaNoticeCopy = "CodeBlog Daily visualizes your coding day and turns it into a standup update fast."
    private let onboardingNoticeCopy = "We’re rolling out access gradually. If you’re interested, book a quick call and we’ll get you set up."
    private let onboardingBookingURL = "https://cal.com/simen-yifei/15min"

    var body: some View {
        ZStack {
            #if DEBUG
            unlockedContent
            #else
            if isUnlocked {
                unlockedContent
                    .transition(.opacity)
            } else {
                lockScreen
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var lockScreen: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 4) {
                Text("CodeBlog Daily")
                    .font(.custom("InstrumentSerif-Italic", size: 38))
                    .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))

                Text("BETA")
                    .font(.custom("Nunito-Bold", size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.98, green: 0.55, blue: 0.20))
                    )
                    .rotationEffect(.degrees(-12))
                    .offset(x: -4, y: -4)
            }

            Text(betaNoticeCopy)
                .font(.custom("Nunito-Regular", size: 15))
                .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)

            accessCodeCard
                .modifier(Shake(animatableData: CGFloat(attempts)))
                .padding(.top, 6)

            VStack(spacing: 8) {
                Text(onboardingNoticeCopy)
                    .font(.custom("Nunito-Regular", size: 13))
                    .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24)

                CodeBlogSurfaceButton(
                    action: openManualOnboardingBooking,
                    content: {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Book a Time")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        }
                    },
                    background: Color(red: 0.25, green: 0.17, blue: 0),
                    foreground: .white,
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 16,
                    verticalPadding: 10,
                    showOverlayStroke: true
                )
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            GeometryReader { geo in
                Image("JournalPreview")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)
            }
        )
    }

    private var accessCodeCard: some View {
        ZStack(alignment: .bottom) {
            Image("JournalLock")
                .resizable()
                .aspectRatio(contentMode: .fit)

            VStack(spacing: 16) {
                Text("Enter access code")
                    .font(.custom("Nunito-SemiBold", size: 20))
                    .foregroundColor(Color(red: 0.85, green: 0.45, blue: 0.25))

                TextField("", text: $accessCode)
                    .textFieldStyle(.plain)
                    .font(.custom("Nunito-Medium", size: 15))
                    .foregroundColor(Color(red: 0.25, green: 0.15, blue: 0.10))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white)
                    )
                    .padding(.horizontal, 80)
                    .submitLabel(.go)
                    .onSubmit { validateCode() }

                Button(action: validateCode) {
                    Text("Get early access")
                        .font(.custom("Nunito-SemiBold", size: 15))
                        .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 1.0, green: 0.92, blue: 0.82),
                                            Color(red: 1.0, green: 0.85, blue: 0.70)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color(red: 0.90, green: 0.75, blue: 0.55), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.bottom, 28)
        }
        .frame(width: 380)
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 6)
    }

    private var unlockedContent: some View {
        GeometryReader { geometry in
            let baselineWidth: CGFloat = 950
            let rawContentWidth = max(320, geometry.size.width)
            let scale = min(max(rawContentWidth / baselineWidth, 0.82), 1.18)
            let horizontalInset = 16 * scale
            let topInset = max(22, 20 * scale)
            let bottomInset = 16 * scale
            let sectionSpacing = 20 * scale
            let contentWidth = max(320, geometry.size.width - (horizontalInset * 2))
            let useSingleColumn = contentWidth < (840 * scale)
            let isViewingToday = isTodaySelection(selectedDate)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    topControls(scale: scale)
                    workflowSection(scale: scale, isViewingToday: isViewingToday)
                    actionRow(useSingleColumn: useSingleColumn, scale: scale)
                    highlightsAndTasksSection(
                        useSingleColumn: useSingleColumn,
                        contentWidth: contentWidth,
                        scale: scale,
                        showData: useAgentDailyDataView ? true : !isViewingToday
                    )
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            refreshWorkflowData()
            if useAgentDailyDataView {
                loadCachedAgentDailyData()
            }
        }
        .onDisappear {
            workflowLoadTask?.cancel()
            workflowLoadTask = nil
            standupDraftSaveTask?.cancel()
            standupDraftSaveTask = nil
            standupCopyResetTask?.cancel()
            standupCopyResetTask = nil
        }
        .onChange(of: selectedDate) { _, _ in
            refreshWorkflowData()
            highlightedAgentEvent = nil
            if useAgentDailyDataView {
                loadCachedAgentDailyData()
            }
        }
        .onChange(of: standupDraft) { _, _ in
            if useAgentDailyDataView || isApplyingAgentDraft {
                return
            }
            scheduleStandupDraftSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { notification in
            guard let dayString = notification.userInfo?["dayString"] as? String else {
                return
            }
            if dayString == workflowDayString(for: selectedDate) {
                refreshWorkflowData()
                if useAgentDailyDataView {
                    loadCachedAgentDailyData()
                }
            }
        }
        .sheet(isPresented: $showsAgentEventsPanel) {
            AgentEventsPanel(
                dateTitle: dailyDateTitle(for: selectedDate),
                events: buildAgentEventPanelItems()
            ) { selection in
                highlightedAgentEvent = selection
                showsAgentEventsPanel = false
            }
        }
    }

    private func validateCode() {
        let inputLowercased = accessCode.lowercased()
        let inputData = Data(inputLowercased.utf8)
        let inputHash = SHA256.hash(data: inputData)
        let inputHashString = inputHash.compactMap { String(format: "%02x", $0) }.joined()

        if inputHashString == requiredCodeHash {
            AnalyticsService.shared.capture("daily_unlocked")
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                isUnlocked = true
            }
        } else {
            withAnimation(.default) {
                attempts += 1
                accessCode = ""
            }
        }
    }

    private func openManualOnboardingBooking() {
        guard let url = URL(string: onboardingBookingURL) else { return }
        AnalyticsService.shared.capture("daily_manual_onboarding_booking_opened", [
            "source": "daily_lock_screen",
            "url": onboardingBookingURL
        ])
        openURL(url)
    }

    private func topControls(scale: CGFloat) -> some View {
        VStack(spacing: 10 * scale) {
            HStack(spacing: 10 * scale) {
                DailyCircleNavButton(iconName: "chevron.left", isDisabled: false, scale: scale) {
                    shiftDate(by: -1)
                }

                Text(dailyDateTitle(for: selectedDate))
                    .font(.custom("InstrumentSerif-Regular", size: 26 * scale))
                    .foregroundStyle(Color(hex: "1E1B18"))

                let canMoveForward = canNavigateForward(from: selectedDate)
                DailyCircleNavButton(iconName: "chevron.right", isDisabled: !canMoveForward, scale: scale) {
                    guard canMoveForward else { return }
                    shiftDate(by: 1)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func isTodaySelection(_ date: Date) -> Bool {
        let displayDate = timelineDisplayDate(from: date)
        let timelineToday = timelineDisplayDate(from: Date())
        return Calendar.current.isDate(displayDate, inSameDayAs: timelineToday)
    }

    private func workflowSection(scale: CGFloat, isViewingToday: Bool) -> some View {
        let headingText: String
        if useAgentDailyDataView {
            headingText = "Agent activity timeline"
        } else {
            headingText = isViewingToday
                ? "Come back tomorrow to see this filled out."
                : "Your workflow yesterday"
        }

        return VStack(alignment: .leading, spacing: 8 * scale) {
            HStack {
                Text(headingText)
                    .font(.custom("InstrumentSerif-Regular", size: 24 * scale))
                    .foregroundStyle(Color(hex: "B46531"))

                Spacer()

                Button {
                    if useAgentDailyDataView {
                        showsAgentEventsPanel = true
                    }
                } label: {
                    HStack(spacing: 4 * scale) {
                        Image(systemName: useAgentDailyDataView ? "waveform.path.ecg" : "pencil")
                            .font(.system(size: 9 * scale, weight: .medium))
                        Text(useAgentDailyDataView ? "Agent events" : "Edit categories")
                            .font(.custom("Nunito-Regular", size: 10 * scale))
                    }
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 5 * scale)
                    .foregroundStyle(Color(hex: "D17C45"))
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(hex: "FFF2E6"))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color(hex: "E6C6A8"), lineWidth: max(0.6, 0.8 * scale))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursorOnHover(reassertOnPressEnd: true)
            }

            VStack(spacing: 0) {
                DailyWorkflowGrid(
                    rows: workflowRows,
                    timelineWindow: workflowWindow,
                    scale: scale,
                    highlightedCategoryKey: highlightedAgentEvent?.categoryKey,
                    highlightedSlotRange: highlightedAgentEvent?.slotRange
                )

                Divider()
                    .overlay(Color(hex: "E5DFD9"))

                workflowTotalsView(scale: scale, isViewingToday: isViewingToday)
                    .padding(.horizontal, 16 * scale)
                    .padding(.top, 14 * scale)
                    .padding(.bottom, 12 * scale)
            }
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color(hex: "E8E1DA"), lineWidth: max(0.7, 1 * scale))
            )
        }
    }

    private func workflowTotalsView(scale: CGFloat, isViewingToday: Bool) -> some View {
        Group {
            if useAgentDailyDataView {
                if workflowTotals.isEmpty || workflowTotals.allSatisfy({ $0.minutes == 0 }) {
                    Text("No agent activity events for this day yet.")
                        .font(.custom("Nunito-Regular", size: 12 * scale))
                        .foregroundStyle(Color(hex: "7F7062"))
                } else {
                    HStack(spacing: 8 * scale) {
                        Text("Agent activity")
                            .font(.custom("InstrumentSerif-Regular", size: 14 * scale))
                            .foregroundStyle(Color(hex: "777777"))

                        ForEach(workflowTotals) { total in
                            if total.minutes > 0 {
                                HStack(spacing: 2 * scale) {
                                    Text(total.name)
                                        .font(.custom("Nunito-Regular", size: 12 * scale))
                                        .foregroundStyle(Color(hex: "1F1B18"))
                                    Text("\(Int(total.minutes)) events")
                                        .font(.custom("Nunito-SemiBold", size: 12 * scale))
                                        .foregroundStyle(Color(hex: total.colorHex))
                                }
                            }
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            } else if isViewingToday {
                Text("Yesterday's total")
                    .font(.custom("InstrumentSerif-Regular", size: 14 * scale))
                    .foregroundStyle(Color(hex: "777777"))
            } else if workflowTotals.isEmpty {
                Text("Yesterday's total  No captured activity during 9am-9pm")
                    .font(.custom("Nunito-Regular", size: 12 * scale))
                    .foregroundStyle(Color(hex: "7F7062"))
            } else {
                HStack(spacing: 8 * scale) {
                    Text("Yesterday's total")
                        .font(.custom("InstrumentSerif-Regular", size: 14 * scale))
                        .foregroundStyle(Color(hex: "777777"))

                    ForEach(workflowTotals) { total in
                        HStack(spacing: 2 * scale) {
                            Text(total.name)
                                .font(.custom("Nunito-Regular", size: 12 * scale))
                                .foregroundStyle(Color(hex: "1F1B18"))
                            Text(formatDuration(minutes: total.minutes))
                                .font(.custom("Nunito-SemiBold", size: 12 * scale))
                                .foregroundStyle(Color(hex: total.colorHex))
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
    }

    @ViewBuilder
    private func actionRow(useSingleColumn: Bool, scale: CGFloat) -> some View {
        let leadingToggleText = useAgentDailyDataView ? "Notes" : "Highlights"
        let trailingToggleText = useAgentDailyDataView ? "Memory" : "Details"
        let onSelect: ((DailyModeToggle.ActiveMode) -> Void)? = useAgentDailyDataView ? { mode in
            withAnimation(.easeInOut(duration: 0.2)) {
                agentActiveMode = mode
            }
        } : nil

        if useSingleColumn {
            VStack(alignment: .leading, spacing: 10 * scale) {
                DailyModeToggle(
                    activeMode: useAgentDailyDataView ? agentActiveMode : .highlights,
                    scale: scale,
                    leadingText: leadingToggleText,
                    trailingText: trailingToggleText,
                    onSelect: onSelect
                )
                syncActionCluster(scale: scale)
            }
        } else {
            HStack(alignment: .top) {
                DailyModeToggle(
                    activeMode: useAgentDailyDataView ? agentActiveMode : .highlights,
                    scale: scale,
                    leadingText: leadingToggleText,
                    trailingText: trailingToggleText,
                    onSelect: onSelect
                )
                Spacer()
                syncActionCluster(scale: scale)
            }
        }
    }

    @ViewBuilder
    private func syncActionCluster(scale: CGFloat) -> some View {
        standupCopyButton(scale: scale)
    }

    private func agentNotificationMuteInlineButton(scale: CGFloat) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                agentNotificationsMuted.toggle()
            }
        } label: {
            Image(systemName: agentNotificationsMuted ? "bell.slash.fill" : "bell.fill")
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(agentNotificationsMuted ? Color(hex: "B64C38") : Color(hex: "7A6A5D"))
                .padding(.horizontal, 9 * scale)
                .padding(.vertical, 6 * scale)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(hex: "FFF6EE"))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            agentNotificationsMuted ? Color(hex: "E7B7A9") : Color(hex: "E9D8CB"),
                            lineWidth: max(0.7, 1 * scale)
                        )
                )
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.2), value: agentNotificationsMuted)
        }
        .buttonStyle(.plain)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
        .accessibilityLabel(Text("Mute agent system notifications"))
    }

    private func notificationsHeaderAccessory(scale: CGFloat) -> AnyView? {
        guard useAgentDailyDataView else { return nil }
        return AnyView(
            agentNotificationMuteInlineButton(scale: scale)
        )
    }

    private func standupCopyButton(scale: CGFloat) -> some View {
        let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))
        let isSyncing = useAgentDailyDataView && (agentDailyViewModel.isLoading || standupCopyState == .syncing)
        let isSynced = standupCopyState == .copied
        let buttonLabelText: String = {
            if useAgentDailyDataView {
                if isSyncing { return "Syncing with Agent" }
                if isSynced { return "Synced" }
                return "Sync with Agent"
            }
            return isSynced ? "Copied" : "Copy standup update"
        }()
        let accessibilityText: String = {
            if useAgentDailyDataView {
                if isSyncing { return "Syncing agent data" }
                if isSynced { return "Agent data synced" }
                return "Sync agent data"
            }
            return isSynced ? "Copied standup update" : "Copy standup update"
        }()

        return Button(action: {
            if useAgentDailyDataView {
                refreshAgentDailyData(forceRemote: true, showFeedback: true)
            } else {
                copyStandupUpdateToClipboard()
            }
        }) {
            HStack(spacing: 6 * scale) {
                ZStack {
                    if isSynced {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12 * scale, weight: .semibold))
                            .transition(transition)
                    } else if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                            .transition(transition)
                    } else {
                        Image(systemName: useAgentDailyDataView ? "arrow.triangle.2.circlepath" : "doc.on.doc")
                            .font(.system(size: 13 * scale, weight: .semibold))
                            .transition(transition)
                    }
                }
                .frame(width: 16 * scale, height: 16 * scale)

                Text(buttonLabelText)
                    .font(.custom("Nunito-Medium", size: 14 * scale))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 10 * scale)
            .background(
                LinearGradient(
                    colors: [
                        Color(hex: "FF986F"),
                        Color(hex: "BDAAFF")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(hex: "F2D7C3"), lineWidth: max(1.2, 1.5 * scale))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(DailyCopyPressButtonStyle())
        .animation(.easeInOut(duration: 0.22), value: standupCopyState)
        .animation(.easeInOut(duration: 0.22), value: agentDailyViewModel.isLoading)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
        .accessibilityLabel(Text(accessibilityText))
    }

    private func highlightsTitleBinding() -> Binding<String> {
        if useAgentDailyDataView {
            return $agentNotificationsTitle
        }
        return $standupDraft.highlightsTitle
    }

    private func highlightsItemsBinding() -> Binding<[DailyBulletItem]> {
        if useAgentDailyDataView {
            return $agentNotificationsItems
        }
        return $standupDraft.highlights
    }

    private func tasksTitleBinding() -> Binding<String> {
        if useAgentDailyDataView {
            return agentActiveMode == .highlights ? $agentNotesTitle : $agentMemoryTitle
        }
        return $standupDraft.tasksTitle
    }

    private func tasksItemsBinding() -> Binding<[DailyBulletItem]> {
        if useAgentDailyDataView {
            return agentActiveMode == .highlights ? $agentNotesItems : $agentMemoryItems
        }
        return $standupDraft.tasks
    }

    private func blockersTitleBinding() -> Binding<String> {
        return $standupDraft.blockersTitle
    }

    private func blockersBodyBinding() -> Binding<String> {
        return $standupDraft.blockersBody
    }

    @ViewBuilder
    private func highlightsAndTasksSection(useSingleColumn: Bool, contentWidth: CGFloat, scale: CGFloat, showData: Bool) -> some View {
        let leadingReviewEntries = reviewEntriesForCurrentMode(onLeadingCard: true)
        let trailingReviewEntries = reviewEntriesForCurrentMode(onLeadingCard: false)

        if useSingleColumn {
            VStack(alignment: .leading, spacing: 12 * scale) {
                DailyBulletCard(
                    style: .highlights,
                    seamMode: .standalone,
                    title: highlightsTitleBinding(),
                    items: highlightsItemsBinding(),
                    showItems: showData,
                    addTaskLabel: $standupDraft.addTaskLabel,
                    blockersTitle: blockersTitleBinding(),
                    blockersBody: blockersBodyBinding(),
                    scale: scale,
                    isReadOnly: useAgentDailyDataView,
                    reviewEntries: leadingReviewEntries,
                    reviewActionInFlight: reviewActionInFlight,
                    reviewFeedbackMessage: agentDailyViewModel.reviewFeedbackMessage,
                    reviewErrorMessage: agentDailyViewModel.errorMessage,
                    onApproveReview: approveNotificationReview,
                    onRejectReview: rejectNotificationReview,
                    onUndoReview: undoNotificationReview,
                    onOpenLinkedItem: openLinkedTimelineItem,
                    showsBlockersSection: !useAgentDailyDataView,
                    headerAccessory: notificationsHeaderAccessory(scale: scale),
                    headerActionTitle: nil,
                    headerActionStyle: .subtle,
                    onHeaderAction: nil
                )
                DailyBulletCard(
                    style: .tasks,
                    seamMode: .standalone,
                    title: tasksTitleBinding(),
                    items: tasksItemsBinding(),
                    showItems: showData,
                    addTaskLabel: $standupDraft.addTaskLabel,
                    blockersTitle: blockersTitleBinding(),
                    blockersBody: blockersBodyBinding(),
                    scale: scale,
                    isReadOnly: useAgentDailyDataView,
                    reviewEntries: trailingReviewEntries,
                    reviewActionInFlight: reviewActionInFlight,
                    reviewFeedbackMessage: agentDailyViewModel.reviewFeedbackMessage,
                    reviewErrorMessage: agentDailyViewModel.errorMessage,
                    onApproveReview: approveNotificationReview,
                    onRejectReview: rejectNotificationReview,
                    onUndoReview: undoNotificationReview,
                    onOpenLinkedItem: openLinkedTimelineItem,
                    showsBlockersSection: !useAgentDailyDataView,
                    headerAccessory: nil,
                    headerActionTitle: useAgentDailyDataView && agentActiveMode == .details ? "Memory tuning" : nil,
                    headerActionStyle: .gradientPulse,
                    onHeaderAction: useAgentDailyDataView && agentActiveMode == .details ? openMemoryTuningChat : nil
                )
            }
        } else {
            // Figma overlaps borders by ~1px to avoid a visible gutter.
            let cardSpacing = -1 * scale
            let cardWidths: (leading: CGFloat, trailing: CGFloat) = {
                if useAgentDailyDataView {
                    let availableWidth = contentWidth - cardSpacing
                    let leading = max(360, availableWidth * 0.58)
                    return (leading, max(240, availableWidth - leading))
                }
                let equal = (contentWidth - cardSpacing) / 2
                return (equal, equal)
            }()
            HStack(alignment: .top, spacing: cardSpacing) {
                DailyBulletCard(
                    style: .highlights,
                    seamMode: .joinedLeading,
                    title: highlightsTitleBinding(),
                    items: highlightsItemsBinding(),
                    showItems: showData,
                    addTaskLabel: $standupDraft.addTaskLabel,
                    blockersTitle: blockersTitleBinding(),
                    blockersBody: blockersBodyBinding(),
                    scale: scale,
                    isReadOnly: useAgentDailyDataView,
                    reviewEntries: leadingReviewEntries,
                    reviewActionInFlight: reviewActionInFlight,
                    reviewFeedbackMessage: agentDailyViewModel.reviewFeedbackMessage,
                    reviewErrorMessage: agentDailyViewModel.errorMessage,
                    onApproveReview: approveNotificationReview,
                    onRejectReview: rejectNotificationReview,
                    onUndoReview: undoNotificationReview,
                    onOpenLinkedItem: openLinkedTimelineItem,
                    showsBlockersSection: !useAgentDailyDataView,
                    headerAccessory: notificationsHeaderAccessory(scale: scale),
                    headerActionTitle: nil,
                    headerActionStyle: .subtle,
                    onHeaderAction: nil
                )
                    .frame(width: cardWidths.leading)

                DailyBulletCard(
                    style: .tasks,
                    seamMode: .joinedTrailing,
                    title: tasksTitleBinding(),
                    items: tasksItemsBinding(),
                    showItems: showData,
                    addTaskLabel: $standupDraft.addTaskLabel,
                    blockersTitle: blockersTitleBinding(),
                    blockersBody: blockersBodyBinding(),
                    scale: scale,
                    isReadOnly: useAgentDailyDataView,
                    reviewEntries: trailingReviewEntries,
                    reviewActionInFlight: reviewActionInFlight,
                    reviewFeedbackMessage: agentDailyViewModel.reviewFeedbackMessage,
                    reviewErrorMessage: agentDailyViewModel.errorMessage,
                    onApproveReview: approveNotificationReview,
                    onRejectReview: rejectNotificationReview,
                    onUndoReview: undoNotificationReview,
                    onOpenLinkedItem: openLinkedTimelineItem,
                    showsBlockersSection: !useAgentDailyDataView,
                    headerAccessory: nil,
                    headerActionTitle: useAgentDailyDataView && agentActiveMode == .details ? "Memory tuning" : nil,
                    headerActionStyle: .gradientPulse,
                    onHeaderAction: useAgentDailyDataView && agentActiveMode == .details ? openMemoryTuningChat : nil
                )
                    .frame(width: cardWidths.trailing)
            }
        }
    }

    private func refreshWorkflowData() {
        workflowLoadTask?.cancel()
        workflowLoadTask = nil

        if useAgentDailyDataView {
            applyAgentActivityToWorkflow()
            return
        }

        let dayString = workflowDayString(for: selectedDate)
        refreshStandupDraftIfNeeded(for: dayString)

        if isTodaySelection(selectedDate) {
            workflowRows = []
            workflowTotals = []
            workflowStats = DailyWorkflowStatChip.placeholder
            workflowWindow = .placeholder
            return
        }

        let categorySnapshot = categoryStore.categories

        workflowLoadTask = Task.detached(priority: .userInitiated) {
            let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
            let computed = computeDailyWorkflow(cards: cards, categories: categorySnapshot)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                workflowRows = computed.rows
                workflowTotals = computed.totals
                workflowStats = computed.stats
                workflowWindow = computed.window
            }
        }
    }

    private func copyStandupUpdateToClipboard() {
        let clipboardText = standupClipboardText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardText, forType: .string)

        standupCopyResetTask?.cancel()

        withAnimation(.easeInOut(duration: 0.22)) {
            standupCopyState = .copied
        }

        AnalyticsService.shared.capture("daily_standup_copied", [
            "timeline_day": workflowDayString(for: selectedDate),
            "highlights_count": standupDraft.highlights.count,
            "tasks_count": standupDraft.tasks.count
        ])

        standupCopyResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.22)) {
                    standupCopyState = .idle
                }
                standupCopyResetTask = nil
            }
        }
    }

    private func refreshAgentDailyData(forceRemote: Bool = false, showFeedback: Bool = false) {
        if showFeedback {
            standupCopyResetTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) {
                standupCopyState = .syncing
            }
        }
        Task {
            await agentDailyViewModel.refresh(for: selectedDate, forceRemote: forceRemote)
            applyAgentDataToDraft()
            applyAgentActivityToWorkflow()
            if showFeedback {
                if agentDailyViewModel.errorMessage == nil {
                    indicateRefreshCompleted()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        standupCopyState = .idle
                    }
                }
            }
        }
    }

    private func loadCachedAgentDailyData() {
        agentDailyViewModel.loadCached(for: selectedDate)
        applyAgentDataToDraft()
        applyAgentActivityToWorkflow()
    }

    private func applyAgentDataToDraft() {
        guard useAgentDailyDataView else { return }

        isApplyingAgentDraft = true
        defer { isApplyingAgentDraft = false }

        let pendingEntries = agentDailyViewModel.pendingReviews.prefix(6).map {
            buildReviewEntry(from: $0, isRejected: false)
        }
        let rejectedEntries = agentDailyViewModel.rejectedReviews.prefix(4).map {
            buildReviewEntry(from: $0, isRejected: true)
        }

        agentPendingReviewEntries = pendingEntries
        agentRejectedReviewEntries = rejectedEntries

        let pendingItems: [DailyBulletItem]
        if pendingEntries.isEmpty && rejectedEntries.isEmpty {
            pendingItems = [
                DailyBulletItem(
                    title: "No notifications",
                    body: "No pending notification items for this date."
                )
            ]
        } else {
            var mapped: [DailyBulletItem] = pendingEntries.map {
                DailyBulletItem(title: $0.title, body: $0.body)
            }
            if !rejectedEntries.isEmpty {
                mapped.append(contentsOf: rejectedEntries.map {
                    DailyBulletItem(title: "\($0.title) (Rejected)", body: $0.body)
                })
            }
            pendingItems = mapped
        }

        let noteItems: [DailyBulletItem]
        if agentDailyViewModel.notes.isEmpty {
            noteItems = [
                DailyBulletItem(
                    title: "No agent notes yet",
                    body: "No local agent cards found for this date.",
                    meta: nil,
                    linkedPreviewId: nil,
                    linkedDayString: nil
                )
            ]
        } else {
            noteItems = agentDailyViewModel.notes.prefix(6).map { note in
                let summary = note.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let metadata = "\(note.cardType.uppercased()) · \(note.time)"
                return DailyBulletItem(
                    title: note.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: summary.isEmpty ? "No summary available." : summary,
                    meta: metadata,
                    linkedPreviewId: note.previewId,
                    linkedDayString: note.dayString
                )
            }
        }

        let memoryItems = buildAgentMemoryItems()

        agentNotificationsTitle = "Notifications"
        agentNotificationsItems = pendingItems
        agentNotesTitle = "Agent notes"
        agentNotesItems = noteItems
        agentMemoryTitle = "Agent memory"
        agentMemoryItems = memoryItems
    }

    private func applyAgentActivityToWorkflow() {
        guard useAgentDailyDataView else { return }

        guard let activity = agentDailyViewModel.activity else {
            workflowWindow = .placeholder
            workflowTotals = []
            workflowStats = DailyWorkflowStatChip.placeholder
            workflowRows = DailyGridConfig.agentCategoryNames.enumerated().map { index, name in
                DailyWorkflowGridRow(
                    id: "agent-placeholder-\(index)",
                    name: name,
                    colorHex: DailyGridConfig.agentColorHexes[index % DailyGridConfig.agentColorHexes.count],
                    slotOccupancies: Array(repeating: 0, count: workflowWindow.slotCount)
                )
            }
            return
        }

        let maxCount = max(
            activity.rows.flatMap(\.slot_counts).max() ?? 1,
            1
        )

        workflowWindow = DailyWorkflowTimelineWindow(
            startMinute: Double(activity.start_minute),
            endMinute: Double(activity.end_minute)
        )
        workflowRows = activity.rows.map { row in
            DailyWorkflowGridRow(
                id: row.key,
                name: row.label,
                colorHex: row.color_hex,
                slotOccupancies: row.slot_counts.map { count in
                    guard count > 0 else { return 0 }
                    return min(1, Double(count) / Double(maxCount))
                }
            )
        }
        workflowTotals = activity.totals.map { total in
            DailyWorkflowTotalItem(
                id: total.key,
                name: total.label,
                minutes: Double(total.total_events),
                colorHex: total.color_hex
            )
        }
        workflowStats = [
            DailyWorkflowStatChip(
                id: "event-count",
                title: "Events",
                value: "\(workflowTotals.reduce(0) { $0 + Int($1.minutes) })"
            ),
            DailyWorkflowStatChip(
                id: "active-categories",
                title: "Active categories",
                value: "\(workflowTotals.filter { $0.minutes > 0 }.count)"
            ),
            DailyWorkflowStatChip(
                id: "window",
                title: "Window",
                value: "\(formatAxisHourLabel(fromAbsoluteHour: Int(activity.start_minute / 60)))-\(formatAxisHourLabel(fromAbsoluteHour: Int(activity.end_minute / 60)))"
            )
        ]
    }

    private func buildReviewEntry(
        from notification: CodeBlogAPIService.NotificationItem,
        isRejected: Bool
    ) -> AgentReviewEntry {
        let postID = (notification.comment_post_id ?? notification.post_id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = agentDailyViewModel.postTitle(for: notification)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? "Post awaiting review"
        let content = (notification.comment_content ?? notification.message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentReviewEntry(
            id: notification.id,
            title: resolvedTitle,
            body: content.isEmpty ? "No comment preview available." : content,
            isRejected: isRejected,
            postId: postID
        )
    }

    private func buildAgentMemoryItems() -> [DailyBulletItem] {
        var items: [DailyBulletItem] = []

        if let profile = agentDailyViewModel.memoryProfileV2 {
            appendMemoryGroup(
                title: "Thoughts",
                values: profile.thoughts,
                body: "How your agent currently interprets your direction.",
                into: &items
            )
            appendMemoryGroup(
                title: "Tone",
                values: profile.tone,
                body: "How your preferred communication style is evolving.",
                into: &items
            )
            appendMemoryGroup(
                title: "Preferences",
                values: profile.preferences,
                body: "What topics and response patterns your agent now prioritizes.",
                into: &items
            )
            appendMemoryGroup(
                title: "Habits",
                values: profile.habits,
                body: "Recurring collaboration patterns your agent has learned.",
                into: &items
            )
            appendMemoryGroup(
                title: "Recent context",
                values: profile.recent,
                body: "Recent signals that shaped the latest behavior.",
                into: &items
            )
            appendMemoryGroup(
                title: "Tech stack",
                values: profile.tech_stack,
                body: "Technologies your current conversations focus on.",
                into: &items
            )

            let note = profile.agent_note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                items.append(
                    DailyBulletItem(
                        title: "Agent self-note",
                        body: note,
                        meta: "Updated \(profile.updated_at)",
                        linkedPreviewId: nil,
                        linkedDayString: nil
                    )
                )
            }
        } else if let profile = agentDailyViewModel.memoryProfile,
                  let summary = profile.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty {
            items.append(
                DailyBulletItem(
                    title: "Agent memory snapshot",
                    body: summary,
                    meta: nil,
                    linkedPreviewId: nil,
                    linkedDayString: nil
                )
            )
        } else {
            let approved = agentDailyViewModel.approvedRules.prefix(5)
            let rejected = agentDailyViewModel.rejectedRules.prefix(4)

            for rule in approved {
                items.append(
                    DailyBulletItem(
                        title: readableMemoryText(rule.text),
                        body: "Your agent now leans toward this pattern when responding.",
                        meta: "Used in \(rule.evidence_count) successful updates",
                        linkedPreviewId: nil,
                        linkedDayString: nil
                    )
                )
            }
            for rule in rejected {
                items.append(
                    DailyBulletItem(
                        title: readableMemoryText(rule.text),
                        body: "Your agent treats this pattern as less useful now.",
                        meta: "Marked as less helpful \(rule.evidence_count) times",
                        linkedPreviewId: nil,
                        linkedDayString: nil
                    )
                )
            }
        }

        if items.isEmpty {
            return [
                DailyBulletItem(
                    title: "No memory insights yet",
                    body: "Review notifications and chat naturally with your agent so memory can grow with real signals.",
                    meta: nil,
                    linkedPreviewId: nil,
                    linkedDayString: nil
                )
            ]
        }

        return items
    }

    private func appendMemoryGroup(
        title: String,
        values: [String],
        body: String,
        into items: inout [DailyBulletItem]
    ) {
        let normalized = values
            .map { readableMemoryText($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !normalized.isEmpty else { return }

        for value in normalized.prefix(3) {
            items.append(
                DailyBulletItem(
                    title: value,
                    body: body,
                    meta: title,
                    linkedPreviewId: nil,
                    linkedDayString: nil
                )
            )
        }
    }

    private func readableMemoryText(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? raw : stripped
    }

    private func buildAgentEventPanelItems() -> [AgentEventPanelItem] {
        guard let activity = agentDailyViewModel.activity else { return [] }
        let slotDuration = max(1, activity.slot_duration_minutes)
        var items: [AgentEventPanelItem] = []

        for row in activity.rows {
            let counts = row.slot_counts
            guard !counts.isEmpty else { continue }

            var cursor = 0
            while cursor < counts.count {
                guard counts[cursor] > 0 else {
                    cursor += 1
                    continue
                }

                let startSlot = cursor
                var endSlot = cursor
                var eventCount = 0
                while endSlot < counts.count, counts[endSlot] > 0 {
                    eventCount += counts[endSlot]
                    endSlot += 1
                }

                let slotRange = startSlot...(max(startSlot, endSlot - 1))
                let startMinute = activity.start_minute + (startSlot * slotDuration)
                let endMinute = activity.start_minute + (endSlot * slotDuration)
                let timeLabel = "\(formatAgentEventTime(startMinute)) - \(formatAgentEventTime(endMinute))"
                let summary = eventCount == 1 ? "1 event in this window." : "\(eventCount) events in this window."
                let id = "\(row.key)-\(startSlot)-\(endSlot)"

                items.append(
                    AgentEventPanelItem(
                        id: id,
                        categoryKey: row.key,
                        categoryLabel: row.label,
                        timeLabel: timeLabel,
                        summary: summary,
                        slotRange: slotRange
                    )
                )
                cursor = endSlot
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.slotRange.lowerBound == rhs.slotRange.lowerBound {
                return lhs.categoryLabel < rhs.categoryLabel
            }
            return lhs.slotRange.lowerBound < rhs.slotRange.lowerBound
        }
    }

    private func formatAgentEventTime(_ minute: Int) -> String {
        let clamped = max(0, minute)
        let hour24 = (clamped / 60) % 24
        let minutePart = clamped % 60
        let period = hour24 >= 12 ? "PM" : "AM"
        let displayHour = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d %@", displayHour, minutePart, period)
    }

    private func openLinkedTimelineItem(_ item: DailyBulletItem) {
        guard let previewId = item.linkedPreviewId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !previewId.isEmpty else {
            return
        }

        var userInfo: [String: Any] = ["previewId": previewId]
        if let linkedDayString = item.linkedDayString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !linkedDayString.isEmpty {
            userInfo["dayString"] = linkedDayString
        }

        NotificationCenter.default.post(
            name: .navigateToAgentPost,
            object: nil,
            userInfo: userInfo
        )
    }

    private func openMemoryTuningChat() {
        let topSignals = agentMemoryItems.prefix(3).map(\.title).joined(separator: " | ")
        let context = topSignals.isEmpty ? "No explicit memory cards yet." : topSignals
        let prompt = """
Help me fine-tune your memory based on our latest collaboration.
Current memory highlights: \(context)

Ask me focused questions to refine: thoughts, tone, preferences, habits, recent context, and tech stack.
Then summarize the refined memory profile in clear natural language.
"""

        NotificationCenter.default.post(
            name: .injectAgentPostToChat,
            object: nil,
            userInfo: [
                "title": "Memory tuning",
                "content": prompt,
                "cardType": "memory_tuning"
            ]
        )
    }

    private func reviewEntriesForCurrentMode(onLeadingCard: Bool) -> [AgentReviewEntry]? {
        guard useAgentDailyDataView else { return nil }
        guard onLeadingCard else { return nil }
        return agentPendingReviewEntries + agentRejectedReviewEntries
    }

    private func approveNotificationReview(_ notificationId: String) {
        runReviewAction(notificationId: notificationId) {
            await agentDailyViewModel.review(notificationId: notificationId, action: "approve")
        }
    }

    private func rejectNotificationReview(_ notificationId: String, note: String?) {
        runReviewAction(notificationId: notificationId) {
            await agentDailyViewModel.review(notificationId: notificationId, action: "reject", note: note)
        }
    }

    private func undoNotificationReview(_ notificationId: String) {
        runReviewAction(notificationId: notificationId) {
            await agentDailyViewModel.undoReview(notificationId: notificationId)
        }
    }

    private func runReviewAction(
        notificationId: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard !reviewActionInFlight.contains(notificationId) else { return }
        reviewActionInFlight.insert(notificationId)

        Task { @MainActor in
            defer {
                reviewActionInFlight.remove(notificationId)
            }
            await operation()
            await agentDailyViewModel.refresh(for: selectedDate, forceRemote: true)
            applyAgentDataToDraft()
            applyAgentActivityToWorkflow()
        }
    }

    private func indicateRefreshCompleted() {
        standupCopyResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.22)) {
            standupCopyState = .copied
        }

        standupCopyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.22)) {
                    standupCopyState = .idle
                }
                standupCopyResetTask = nil
            }
        }
    }

    private func standupClipboardText() -> String {
        var lines: [String] = []
        lines.append("Standup update (\(dailyDateTitle(for: selectedDate)))")
        lines.append("")
        lines.append(standupDraft.highlightsTitle)
        standupDraft.highlights.forEach { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !body.isEmpty else { return }
            if !title.isEmpty && !body.isEmpty {
                lines.append("- \(title) — \(body)")
            } else if !title.isEmpty {
                lines.append("- \(title)")
            } else {
                lines.append("- \(body)")
            }
        }
        lines.append("")
        lines.append(standupDraft.tasksTitle)
        standupDraft.tasks.forEach { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !body.isEmpty else { return }
            if !title.isEmpty && !body.isEmpty {
                lines.append("- \(title) — \(body)")
            } else if !title.isEmpty {
                lines.append("- \(title)")
            } else {
                lines.append("- \(body)")
            }
        }
        lines.append("")
        lines.append(standupDraft.blockersTitle)
        lines.append("- \(standupDraft.blockersBody)")
        return lines.joined(separator: "\n")
    }

    private func refreshStandupDraftIfNeeded(for dayString: String) {
        guard loadedStandupDraftDay != dayString else { return }
        loadedStandupDraftDay = dayString

        guard let entry = StorageManager.shared.fetchDailyStandup(forDay: dayString),
              let data = entry.payloadJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DailyStandupDraft.self, from: data) else {
            standupDraft = .default
            return
        }

        var normalized = decoded
        if normalized.addTaskLabel == "Add task" {
            normalized.addTaskLabel = ""
        }
        standupDraft = normalized
    }

    private func scheduleStandupDraftSave() {
        guard let dayString = loadedStandupDraftDay else { return }
        let draftToSave = standupDraft

        standupDraftSaveTask?.cancel()
        standupDraftSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            guard let data = try? JSONEncoder().encode(draftToSave),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }

            StorageManager.shared.saveDailyStandup(forDay: dayString, payloadJSON: json)
        }
    }

    private func workflowDayString(for date: Date) -> String {
        let anchorDate = timelineDisplayDate(from: date)
        return anchorDate.getDayInfoFor4AMBoundary().dayString
    }

    private func shiftDate(by days: Int) {
        let shifted = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
        selectedDate = normalizedTimelineDate(shifted)
    }

    private func dailyDateTitle(for date: Date) -> String {
        let displayDate = timelineDisplayDate(from: date)
        let timelineToday = timelineDisplayDate(from: Date())
        if Calendar.current.isDate(displayDate, inSameDayAs: timelineToday) {
            return dailyTodayDisplayFormatter.string(from: displayDate)
        }
        return dailyOtherDayDisplayFormatter.string(from: displayDate)
    }

    private func formatDuration(minutes: Double) -> String {
        let rounded = max(0, Int(minutes.rounded()))
        let hours = rounded / 60
        let mins = rounded % 60

        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }
}

private struct DailyCircleNavButton: View {
    let iconName: String
    let isDisabled: Bool
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(hex: "F4EFEA"))
                Circle()
                    .stroke(Color(hex: "E2DDD8"), lineWidth: max(0.7, 1 * scale))

                Image(systemName: iconName)
                    .font(.system(size: 13 * scale, weight: .medium))
                    .foregroundStyle(Color(hex: "C9C2BC").opacity(isDisabled ? 0.5 : 1.0))
            }
            .frame(width: 30 * scale, height: 30 * scale)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .pointingHandCursorOnHover(enabled: !isDisabled, reassertOnPressEnd: true)
    }
}

private struct DailyCopyPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct DailyWorkflowGrid: View {
    let rows: [DailyWorkflowGridRow]
    let timelineWindow: DailyWorkflowTimelineWindow
    let scale: CGFloat
    let highlightedCategoryKey: String?
    let highlightedSlotRange: ClosedRange<Int>?

    init(
        rows: [DailyWorkflowGridRow],
        timelineWindow: DailyWorkflowTimelineWindow,
        scale: CGFloat,
        highlightedCategoryKey: String? = nil,
        highlightedSlotRange: ClosedRange<Int>? = nil
    ) {
        self.rows = rows
        self.timelineWindow = timelineWindow
        self.scale = scale
        self.highlightedCategoryKey = highlightedCategoryKey
        self.highlightedSlotRange = highlightedSlotRange
    }

    private var renderRows: [DailyWorkflowGridRow] {
        if rows.isEmpty {
            return DailyWorkflowGridRow.placeholderRows(slotCount: timelineWindow.slotCount)
        }
        return rows
    }

    var body: some View {
        GeometryReader { geo in
            let hourTicks = timelineWindow.hourTickHours
            let slotCount = max(1, renderRows.map { $0.slotOccupancies.count }.max() ?? timelineWindow.slotCount)
            let widthScale = max(0.7, min(1.35, geo.size.width / 1016))
            let layoutScale = max(0.7, min(1.35, widthScale))

            let leftInset: CGFloat = 36 * layoutScale
            let categoryLabelWidth = labelColumnWidth(for: renderRows, layoutScale: layoutScale)
            let labelToGridSpacing: CGFloat = 13 * layoutScale
            let rightInset: CGFloat = 52 * layoutScale
            let topInset: CGFloat = 25 * layoutScale
            let axisTopSpacing: CGFloat = 10 * layoutScale
            let axisLabelSpacing: CGFloat = 5 * layoutScale

            let gridViewportWidth = max(80, geo.size.width - leftInset - categoryLabelWidth - labelToGridSpacing - rightInset)
            let baselineCellSize: CGFloat = 18 * layoutScale
            let baselineGap: CGFloat = 2 * layoutScale
            let cellSize = baselineCellSize
            let columnSpacing = baselineGap
            let rowSpacing = baselineGap
            let cellCornerRadius = max(1.2, 2.5 * layoutScale)
            let categoryLabelFontSize: CGFloat = 12 * layoutScale
            let axisLabelFontSize: CGFloat = 10 * layoutScale
            let totalGap = columnSpacing * CGFloat(slotCount - 1)
            let gridWidth = (cellSize * CGFloat(slotCount)) + totalGap
            let axisWidth = gridWidth

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: labelToGridSpacing) {
                    VStack(alignment: .trailing, spacing: rowSpacing) {
                        ForEach(renderRows) { row in
                            Text(row.name)
                                .font(.custom("Nunito-Regular", size: categoryLabelFontSize))
                                .foregroundStyle(Color.black.opacity(0.9))
                                .frame(width: categoryLabelWidth, height: cellSize, alignment: .trailing)
                        }
                    }
                    .padding(.top, topInset)

                    ScrollView(.horizontal, showsIndicators: gridWidth > gridViewportWidth) {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: rowSpacing) {
                                ForEach(renderRows) { row in
                                    HStack(spacing: columnSpacing) {
                                        ForEach(0..<slotCount, id: \.self) { index in
                                            Rectangle()
                                                .foregroundStyle(.clear)
                                                .background(fillColor(for: row, slotIndex: index))
                                                .cornerRadius(cellCornerRadius)
                                                .frame(width: cellSize, height: cellSize)
                                        }
                                    }
                                    .frame(width: gridWidth, alignment: .leading)
                                }
                            }
                            .padding(.top, topInset)

                            VStack(alignment: .leading, spacing: axisLabelSpacing) {
                                Rectangle()
                                    .fill(Color(hex: "E0D9D5"))
                                    .frame(width: axisWidth, height: max(0.7, 0.9 * layoutScale))

                                if hourTicks.count > 1 {
                                    let intervalCount = hourTicks.count - 1
                                    let intervalWidth = axisWidth / CGFloat(intervalCount)
                                    let labelWidth = max(22 * layoutScale, min(34 * layoutScale, intervalWidth * 1.4))

                                    ZStack(alignment: .leading) {
                                        ForEach(Array(hourTicks.enumerated()), id: \.offset) { index, hour in
                                            let tickX = CGFloat(index) * intervalWidth
                                            Text(formatAxisHourLabel(fromAbsoluteHour: hour))
                                                .font(.custom("Nunito-Regular", size: axisLabelFontSize))
                                                .kerning(-0.08 * layoutScale)
                                                .foregroundStyle(Color.black.opacity(0.78))
                                                .frame(
                                                    width: labelWidth,
                                                    alignment: axisLabelAlignment(
                                                        tickIndex: index,
                                                        tickCount: hourTicks.count
                                                    )
                                                )
                                                .offset(
                                                    x: axisLabelOffset(
                                                        tickIndex: index,
                                                        tickCount: hourTicks.count,
                                                        tickX: tickX,
                                                        axisWidth: axisWidth,
                                                        labelWidth: labelWidth
                                                    )
                                                )
                                        }
                                    }
                                    .frame(width: axisWidth, alignment: .leading)
                                } else if let onlyTick = hourTicks.first {
                                    Text(formatAxisHourLabel(fromAbsoluteHour: onlyTick))
                                        .font(.custom("Nunito-Regular", size: axisLabelFontSize))
                                        .kerning(-0.08 * layoutScale)
                                        .foregroundStyle(Color.black.opacity(0.78))
                                        .frame(width: axisWidth, alignment: .leading)
                                }
                            }
                            .padding(.top, axisTopSpacing)
                        }
                        .frame(width: gridWidth, alignment: .leading)
                    }
                    .frame(width: gridViewportWidth, alignment: .leading)
                }
            }
            .padding(.leading, leftInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 146 * scale)
    }

    private func fillColor(for row: DailyWorkflowGridRow, slotIndex: Int) -> Color {
        guard slotIndex < row.slotOccupancies.count else {
            return Color(red: 0.95, green: 0.93, blue: 0.92)
        }
        let occupancy = min(max(row.slotOccupancies[slotIndex], 0), 1)
        let baseEmpty = Color(red: 0.95, green: 0.93, blue: 0.92)
        guard occupancy > 0 else {
            return baseEmpty
        }

        let isHighlightedCategory = highlightedCategoryKey == nil || highlightedCategoryKey == row.id
        let isHighlightedSlot = highlightedSlotRange == nil || highlightedSlotRange?.contains(slotIndex) == true
        let isHighlighted = isHighlightedCategory && isHighlightedSlot
        let alpha = isHighlighted ? (0.32 + (occupancy * 0.68)) : (0.12 + (occupancy * 0.16))
        return Color(hex: row.colorHex).opacity(alpha)
    }

    private func axisLabelAlignment(tickIndex: Int, tickCount: Int) -> Alignment {
        if tickIndex == tickCount - 1 { return .trailing }
        return .leading
    }

    private func axisLabelOffset(
        tickIndex: Int,
        tickCount: Int,
        tickX: CGFloat,
        axisWidth: CGFloat,
        labelWidth: CGFloat
    ) -> CGFloat {
        if tickIndex == tickCount - 1 { return max(0, axisWidth - labelWidth) }
        return min(max(0, tickX), max(0, axisWidth - labelWidth))
    }

    private func labelColumnWidth(for rows: [DailyWorkflowGridRow], layoutScale: CGFloat) -> CGFloat {
        let fontSize = 12 * layoutScale
        let font = NSFont(name: "Nunito-Regular", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let measuredMax = rows.reduce(CGFloat.zero) { currentMax, row in
            let width = (row.name as NSString).size(withAttributes: [.font: font]).width
            return max(currentMax, width)
        }

        // Keep the label column as tight as possible while avoiding text clipping.
        return ceil(measuredMax + 1)
    }
}

private struct DailyStatChip: View {
    let title: String
    let value: String
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.custom("Nunito-Regular", size: 10 * scale))
                .foregroundStyle(Color(hex: "5D5651"))
            Text(value)
                .font(.custom("Nunito-SemiBold", size: 10 * scale))
                .foregroundStyle(Color(hex: "D77A43"))
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 6 * scale)
        .background(
            Capsule(style: .continuous)
                .fill(Color(hex: "F7F3F0"))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(hex: "DDD6CF"), lineWidth: max(0.6, 0.8 * scale))
        )
    }
}

private struct DailyModeToggle: View {
    enum ActiveMode {
        case highlights
        case details
    }

    let activeMode: ActiveMode
    let scale: CGFloat
    let leadingText: String
    let trailingText: String
    let onSelect: ((ActiveMode) -> Void)?

    init(
        activeMode: ActiveMode,
        scale: CGFloat,
        leadingText: String = "Highlights",
        trailingText: String = "Details",
        onSelect: ((ActiveMode) -> Void)? = nil
    ) {
        self.activeMode = activeMode
        self.scale = scale
        self.leadingText = leadingText
        self.trailingText = trailingText
        self.onSelect = onSelect
    }

    private var cornerRadius: CGFloat { 8 * scale }
    private var borderWidth: CGFloat { max(0.7, 1 * scale) }
    private var borderColor: Color { Color(hex: "C7C2C0") }

    var body: some View {
        HStack(spacing: 0) {
            segment(
                text: leadingText,
                isActive: activeMode == .highlights,
                isLeading: true,
                mode: .highlights
            )
            segment(
                text: trailingText,
                isActive: activeMode == .details,
                isLeading: false,
                mode: .details
            )
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
    }

    @ViewBuilder
    private func segment(text: String, isActive: Bool, isLeading: Bool, mode: ActiveMode) -> some View {
        let fill = isActive ? Color(hex: "FFA767") : Color(hex: "FFFAF7").opacity(0.6)

        let segmentContent = Text(text)
            .font(.custom("Nunito-Regular", size: 14 * scale))
            .lineLimit(1)
            .foregroundStyle(isActive ? Color.white : Color(hex: "837870"))
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 8 * scale)
            .frame(minHeight: 33 * scale)
            .background(
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: isLeading ? cornerRadius : 0,
                        bottomLeading: isLeading ? cornerRadius : 0,
                        bottomTrailing: isLeading ? 0 : cornerRadius,
                        topTrailing: isLeading ? 0 : cornerRadius
                    ),
                    style: .continuous
                )
                .fill(fill)
            )
            .overlay(alignment: .trailing) {
                if isLeading {
                    Rectangle()
                        .fill(borderColor)
                        .frame(width: borderWidth)
                }
            }

        if let onSelect {
            Button {
                guard !isActive else { return }
                onSelect(mode)
            } label: {
                segmentContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursorOnHover(reassertOnPressEnd: true)
        } else {
            segmentContent
        }
    }
}

private struct DailyBulletCard: View {
    enum SeamMode {
        case standalone
        case joinedLeading
        case joinedTrailing
    }

    enum Style {
        case highlights
        case tasks
    }

    enum HeaderActionStyle {
        case subtle
        case gradientPulse
    }

    let style: Style
    let seamMode: SeamMode
    @Binding var title: String
    @Binding var items: [DailyBulletItem]
    let showItems: Bool
    @Binding var addTaskLabel: String
    @Binding var blockersTitle: String
    @Binding var blockersBody: String
    let scale: CGFloat
    let isReadOnly: Bool
    let reviewEntries: [AgentReviewEntry]?
    let reviewActionInFlight: Set<String>
    let reviewFeedbackMessage: String?
    let reviewErrorMessage: String?
    let onApproveReview: ((String) -> Void)?
    let onRejectReview: ((String, String?) -> Void)?
    let onUndoReview: ((String) -> Void)?
    let onOpenLinkedItem: ((DailyBulletItem) -> Void)?
    let showsBlockersSection: Bool
    let headerAccessory: AnyView?
    let headerActionTitle: String?
    let headerActionStyle: HeaderActionStyle
    let onHeaderAction: (() -> Void)?
    @State private var draggedItemID: UUID? = nil

    private var cardShape: UnevenRoundedRectangle {
        let cornerRadius = 12 * scale
        let cornerRadii: RectangleCornerRadii

        switch seamMode {
        case .standalone:
            cornerRadii = .init(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        case .joinedLeading:
            cornerRadii = .init(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: 0,
                topTrailing: 0
            )
        case .joinedTrailing:
            cornerRadii = .init(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        }

        return UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18 * scale) {
                if isReadOnly {
                    HStack(alignment: .center, spacing: 10 * scale) {
                        Text(title)
                            .font(.custom("InstrumentSerif-Regular", size: 24 * scale))
                            .foregroundStyle(Color(hex: "B46531"))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let headerAccessory {
                            headerAccessory
                        }

                        if let headerActionTitle,
                           let onHeaderAction {
                            Button {
                                onHeaderAction()
                            } label: {
                                headerActionLabel(title: headerActionTitle)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursorOnHover(reassertOnPressEnd: true)
                        }
                    }
                } else {
                    TextField("Section title", text: $title)
                        .font(.custom("InstrumentSerif-Regular", size: 24 * scale))
                        .foregroundStyle(Color(hex: "B46531"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showItems {
                    if isReadOnly {
                        VStack(alignment: .leading, spacing: 10 * scale) {
                            if let reviewEntries {
                                if let reviewFeedbackMessage,
                                   !reviewFeedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(reviewFeedbackMessage)
                                        .font(.custom("Nunito-SemiBold", size: 12 * scale))
                                        .foregroundStyle(Color(hex: "2D8A4F"))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                if let reviewErrorMessage,
                                   !reviewErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(reviewErrorMessage)
                                        .font(.custom("Nunito-SemiBold", size: 12 * scale))
                                        .foregroundStyle(Color(hex: "B64C38"))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                if reviewEntries.isEmpty {
                                    Text("No notifications")
                                        .font(.custom("Nunito-Regular", size: 13 * scale))
                                        .foregroundStyle(Color(hex: "8E847C"))
                                } else {
                                    ForEach(reviewEntries) { entry in
                                        DailyReviewEntryView(
                                            entry: entry,
                                            scale: scale,
                                            isBusy: reviewActionInFlight.contains(entry.id),
                                            onApprove: onApproveReview,
                                            onReject: onRejectReview,
                                            onUndo: onUndoReview
                                        )
                                    }
                                }
                            } else if items.isEmpty {
                                Text("No items available.")
                                    .font(.custom("Nunito-Regular", size: 13 * scale))
                                    .foregroundStyle(Color(hex: "8E847C"))
                            } else {
                                ForEach(items) { item in
                                    readOnlyItemCard(item: item)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 14 * scale) {
                            ForEach($items) { $item in
                                let itemID = item.id
                                HStack(alignment: .top, spacing: 6 * scale) {
                                    DailyDragHandleIcon(scale: scale)
                                        .padding(.top, 5 * scale)
                                        .onDrag {
                                            draggedItemID = itemID
                                            return NSItemProvider(object: itemID.uuidString as NSString)
                                        }
                                        .pointingHandCursorOnHover(reassertOnPressEnd: true)

                                    HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
                                        TextField("Item title", text: $item.title)
                                            .font(.custom("Nunito-Bold", size: 14 * scale))
                                            .foregroundStyle(Color.black)
                                            .textFieldStyle(.plain)
                                            .lineLimit(1)

                                        Text("—")
                                            .font(.custom("Nunito-Regular", size: 14 * scale))
                                            .foregroundStyle(Color.black)

                                        TextField("Details", text: $item.body, axis: .vertical)
                                            .font(.custom("Nunito-Regular", size: 14 * scale))
                                            .foregroundStyle(Color.black)
                                            .textFieldStyle(.plain)
                                            .lineLimit(1...6)
                                    }
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .onDrop(
                                    of: ["public.text"],
                                    delegate: DailyItemDropDelegate(
                                        targetItemID: itemID,
                                        items: $items,
                                        draggedItemID: $draggedItemID
                                    )
                                )
                            }
                        }
                        .onDrop(
                            of: ["public.text"],
                            delegate: DailyItemDropToEndDelegate(
                                items: $items,
                                draggedItemID: $draggedItemID
                            )
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.leading, 26 * scale)
            .padding(.trailing, 26 * scale)
            .padding(.top, 26 * scale)

            Spacer(minLength: 0)

            if !isReadOnly {
                DailyAddTaskRow(scale: scale, text: $addTaskLabel) { submitted in
                    let normalizedTitle = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalizedTitle.isEmpty else { return }
                    items.append(DailyBulletItem(title: normalizedTitle, body: ""))
                }
                    .padding(.leading, style == .highlights ? 16 * scale : 26 * scale)
                    .padding(.bottom, style == .tasks ? 24 * scale : 20 * scale)
            }

            if style == .tasks && showsBlockersSection {
                DailyBlockersSection(
                    scale: scale,
                    title: $blockersTitle,
                    prompt: $blockersBody,
                    isReadOnly: isReadOnly
                )
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: isReadOnly ? max(180, 340 * scale) : max(180, 394 * scale),
            alignment: .topLeading
        )
        .background(
            cardShape
                .fill(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.6), location: 0.011932),
                            .init(color: Color.white, location: 0.5104),
                            .init(color: Color.white.opacity(0.6), location: 0.98092)
                        ]),
                        startPoint: UnitPoint(x: 1, y: 0.45),
                        endPoint: UnitPoint(x: 0, y: 0.55)
                    )
                )
        )
        .clipShape(cardShape)
        .overlay(
            cardShape
                .stroke(Color(hex: "EBE6E3"), lineWidth: max(0.7, 1 * scale))
        )
        .shadow(color: Color.black.opacity(0.1), radius: 12 * scale, x: 0, y: 0)
    }

    @ViewBuilder
    private func headerActionLabel(title: String) -> some View {
        switch headerActionStyle {
        case .subtle:
            Text(title)
                .font(.custom("Nunito-SemiBold", size: 12 * scale))
                .foregroundStyle(Color(hex: "F96E00"))
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 6 * scale)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(hex: "FFF6EE"))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(hex: "F3DCC7"), lineWidth: max(0.7, 1 * scale))
                )
        case .gradientPulse:
            MemoryTuningActionCapsule(title: title, scale: scale)
        }
    }

    @ViewBuilder
    private func readOnlyItemCard(item: DailyBulletItem) -> some View {
        let content = VStack(alignment: .leading, spacing: 6 * scale) {
            Text(item.title.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.custom("Nunito-Bold", size: 14 * scale))
                .foregroundStyle(Color(hex: "1F1B18"))

            let bodyText = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bodyText.isEmpty {
                Text(bodyText)
                    .font(.custom("Nunito-Regular", size: 14 * scale))
                    .foregroundStyle(Color(hex: "2B2521"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let meta = item.meta?.trimmingCharacters(in: .whitespacesAndNewlines),
               !meta.isEmpty {
                Text(meta)
                    .font(.custom("Nunito-Regular", size: 12 * scale))
                    .foregroundStyle(Color(hex: "8B7E73"))
            }

            if item.hasTimelineLink {
                HStack(spacing: 5 * scale) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 11 * scale, weight: .semibold))
                    Text("Open in timeline")
                        .font(.custom("Nunito-SemiBold", size: 12 * scale))
                }
                .foregroundStyle(Color(hex: "B46531"))
                .padding(.top, 2 * scale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 10 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .fill(Color(hex: "FCFAF8"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .stroke(Color(hex: "ECE4DD"), lineWidth: max(0.6, 0.8 * scale))
        )

        if item.hasTimelineLink, let onOpenLinkedItem {
            Button {
                onOpenLinkedItem(item)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .pointingHandCursorOnHover(reassertOnPressEnd: true)
        } else {
            content
        }
    }
}

private struct DailyReviewEntryView: View {
    let entry: AgentReviewEntry
    let scale: CGFloat
    let isBusy: Bool
    let onApprove: ((String) -> Void)?
    let onReject: ((String, String?) -> Void)?
    let onUndo: ((String) -> Void)?

    @State private var note: String = ""
    @State private var isRejectEditorPresented: Bool = false

    private var prefersScrollableBody: Bool {
        entry.body.count > 230
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text(entry.title)
                .font(.custom("Nunito-Bold", size: 14 * scale))
                .foregroundStyle(Color(hex: "1F1B18"))

            Group {
                if prefersScrollableBody {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(entry.body)
                            .font(.custom("Nunito-Regular", size: 14 * scale))
                            .foregroundStyle(Color(hex: "2B2521"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 4 * scale)
                    }
                    .frame(maxHeight: 130 * scale)
                } else {
                    Text(entry.body)
                        .font(.custom("Nunito-Regular", size: 14 * scale))
                        .foregroundStyle(Color(hex: "2B2521"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if entry.isRejected {
                HStack(spacing: 10 * scale) {
                    Text("Needs revision")
                        .font(.custom("Nunito-SemiBold", size: 12 * scale))
                        .foregroundStyle(Color(hex: "B64C38"))
                        .padding(.horizontal, 8 * scale)
                        .padding(.vertical, 4 * scale)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(hex: "FFF3EF"))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color(hex: "F0C8BC"), lineWidth: max(0.6, 0.8 * scale))
                        )

                    Button {
                        guard !isBusy else { return }
                        onUndo?(entry.id)
                    } label: {
                        DailyReviewActionButtonLabel(
                            text: "Undo",
                            scale: scale,
                            style: .neutral
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.45 : 1)
                    .pointingHandCursorOnHover(enabled: !isBusy, reassertOnPressEnd: true)
                }
            } else {
                HStack(spacing: 10 * scale) {
                    Button {
                        guard !isBusy else { return }
                        onApprove?(entry.id)
                    } label: {
                        DailyReviewActionButtonLabel(
                            text: "Approve",
                            scale: scale,
                            style: .approve
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.45 : 1)
                    .pointingHandCursorOnHover(enabled: !isBusy, reassertOnPressEnd: true)

                    Button {
                        guard !isBusy else { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            isRejectEditorPresented.toggle()
                        }
                    } label: {
                        DailyReviewActionButtonLabel(
                            text: "Reject",
                            scale: scale,
                            style: .reject
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.45 : 1)
                    .pointingHandCursorOnHover(enabled: !isBusy, reassertOnPressEnd: true)

                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if isRejectEditorPresented {
                    VStack(alignment: .leading, spacing: 8 * scale) {
                        TextField("Optional reject note", text: $note)
                            .textFieldStyle(.plain)
                            .font(.custom("Nunito-Regular", size: 13 * scale))
                            .foregroundStyle(Color(hex: "6F655D"))
                            .padding(.horizontal, 10 * scale)
                            .padding(.vertical, 7 * scale)
                            .background(
                                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                                    .fill(Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                                    .stroke(Color(hex: "E5DBD3"), lineWidth: max(0.6, 0.8 * scale))
                            )

                        HStack(spacing: 10 * scale) {
                            Button {
                                guard !isBusy else { return }
                                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                                onReject?(entry.id, trimmed.isEmpty ? nil : trimmed)
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    isRejectEditorPresented = false
                                    note = ""
                                }
                            } label: {
                                DailyReviewActionButtonLabel(
                                    text: "Confirm reject",
                                    scale: scale,
                                    style: .reject
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy)
                            .opacity(isBusy ? 0.45 : 1)
                            .pointingHandCursorOnHover(enabled: !isBusy, reassertOnPressEnd: true)

                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    isRejectEditorPresented = false
                                    note = ""
                                }
                            } label: {
                                DailyReviewActionButtonLabel(
                                    text: "Cancel",
                                    scale: scale,
                                    style: .neutral
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy)
                            .opacity(isBusy ? 0.45 : 1)
                            .pointingHandCursorOnHover(enabled: !isBusy, reassertOnPressEnd: true)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 10 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .fill(Color(hex: "FCFAF8"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .stroke(Color(hex: "ECE4DD"), lineWidth: max(0.6, 0.8 * scale))
        )
    }
}

private struct DailyReviewActionButtonLabel: View {
    enum Style {
        case approve
        case reject
        case neutral
    }

    let text: String
    let scale: CGFloat
    let style: Style

    var body: some View {
        Text(text)
            .font(.custom("Nunito-SemiBold", size: 12 * scale))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 6 * scale)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: max(0.6, 0.8 * scale))
            )
    }

    private var foregroundColor: Color {
        switch style {
        case .approve:
            return Color(hex: "1A8A55")
        case .reject:
            return Color(hex: "B64C38")
        case .neutral:
            return Color(hex: "7C7068")
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .approve:
            return Color(hex: "F0FBF5")
        case .reject:
            return Color(hex: "FFF3EF")
        case .neutral:
            return Color(hex: "FAF6F2")
        }
    }

    private var borderColor: Color {
        switch style {
        case .approve:
            return Color(hex: "C5EAD4")
        case .reject:
            return Color(hex: "F0C8BC")
        case .neutral:
            return Color(hex: "E8D9CD")
        }
    }
}

private struct MemoryTuningActionCapsule: View {
    let title: String
    let scale: CGFloat

    var body: some View {
        Text(title)
            .font(.custom("Nunito-SemiBold", size: 12 * scale))
            .foregroundStyle(.white)
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 7 * scale)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "FF996E"), Color(hex: "BFA6FF")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(hex: "F6D5BE"), lineWidth: max(0.8, 1 * scale))
            )
    }
}

private struct AgentEventsPanel: View {
    let dateTitle: String
    let events: [AgentEventPanelItem]
    let onSelect: (AgentActivityHighlight) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent events")
                        .font(.custom("InstrumentSerif-Regular", size: 24))
                        .foregroundStyle(Color(hex: "B46531"))
                    Text(dateTitle)
                        .font(.custom("Nunito-Regular", size: 12))
                        .foregroundStyle(Color(hex: "8D8073"))
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.custom("Nunito-SemiBold", size: 12))
                    .foregroundStyle(Color(hex: "9A6A45"))
                    .pointingHandCursorOnHover(reassertOnPressEnd: true)
            }

            if events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No event slices available yet")
                        .font(.custom("Nunito-SemiBold", size: 14))
                        .foregroundStyle(Color(hex: "64584F"))
                    Text("Sync with Agent to pull activity signals, then select an event slice to highlight it on the timeline.")
                        .font(.custom("Nunito-Regular", size: 13))
                        .foregroundStyle(Color(hex: "8B7E73"))
                }
                .padding(.top, 8)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(events) { event in
                            Button {
                                onSelect(
                                    AgentActivityHighlight(
                                        categoryKey: event.categoryKey,
                                        slotRange: event.slotRange
                                    )
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(event.categoryLabel)
                                            .font(.custom("Nunito-SemiBold", size: 14))
                                            .foregroundStyle(Color(hex: "2D261F"))
                                        Spacer(minLength: 8)
                                        Text(event.timeLabel)
                                            .font(.custom("Nunito-SemiBold", size: 12))
                                            .foregroundStyle(Color(hex: "A07148"))
                                    }
                                    Text(event.summary)
                                        .font(.custom("Nunito-Regular", size: 13))
                                        .foregroundStyle(Color(hex: "6F655D"))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(hex: "FFF8F2"))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color(hex: "F2DEC9"), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursorOnHover(reassertOnPressEnd: true)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(minWidth: 440, idealWidth: 520)
    }
}

private struct DailyDragHandleIcon: View {
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 2 * scale) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2 * scale) {
                    Circle()
                        .fill(Color(hex: "999999"))
                        .frame(width: 2.5 * scale, height: 2.5 * scale)
                    Circle()
                        .fill(Color(hex: "999999"))
                        .frame(width: 2.5 * scale, height: 2.5 * scale)
                }
            }
        }
        .frame(width: 16 * scale, height: 16 * scale, alignment: .topLeading)
    }
}

private struct DailyAddTaskRow: View {
    let scale: CGFloat
    @Binding var text: String
    var onCommit: (String) -> Void

    var body: some View {
        HStack(spacing: 6 * scale) {
            Button(action: commit) {
                Image(systemName: "plus")
                    .font(.system(size: 24 * scale, weight: .regular))
                    .foregroundStyle(Color(hex: "999999"))
                    .frame(width: 24 * scale, height: 24 * scale)
            }
            .buttonStyle(.plain)
            .pointingHandCursorOnHover(reassertOnPressEnd: true)

            TextField("Add task", text: $text)
                .font(.custom("Nunito-Regular", size: 12 * scale))
                .foregroundStyle(Color(hex: "999999"))
                .textFieldStyle(.plain)
                .onSubmit(commit)
                .onAppear {
                    if text == "Add task" {
                        text = ""
                    }
                }
        }
    }

    private func commit() {
        let submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        onCommit(submitted)
        text = ""
    }
}

private struct DailyBlockersSection: View {
    let scale: CGFloat
    @Binding var title: String
    @Binding var prompt: String
    let isReadOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            if isReadOnly {
                Text(title)
                    .font(.custom("Nunito-Medium", size: 14 * scale))
                    .foregroundStyle(Color(hex: "BD9479"))
                Text(prompt)
                    .font(.custom("Nunito-Regular", size: 14 * scale))
                    .foregroundStyle(Color(hex: "6F655D"))
                    .lineSpacing(3 * scale)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Blockers", text: $title)
                    .font(.custom("Nunito-Medium", size: 14 * scale))
                    .foregroundStyle(Color(hex: "BD9479"))
                    .textFieldStyle(.plain)

                HStack(alignment: .top, spacing: 6 * scale) {
                    DailyDragHandleIcon(scale: scale)
                        .padding(.top, 1 * scale)

                    TextField("Fill in any blockers you may have", text: $prompt, axis: .vertical)
                        .font(.custom("Nunito-Regular", size: 14 * scale))
                        .foregroundStyle(Color(hex: "929292"))
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 26 * scale)
        .padding(.trailing, 26 * scale)
        .padding(.top, 14 * scale)
        .frame(maxWidth: .infinity, minHeight: 94 * scale, alignment: .topLeading)
        .background(Color(hex: "F7F6F5"))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(hex: "EBE6E3"))
                .frame(height: max(0.7, 1 * scale))
        }
    }
}

private struct DailyItemDropDelegate: DropDelegate {
    let targetItemID: UUID
    @Binding var items: [DailyBulletItem]
    @Binding var draggedItemID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedID = draggedItemID,
              draggedID != targetItemID,
              let fromIndex = items.firstIndex(where: { $0.id == draggedID }),
              let toIndex = items.firstIndex(where: { $0.id == targetItemID }) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.14)) {
            items.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }
}

private struct DailyItemDropToEndDelegate: DropDelegate {
    @Binding var items: [DailyBulletItem]
    @Binding var draggedItemID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedID = draggedItemID,
              let fromIndex = items.firstIndex(where: { $0.id == draggedID }) else {
            return
        }

        let endIndex = items.count
        guard fromIndex != endIndex - 1 else { return }

        withAnimation(.easeInOut(duration: 0.14)) {
            items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: endIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }
}

private struct DailyBulletItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var meta: String?
    var linkedPreviewId: String?
    var linkedDayString: String?

    var hasTimelineLink: Bool {
        guard let linkedPreviewId = linkedPreviewId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !linkedPreviewId.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case meta
        case linkedPreviewId
        case linkedDayString
    }

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        meta: String? = nil,
        linkedPreviewId: String? = nil,
        linkedDayString: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.meta = meta
        self.linkedPreviewId = linkedPreviewId
        self.linkedDayString = linkedDayString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        meta = try container.decodeIfPresent(String.self, forKey: .meta)
        linkedPreviewId = try container.decodeIfPresent(String.self, forKey: .linkedPreviewId)
        linkedDayString = try container.decodeIfPresent(String.self, forKey: .linkedDayString)
    }
}

private struct AgentReviewEntry: Identifiable, Sendable {
    let id: String
    let title: String
    let body: String
    let isRejected: Bool
    let postId: String?
}

private struct AgentActivityHighlight {
    let categoryKey: String
    let slotRange: ClosedRange<Int>
}

private struct AgentEventPanelItem: Identifiable {
    let id: String
    let categoryKey: String
    let categoryLabel: String
    let timeLabel: String
    let summary: String
    let slotRange: ClosedRange<Int>
}

private struct DailyWorkflowGridRow: Identifiable, Sendable {
    let id: String
    let name: String
    let colorHex: String
    let slotOccupancies: [Double]

    static func placeholderRows(slotCount: Int) -> [DailyWorkflowGridRow] {
        DailyGridConfig.fallbackCategoryNames.enumerated().map { index, name in
            DailyWorkflowGridRow(
                id: "placeholder-\(index)",
                name: name,
                colorHex: DailyGridConfig.fallbackColorHexes[index % DailyGridConfig.fallbackColorHexes.count],
                slotOccupancies: Array(repeating: 0, count: max(1, slotCount))
            )
        }
    }
}

private struct DailyWorkflowTotalItem: Identifiable, Sendable {
    let id: String
    let name: String
    let minutes: Double
    let colorHex: String
}

private struct DailyWorkflowComputationResult: Sendable {
    let rows: [DailyWorkflowGridRow]
    let totals: [DailyWorkflowTotalItem]
    let stats: [DailyWorkflowStatChip]
    let window: DailyWorkflowTimelineWindow
}

private struct DailyWorkflowSegment: Sendable {
    let categoryKey: String
    let displayName: String
    let colorHex: String
    let startMinute: Double
    let endMinute: Double
    let hasDistraction: Bool
}

private struct DailyWorkflowStatChip: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String

    static let placeholder: [DailyWorkflowStatChip] = [
        DailyWorkflowStatChip(id: "context-switched", title: "Context switched", value: "0 times"),
        DailyWorkflowStatChip(id: "interrupted", title: "Interrupted", value: "0 times"),
        DailyWorkflowStatChip(id: "focused-for", title: "Focused for", value: "0m"),
        DailyWorkflowStatChip(id: "distracted-for", title: "Distracted for", value: "0m"),
        DailyWorkflowStatChip(id: "transitioning-time", title: "Transitioning time", value: "0m")
    ]
}

private struct DailyWorkflowTimelineWindow: Sendable {
    let startMinute: Double
    let endMinute: Double

    static let placeholder = DailyWorkflowTimelineWindow(
        startMinute: DailyGridConfig.visibleStartMinute,
        endMinute: DailyGridConfig.visibleEndMinute
    )

    var hourTickHours: [Int] {
        guard endMinute > startMinute else { return [9, 17] }

        let startHour = Int(floor(startMinute / 60))
        let endHour = Int(ceil(endMinute / 60))
        let adjustedEndHour = max(startHour + 1, endHour)
        return Array(startHour...adjustedEndHour)
    }

    var slotCount: Int {
        guard endMinute > startMinute else {
            let fallbackDuration = DailyGridConfig.visibleEndMinute - DailyGridConfig.visibleStartMinute
            return max(1, Int((fallbackDuration / DailyGridConfig.slotDurationMinutes).rounded()))
        }

        let durationMinutes = endMinute - startMinute
        return max(1, Int((durationMinutes / DailyGridConfig.slotDurationMinutes).rounded()))
    }

    var hourLabels: [String] {
        hourTickHours.map(formatAxisHourLabel(fromAbsoluteHour:))
    }
}

private func computeDailyWorkflow(cards: [TimelineCard], categories: [TimelineCategory]) -> DailyWorkflowComputationResult {
    let orderedCategories = categories.sorted { $0.order < $1.order }

    let colorMap: [String: String] = Dictionary(uniqueKeysWithValues: orderedCategories.map {
        (normalizedCategoryKey($0.name), normalizedHex($0.colorHex))
    })

    let nameMap: [String: String] = Dictionary(uniqueKeysWithValues: orderedCategories.map {
        (normalizedCategoryKey($0.name), $0.name.trimmingCharacters(in: .whitespacesAndNewlines))
    })

    struct RawDailyWorkflowSegment {
        let categoryKey: String
        let displayName: String
        let colorHex: String
        let startMinute: Double
        let endMinute: Double
        let hasDistraction: Bool
    }

    var rawSegments: [RawDailyWorkflowSegment] = []
    rawSegments.reserveCapacity(cards.count)

    for card in cards {
        guard var startMinute = parseCardMinute(card.startTimestamp),
              var endMinute = parseCardMinute(card.endTimestamp) else {
            continue
        }

        if startMinute < 240 { startMinute += 1440 }
        if endMinute < 240 { endMinute += 1440 }
        if endMinute <= startMinute { endMinute += 1440 }

        let trimmed = card.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Uncategorized" : trimmed
        let key = normalizedCategoryKey(displayName)
        let colorHex = colorMap[key] ?? fallbackColorHex(for: key)

        rawSegments.append(
            RawDailyWorkflowSegment(
                categoryKey: key,
                displayName: displayName,
                colorHex: colorHex,
                startMinute: startMinute,
                endMinute: endMinute,
                hasDistraction: !(card.distractions?.isEmpty ?? true)
            )
        )
    }

    let workflowWindow: DailyWorkflowTimelineWindow = {
        guard !rawSegments.isEmpty else { return .placeholder }

        let firstUsedMinute = rawSegments.map(\.startMinute).min() ?? DailyGridConfig.visibleStartMinute
        let lastUsedMinute = rawSegments.map(\.endMinute).max() ?? DailyGridConfig.visibleEndMinute

        let alignedStart = floor(firstUsedMinute / 60) * 60
        let alignedDataEnd = ceil(lastUsedMinute / 60) * 60
        let minWindowDuration = DailyGridConfig.visibleEndMinute - DailyGridConfig.visibleStartMinute
        let computedEnd = max(alignedStart + minWindowDuration, alignedDataEnd)

        return DailyWorkflowTimelineWindow(startMinute: alignedStart, endMinute: computedEnd)
    }()

    let visibleStart = workflowWindow.startMinute
    let visibleEnd = workflowWindow.endMinute
    let slotCount = workflowWindow.slotCount
    let slotDuration = DailyGridConfig.slotDurationMinutes

    let segments: [DailyWorkflowSegment] = rawSegments.compactMap { raw in
        let clippedStart = max(raw.startMinute, visibleStart)
        let clippedEnd = min(raw.endMinute, visibleEnd)
        guard clippedEnd > clippedStart else { return nil }
        return DailyWorkflowSegment(
            categoryKey: raw.categoryKey,
            displayName: raw.displayName,
            colorHex: raw.colorHex,
            startMinute: clippedStart,
            endMinute: clippedEnd,
            hasDistraction: raw.hasDistraction
        )
    }

    var durationByCategory: [String: Double] = [:]
    var resolvedNameByCategory: [String: String] = [:]
    var resolvedColorByCategory: [String: String] = [:]

    for segment in segments {
        let overlap = max(0, segment.endMinute - segment.startMinute)
        guard overlap > 0 else { continue }
        durationByCategory[segment.categoryKey, default: 0] += overlap
        resolvedNameByCategory[segment.categoryKey] = segment.displayName
        resolvedColorByCategory[segment.categoryKey] = segment.colorHex
    }

    let sortedSegments = segments.sorted { lhs, rhs in
        if lhs.startMinute == rhs.startMinute {
            return lhs.endMinute < rhs.endMinute
        }
        return lhs.startMinute < rhs.startMinute
    }

    let idleCategoryKeys = Set(orderedCategories.filter(\.isIdle).map { normalizedCategoryKey($0.name) })
    var contextSwitches = 0
    var interruptions = 0
    var focusedMinutes = 0.0
    var distractedMinutes = 0.0
    var transitionMinutes = 0.0
    var previousCategory: String? = nil
    var previousEndMinute: Double? = nil

    for segment in sortedSegments {
        let duration = max(0, segment.endMinute - segment.startMinute)
        guard duration > 0 else { continue }

        if idleCategoryKeys.contains(segment.categoryKey) {
            distractedMinutes += duration
        } else {
            focusedMinutes += duration
        }

        if segment.hasDistraction {
            interruptions += 1
        }

        if let previousCategory, previousCategory != segment.categoryKey {
            contextSwitches += 1
        }
        previousCategory = segment.categoryKey

        if let priorEndMinute = previousEndMinute {
            let gap = segment.startMinute - priorEndMinute
            if gap > 0 {
                transitionMinutes += gap
            }
            previousEndMinute = max(priorEndMinute, segment.endMinute)
        } else {
            previousEndMinute = segment.endMinute
        }
    }

    var selectedKeys = durationByCategory
        .sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        .map(\.key)

    if selectedKeys.count < 5 {
        for category in orderedCategories where !category.isIdle {
            let key = normalizedCategoryKey(category.name)
            if !selectedKeys.contains(key) {
                selectedKeys.append(key)
            }
            if selectedKeys.count >= 5 { break }
        }
    }

    if selectedKeys.count < 5 {
        for fallback in DailyGridConfig.fallbackCategoryNames {
            let key = normalizedCategoryKey(fallback)
            if !selectedKeys.contains(key) {
                selectedKeys.append(key)
            }
            if selectedKeys.count >= 5 { break }
        }
    }

    selectedKeys = Array(selectedKeys.prefix(5))

    let segmentsByCategory = Dictionary(grouping: segments, by: { $0.categoryKey })

    let rows: [DailyWorkflowGridRow] = selectedKeys.enumerated().map { index, key in
        let rowSegments = segmentsByCategory[key] ?? []
        let occupancies: [Double] = (0..<slotCount).map { slotIndex in
            let slotStart = visibleStart + (Double(slotIndex) * slotDuration)
            let slotEnd = min(visibleEnd, slotStart + slotDuration)
            let slotMinutes = max(1, slotEnd - slotStart)

            let occupied = rowSegments.reduce(0.0) { partial, segment in
                let overlap = max(0, min(segment.endMinute, slotEnd) - max(segment.startMinute, slotStart))
                return partial + overlap
            }

            return min(1, occupied / slotMinutes)
        }

        let displayName = resolvedNameByCategory[key] ?? nameMap[key] ?? DailyGridConfig.fallbackCategoryNames[index % DailyGridConfig.fallbackCategoryNames.count]
        let colorHex = resolvedColorByCategory[key] ?? colorMap[key] ?? DailyGridConfig.fallbackColorHexes[index % DailyGridConfig.fallbackColorHexes.count]

        return DailyWorkflowGridRow(
            id: key,
            name: displayName,
            colorHex: colorHex,
            slotOccupancies: occupancies
        )
    }

    let totals = selectedKeys.compactMap { key -> DailyWorkflowTotalItem? in
        guard let minutes = durationByCategory[key], minutes > 0 else { return nil }
        let name = resolvedNameByCategory[key] ?? nameMap[key] ?? "Uncategorized"
        let colorHex = resolvedColorByCategory[key] ?? colorMap[key] ?? fallbackColorHex(for: key)
        return DailyWorkflowTotalItem(id: key, name: name, minutes: minutes, colorHex: colorHex)
    }

    let stats = [
        DailyWorkflowStatChip(
            id: "context-switched",
            title: "Context switched",
            value: formatCount(contextSwitches)
        ),
        DailyWorkflowStatChip(
            id: "interrupted",
            title: "Interrupted",
            value: formatCount(interruptions)
        ),
        DailyWorkflowStatChip(
            id: "focused-for",
            title: "Focused for",
            value: formatDurationValue(focusedMinutes)
        ),
        DailyWorkflowStatChip(
            id: "distracted-for",
            title: "Distracted for",
            value: formatDurationValue(distractedMinutes)
        ),
        DailyWorkflowStatChip(
            id: "transitioning-time",
            title: "Transitioning time",
            value: formatDurationValue(transitionMinutes)
        )
    ]

    return DailyWorkflowComputationResult(rows: rows, totals: totals, stats: stats, window: workflowWindow)
}

private func parseCardMinute(_ value: String) -> Double? {
    guard let parsed = parseTimeHMMA(timeString: value) else { return nil }
    return Double(parsed)
}

private func normalizedCategoryKey(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func normalizedHex(_ value: String) -> String {
    value.replacingOccurrences(of: "#", with: "")
}

private func fallbackColorHex(for key: String) -> String {
    let hash = key.utf8.reduce(5381) { current, byte in
        ((current << 5) &+ current) &+ Int(byte)
    }
    let palette = DailyGridConfig.fallbackColorHexes
    let index = abs(hash) % palette.count
    return palette[index]
}

private func formatAxisHourLabel(fromAbsoluteHour hour: Int) -> String {
    let normalized = ((hour % 24) + 24) % 24
    let period = normalized >= 12 ? "pm" : "am"
    let display = normalized % 12 == 0 ? 12 : normalized % 12
    return "\(display)\(period)"
}

private func formatCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "time" : "times")"
}

private func formatDurationValue(_ minutes: Double) -> String {
    let rounded = max(0, Int(minutes.rounded()))
    let hours = rounded / 60
    let mins = rounded % 60

    if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
    if hours > 0 { return "\(hours)h" }
    return "\(mins)m"
}

private struct DailyStandupDraft: Codable, Equatable, Sendable {
    var highlightsTitle: String
    var highlights: [DailyBulletItem]
    var tasksTitle: String
    var tasks: [DailyBulletItem]
    var addTaskLabel: String
    var blockersTitle: String
    var blockersBody: String

    static let `default` = DailyStandupDraft(
        highlightsTitle: "Yesterday's highlights",
        highlights: DailyContent.yesterdayHighlights,
        tasksTitle: "Today's tasks",
        tasks: DailyContent.todayTasks,
        addTaskLabel: "",
        blockersTitle: "Blockers",
        blockersBody: DailyContent.notGeneratedMessage
    )
}

private enum DailyContent {
    static let notGeneratedTitle = "Daily data not generated yet"
    static let notGeneratedMessage = "Daily data has not been generated yet. If this is unexpected, please report a bug."

    static let yesterdayHighlights: [DailyBulletItem] = [
        DailyBulletItem(
            title: notGeneratedTitle,
            body: notGeneratedMessage
        )
    ]

    static let todayTasks: [DailyBulletItem] = [
        DailyBulletItem(
            title: notGeneratedTitle,
            body: notGeneratedMessage
        )
    ]
}

struct DailyView_Previews: PreviewProvider {
    static var previews: some View {
        DailyView(selectedDate: .constant(Date()))
            .environmentObject(CategoryStore.shared)
            .frame(width: 1180, height: 760)
    }
}
