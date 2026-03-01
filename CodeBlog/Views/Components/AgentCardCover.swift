import SwiftUI

// MARK: - AgentCardCover
//
// SwiftUI-drawn cover art for Agent cards. Each type has 5 visual variants.
// The variant is determined by the card ID so the same card always shows the same cover.
//
// When designers provide assets, replace the variant body with:
//   Image("agent_cover_journal_1")
// The public interface stays the same.
//
// To add a new card type: add a case to AgentCardType and a Cover struct below.

// MARK: - Type

enum AgentCardType: String {
    case journal
    case insight
    case post
    case unknown

    static func from(_ string: String) -> AgentCardType {
        switch string.lowercased() {
        case "journal": return .journal
        case "insight": return .insight
        case "post":    return .post
        default:        return .unknown
        }
    }

    var label: String {
        switch self {
        case .journal: return "Journal"
        case .insight: return "Insight"
        case .post:    return "Post"
        case .unknown: return "Card"
        }
    }
}

// MARK: - Entry point

struct AgentCardCover: View {
    let cardId: String
    let type: AgentCardType
    let title: String

    private var variantIndex: Int {
        // Extract trailing digits from the card ID for a stable, process-restart-safe index.
        let digits = cardId.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }
        let seed = digits.suffix(6).reduce(0) { $0 * 10 + Int($1.value - 48) }
        return seed % variantCount
    }

    private var variantCount: Int { 5 }

    var body: some View {
        switch type {
        case .journal:
            JournalCover(variant: variantIndex, title: title)
        case .insight:
            InsightCover(variant: variantIndex, title: title)
        case .post:
            PostCover(variant: variantIndex, title: title)
        case .unknown:
            UnknownCover(title: title)
        }
    }
}

// MARK: - Shared label

private struct CoverLabel: View {
    let typeLabel: String
    let title: String
    var labelColor: Color = .white.opacity(0.9)
    var titleColor: Color = .white.opacity(0.65)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(typeLabel.uppercased())
                .font(.custom("Nunito", size: 10).weight(.heavy))
                .tracking(2.5)
                .foregroundColor(labelColor)
            Text(title)
                .font(.custom("InstrumentSerif-Regular", size: 14))
                .foregroundColor(titleColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

// MARK: - Journal covers (warm, notebook feel)

private struct JournalCover: View {
    let variant: Int
    let title: String

    private static let palettes: [(bg: [Color], accent: Color)] = [
        // 0: Cream coral
        ([Color(hex: "FDECD7"), Color(hex: "F9CBB0"), Color(hex: "F4A47A")], Color(hex: "E8724A")),
        // 1: Honey amber
        ([Color(hex: "FFF3C4"), Color(hex: "FFD97D"), Color(hex: "F4A623")], Color(hex: "C47B0A")),
        // 2: Lavender rose
        ([Color(hex: "F5E6FA"), Color(hex: "E5C5F5"), Color(hex: "CC8FE8")], Color(hex: "9B5EC7")),
        // 3: Mint seafoam
        ([Color(hex: "E0F7F0"), Color(hex: "A8E6CF"), Color(hex: "5EC9A6")], Color(hex: "2EA07D")),
        // 4: Deep navy
        ([Color(hex: "1A2340"), Color(hex: "2B3A6B"), Color(hex: "3D5299")], Color(hex: "7A9FFF")),
    ]

    private var palette: (bg: [Color], accent: Color) { Self.palettes[variant] }
    private var isDark: Bool { variant == 4 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: palette.bg, startPoint: .topLeading, endPoint: .bottomTrailing)

            // Horizontal ruled lines + left margin line (notebook decoration)
            GeometryReader { geo in
                let spacing: CGFloat = 22
                let count = Int(geo.size.height / spacing)
                ForEach(0..<count, id: \.self) { i in
                    Rectangle()
                        .fill(palette.accent.opacity(0.18))
                        .frame(height: 0.8)
                        .offset(x: 0, y: CGFloat(i + 2) * spacing)
                }
                Rectangle()
                    .fill(palette.accent.opacity(0.35))
                    .frame(width: 1.5)
                    .offset(x: 34, y: 0)
            }

            VStack(spacing: 8) {
                Text("📔").font(.system(size: 40))
                Text("JOURNAL")
                    .font(.custom("Nunito", size: 10).weight(.heavy))
                    .tracking(3)
                    .foregroundColor(isDark ? Color(hex: "7A9FFF") : palette.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: 0, y: -14)

            CoverLabel(
                typeLabel: "Journal",
                title: title,
                labelColor: isDark ? Color(hex: "7A9FFF") : palette.accent,
                titleColor: (isDark ? Color.white : Color.black).opacity(0.55)
            )
        }
        .clipShape(Rectangle())
    }
}

// MARK: - Insight covers (cool, analytical feel)

private struct InsightCover: View {
    let variant: Int
    let title: String

