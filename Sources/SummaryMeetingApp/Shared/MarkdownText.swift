import SwiftUI

/// 轻量 Markdown 渲染：支持 #/##/### 标题、- 列表、- [ ] 任务、**粗体**、段落。
/// 目的是避免依赖系统默认 Markdown 渲染（参考 docs/10 教训）。
struct MarkdownText: View {
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks(raw).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case task(done: Bool, String)
        case blank
    }

    private func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blocks.append(.blank)
                continue
            }
            if trimmed.hasPrefix("### ") {
                blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- [ ] ") {
                blocks.append(.task(done: false, String(trimmed.dropFirst(6))))
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                blocks.append(.task(done: true, String(trimmed.dropFirst(6))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        return blocks
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .title3.bold())
                .padding(.top, level == 1 ? 6 : 2)
        case .paragraph(let text):
            Text(inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .task(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square" : "square")
                    .foregroundStyle(done ? .green : .secondary)
                Text(inline(text))
                    .strikethrough(done)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .blank:
            Spacer().frame(height: 4)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        // 支持 **bold** 和 `code`。
        var result = AttributedString()
        var remaining = Substring(text)
        while !remaining.isEmpty {
            if let range = remaining.range(of: "**"), let end = remaining.range(of: "**", range: range.upperBound..<remaining.endIndex) {
                result.append(AttributedString(remaining[remaining.startIndex..<range.lowerBound]))
                var bold = AttributedString(remaining[range.upperBound..<end.lowerBound])
                bold.font = .body.bold()
                result.append(bold)
                remaining = remaining[end.upperBound..<remaining.endIndex]
            } else {
                result.append(AttributedString(remaining))
                break
            }
        }
        return result
    }
}
