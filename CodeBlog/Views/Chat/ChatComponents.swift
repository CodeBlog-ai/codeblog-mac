//
//  ChatComponents.swift
//  CodeBlog
//
//  Small, stateless UI components used in the chat interface.
//

import SwiftUI

// MARK: - Animated Ellipsis

struct AnimatedEllipsis: View {
    private let interval: TimeInterval = 0.45

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / interval) % 3 + 1
            Text(String(repeating: ".", count: step))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Work Status Card

struct WorkStatusCard: View {
    let status: ChatWorkStatus
    @Binding var showDetails: Bool
    @State private var shimmerOffset: CGFloat = -1.0

    var body: some View {
        // Only show when thinking or answering (tool calls are shown as chat messages)
        if status.stage == .thinking || status.stage == .answering {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: headerIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(accentColor)
                        .frame(width: 12, height: 12, alignment: .center)

                    HStack(spacing: 0) {
                        Text(headerTitle)
                        AnimatedEllipsis()
                    }
                    .font(.custom("Nunito", size: 11).weight(.semibold))
                    .foregroundColor(Color(hex: "4A4A4A"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        LinearGradient(
                            colors: [Color(hex: "FFF8F0"), Color(hex: "FFF4E9")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        ShimmerOverlay(offset: shimmerOffset)
                            .blendMode(.softLight)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(hex: "F0CBA7"), lineWidth: 1)
                )

                Spacer()
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerOffset = 1.0
                }
            }
        } else if status.stage == .error, let message = status.errorMessage, !message.isEmpty {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "FF3B30"))

                    Text(message)
                        .font(.custom("Nunito", size: 12).weight(.semibold))
                        .foregroundColor(Color(hex: "C62828"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(hex: "FFEBEE"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(hex: "FF3B30").opacity(0.3), lineWidth: 1)
                )

                Spacer(minLength: 60)
            }
        }
    }

    private var headerTitle: String {
        status.stage == .thinking ? "Thinking" : "Answering"
    }

    private var headerIcon: String {
        status.stage == .thinking ? "sparkles" : "text.bubble"
    }

    private var accentColor: Color {
        Color(hex: "F96E00")
    }
}

// MARK: - Thinking Indicator

struct ThinkingIndicator: View {
    @State private var dotScale: [CGFloat] = [1, 1, 1]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "F96E00"))

            Text("Thinking")
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "8B5E3C"))

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color(hex: "F96E00"))
                        .frame(width: 4, height: 4)
                        .scaleEffect(dotScale[index])
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color(hex: "FFF4E9"), Color(hex: "FFECD8")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: "F96E00").opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        for i in 0..<3 {
            withAnimation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
                .delay(Double(i) * 0.15)
            ) {
                dotScale[i] = 1.4
            }
        }
    }
}

// MARK: - Suggestion Chip

struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.custom("Nunito", size: 12).weight(.medium))
                .foregroundColor(Color(hex: "F96E00"))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(hex: "FFF4E9"))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(hex: "F96E00").opacity(0.3), lineWidth: 1)
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Flow Layout

struct ChatFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        maxRowWidth = max(maxRowWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Welcome Prompt

struct WelcomePrompt {
    let icon: String
    let text: String
}

// MARK: - Welcome Suggestion Row

struct WelcomeSuggestionRow: View {
    let prompt: WelcomePrompt
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: prompt.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "C9670D"))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color(hex: "FFF0E1"))
                    )

                Text(prompt.text)
                    .font(.custom("Nunito", size: 13).weight(.semibold))
                    .foregroundColor(Color(hex: "5C432F"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: "D58A3D"))
                    .padding(.trailing, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.88) : Color.white.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(hex: "EED7BF"), lineWidth: 1)
            )
            .scaleEffect(reduceMotion ? 1 : (isHovered ? 1.01 : 1))
            .offset(y: reduceMotion ? 0 : (isHovered ? -1 : 0))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            guard !reduceMotion else {
                isHovered = false
                return
            }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Provider Toggle Pill

struct ProviderTogglePill: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    private var backgroundColor: Color {
        if !isEnabled { return Color(hex: "F2F2F2") }
        return isSelected ? Color(hex: "FFF4E9") : Color.white
    }

    private var borderColor: Color {
        if !isEnabled { return Color(hex: "E0E0E0") }
        return isSelected ? Color(hex: "F96E00").opacity(0.25) : Color(hex: "E0E0E0")
    }

    private var textColor: Color {
        if !isEnabled { return Color(hex: "B0B0B0") }
        return isSelected ? Color(hex: "F96E00") : Color(hex: "666666")
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointingHandCursor(enabled: isEnabled)
    }
}

// MARK: - Press Scale Button Style

struct PressScaleButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1.0)
            .brightness(configuration.isPressed && isEnabled ? -0.02 : 0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .pointingHandCursor(enabled: isEnabled)
    }
}

// MARK: - Debug Log Entry

struct DebugLogEntry: View {
    let entry: ChatDebugEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.type.rawValue)
                    .font(.custom("Nunito", size: 10).weight(.bold))
                    .foregroundColor(Color(hex: entry.typeColor))

                Spacer()

                Text(formatTimestamp(entry.timestamp))
                    .font(.custom("Nunito", size: 9))
                    .foregroundColor(Color(hex: "AAAAAA"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(entry.content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "333333"))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
        }
        .padding(8)
        .background(Color(hex: "FAFAFA"))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(hex: entry.typeColor).opacity(0.3), lineWidth: 1)
        )
    }

    private func formatTimestamp(_ date: Date) -> String {
        chatDebugTimestampFormatter.string(from: date)
    }
}

// MARK: - History Row View

struct HistoryRowView: View {
    let conv: ChatConversation
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conv.title)
                        .font(.custom("Nunito", size: 12).weight(isActive ? .bold : .medium))
                        .foregroundColor(isActive ? Color(hex: "F96E00") : Color(hex: "4A4A4A"))
                        .lineLimit(1)

                    Text(relativeTimeString(conv.updatedAt))
                        .font(.custom("Nunito", size: 10).weight(.regular))
                        .foregroundColor(Color(hex: "BBBBBB"))
                }

                Spacer()

                ZStack {
                    if isActive && !isHovered {
                        Circle()
                            .fill(Color(hex: "F96E00"))
                            .frame(width: 6, height: 6)
                    }
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(Color(hex: "BBBBBB"))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                }
                .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isActive ? Color(hex: "FFF4E9") : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func relativeTimeString(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

// MARK: - Shared Formatters

let chatDebugTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()
