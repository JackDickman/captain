import SwiftUI

/// Lightweight markdown renderer for the profile documents. Handles the
/// block-level elements the LLM actually produces: headings (`#`, `##`,
/// `###`), bullet lists (`- `), and paragraphs. Inline syntax (`**bold**`,
/// `*italic*`, links) is delegated to AttributedString's parser inside
/// each paragraph.
///
/// We can't get this from `Text` + `AttributedString.MarkdownParsingOptions`
/// alone — `interpretedSyntax: .full` renders headings as plain text in a
/// SwiftUI Text view. Parsing into blocks ourselves keeps rendering
/// faithful while staying dependency-free.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Parsing

    private enum Block {
        case h1(String)
        case h2(String)
        case h3(String)
        case paragraph(String)
        case bullet(String)
        case numbered(marker: String, text: String)
        case blank
    }

    private var blocks: [Block] {
        var out: [Block] = []
        // Accumulate consecutive non-special lines into one paragraph so
        // soft-wrap stays natural.
        var paragraphBuffer: [String] = []
        func flush() {
            if !paragraphBuffer.isEmpty {
                let joined = paragraphBuffer.joined(separator: " ")
                out.append(.paragraph(joined))
                paragraphBuffer.removeAll()
            }
        }
        for rawLine in markdown.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                out.append(.blank)
            } else if line.hasPrefix("### ") {
                flush()
                out.append(.h3(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flush()
                out.append(.h2(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flush()
                out.append(.h1(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else if let parsed = parseOrderedListItem(line) {
                flush()
                out.append(.numbered(marker: parsed.marker, text: parsed.text))
            } else {
                paragraphBuffer.append(line)
            }
        }
        flush()
        return out
    }

    // MARK: - Rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .h1(let text):
            Text(inlineAttributed(text))
                .font(CaptainTheme.display(24))
                .foregroundStyle(CaptainTheme.textPrimary)
                .padding(.top, 4)
        case .h2(let text):
            Text(inlineAttributed(text))
                .font(CaptainTheme.display(18))
                .foregroundStyle(CaptainTheme.textPrimary)
                .padding(.top, 8)
        case .h3(let text):
            Text(inlineAttributed(text))
                .font(CaptainTheme.body(15, weight: .semibold))
                .foregroundStyle(CaptainTheme.textPrimary)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(inlineAttributed(text))
                .font(CaptainTheme.body(15))
                .foregroundStyle(CaptainTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(CaptainTheme.body(15))
                    .foregroundStyle(CaptainTheme.brass)
                Text(inlineAttributed(text))
                    .font(CaptainTheme.body(15))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let marker, let text):
            HStack(alignment: .top, spacing: 8) {
                Text("\(marker).")
                    .font(CaptainTheme.body(15, weight: .semibold))
                    .foregroundStyle(CaptainTheme.brass)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inlineAttributed(text))
                    .font(CaptainTheme.body(15))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .blank:
            Color.clear.frame(height: 2)
        }
    }

    /// Recognize a leading ordered-list marker like "1. " / "12) ". Returns
    /// the marker digits + the rest, or nil if the line doesn't match.
    private func parseOrderedListItem(_ line: String) -> (marker: String, text: String)? {
        var digits = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            digits.append(line[idx])
            idx = line.index(after: idx)
        }
        guard !digits.isEmpty, idx < line.endIndex else { return nil }
        let sep = line[idx]
        guard sep == "." || sep == ")" else { return nil }
        let afterSep = line.index(after: idx)
        guard afterSep < line.endIndex, line[afterSep] == " " else { return nil }
        let rest = String(line[line.index(after: afterSep)...])
        return (digits, rest)
    }

    /// Parse inline markdown (bold, italic, links, code) for a single
    /// line-or-paragraph fragment.
    private func inlineAttributed(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: options))
            ?? AttributedString(s)
    }
}

#Preview {
    ScrollView {
        MarkdownView(markdown: """
            # Home profile

            **Address:** 4221 Silsby Rd, University Heights, OH 44118

            _Initial profile seeded from the first-session photo and public records._

            ## Architecture

            - 1942 brick Tudor with steep gabled roof
            - Front door is a vivid red
            - Mature pink-flowering tree on the side yard

            ## Landscaping

            - Garden beds along the front walk with low evergreens
            - Lawn slopes gently from sidewalk to porch
            """)
        .padding()
    }
    .background(CaptainTheme.cream)
}
