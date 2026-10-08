import SwiftUI
import UIKit

struct DetailView: View {
    let id: Int

    @Environment(AppModel.self) private var app
    @State private var detail: Detail?
    @State private var meta: Templates?
    @State private var player: Player?
    @State private var tab = 0
    @State private var showRaw = false
    @State private var error: String?
    @State private var renaming: Segment?
    @State private var showPromptOptions = false
    @State private var share: ShareItem?
    @State private var toast: String?

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if let error {
                ContentUnavailableView("無法載入", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(detail?.recording.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(busy ? 3 : 60))
            }
        }
        .onDisappear { player?.stop() }
        .sheet(item: $renaming) { seg in
            if let detail {
                SpeakerSheet(segment: seg, name: name(seg.speakerId, in: detail)) { self.detail = $0 }
            }
        }
        .sheet(isPresented: $showPromptOptions) {
            if let detail { PromptOptionsSheet(detail: detail, templates: meta?.templates ?? [], origin: app.origin) { share = $0 } }
        }
        .sheet(item: $share) { ActivityView(items: $0.items) }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule).padding(.top, 8)
                    .accessibilityIdentifier("detail.toast")
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(2.5)); withAnimation { self.toast = nil } }
            }
        }
    }

    private var busy: Bool {
        guard let d = detail else { return false }
        return Status.busy(d.recording.status) || d.summaries.contains { Status.busy($0.status) }
    }

    private func load() async {
        do {
            let d: Detail = try await app.get("api/recordings/\(id)")
            detail = d
            if meta == nil { meta = try? await app.get("api/templates") }
            if player == nil, d.recording.status == "done", let b = app.backend {
                player = Player(url: b.base.appending(path: "media/\(id)"), backend: b, fallbackDuration: d.recording.durationS)
            }
            error = nil
        } catch is CancellationError {
        } catch {
            if detail == nil { self.error = error.localizedDescription }
        }
    }

    private func name(_ speakerId: Int?, in d: Detail) -> String {
        speakerId.flatMap { sid in d.speakers.first { $0.id == sid }?.displayName } ?? "未知講者"
    }

    @ViewBuilder private func content(_ d: Detail) -> some View {
        VStack(spacing: 0) {
            Picker("檢視", selection: $tab) {
                Text("逐字稿").tag(0)
                Text("摘要").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            if tab == 0 {
                TranscriptView(detail: d, player: player, showRaw: showRaw, onRename: { renaming = $0 }, onDetail: { detail = $0 },
                               onPrompt: { copyPrompt(range: $0) })
            } else {
                SummariesView(detail: d, meta: meta, onChange: { Task { await load() } })
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let player { PlayerBar(player: player) }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { copyPrompt() } label: { Label("複製為 Prompt", systemImage: "doc.on.doc") }
                Button { sharePrompt(asFile: false) } label: { Label("分享 Prompt…", systemImage: "square.and.arrow.up") }
                Button { sharePrompt(asFile: true) } label: { Label("分享 .md 檔…", systemImage: "doc.richtext") }
                Button { showPromptOptions = true } label: { Label("Prompt 選項與預覽…", systemImage: "slider.horizontal.3") }
                if detail?.segments.contains(where: { $0.textClean != nil }) == true {
                    Divider()
                    Toggle("檢視原始逐字稿", isOn: $showRaw)
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("detail.more")
            .disabled(detail == nil)
        }
    }

    private func promptText(range: ClosedRange<Int>? = nil) -> String? {
        guard let detail else { return nil }
        return Prompt.build(detail, .load(), origin: app.origin, templates: meta?.templates ?? [], range: range)
    }

    private func copyPrompt(range: ClosedRange<Int>? = nil) {
        guard let t = promptText(range: range) else { return }
        UIPasteboard.general.string = t
        withAnimation { toast = "已複製為 Prompt（\(Prompt.estimateText(Prompt.estimate(t)).components(separatedBy: "　")[0])）" }
    }

    private func sharePrompt(asFile: Bool) {
        guard let t = promptText(), let detail else { return }
        share = asFile ? ShareItem.file(t, title: detail.recording.title) : ShareItem(items: [t])
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let detail: Detail
    let player: Player?
    let showRaw: Bool
    let onRename: (Segment) -> Void
    let onDetail: (Detail) -> Void
    let onPrompt: (ClosedRange<Int>) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if Status.busy(detail.recording.status) || detail.recording.status == "error" {
                    Section { notice }
                }
                if !detail.segments.isEmpty {
                    Section { SpeakerLegend(detail: detail, onDetail: onDetail) }
                }
                Section {
                    ForEach(Array(detail.segments.enumerated()), id: \.element.id) { i, seg in
                        SegmentRow(index: i, segment: seg, speaker: speaker(seg.speakerId), showRaw: showRaw,
                                   active: seg.id == activeId, onSeek: { seek(seg) }, onRename: { onRename(seg) })
                            .id(seg.id)
                            .contextMenu {
                                // the web copies a text selection; here: one segment, or from it to the end
                                Button { onPrompt(i...i) } label: { Label("複製這句為 Prompt", systemImage: "doc.on.doc") }
                                Button { onPrompt(i...(detail.segments.count - 1)) } label: {
                                    Label("從這句到結尾複製為 Prompt", systemImage: "text.append")
                                }
                                Button { UIPasteboard.general.string = showRaw ? seg.textRaw : (seg.textClean ?? seg.textRaw) } label: {
                                    Label("複製文字", systemImage: "doc.on.clipboard")
                                }
                            }
                    }
                }
            }
            .listStyle(.plain)
            .onChange(of: activeId) { _, id in
                guard let id, player?.isPlaying == true else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var notice: some View {
        let r = detail.recording
        return Label(r.status == "error" ? "處理失敗：\(r.error ?? "")" : "處理中：\(Status.label(r.status))…（完成後會自動更新）",
                     systemImage: r.status == "error" ? "exclamationmark.triangle" : "hourglass")
            .foregroundStyle(r.status == "error" ? .red : .orange)
    }

    private func speaker(_ id: Int?) -> Speaker? { id.flatMap { sid in detail.speakers.first { $0.id == sid } } }

    /// The segment playing now: the last one starting at or before the playhead.
    private var activeId: Int? {
        guard let t = player?.time, t > 0 else { return nil }
        let ms = Int(t * 1000)
        return detail.segments.last { $0.startMs <= ms }?.id
    }

    private func seek(_ seg: Segment) { player?.seek(Double(seg.startMs) / 1000, play: true) }
}

/// Talk share per speaker, 「自動」 tags and 「可能是 X？」 suggestions (✓ confirm / ✕ dismiss), like the web legend.
struct SpeakerLegend: View {
    let detail: Detail
    let onDetail: (Detail) -> Void
    @Environment(AppModel.self) private var app
    @State private var deciding = false

    var body: some View {
        let share = shares
        let total = max(1, share.reduce(0) { $0 + $1.ms })
        VStack(alignment: .leading, spacing: 8) {
            ForEach(share, id: \.id) { item in
                let sp = item.id.flatMap { sid in detail.speakers.first { $0.id == sid } }
                HStack(spacing: 6) {
                    Circle().fill(SpeakerColor.of(item.id)).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(sp?.displayName ?? "未知講者").bold()
                    if sp?.auto == 1 { Badge(text: "自動") }
                    Text("\(Int((Double(item.ms) / Double(total) * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    if let sp, let sug = sp.suggest {
                        Text("可能是 \(sug.name)？").font(.callout).foregroundStyle(.orange)
                        Button { decide(sp, name: sug.name) } label: { Image(systemName: "checkmark.circle.fill") }
                            .accessibilityLabel("確認是 \(sug.name)")
                        Button { decide(sp, name: sp.displayName) } label: { Image(systemName: "xmark.circle") }
                            .accessibilityLabel("不是")
                    }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
                .disabled(deciding)
            }
        }
    }

    private var shares: [(id: Int?, ms: Int)] {
        var out: [(id: Int?, ms: Int)] = []
        for s in detail.segments {
            if let i = out.firstIndex(where: { $0.id == s.speakerId }) { out[i].ms += s.endMs - s.startMs }
            else { out.append((s.speakerId, s.endMs - s.startMs)) }
        }
        return out.sorted { $0.ms > $1.ms }
    }

    /// ✓ names the speaker X; ✕ re-saves its default name (= dismiss). Same endpoint as the web.
    private func decide(_ sp: Speaker, name: String) {
        guard let seg = detail.segments.first(where: { $0.speakerId == sp.id }) else { return }
        deciding = true
        Task {
            defer { deciding = false }
            if let d: Detail = try? await app.json("POST", "api/segments/\(seg.id)/speaker", ["name": name, "scope": "all"]) { onDetail(d) }
        }
    }
}

enum SpeakerColor {
    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
    static func of(_ id: Int?) -> Color { id.map { palette[$0 % palette.count] } ?? .gray }
}

struct SegmentRow: View {
    let index: Int
    let segment: Segment
    let speaker: Speaker?
    let showRaw: Bool
    let active: Bool
    let onSeek: () -> Void
    let onRename: () -> Void

    var body: some View {
        let name = speaker?.displayName ?? "未知講者"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: onSeek) { Text(Prompt.fmtDur(Double(segment.startMs) / 1000)).monospacedDigit() }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("從 \(Prompt.fmtDur(Double(segment.startMs) / 1000)) 播放")
                Button(action: onRename) {
                    HStack(spacing: 4) {
                        Text(name).bold().foregroundStyle(SpeakerColor.of(segment.speakerId))
                        if speaker?.auto == 1 { Badge(text: "自動") }
                    }
                }
                .accessibilityLabel("講者：\(name)\(speaker?.auto == 1 ? "（依聲紋自動辨識）" : "")，點擊重新命名")
                .accessibilityIdentifier("segment.\(index).speaker")
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            Text(showRaw ? segment.textRaw : (segment.textClean ?? segment.textRaw))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: onSeek)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("從這句開始播放")
                .accessibilityIdentifier("segment.\(index).text")
        }
        .padding(.vertical, 4)
        .listRowBackground(active ? Color.accentColor.opacity(0.15) : nil)
    }
}

// MARK: - Speaker rename

struct SpeakerSheet: View {
    let segment: Segment
    let name: String
    let onDone: (Detail) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scope = "all"
    @State private var people: [String] = []
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField("講者名稱", text: $text).accessibilityIdentifier("rename.name").focused($focused).submitLabel(.done).onSubmit(save)
                }
                Section("套用到") {
                    Picker("套用到", selection: $scope) {
                        Text("所有段落").tag("all")
                        Text("只有這段").tag("segment")
                    }
                    .pickerStyle(.segmented)
                    .disabled(segment.speakerId == nil)
                }
                Section("最近使用") {
                    if people.isEmpty { Text("尚無紀錄").foregroundStyle(.secondary) }
                    ForEach(people, id: \.self) { n in
                        Button(n) { text = n }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("重新命名講者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存", action: save).accessibilityIdentifier("rename.save").disabled(saving || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                text = name == "未知講者" ? "" : name
                if segment.speakerId == nil { scope = "segment" }
                focused = true
            }
            .task { people = (try? await app.get("api/people")) ?? [] }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let n = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let d: Detail = try await app.json("POST", "api/segments/\(segment.id)/speaker", ["name": n, "scope": scope])
                onDone(d)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Player bar

struct PlayerBar: View {
    @Bindable var player: Player
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { scrub ?? player.time }, set: { scrub = $0 }), in: 0...max(1, player.duration)) { editing in
                if !editing, let s = scrub { player.seek(s); scrub = nil }
            }
            .accessibilityLabel("播放位置")
            .accessibilityIdentifier("player.slider")
            .accessibilityValue(Prompt.fmtDur(player.time))
            HStack {
                Text(Prompt.fmtDur(scrub ?? player.time)).monospacedDigit().accessibilityIdentifier("player.time")
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("倒退 15 秒")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
                }
                .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
                .accessibilityIdentifier("player.toggle")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("快轉 15 秒")
                Spacer()
                Menu {
                    Picker("速度", selection: $player.rate) {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }
                } label: {
                    Text("\(player.rate.formatted())×").monospacedDigit()
                }
                .accessibilityLabel("播放速度")
                Text(Prompt.fmtDur(player.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Summaries

struct SummariesView: View {
    let detail: Detail
    let meta: Templates?
    let onChange: () -> Void

    @Environment(AppModel.self) private var app
    @State private var template = "meeting"
    @State private var language = "zh-TW"
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            Section("產生新摘要") {
                if let meta {
                    Picker("範本", selection: $template) {
                        ForEach(meta.templates, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("語言", selection: $language) {
                        ForEach(meta.languages, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                Button("產生摘要", action: generate).disabled(working || detail.recording.status != "done")
                if let error { Text(error).foregroundStyle(.red) }
            }
            if detail.summaries.isEmpty {
                Text("還沒有摘要。").foregroundStyle(.secondary)
            }
            ForEach(detail.summaries) { s in
                Section {
                    switch s.status {
                    case "done": MarkdownView(markdown: s.contentMd ?? "")
                    case "error": Text("錯誤：\(s.error ?? "")").foregroundStyle(.red)
                    default: Label(Status.label(s.status) + "…", systemImage: "hourglass").foregroundStyle(.orange)
                    }
                } header: {
                    HStack {
                        Text(templateName(s.templateId) + " · " + languageName(s.language))
                        Spacer()
                        if s.status == "done", let md = s.contentMd {
                            Button { UIPasteboard.general.string = md } label: { Image(systemName: "doc.on.doc") }
                                .accessibilityLabel("複製摘要")
                        }
                    }
                }
            }
        }
        .onAppear { if let first = meta?.templates.first, !(meta?.templates.contains { $0.id == template } ?? false) { template = first.id } }
    }

    private func templateName(_ id: String) -> String { meta?.templates.first { $0.id == id }?.name ?? id }
    private func languageName(_ id: String) -> String { meta?.languages.first { $0.id == id }?.name ?? id }

    private func generate() {
        working = true
        Task {
            defer { working = false }
            do {
                let _: Summary = try await app.json("POST", "api/recordings/\(detail.recording.id)/summaries",
                                                    ["template_id": template, "language": language])
                error = nil
                onChange()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Line-based Markdown: headings, bullets and paragraphs as blocks; inline styles via AttributedString.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                block(line)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        if trimmed.isEmpty {
            EmptyView()
        } else if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
            inline(String(trimmed.dropFirst(hashes + 1)))
                .font(hashes <= 1 ? .title2.bold() : hashes == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        } else if let marker = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
            let indent = CGFloat(line.prefix { $0 == " " }.count / 2) * 16
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(String(trimmed.dropFirst(marker.count)))
            }
            .padding(.leading, indent)
        } else {
            inline(trimmed)
        }
    }

    private func inline(_ s: String) -> Text {
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(a)
    }
}

// MARK: - Copy as prompt options

struct PromptOptionsSheet: View {
    let detail: Detail
    let templates: [Named]
    let origin: String
    let onShare: (ShareItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var o = PromptOptions.load()
    @State private var copied = false

    var body: some View {
        let text = Prompt.build(detail, o, origin: origin, templates: templates)
        let est = Prompt.estimate(text)
        NavigationStack {
            Form {
                Section {
                    Toggle("包含摘要", isOn: $o.summary)
                    Toggle("包含逐字稿", isOn: $o.transcript)
                    Toggle("時間戳", isOn: $o.ts)
                    Toggle("使用原始辨識文字（未整理）", isOn: $o.raw)
                    Picker("開頭指示語", selection: $o.intro) {
                        ForEach(Prompt.intros, id: \.key) { Text($0.label).tag($0.key) }
                    }
                    if o.intro == "custom" {
                        TextField("例如：請用三點整理重點，並列出我需要追蹤的事。", text: $o.custom, axis: .vertical)
                            .lineLimit(2...6)
                            .accessibilityLabel("自訂指示語")
                    }
                } footer: {
                    Text(Prompt.estimateText(est)).foregroundStyle(est.warn ? .orange : .secondary)
                }
                Section {
                    Button(copied ? "已複製為 Prompt" : "複製為 Prompt") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                    Button("分享 Prompt…") { dismiss(); onShare(ShareItem(items: [text])) }
                    Button("分享 .md 檔…") { dismiss(); onShare(.file(text, title: detail.recording.title)) }
                }
                Section("預覽") {
                    Text(text).accessibilityIdentifier("prompt.preview").font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("複製為 Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: o) { _, new in new.save(); copied = false }
        }
    }
}

// MARK: - Share sheet

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]

    /// Writes the prompt to a temporary "<title>.md" and shares the file.
    static func file(_ text: String, title: String) -> ShareItem {
        let url = URL.temporaryDirectory.appending(path: Prompt.fileName(title))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return ShareItem(items: [url])
        } catch {
            return ShareItem(items: [text])
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
