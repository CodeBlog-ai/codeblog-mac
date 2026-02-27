//
//  ToolCallBubble.swift
//  CodeBlog
//
//  Animated tool call indicator showing when the AI is fetching data.
//  Supports multi-step tool sequences merged into a single bubble.
//

import SwiftUI

struct ToolCallBubble: View {
    let message: ChatMessage
    @State private var shimmerOffset: CGFloat = -1.0
    @State private var spinnerRotation: Double = 0
    @State private var appearScale: CGFloat = 0.8
    @State private var appearOpacity: Double = 0
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasMultipleSteps: Bool {
        message.toolSteps.count > 1
    }

    private var completedSteps: [ChatMessage.ToolStep] {
        message.toolSteps.filter { step in
            if case .running = step.status { return false }
            return true
        }
    }

    private var currentStep: ChatMessage.ToolStep? {
        message.toolSteps.last(where: { step in
            if case .running = step.status { return true }
            return false
        }) ?? message.toolSteps.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if message.toolSteps.isEmpty {
                // Legacy fallback for single-step messages
                legacyRow
            } else {
                // Current/active step
                if let step = currentStep {
                    currentStepRow(step: step)
                }

                // Completed steps summary
                if hasMultipleSteps {
                    // Expand/collapse toggle
                    Button(action: { withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                            Text("\(completedSteps.count) step\(completedSteps.count > 1 ? "s" : "") completed")
                                .font(.custom("Nunito", size: 10).weight(.medium))
                        }
                        .foregroundColor(Color(hex: "9B7753"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(message.toolSteps.dropLast()) { step in
                                completedStepRow(step: step)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(borderOverlay)
        .shadow(color: shadowColor, radius: 6, x: 0, y: 3)
        .scaleEffect(appearScale)
        .opacity(appearOpacity)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                appearScale = 1.0
                appearOpacity = 1.0
            }
            startAnimationsIfNeeded()
        }
        .onChange(of: message.toolSteps.count) {
            // Bounce when a new step is added
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                appearScale = 1.03
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    appearScale = 1.0
                }
            }
            // Restart animations if running
            if message.isRunning {
                startAnimationsIfNeeded()
            }
        }
    }

    // MARK: - Step Rows

    private func currentStepRow(step: ChatMessage.ToolStep) -> some View {
        HStack(spacing: 8) {
            stepIcon(for: step.status)
            Text(step.description)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(stepTextColor(for: step.status))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func completedStepRow(step: ChatMessage.ToolStep) -> some View {
        HStack(spacing: 5) {
            stepIcon(for: step.status)
                .scaleEffect(0.8)
            Text(step.name)
                .font(.custom("Nunito", size: 10).weight(.medium))
                .foregroundColor(Color(hex: "888888"))
            if case .completed(let summary) = step.status {
                Text("— \(summary)")
                    .font(.custom("Nunito", size: 10).weight(.regular))
                    .foregroundColor(Color(hex: "AAAAAA"))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Legacy Single Row

    private var legacyRow: some View {
        HStack(spacing: 8) {
            statusIcon
            statusText
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Icons

    @ViewBuilder
    private func stepIcon(for status: ChatMessage.ToolStatus) -> some View {
        switch status {
        case .running:
            Image(systemName: "circle.dotted")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "F96E00"))
                .rotationEffect(.degrees(spinnerRotation))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "34C759"))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "FF3B30"))
        }
    }

    private func stepTextColor(for status: ChatMessage.ToolStatus) -> Color {
        switch status {
        case .running: return Color(hex: "8B5E3C")
        case .completed: return Color(hex: "2D7D46")
        case .failed: return Color(hex: "C62828")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.toolStatus {
        case .running:
            Image(systemName: "circle.dotted")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "F96E00"))
                .rotationEffect(.degrees(spinnerRotation))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "34C759"))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "FF3B30"))
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch message.toolStatus {
        case .running:
            Text(message.content)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "8B5E3C"))
        case .completed(let summary):
            Text(summary)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "2D7D46"))
        case .failed(let error):
            Text(error)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "C62828"))
        case nil:
            Text(message.content)
                .font(.custom("Nunito", size: 12).weight(.semibold))
                .foregroundColor(Color(hex: "8B5E3C"))
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundView: some View {
        switch message.toolStatus {
        case .running:
            ZStack {
                LinearGradient(
                    colors: [Color(hex: "FFF4E9"), Color(hex: "FFECD8")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if !reduceMotion {
                    ShimmerOverlay(offset: shimmerOffset)
                        .blendMode(.softLight)
                }
            }
        case .completed:
            LinearGradient(
                colors: [Color(hex: "E8F5E9"), Color(hex: "C8E6C9")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .failed:
            LinearGradient(
                colors: [Color(hex: "FFEBEE"), Color(hex: "FFCDD2")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case nil:
            Color(hex: "FFF4E9")
        }
    }

    // MARK: - Border & Shadow

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(borderColor, lineWidth: 1.5)
    }

    private var borderColor: Color {
        switch message.toolStatus {
        case .running:   return Color(hex: "F96E00").opacity(0.3)
        case .completed: return Color(hex: "34C759").opacity(0.3)
        case .failed:    return Color(hex: "FF3B30").opacity(0.3)
        case nil:        return Color(hex: "F96E00").opacity(0.3)
        }
    }

    private var shadowColor: Color {
        switch message.toolStatus {
        case .running:   return Color(hex: "F96E00").opacity(0.1)
        case .completed: return Color(hex: "34C759").opacity(0.1)
        case .failed:    return Color(hex: "FF3B30").opacity(0.1)
        case nil:        return Color(hex: "F96E00").opacity(0.1)
        }
    }

    // MARK: - Animations

    private func startAnimationsIfNeeded() {
        guard message.isRunning, !reduceMotion else { return }

        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            spinnerRotation = 360
        }

        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
            shimmerOffset = 1.0
        }
    }
}

// MARK: - Shimmer Overlay

struct ShimmerOverlay: View {
    let offset: CGFloat

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.5),
                    Color.white.opacity(0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.4)
            .offset(x: offset * geo.size.width * 1.4 - geo.size.width * 0.2)
        }
        .clipped()
    }
}

// MARK: - Preview

#Preview("Tool Call Bubble - Multi-step") {
    VStack(spacing: 20) {
        ToolCallBubble(
            message: ChatMessage(
                role: .toolCall,
                content: "Scanning sessions...",
                toolStatus: .running,
                toolSteps: [
                    .init(id: UUID(), name: "Scanning sessions", description: "Scanning your recent coding sessions...", status: .completed(summary: "Found 5 sessions")),
                    .init(id: UUID(), name: "Reading session", description: "Reading session content...", status: .running)
                ]
            )
        )

        ToolCallBubble(
            message: ChatMessage(
                role: .toolCall,
                content: "3 tools completed",
                toolStatus: .completed(summary: "3 tools completed"),
                toolSteps: [
                    .init(id: UUID(), name: "Scanning sessions", description: "Scanning your recent coding sessions...", status: .completed(summary: "Found 5 sessions")),
                    .init(id: UUID(), name: "Reading session", description: "Reading session content...", status: .completed(summary: "42 lines")),
                    .init(id: UUID(), name: "Analyzing", description: "Analyzing session data...", status: .completed(summary: "3 topics found"))
                ]
            )
        )
    }
    .padding(40)
    .background(Color(hex: "FAF5F0"))
}
