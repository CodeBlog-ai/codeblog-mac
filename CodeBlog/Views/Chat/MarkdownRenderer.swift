//
//  MarkdownRenderer.swift
//  CodeBlog
//
//  Markdown parsing/rendering and inline chart rendering for assistant messages.
//

import SwiftUI
import Charts
import AppKit

// MARK: - Markdown Block Renderer

/// Renders markdown content with proper block-level formatting:
/// code blocks, headers, lists, blockquotes, and inline styling.
struct MarkdownBlockRenderer: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case .codeBlock(let language, let code):
                    codeBlockView(language: language, code: code)
                case .heading(let level, let text):
                    headingView(level: level, text: text)
                case .paragraph(let text):
                    inlineMarkdownText(text)
                case .listItem(let text, let ordered, let index):
                    listItemView(text: text, ordered: ordered, index: index)
                case .blockquote(let text):
                    blockquoteView(text: text)
                case .horizontalRule:
                    Divider()
                        .padding(.vertical, 4)
                case .table(let headers, let rows):
                    tableView(headers: headers, rows: rows)
                }
            }
        }
    }

    // MARK: - Block Parsing

    private enum MarkdownBlock {
        case codeBlock(language: String?, code: String)
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case listItem(text: String, ordered: Bool, index: Int)
        case blockquote(text: String)
        case horizontalRule
        case table(headers: [String], rows: [[String]])
    }

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            let text = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text: text))
            }
            paragraphBuffer = []
        }

        var orderedIndex = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code fence
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(codeLine)
                    i += 1
                }
                // Skip suggestions blocks -- they are rendered as follow-up chips
                if lang.lowercased() == "suggestions" {
                    continue
                }
                let code = codeLines.joined(separator: "\n")
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: code))
                orderedIndex = 0
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                flushParagraph()
                var level = 0
                for ch in trimmed {
                    if ch == "#" { level += 1 } else { break }
                }
                level = min(level, 6)
                let headingText = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: headingText))
                orderedIndex = 0
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.horizontalRule)
                orderedIndex = 0
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                let quoteText = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : ""
                blocks.append(.blockquote(text: quoteText))
                orderedIndex = 0
                i += 1
                continue
            }

            // Table: detect rows starting and ending with |
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                flushParagraph()
                var tableLines: [String] = [trimmed]
                i += 1
                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("|") && nextTrimmed.hasSuffix("|") {
                        tableLines.append(nextTrimmed)
                        i += 1
                    } else {
                        break
                    }
                }

                if tableLines.count >= 2 {
                    let parseRow: (String) -> [String] = { line in
                        let inner = line.dropFirst().dropLast()
                        return inner.components(separatedBy: "|").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }
                    }

                    let headerCells = parseRow(tableLines[0])
                    let separatorChars = CharacterSet(charactersIn: "-:| ")
                    let isSeparator = tableLines[1].unicodeScalars.allSatisfy {
                        separatorChars.contains($0)
                    }
                    let dataStart = isSeparator ? 2 : 1
                    var dataRows: [[String]] = []
                    for rowIdx in dataStart..<tableLines.count {
                        dataRows.append(parseRow(tableLines[rowIdx]))
                    }
                    blocks.append(.table(headers: headerCells, rows: dataRows))
                } else {
                    paragraphBuffer.append(contentsOf: tableLines)
                }
                orderedIndex = 0
                continue
            }

            // Unordered list item
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                let itemText = String(trimmed.dropFirst(2))
                blocks.append(.listItem(text: itemText, ordered: false, index: 0))
                orderedIndex = 0
                i += 1
                continue
            }

            // Ordered list item (e.g. "1. ", "2. ")
            if trimmed.count >= 3,
               let dotIdx = trimmed.firstIndex(of: "."),
               dotIdx < trimmed.index(trimmed.startIndex, offsetBy: min(3, trimmed.count)),
               trimmed.index(after: dotIdx) < trimmed.endIndex,
               trimmed[trimmed.index(after: dotIdx)] == " ",
               let num = Int(trimmed[trimmed.startIndex..<dotIdx]) {
                flushParagraph()
                orderedIndex += 1
                let itemText = String(trimmed[trimmed.index(dotIdx, offsetBy: 2)...])
                blocks.append(.listItem(text: itemText, ordered: true, index: num))
                i += 1
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                flushParagraph()
                orderedIndex = 0
                i += 1
                continue
            }

            // Regular text line
            paragraphBuffer.append(line)
            i += 1
        }

        // Suppress incomplete suggestions block during streaming
        let bufferText = paragraphBuffer.joined(separator: "\n")
        if bufferText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```suggestions") {
            paragraphBuffer = []
        }

        flushParagraph()
        return blocks
    }

    // MARK: - Block Views

    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language label and copy button
            if let lang = language, !lang.isEmpty {
                HStack {
                    Text(lang)
                        .font(.custom("Nunito", size: 10).weight(.bold))
                        .foregroundColor(Color(hex: "8B7355"))
                    Spacer()
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                            Text("Copy")
                                .font(.custom("Nunito", size: 10).weight(.medium))
                        }
                        .foregroundColor(Color(hex: "9B7753"))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(hex: "F0E6D8"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(hex: "2F2A24"))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(hex: "FAF5EF"))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: "E9DDD0"), lineWidth: 1)
        )
    }

    private func headingView(level: Int, text: String) -> some View {
        let fontSize: CGFloat
        let weight: Font.Weight
        switch level {
        case 1:
            fontSize = 20
            weight = .bold
        case 2:
            fontSize = 17
            weight = .bold
        case 3:
            fontSize = 15
            weight = .semibold
        default:
            fontSize = 14
            weight = .semibold
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        let displayText: Text
        if let parsed = try? AttributedString(markdown: text, options: options) {
            displayText = Text(parsed)
        } else {
            displayText = Text(text)
        }

        return displayText
            .font(.custom("Nunito", size: fontSize).weight(weight))
            .foregroundColor(Color(hex: "2F2A24"))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, level <= 2 ? 4 : 2)
    }

    private func listItemView(text: String, ordered: Bool, index: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if ordered {
                Text("\(index).")
                    .font(.custom("Nunito", size: 13).weight(.semibold))
                    .foregroundColor(Color(hex: "9B7753"))
                    .frame(width: 20, alignment: .trailing)
            } else {
                Text("\u{2022}")
                    .font(.custom("Nunito", size: 13).weight(.bold))
                    .foregroundColor(Color(hex: "9B7753"))
                    .frame(width: 12, alignment: .center)
            }
            inlineMarkdownText(text)
        }
    }

    private func blockquoteView(text: String) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: "F96E00").opacity(0.5))
                .frame(width: 3)

            inlineMarkdownText(text)
                .padding(.leading, 10)
        }
        .padding(.vertical, 4)
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let columnCount = headers.count

        return VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { col in
                    Text(headers[col])
                        .font(.custom("Nunito", size: 12).weight(.bold))
                        .foregroundColor(Color(hex: "2F2A24"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }
            .background(Color(hex: "F5EDE4"))

            Rectangle()
                .fill(Color(hex: "E0D5C8"))
                .frame(height: 1)

            // Data rows
            ForEach(0..<rows.count, id: \.self) { rowIdx in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { col in
                        let cellText = col < rows[rowIdx].count ? rows[rowIdx][col] : ""
                        inlineMarkdownText(cellText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .background(rowIdx % 2 == 0 ? Color.clear : Color(hex: "FAF7F3"))

                if rowIdx < rows.count - 1 {
                    Rectangle()
                        .fill(Color(hex: "EEEEEE").opacity(0.5))
                        .frame(height: 0.5)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: "E0D5C8"), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func inlineMarkdownText(_ text: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        if let parsed = try? AttributedString(markdown: text, options: options) {
            Text(parsed)
                .font(.custom("Nunito", size: 13).weight(.medium))
                .foregroundColor(Color(hex: "333333"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.custom("Nunito", size: 13).weight(.medium))
                .foregroundColor(Color(hex: "333333"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Inline Charts

enum ChatContentBlock: Identifiable {
    case text(id: UUID, content: String)
    case chart(ChatChartSpec)

    var id: UUID {
        switch self {
        case .text(let id, _):
            return id
        case .chart(let spec):
            return spec.id
        }
    }
}

enum ChatChartSpec: Identifiable {
    case bar(BasicChartSpec)
    case line(BasicChartSpec)
    case stackedBar(StackedBarChartSpec)
    case donut(DonutChartSpec)
    case heatmap(HeatmapChartSpec)
    case gantt(GanttChartSpec)

    var id: UUID {
        switch self {
        case .bar(let spec):
            return spec.id
        case .line(let spec):
            return spec.id
        case .stackedBar(let spec):
            return spec.id
        case .donut(let spec):
            return spec.id
        case .heatmap(let spec):
            return spec.id
        case .gantt(let spec):
            return spec.id
        }
    }

    var title: String {
        switch self {
        case .bar(let spec):
            return spec.title
        case .line(let spec):
            return spec.title
        case .stackedBar(let spec):
            return spec.title
        case .donut(let spec):
            return spec.title
        case .heatmap(let spec):
            return spec.title
        case .gantt(let spec):
            return spec.title
        }
    }

    static func parse(type: String, jsonString: String) -> ChatChartSpec? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        switch type {
        case "bar":
            guard let payload = try? JSONDecoder().decode(BasicPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, payload.x.count == payload.y.count else { return nil }
            return .bar(BasicChartSpec(
                title: payload.title,
                labels: payload.x,
                values: payload.y,
                colorHex: sanitizeHex(payload.color)
            ))
        case "line":
            guard let payload = try? JSONDecoder().decode(BasicPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, payload.x.count == payload.y.count else { return nil }
            return .line(BasicChartSpec(
                title: payload.title,
                labels: payload.x,
                values: payload.y,
                colorHex: sanitizeHex(payload.color)
            ))
        case "stacked_bar":
            guard let payload = try? JSONDecoder().decode(StackedPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, !payload.series.isEmpty else { return nil }

            let series = payload.series.compactMap { entry -> StackedBarChartSpec.Series? in
                guard !entry.values.isEmpty, entry.values.count == payload.x.count else { return nil }
                return StackedBarChartSpec.Series(
                    name: entry.name,
                    values: entry.values,
                    colorHex: sanitizeHex(entry.color)
                )
            }
            guard !series.isEmpty else { return nil }

            return .stackedBar(StackedBarChartSpec(
                title: payload.title,
                categories: payload.x,
                series: series
            ))
        case "donut":
            guard let payload = try? JSONDecoder().decode(DonutPayload.self, from: data) else { return nil }
            guard !payload.labels.isEmpty, payload.labels.count == payload.values.count else { return nil }
            let colors = payload.colors?.map { sanitizeHex($0) }
            let colorHexes: [String?]
            if let colors, colors.count == payload.labels.count {
                colorHexes = colors
            } else {
                colorHexes = Array(repeating: nil, count: payload.labels.count)
            }
            return .donut(DonutChartSpec(
                title: payload.title,
                labels: payload.labels,
                values: payload.values,
                colorHexes: colorHexes
            ))
        case "heatmap":
            guard let payload = try? JSONDecoder().decode(HeatmapPayload.self, from: data) else { return nil }
            guard !payload.x.isEmpty, !payload.y.isEmpty else { return nil }
            guard payload.values.count == payload.y.count else { return nil }
            for row in payload.values {
                guard row.count == payload.x.count else { return nil }
            }
            return .heatmap(HeatmapChartSpec(
                title: payload.title,
                xLabels: payload.x,
                yLabels: payload.y,
                values: payload.values,
                colorHex: sanitizeHex(payload.color)
            ))
        case "gantt":
            guard let payload = try? JSONDecoder().decode(GanttPayload.self, from: data) else { return nil }
            let items = payload.items.compactMap { item -> GanttChartSpec.Item? in
                guard item.end > item.start else { return nil }
                return GanttChartSpec.Item(
                    label: item.label,
                    start: item.start,
                    end: item.end,
                    colorHex: sanitizeHex(item.color)
                )
            }
            guard !items.isEmpty else { return nil }
            return .gantt(GanttChartSpec(
                title: payload.title,
                items: items
            ))
        default:
            return nil
        }
    }

    private struct BasicPayload: Decodable {
        let title: String
        let x: [String]
        let y: [Double]
        let color: String?
    }

    private struct StackedPayload: Decodable {
        let title: String
        let x: [String]
        let series: [SeriesPayload]

        struct SeriesPayload: Decodable {
            let name: String
            let values: [Double]
            let color: String?
        }
    }

    private struct DonutPayload: Decodable {
        let title: String
        let labels: [String]
        let values: [Double]
        let colors: [String]?
    }

    private struct HeatmapPayload: Decodable {
        let title: String
        let x: [String]
        let y: [String]
        let values: [[Double]]
        let color: String?
    }

    private struct GanttPayload: Decodable {
        let title: String
        let items: [ItemPayload]

        struct ItemPayload: Decodable {
            let label: String
            let start: Double
            let end: Double
            let color: String?
        }
    }

    private static func sanitizeHex(_ value: String?) -> String? {
        guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }
        let length = raw.count
        guard length == 6 || length == 8 else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw.uppercased()
    }
}

struct BasicChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let labels: [String]
    let values: [Double]
    let colorHex: String?
}

struct StackedBarChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let categories: [String]
    let series: [Series]

    struct Series: Identifiable {
        let id = UUID()
        let name: String
        let values: [Double]
        let colorHex: String?
    }
}

struct DonutChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let labels: [String]
    let values: [Double]
    let colorHexes: [String?]
}

struct HeatmapChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let xLabels: [String]
    let yLabels: [String]
    let values: [[Double]]
    let colorHex: String?
}

struct GanttChartSpec: Identifiable {
    let id = UUID()
    let title: String
    let items: [Item]

    struct Item: Identifiable {
        let id = UUID()
        let label: String
        let start: Double
        let end: Double
        let colorHex: String?
    }
}

struct ChatContentParser {
    static func blocks(from text: String) -> [ChatContentBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let pattern = "```chart\\s+type\\s*=\\s*(\\w+)\\s*\\n([\\s\\S]*?)\\n```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [.text(id: UUID(), content: text)]
        }

        let range = NSRange(normalized.startIndex..., in: normalized)
        let matches = regex.matches(in: normalized, range: range)
        guard !matches.isEmpty else { return [.text(id: UUID(), content: text)] }

        var blocks: [ChatContentBlock] = []
        var currentIndex = normalized.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: normalized) else { continue }

            if matchRange.lowerBound > currentIndex {
                let chunk = String(normalized[currentIndex..<matchRange.lowerBound])
                if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.text(id: UUID(), content: chunk))
                }
            }

            if let typeRange = Range(match.range(at: 1), in: normalized),
               let jsonRange = Range(match.range(at: 2), in: normalized) {
                let typeString = normalized[typeRange].lowercased()
                let jsonString = normalized[jsonRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if let spec = ChatChartSpec.parse(type: typeString, jsonString: jsonString) {
                    blocks.append(.chart(spec))
                } else {
                    blocks.append(.text(id: UUID(), content: String(normalized[matchRange])))
                }
            }

            currentIndex = matchRange.upperBound
        }

        if currentIndex < normalized.endIndex {
            let tail = String(normalized[currentIndex...])
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(id: UUID(), content: tail))
            }
        }

        return blocks.isEmpty ? [.text(id: UUID(), content: text)] : blocks
    }
}

struct ChatChartBlockView: View {
    let spec: ChatChartSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                Text(title)
                    .font(.custom("Nunito", size: 12).weight(.semibold))
                    .foregroundColor(Color(hex: "4A4A4A"))
            }
            chartBody
                .frame(height: 180)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        switch spec {
        case .bar(let chartSpec):
            basicChartBody(spec: chartSpec, isLine: false)
        case .line(let chartSpec):
            basicChartBody(spec: chartSpec, isLine: true)
        case .stackedBar(let chartSpec):
            stackedBarBody(spec: chartSpec)
        case .donut(let chartSpec):
            donutBody(spec: chartSpec)
        case .heatmap(let chartSpec):
            heatmapBody(spec: chartSpec)
        case .gantt(let chartSpec):
            ganttBody(spec: chartSpec)
        }
    }

    private func basicChartBody(spec: BasicChartSpec, isLine: Bool) -> some View {
        let points = Array(zip(spec.labels, spec.values)).map { ChartPoint(label: $0.0, value: $0.1) }
        let color = seriesColor(for: spec.colorHex, fallbackIndex: 0)

        return Chart(points) { point in
            if isLine {
                LineMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)

                PointMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color)
            } else {
                BarMark(
                    x: .value("Category", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color)
            }
        }
        .chartXAxis {
            AxisMarks(values: points.map(\.label)) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    private func stackedBarBody(spec: StackedBarChartSpec) -> some View {
        let points = stackedPoints(from: spec)
        let domain = spec.series.map(\.name)
        let range = spec.series.enumerated().map { index, series in
            seriesColor(for: series.colorHex, fallbackIndex: index)
        }

        return Chart(points) { point in
            BarMark(
                x: .value("Category", point.category),
                y: .value("Value", point.value)
            )
            .foregroundStyle(by: .value("Series", point.seriesName))
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartXAxis {
            AxisMarks(values: spec.categories) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    private func donutBody(spec: DonutChartSpec) -> some View {
        let slices = zip(spec.labels, spec.values).map { DonutSlice(label: $0.0, value: $0.1) }
        let range = spec.labels.enumerated().map { index, _ in
            let hex = spec.colorHexes.indices.contains(index) ? spec.colorHexes[index] : nil
            return seriesColor(for: hex, fallbackIndex: index)
        }

        return Chart(slices) { slice in
            SectorMark(
                angle: .value("Value", slice.value),
                innerRadius: .ratio(0.6),
                angularInset: 1
            )
            .foregroundStyle(by: .value("Label", slice.label))
        }
        .chartForegroundStyleScale(domain: spec.labels, range: range)
        .chartLegend(position: .bottom, alignment: .leading)
    }

    private func heatmapBody(spec: HeatmapChartSpec) -> some View {
        let points = heatmapPoints(from: spec)
        let range = heatmapRange(for: spec)
        let baseColor = seriesColor(for: spec.colorHex, fallbackIndex: 1)

        return Chart(points) { point in
            RectangleMark(
                x: .value("X", point.xLabel),
                y: .value("Y", point.yLabel),
                width: .ratio(0.9),
                height: .ratio(0.9)
            )
            .foregroundStyle(heatmapColor(value: point.value, range: range, base: baseColor))
            .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: spec.xLabels) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: spec.yLabels) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func ganttBody(spec: GanttChartSpec) -> some View {
        let domain = ganttDomain(for: spec)
        let labels = spec.items.map(\.label)

        return Chart(spec.items) { item in
            BarMark(
                xStart: .value("Start", item.start),
                xEnd: .value("End", item.end),
                y: .value("Label", item.label)
            )
            .foregroundStyle(seriesColor(for: item.colorHex, fallbackIndex: itemIndex(for: item, in: spec)))
            .cornerRadius(4)
        }
        .chartXScale(domain: domain.min...domain.max)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                if let number = value.as(Double.self) {
                    AxisValueLabel {
                        Text(number, format: .number.precision(.fractionLength(1)))
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: labels) { value in
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "666666"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func stackedPoints(from spec: StackedBarChartSpec) -> [StackedPoint] {
        var points: [StackedPoint] = []
        for series in spec.series {
            for (index, category) in spec.categories.enumerated() {
                points.append(StackedPoint(
                    category: category,
                    seriesName: series.name,
                    value: series.values[index]
                ))
            }
        }
        return points
    }

    private func seriesColor(for hex: String?, fallbackIndex: Int) -> Color {
        if let hex {
            return Color(hex: hex)
        }
        return Self.defaultPalette[fallbackIndex % Self.defaultPalette.count]
    }

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
    }

    private struct StackedPoint: Identifiable {
        let id = UUID()
        let category: String
        let seriesName: String
        let value: Double
    }

    private struct DonutSlice: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
    }

    private struct HeatmapPoint: Identifiable {
        let id = UUID()
        let xLabel: String
        let yLabel: String
        let value: Double
    }

    private struct HeatmapRange {
        let min: Double
        let max: Double
    }

    private struct GanttDomain {
        let min: Double
        let max: Double
    }

    private func heatmapPoints(from spec: HeatmapChartSpec) -> [HeatmapPoint] {
        var points: [HeatmapPoint] = []
        for (rowIndex, row) in spec.values.enumerated() {
            let yLabel = spec.yLabels[rowIndex]
            for (colIndex, value) in row.enumerated() {
                points.append(HeatmapPoint(
                    xLabel: spec.xLabels[colIndex],
                    yLabel: yLabel,
                    value: value
                ))
            }
        }
        return points
    }

    private func heatmapRange(for spec: HeatmapChartSpec) -> HeatmapRange {
        let flattened = spec.values.flatMap { $0 }
        let minValue = flattened.min() ?? 0
        let maxValue = flattened.max() ?? minValue
        return HeatmapRange(min: minValue, max: maxValue)
    }

    private func heatmapColor(value: Double, range: HeatmapRange, base: Color) -> Color {
        let denominator = range.max - range.min
        let normalized = denominator == 0 ? 1.0 : (value - range.min) / denominator
        let clamped = min(max(normalized, 0), 1)
        let opacity = 0.2 + (0.8 * clamped)
        return base.opacity(opacity)
    }

    private func ganttDomain(for spec: GanttChartSpec) -> GanttDomain {
        let starts = spec.items.map(\.start)
        let ends = spec.items.map(\.end)
        let minValue = min(starts.min() ?? 0, ends.min() ?? 0)
        let maxValue = max(starts.max() ?? 0, ends.max() ?? 0)
        return GanttDomain(min: minValue, max: maxValue)
    }

    private func itemIndex(for item: GanttChartSpec.Item, in spec: GanttChartSpec) -> Int {
        spec.items.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    private static let defaultPalette: [Color] = [
        Color(hex: "F96E00"),
        Color(hex: "1F6FEB"),
        Color(hex: "2E7D32"),
        Color(hex: "8E24AA"),
        Color(hex: "00897B")
    ]
}

