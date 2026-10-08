import Foundation

/// "Copy as prompt": a port of buildPrompt / capOpts in web/public/index.html. Same input → same Markdown.
nonisolated struct PromptOptions: Codable, Equatable, Sendable {
    var summary = true
    var transcript = true
    var ts = true
    var raw = false
    var intro = "qa"
    var custom = ""

    private static let key = "tally.cap"

    static func load() -> PromptOptions {
        guard let d = UserDefaults.standard.data(forKey: key), let o = try? JSONDecoder().decode(PromptOptions.self, from: d) else { return .init() }
        return o
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

nonisolated enum Prompt {
    static let intros: [(key: String, label: String, text: String)] = [
        ("none", "無", ""),
        ("qa", "請根據內容回答問題", "以下是一份錄音的摘要與逐字稿，請根據內容回答我接下來的問題。"),
        ("todo", "請整理待辦與決議", "以下是一份會議錄音的逐字稿，請整理出所有待辦事項（負責人、內容、期限）與會議中做出的決定。"),
        ("custom", "自訂…", ""),
    ]

    /// `range`: segment indexes of a selection (web: selected text); summaries are left out then.
    static func build(_ d: Detail, _ o: PromptOptions, origin: String, templates: [Named],
                      range: ClosedRange<Int>? = nil, timeZone: TimeZone = .current) -> String {
        let r = d.recording
        let names = Dictionary(d.speakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { _, b in b })
        let who = { (id: Int?) in id.flatMap { names[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? "未知講者" }
        let segs = range.map { r in d.segments.enumerated().filter { r.contains($0.offset) }.map(\.element) } ?? d.segments
        // talk time per speaker in first-appearance order (a JS Map), then a stable sort by time desc
        var talk: [(id: Int?, ms: Int)] = []
        for s in segs {
            if let i = talk.firstIndex(where: { $0.id == s.speakerId }) { talk[i].ms += s.endMs - s.startMs }
            else { talk.append((s.speakerId, s.endMs - s.startMs)) }
        }
        var out: [String] = []
        let intro = o.intro == "custom" ? o.custom.trimmingCharacters(in: .whitespacesAndNewlines) : intros.first { $0.key == o.intro }?.text ?? ""
        if !intro.isEmpty { out += [intro, ""] }
        out.append("# " + r.title)
        out.append("- 日期：" + fmtDate(r.createdAt, timeZone: timeZone))
        if let dur = r.durationS { out.append("- 長度：" + fmtDur(dur)) }
        if range != nil, let a = segs.first, let b = segs.last {
            out.append("- 片段：\(fmtDur(Double(a.startMs) / 1000))–\(fmtDur(Double(b.endMs) / 1000))")
        }
        if !talk.isEmpty {
            let sorted = talk.enumerated().sorted { $0.element.ms != $1.element.ms ? $0.element.ms > $1.element.ms : $0.offset < $1.offset }
            out.append("- 參與者：" + sorted.map { who($0.element.id) }.joined(separator: "、"))
        }
        out.append("- 來源：\(origin)/#/rec/\(r.id)")
        if o.summary && range == nil {
            for sm in d.summaries where sm.status == "done" {
                guard let md = sm.contentMd, !md.isEmpty else { continue }
                let tname = templates.first { $0.id == sm.templateId }?.name ?? sm.templateId
                out += ["", "## 摘要（\(tname)）", "", nestHeadings(md.trimmingCharacters(in: .whitespacesAndNewlines))]
            }
        }
        if o.transcript || range != nil {
            out += ["", "## 逐字稿", ""]
            var cur: (id: Int?, text: String, ms: Int)?
            func line(_ c: (id: Int?, text: String, ms: Int)) -> String {
                (o.ts ? "[\(fmtDur(Double(c.ms) / 1000))] " : "") + who(c.id) + "：" + c.text
            }
            for s in segs {
                let t = (o.raw ? s.textRaw : (s.textClean ?? s.textRaw)).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                if let c = cur, c.id == s.speakerId { cur!.text = joinTxt(c.text, t); continue }
                if let c = cur { out.append(line(c)) }
                cur = (s.speakerId, t, s.startMs)
            }
            if let c = cur { out.append(line(c)) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// `#`…`#####` headings get one more level so they sit under our `## 摘要`.
    static func nestHeadings(_ md: String) -> String {
        md.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let hashes = line.prefix { $0 == "#" }.count
            return (1...5).contains(hashes) && line.dropFirst(hashes).first == " " ? "#" + line : String(line)
        }.joined(separator: "\n")
    }

    static func joinTxt(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        let alnum = { (c: Character?) in c.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false }
        return alnum(a.last) && alnum(b.first) ? a + " " + b : a + b
    }

    static func fmtDur(_ sec: Double) -> String {
        guard sec.isFinite else { return "--:--" }
        let s = max(0, Int(sec.rounded(.down)))
        let h = s / 3600, m = s % 3600 / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%02d:%02d", m, ss)
    }

    /// D1 datetimes ("YYYY-MM-DD HH:MM:SS") are UTC; shown like the web's zh-TW toLocaleString: 2026/10/08 14:30.
    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if s.contains("T") {
            return ISO8601DateFormatter().date(from: s) ?? {
                f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                return f.date(from: String(s.prefix(19)))
            }()
        }
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }

    /// Same CLDR pattern as the web's toLocaleString('zh-TW', {numeric year, 2-digit rest, hour12 false}),
    /// so the output follows the platform's ICU exactly (currently "2026/10/08\u{2009}14:30", thin space).
    static func fmtDate(_ s: String, timeZone: TimeZone = .current) -> String {
        guard !s.isEmpty, let d = parseDate(s) else { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh-TW")
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("yyyyMMddHHmm")
        return f.string(from: d)
    }

    /// List rows (web fmtShort): the year only when it is not this year.
    static func fmtShort(_ s: String) -> String {
        guard let d = parseDate(s) else { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh-TW")
        let thisYear = Calendar.current.isDate(d, equalTo: .now, toGranularity: .year)
        f.setLocalizedDateFormatFromTemplate(thisYear ? "MMddHHmm" : "yyyyMMddHHmm")
        return f.string(from: d)
    }

    /// Rough, like the web: CJK ≈ 1 token per char, other text ≈ 4 chars per token (UTF-16 lengths, as in JS).
    static func estimate(_ text: String) -> (chars: Int, tokens: Int, warn: Bool) {
        let units = Array(text.utf16)
        let cjk = units.filter { (0x3000...0x9fff).contains($0) || (0xff00...0xffef).contains($0) }.count
        let tokens = Int((Double(cjk) + Double(units.count - cjk) / 4).rounded())
        return (units.count, tokens, units.count > 150_000)
    }

    static func estimateText(_ e: (chars: Int, tokens: Int, warn: Bool)) -> String {
        let n = { (v: Int) in v.formatted(.number.locale(Locale(identifier: "en_US"))) }
        return "約 \(n(e.chars)) 字 · ~\(n(e.tokens)) tokens" + (e.warn ? "　內容很長，有些模型一次放不下，可只複製摘要或一段" : "")
    }

    static func fileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let t = title.isEmpty ? "recording" : title
        return String(t.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) }) + ".md"
    }
}
