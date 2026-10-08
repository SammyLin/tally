import SwiftUI

/// Block-level Markdown for summaries and Ask answers (web: marked): headings, bullet / numbered lists, quotes,
/// fenced code, dividers, tables and paragraphs. Inline styles and links go through AttributedString.
nonisolated enum MD {
    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(indent: Int, String)
        case numbered(indent: Int, number: String, String)
        case quote(String)
        case code(String)
        case rule
        case table(header: [String], rows: [[String]])
    }

    nonisolated(unsafe) static let ruleRe = /^ {0,3}([-*_])( *\1){2,} *$/
    nonisolated(unsafe) static let numberedRe = /^(\s*)(\d{1,9})[.)]\s+(.*)$/
    nonisolated(unsafe) static let bulletRe = /^(\s*)[-*+]\s+(.*)$/
    nonisolated(unsafe) static let tableSepRe = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/

    static func blocks(_ md: String) -> [Block] {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let fence = String(t.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                out.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if t.isEmpty { flush(); i += 1; continue }
            if t.contains("|"), i + 1 < lines.count, lines[i + 1].contains("-"), lines[i + 1].wholeMatch(of: tableSepRe) != nil {
                flush()
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }
            if line.wholeMatch(of: ruleRe) != nil { flush(); out.append(.rule); i += 1; continue }
            let hashes = t.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), t.dropFirst(hashes).first == " " {
                flush()
                out.append(.heading(hashes, String(t.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces).replacing(/\s#+$/, with: "")))
            } else if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count, case let s = lines[i].trimmingCharacters(in: .whitespaces), s.hasPrefix(">") {
                    q.append(String(s.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.quote(q.joined(separator: "\n")))
                continue
            } else if let m = line.wholeMatch(of: bulletRe) {
                flush()
                out.append(.bullet(indent: m.1.count / 2, String(m.2)))
            } else if let m = line.wholeMatch(of: numberedRe) {
                flush()
                out.append(.numbered(indent: m.1.count / 2, number: String(m.2), String(m.3)))
            } else {
                para.append(t)
            }
            i += 1
        }
        flush()
        return out
    }

    /// "| a | b |" → ["a", "b"]; the outer pipes are optional, `\|` stays a literal pipe.
    static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "\u{1}")
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    /// Only these links stay tappable (web: http(s), mailto; tally:// for citations).
    static let safeSchemes: Set<String> = ["http", "https", "mailto", "tally"]

    static func inline(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in a.runs {
            if let url = run.link, !safeSchemes.contains(url.scheme?.lowercased() ?? "") { a[run.range].link = nil }
        }
        return a
    }
}

struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MD.blocks(markdown).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ b: MD.Block) -> some View {
        switch b {
        case .heading(let level, let s):
            inline(s).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).padding(.top, 4)
        case .paragraph(let s):
            inline(s)
        case .bullet(let indent, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(s) }
                .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let indent, let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(n).").monospacedDigit(); inline(s) }
                .padding(.leading, CGFloat(indent) * 16)
        case .quote(let s):
            inline(s).foregroundStyle(Color(.inkMuted)).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .code(let s):
            ScrollView(.horizontal) {
                Text(s).font(.footnote.monospaced()).padding(8)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        case .rule:
            Divider()
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, c in inline(c).bold() } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(0..<header.count, id: \.self) { j in inline(j < row.count ? row[j] : "") } }
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("md.table")
        }
    }

    private func inline(_ s: String) -> Text { Text(MD.inline(s)) }
}
