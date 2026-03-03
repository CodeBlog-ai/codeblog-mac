import SwiftUI

struct AgentDailyReportView: View {
    @StateObject private var viewModel = AgentDailyReportViewModel()
    @State private var isDetailExpanded: Bool = false

    var body: some View {
        HSplitView {
            leftPanel
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            rightPanel
                .frame(minWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .task {
            await viewModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDailyReportPublished)) { notification in
            let postId = notification.userInfo?["postId"] as? String
            Task {
                await viewModel.refresh(preferredPostID: postId, forceRemote: true)
                isDetailExpanded = false
            }
        }
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Agent Daily Reports")
                    .font(.custom("InstrumentSerif-Regular", size: 28))
                    .foregroundStyle(Color(hex: "B46531"))

                Spacer()

                Button {
                    Task { await viewModel.refresh(forceRemote: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.rows) { row in
                        let isSelected = viewModel.selectedRowID == row.id
                        Button {
                            selectRow(row.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.displayDate)
                                    .font(.custom("Nunito-SemiBold", size: 12))
                                    .foregroundStyle(Color(hex: isSelected ? "F96E00" : "6E6055"))

                                Text(row.title)
                                    .font(.custom("Nunito-Regular", size: 13))
                                    .lineLimit(2)
                                    .foregroundStyle(Color(hex: isSelected ? "1E1B18" : "8C8279"))

                                Text(row.hasReport ? "✓ Published on codeblog.ai" : "— No report yet")
                                    .font(.custom("Nunito-Regular", size: 11))
                                    .foregroundStyle(
                                        Color(
                                            hex: row.hasReport
                                                ? (isSelected ? "C56220" : "A3693E")
                                                : "B5ACA3"
                                        )
                                    )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? Color(hex: "FFF4E9") : Color.white.opacity(0.92))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(isSelected ? Color(hex: "F0C7A1") : Color(hex: "ECE4DD"), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: "EADFD4"), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                if !viewModel.hasTodayReport {
                    Button {
                        viewModel.triggerGenerateTodayReport()
                    } label: {
                        HStack(spacing: 8) {
                            if viewModel.isGeneratingTodayReport {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(viewModel.isGeneratingTodayReport ? "Injecting daily-report task…" : "Generate Today's Report")
                                .font(.custom("Nunito-SemiBold", size: 13))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(hex: "F96E00"))
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            if let errorMessage = viewModel.errorMessage,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(errorMessage)
                    .font(.custom("Nunito-Regular", size: 12))
                    .foregroundStyle(Color(hex: "B64C38"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                if let row = viewModel.selectedRow, row.hasReport {
                    reportDetail(for: row)
                } else {
                    emptyDetail
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: "EADFD4"), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func reportDetail(for row: AgentDailyReportViewModel.DailyReportRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.title)
                .font(.custom("InstrumentSerif-Regular", size: 30))
                .foregroundStyle(Color(hex: "B46531"))
            Spacer()
            if let postId = row.postId,
               let url = URL(string: "https://codeblog.ai/posts/\(postId)") {
                Link("Open on CodeBlog", destination: url)
                    .font(.custom("Nunito-SemiBold", size: 12))
                    .foregroundStyle(Color(hex: "F96E00"))
            }
        }

        HStack {
            Text(row.displayDate)
                .font(.custom("Nunito-Regular", size: 12))
                .foregroundStyle(Color(hex: "8A7B70"))
            if let createdAt = row.createdAt {
                Text("· \(createdAt)")
                    .font(.custom("Nunito-Regular", size: 12))
                    .foregroundStyle(Color(hex: "9A8E84"))
                    .lineLimit(1)
            }
            Spacer()
        }

        if let content = row.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldCollapse = normalized.count > 1800
            let previewText = shouldCollapse && !isDetailExpanded
                ? String(normalized.prefix(1800)) + "\n\n..."
                : normalized

            ScrollView(.vertical, showsIndicators: true) {
                Text(markdownText(previewText))
                    .font(.custom("Nunito-Regular", size: 14))
                    .foregroundStyle(Color(hex: "2B2622"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.bottom, 8)
            }

            if shouldCollapse {
                HStack {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            isDetailExpanded.toggle()
                        }
                    } label: {
                        Text(isDetailExpanded ? "Collapse report" : "Expand report")
                            .font(.custom("Nunito-SemiBold", size: 12))
                            .foregroundStyle(Color(hex: "F96E00"))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    Spacer()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("The report is published, but content failed to load. Open it on CodeBlog or refresh and try again.")
                    .font(.custom("Nunito-Regular", size: 14))
                    .foregroundStyle(Color(hex: "8C8279"))
                if let summary = row.summary,
                   !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Summary: \(summary)")
                        .font(.custom("Nunito-Regular", size: 13))
                        .foregroundStyle(Color(hex: "6F655D"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }

        HStack {
            Spacer()
            Button {
                viewModel.chatAboutSelectedReport()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Chat With Agent")
                        .font(.custom("Nunito-SemiBold", size: 13))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(hex: "F96E00"))
                )
            }
            .buttonStyle(.plain)
            .disabled(row.chatContext == nil)
            .opacity(row.chatContext == nil ? 0.55 : 1)
            .pointingHandCursor()
        }
    }

    private var emptyDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Report Detail")
                .font(.custom("InstrumentSerif-Regular", size: 30))
                .foregroundStyle(Color(hex: "B46531"))
            Text("Select a day on the left to view a report, or generate today's report first.")
                .font(.custom("Nunito-Regular", size: 14))
                .foregroundStyle(Color(hex: "8C8279"))
            Spacer()
        }
    }

    private func selectRow(_ rowID: String) {
        guard rowID != viewModel.selectedRowID else { return }
        viewModel.selectedRowID = rowID
        isDetailExpanded = false
    }

    private func markdownText(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return parsed
        }
        return AttributedString(raw)
    }
}

#Preview {
    AgentDailyReportView()
}
