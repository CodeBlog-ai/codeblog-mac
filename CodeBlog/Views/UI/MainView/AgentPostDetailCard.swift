//
//  AgentPostDetailCard.swift
//  CodeBlog
//
//  右侧面板：Agent card 详情视图（复用 ActivityCard 布局结构）
//

import SwiftUI

struct AgentPostDetailCard: View {
    let activity: TimelineActivity
    var scrollSummary: Bool = false
    var onDismiss: (() -> Void)? = nil

    @State private var isPublishing = false
    @State private var publishResult: PublishResult? = nil
    @State private var showToast = false

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private var agentCardType: String {
        activity.agentCardType ?? "journal"
    }

    // MARK: - Header

    private var headerEmoji: String {
        switch agentCardType {
        case "insight": return "💡"
        case "post":    return "✦"
        default:        return "📝"
        }
    }

    private var headerLabel: String {
        switch agentCardType {
        case "insight": return "Agent 发现"
        case "post":    return "待发布"
        default:        return "Agent 记录"
        }
    }

    private var accentColor: Color {
        switch agentCardType {
        case "insight", "post": return Color(hex: "F96E00")
        default:                return Color(hex: "9B7753")
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            Divider().opacity(0.3)
            contentSection
            Spacer(minLength: 4)
            if agentCardType == "insight" || agentCardType == "post" {
                actionRow
            }
        }
        .padding(16)
        .id(activity.id)
        .transition(
            .blurReplace.animation(.easeOut(duration: 0.2))
        )
        .overlay(alignment: .top) {
            if showToast, let result = publishResult {
                toastBanner(result: result)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .onChange(of: activity.id) {
            isPublishing = false
            publishResult = nil
            showToast = false
        }
    }

    // MARK: - Header Row

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activity.title)
                .font(Font.custom("Nunito", size: 16).weight(.semibold))
                .foregroundColor(.black)

            HStack(alignment: .center, spacing: 6) {
                // Time badge
                Text("\(timeFormatter.string(from: activity.startTime)) - \(timeFormatter.string(from: activity.endTime))")
                    .font(Font.custom("Nunito", size: 12))
                    .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.9))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .inset(by: 0.38)
                            .stroke(Color(red: 0.9, green: 0.9, blue: 0.9), lineWidth: 0.75)
                    )

                Spacer(minLength: 6)

                // Type badge
                HStack(spacing: 4) {
                    Text(headerEmoji)
                        .font(.system(size: 10))
                    Text(headerLabel)
                        .font(Font.custom("Nunito", size: 12))
                        .foregroundColor(accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accentColor.opacity(0.1))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .inset(by: 0.25)
                        .stroke(accentColor.opacity(0.3), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Content Section

    private var contentSection: some View {
        Group {
            if scrollSummary {
                ScrollView(.vertical, showsIndicators: false) {
                    summaryContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                summaryContent
            }
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // SUMMARY
            if !activity.summary.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SUMMARY")
                        .font(Font.custom("Nunito", size: 12).weight(.semibold))
                        .foregroundColor(Color(red: 0.55, green: 0.55, blue: 0.55))

                    renderMarkdown(activity.summary)
                        .font(Font.custom("Nunito", size: 12))
                        .foregroundColor(.black)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            // DETAILED SUMMARY / CONTENT
            if !activity.detailedSummary.isEmpty && activity.detailedSummary != activity.summary {
                VStack(alignment: .leading, spacing: 3) {
                    // post 类型改为 CONTENT
                    Text(agentCardType == "post" ? "CONTENT" : "DETAILED SUMMARY")
                        .font(Font.custom("Nunito", size: 12).weight(.semibold))
                        .foregroundColor(Color(red: 0.55, green: 0.55, blue: 0.55))

                    renderMarkdown(activity.detailedSummary)
                        .font(Font.custom("Nunito", size: 12))
                        .foregroundColor(.black)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func renderMarkdown(_ content: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: content, options: options) {
            return Text(parsed)
        }
        return Text(content)
    }

    // MARK: - Action Row

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if agentCardType == "post" {
                publishButton
                chatButton(label: "继续聊")
                skipButton
            } else if agentCardType == "insight" {
                chatButton(label: "继续聊")
                toPostButton
                dismissButton
            }
        }
    }

    private var publishButton: some View {
        Button {
            Task { await publishPost() }
        } label: {
            HStack(spacing: 4) {
                if isPublishing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Text("发布")
                }
            }
            .font(Font.custom("Nunito", size: 12).weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(hex: "F96E00"))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(isPublishing || publishResult?.isSuccess == true)
    }

    private func chatButton(label: String) -> some View {
        Button {
            navigateToChat()
        } label: {
            Text(label)
                .font(Font.custom("Nunito", size: 12))
                .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.3))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(red: 0.96, green: 0.94, blue: 0.91))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var skipButton: some View {
        Button {
            markSkipped()
            onDismiss?()
        } label: {
            Text("跳过")
                .font(Font.custom("Nunito", size: 12))
                .foregroundColor(Color(red: 0.55, green: 0.55, blue: 0.55))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(red: 0.96, green: 0.94, blue: 0.91))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var dismissButton: some View {
        skipButton  // 关闭与跳过行为相同，仅文案不同
    }

    private var toPostButton: some View {
        Button {
            Task { await convertToPost() }
        } label: {
            Text("整理成帖子")
                .font(Font.custom("Nunito", size: 12))
                .foregroundColor(Color(hex: "F96E00"))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(hex: "F96E00").opacity(0.1))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(hex: "F96E00").opacity(0.3), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Toast

    private func toastBanner(result: PublishResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.isSuccess ? .green : .red)
            Text(result.message)
                .font(Font.custom("Nunito", size: 13))
                .foregroundColor(.black)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func publishPost() async {
        guard let previewId = activity.previewId, !previewId.isEmpty else {
            showToastWith(PublishResult(isSuccess: false, message: "无效的 preview_id"))
            return
        }

        isPublishing = true
        defer { isPublishing = false }

        do {
            let result = try await MCPStdioClient.shared.callTool(
                name: "confirm_post",
                arguments: ["preview_id": .string(previewId)]
            )
            if result.isError {
                showToastWith(PublishResult(isSuccess: false, message: "发布失败：\(result.text.prefix(80))"))
            } else {
                showToastWith(PublishResult(isSuccess: true, message: "已发布！"))
            }
        } catch {
            showToastWith(PublishResult(isSuccess: false, message: "发布失败：\(error.localizedDescription)"))
        }
    }

    private func navigateToChat() {
        NotificationCenter.default.post(
            name: .injectAgentPostToChat,
            object: nil,
            userInfo: [
                "title": activity.title,
                "content": activity.detailedSummary.isEmpty ? activity.summary : activity.detailedSummary,
                "previewId": activity.previewId as Any
            ]
        )
    }

    private func convertToPost() async {
        // 重新调用 MCP，让 AI 把 insight 升级成 post
        // 目前简单做：navigate to chat，让用户让 Agent 整理
        navigateToChat()
    }

    private func markSkipped() {
        if let recordId = activity.recordId {
            // 有 recordId 则精准软删除
            StorageManager.shared.deleteTimelineCard(recordId: recordId)
        } else if let batchId = activity.batchId {
            // fallback：通过 batchId 删除
            StorageManager.shared.deleteTimelineCards(forBatchIds: [batchId])
        }
        NotificationCenter.default.post(name: .timelineDataUpdated, object: nil)
    }

    private func showToastWith(_ result: PublishResult) {
        publishResult = result
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeOut(duration: 0.2)) {
                showToast = false
            }
        }
    }
}

// MARK: - Supporting Types

private struct PublishResult {
    let isSuccess: Bool
    let message: String
}
