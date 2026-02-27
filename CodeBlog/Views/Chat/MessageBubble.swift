//
//  MessageBubble.swift
//  CodeBlog
//
//  Renders a single chat message: user bubble, assistant markdown, or tool call.
//

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var onEditResend: ((UUID, String) -> Void)? = nil
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .toolCall:
            ToolCallBubble(message: message)
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isEditing {
                HStack {
                    Spacer(minLength: 60)
                    VStack(alignment: .trailing, spacing: 8) {
                        TextField("", text: $editText, axis: .vertical)
                            .font(.custom("Nunito", size: 13).weight(.medium))
                            .foregroundColor(Color(hex: "2F2A24"))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color(hex: "F96E00").opacity(0.4), lineWidth: 1)
                            )
                            .onSubmit {
                                submitEdit()
                            }

                        HStack(spacing: 8) {
                            Button("Cancel") {
                                isEditing = false
                            }
                            .font(.custom("Nunito", size: 11).weight(.medium))
                            .foregroundColor(Color(hex: "999999"))
                            .buttonStyle(.plain)
                            .pointingHandCursor()

                            Button(action: { submitEdit() }) {
                                Text("Send")
                                    .font(.custom("Nunito", size: 11).weight(.bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(Color(hex: "F96E00"))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }
            } else {
                HStack {
                    Spacer(minLength: 60)
                    Text(message.content)
                        .font(.custom("Nunito", size: 13).weight(.medium))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(hex: "F98D3D"))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                // Always-present action row (fixed height, no layout shift)
                HStack(spacing: 2) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    }) {
                        Image("IconCopy")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 13, height: 13)
                            .foregroundColor(Color(hex: "BBBBBB"))
                            .frame(width: 26, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Copy")

                    Button(action: {
                        editText = message.content
                        isEditing = true
                    }) {
                        Image("IconEdit")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 13, height: 13)
                            .foregroundColor(Color(hex: "BBBBBB"))
                            .frame(width: 26, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Edit")
                }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private func submitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isEditing = false
        onEditResend?(message.id, trimmed)
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        let blocks = ChatContentParser.blocks(from: message.content)
        return HStack {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    switch block {
                    case .text(_, let content):
                        MarkdownBlockRenderer(content: content)
                    case .chart(let spec):
                        ChatChartBlockView(spec: spec)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: "E8E8E8"), lineWidth: 1)
            )
            .environment(\.openURL, OpenURLAction { url in
                handleAssistantLinkTap(url)
            })
            Spacer(minLength: 60)
        }
    }

    // MARK: - Link Handling

    private func handleAssistantLinkTap(_ url: URL) -> OpenURLAction.Result {
        guard let externalURL = normalizedExternalURL(from: url) else {
            print("[ChatView] Blocked unsupported URL: \(url.absoluteString)")
            return .discarded
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(externalURL, configuration: configuration) { _, error in
            if let error {
                print("[ChatView] Failed opening URL \(externalURL.absoluteString): \(error.localizedDescription)")
            }
        }
        return .handled
    }

    private func normalizedExternalURL(from rawURL: URL) -> URL? {
        if let scheme = rawURL.scheme?.lowercased() {
            switch scheme {
            case "http", "https", "mailto":
                return rawURL
            default:
                return nil
            }
        }

        let trimmed = rawURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prefixed = trimmed.hasPrefix("//")
            ? "https:\(trimmed)"
            : "https://\(trimmed)"

        guard let normalized = URL(string: prefixed),
              let scheme = normalized.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = normalized.host,
              !host.isEmpty else {
            return nil
        }

        return normalized
    }
}