    private static let palettes: [(bg: [Color], accent: Color)] = [
        // 0: Aurora violet
        ([Color(hex: "1B0E3D"), Color(hex: "2D1B6E"), Color(hex: "4A35A0")], Color(hex: "A78BFF")),
        // 1: Deep sea
        ([Color(hex: "0A1628"), Color(hex: "0F2D5A"), Color(hex: "1A4D8F")], Color(hex: "5BA3FF")),
        // 2: Teal neon
        ([Color(hex: "0D2B2B"), Color(hex: "0E4040"), Color(hex: "1A6060")], Color(hex: "3FFFD8")),
        // 3: Sky blue (light)
        ([Color(hex: "EEF4FF"), Color(hex: "D0E4FF"), Color(hex: "A8C8FF")], Color(hex: "3D6FD4")),
        // 4: Amber gold
        ([Color(hex: "2B1500"), Color(hex: "5C2E00"), Color(hex: "9B5000")], Color(hex: "FFB347")),
    ]

    private var palette: (bg: [Color], accent: Color) { Self.palettes[variant] }
    private var isLight: Bool { variant == 3 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: palette.bg, startPoint: .top, endPoint: .bottom)

            // Radial glow + dot grid decoration
            GeometryReader { geo in
                Circle()
                    .fill(RadialGradient(
                        colors: [palette.accent.opacity(0.25), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: geo.size.width * 0.55
                    ))
                    .frame(width: geo.size.width * 1.1, height: geo.size.width * 1.1)
                    .position(x: geo.size.width * 0.5, y: geo.size.height * 0.38)

                let cols = 6, rows = 5
                let dotSpacing: CGFloat = geo.size.width / CGFloat(cols + 1)
                ForEach(0..<rows, id: \.self) { r in
                    ForEach(0..<cols, id: \.self) { c in
                        Circle()
                            .fill(palette.accent.opacity(0.2))
                            .frame(width: 2.5, height: 2.5)
                            .position(
                                x: CGFloat(c + 1) * dotSpacing,
                                y: geo.size.height * 0.12 + CGFloat(r) * 14
                            )
                    }
                }
            }

            VStack(spacing: 8) {
                Text("💡").font(.system(size: 40))
                Text("INSIGHT")
                    .font(.custom("Nunito", size: 10).weight(.heavy))
                    .tracking(3)
                    .foregroundColor(palette.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: 0, y: -14)

            CoverLabel(
                typeLabel: "Insight",
                title: title,
                labelColor: palette.accent,
                titleColor: (isLight ? Color.black : Color.white).opacity(0.55)
            )
        }
        .clipShape(Rectangle())
    }
}

// MARK: - Post covers (energetic, publish feel)

private struct PostCover: View {
    let variant: Int
    let title: String

    private static let palettes: [(colors: [Color], accent: Color)] = [
        // 0: CodeBlog orange flame
        ([Color(hex: "F96E00"), Color(hex: "FF4E6A"), Color(hex: "FF9A3C")], Color(hex: "FFEDE0")),
        // 1: Rose gold
        ([Color(hex: "C94040"), Color(hex: "E8517A"), Color(hex: "F4A0A0")], Color(hex: "FFE8E8")),
        // 2: Forest green
        ([Color(hex: "1A6B3A"), Color(hex: "2EA06A"), Color(hex: "6ED4A4")], Color(hex: "E0FFF0")),
        // 3: Indigo calm
        ([Color(hex: "1C3557"), Color(hex: "2B5BA0"), Color(hex: "4E8FD4")], Color(hex: "E0EFFF")),
        // 4: Golden light
        ([Color(hex: "8B5E00"), Color(hex: "C48A00"), Color(hex: "F4C430")], Color(hex: "FFFBE0")),
    ]

    private var palette: (colors: [Color], accent: Color) { Self.palettes[variant] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: palette.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

            // Diagonal stripes + concentric circles (top-right corner)
            GeometryReader { geo in
                let stripeWidth: CGFloat = geo.size.width * 1.6
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(palette.accent.opacity(0.1))
                        .frame(width: stripeWidth, height: 12)
                        .rotationEffect(.degrees(-30), anchor: .leading)
                        .offset(x: -geo.size.width * 0.2, y: CGFloat(i) * 28.0 - 20 + geo.size.height * 0.2)
                }
                Circle()
                    .strokeBorder(palette.accent.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                    .position(x: geo.size.width - 28, y: 36)
                Circle()
                    .strokeBorder(palette.accent.opacity(0.15), lineWidth: 1)
                    .frame(width: 80, height: 80)
                    .position(x: geo.size.width - 28, y: 36)
            }

            VStack(spacing: 8) {
                Text("✍️").font(.system(size: 40))
                Text("POST")
                    .font(.custom("Nunito", size: 10).weight(.heavy))
                    .tracking(3)
                    .foregroundColor(palette.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: 0, y: -14)

            CoverLabel(typeLabel: "Post", title: title, labelColor: palette.accent, titleColor: palette.accent.opacity(0.7))
        }
        .clipShape(Rectangle())
    }
}

// MARK: - Unknown / Fallback

private struct UnknownCover: View {
    let title: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(hex: "7E9EE0"), Color(hex: "C490D8"), Color(hex: "FFB07A")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Text("✨").font(.system(size: 40))
                Text("AGENT CARD")
                    .font(.custom("Nunito", size: 10).weight(.heavy))
                    .tracking(3)
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: 0, y: -14)
            CoverLabel(typeLabel: "Agent Card", title: title)
        }
        .clipShape(Rectangle())
    }
}
