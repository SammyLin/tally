import SwiftUI
import UIKit

struct DetailView: View {
    let id: Int
    /// Opened from an Ask citation: play from here once the player exists (web: S.seek).
    var seekMs: Int? = nil
    /// Opened on the 摘要 tab (tally://rec/<id>/summary, web: #/…/rec/<id>/summary).
    var summary = false

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var detail: Detail?
    @State private var folders: [Folder] = []
    @State private var notFound = false
    @State private var showRetranscribe = false
    @State private var showMove = false
    @State private var confirmPurge = false
    @State private var editing: Segment?
    @State private var meta: Templates?
    @State private var player: Player?
    @State private var tab: Int
    @State private var showRaw = false
    @State private var error: String?
    @State private var renaming: Segment?
    @State private var showPromptOptions = false
    @State private var share: ShareItem?
    @State private var sought = false

    init(id: Int, seekMs: Int? = nil, summary: Bool = false) {
        self.id = id
        self.seekMs = seekMs
        self.summary = summary
        _tab = State(initialValue: summary && seekMs == nil ? 1 : 0)
    }

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if notFound {
                ContentUnavailableView {
                    Label("找不到這筆錄音。", systemImage: "questionmark.folder")
                } actions: {
                    Button("回到清單") { dismiss() }
                }
            } else if let error {
                ContentUnavailableView {
                    Label("無法載入", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重試") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.paper))
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
        .sheet(item: $editing) { seg in
            SegmentEditSheet(segment: seg, text: showRaw ? seg.textRaw : (seg.textClean ?? seg.textRaw)) { saved in
                if let i = detail?.segments.firstIndex(where: { $0.id == saved.id }) { detail?.segments[i] = saved }
                showRaw = false
                app.toast = "已儲存"
            }
        }
        .sheet(isPresented: $showRetranscribe) {
            if let r = detail?.recording {
                LanguageSheet(title: "重新轉錄", note: "會覆蓋目前的逐字稿與講者名稱。", okLabel: "重新轉錄",
                              initial: r.language ?? app.sttLang) { lang in Task { await retranscribe(lang) } }
            }
        }
        .sheet(isPresented: $showMove) {
            if let r = detail?.recording {
                FolderPicker(title: "移動「\(r.title)」到", rootLabel: "未分類", folders: folders, current: r.folderId) { fid in
                    Task { await move(to: fid) }
                }
            }
        }
        .alert("永久刪除「\(detail?.recording.title ?? "")」？此動作無法復原。", isPresented: $confirmPurge) {
            Button("永久刪除", role: .destructive) { Task { await purge() } }
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
            notFound = false
            if meta == nil { meta = try? await app.get("api/templates") }
            if let fs: [Folder] = try? await app.get("api/folders") { folders = fs }
            // play.m4a is uploaded mid-pipeline: the player shows as soon as it exists (web: play_key)
            if player == nil, d.recording.playKey != nil || d.recording.status == "done", let b = app.backend {
                player = Player(url: b.base.appending(path: "media/\(id)"), backend: b, fallbackDuration: d.recording.durationS,
                                freshHeaders: app.mediaHeaders)
            }
            if let ms = seekMs, !sought, let player {
                sought = true
                tab = 0
                player.seek(Double(ms) / 1000, play: true)
            }
            error = nil
        } catch is CancellationError {
        } catch APIError.http(404, _) {
            detail = nil
            notFound = true
        } catch {
            if detail == nil { self.error = error.localizedDescription }
        }
    }

    // MARK: Recording actions (web: the detail ⋯ menu)

    private func rename(_ title: String) async {
        do {
            let r: Recording = try await app.json("PATCH", "api/recordings/\(id)", ["title": title])
            detail?.recording.title = r.title
        } catch { app.fail(error) }
    }

    private func retranscribe(_ language: String) async {
        do {
            let _: Recording = try await app.json("POST", "api/recordings/\(id)/retranscribe", ["language": language])
            app.toast = "已排入重新轉錄"
            tab = 0
            await load()
        } catch { app.fail(error) }
    }

    private func move(to folder: Int?) async {
        guard folder != detail?.recording.folderId else { return }
        do {
            let _: Recording = try await app.json("PATCH", "api/recordings/\(id)", ["folder_id": folder])
            detail?.recording.folderId = folder
            app.toast = "已移到「\(folder.flatMap { f in folders.first { $0.id == f }?.name } ?? "未分類")」"
        } catch { app.fail(error) }
    }

    private func trash() async {
        do {
            let _: Ignored = try await app.json("DELETE", "api/recordings/\(id)")
            app.toast = "已移到垃圾桶"
            dismiss()
        } catch { app.fail(error) }
    }

    private func restore() async {
        do {
            let _: Recording = try await app.json("POST", "api/recordings/\(id)/restore")
            app.toast = "已還原"
            await load()
        } catch { app.fail(error) }
    }

    private func purge() async {
        do {
            let _: Ignored = try await app.json("DELETE", "api/recordings/\(id)", query: [URLQueryItem(name: "purge", value: "1")])
            app.toast = "已永久刪除"
            dismiss()
        } catch { app.fail(error) }
    }

    private func name(_ speakerId: Int?, in d: Detail) -> String {
        speakerId.flatMap { sid in d.speakers.first { $0.id == sid }?.displayName } ?? "未知講者"
    }

    @ViewBuilder private func content(_ d: Detail) -> some View {
        // while processing only the transcript tab exists (web)
        let ready = d.recording.status == "done"
        VStack(spacing: 0) {
            DetailHeader(recording: d.recording, folderPath: FolderTree.path(d.recording.folderId, in: folders)) { t in
                Task { await rename(t) }
            }
            if ready {
                Picker("檢視", selection: $tab) {
                    Text("逐字稿").tag(0)
                    Text("摘要").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            if tab == 0 || !ready {
                TranscriptView(detail: d, player: player, showRaw: showRaw, onRename: { renaming = $0 }, onDetail: { detail = $0 },
                               onPrompt: { copyPrompt(range: $0) }, onEdit: { editing = $0 })
            } else {
                SummariesView(detail: d, meta: meta, onChange: { Task { await load() } })
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let player { PlayerBar(player: player, segments: d.segments) }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let r = detail?.recording {
                    if r.deletedAt != nil {
                        Button { Task { await restore() } } label: { Label("還原", systemImage: "arrow.uturn.backward") }
                        Button(role: .destructive) { confirmPurge = true } label: { Label("永久刪除", systemImage: "trash.slash") }
                    } else {
                        // actions follow the recording's state: while it is processing only filing/trash make sense
                        if r.status == "done" {
                            Button { copyPrompt() } label: { Label("複製為 Prompt", systemImage: "doc.on.doc") }
                            Button { sharePrompt(asFile: false) } label: { Label("分享 Prompt…", systemImage: "square.and.arrow.up") }
                            Button { sharePrompt(asFile: true) } label: { Label("分享 .md 檔…", systemImage: "doc.richtext") }
                            Button { showPromptOptions = true } label: { Label("Prompt 選項與預覽…", systemImage: "slider.horizontal.3") }
                            Divider()
                        }
                        if !Status.busy(r.status) {
                            Button { showRetranscribe = true } label: { Label("重新轉錄", systemImage: "waveform.badge.magnifyingglass") }
                        }
                        Button { showMove = true } label: { Label("移到資料夾…", systemImage: "folder") }
                        Button(role: .destructive) { Task { await trash() } } label: { Label("移到垃圾桶", systemImage: "trash") }
                    }
                    Button {
                        UIPasteboard.general.string = DeepLink.recording(r.id, summary: tab == 1)
                        app.toast = "已複製連結"
                    } label: { Label("複製連結", systemImage: "link") }
                    if detail?.segments.contains(where: { $0.textClean != nil }) == true {
                        Divider()
                        Toggle("檢視原始逐字稿", isOn: $showRaw)
                    }
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
        withAnimation { app.toast = "已複製為 Prompt（\(Prompt.estimateText(Prompt.estimate(t)).components(separatedBy: "　")[0])）" }
    }

    private func sharePrompt(asFile: Bool) {
        guard let t = promptText(), let detail else { return }
        share = asFile ? ShareItem.file(t, title: detail.recording.title) : ShareItem(items: [t])
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @Environment(AppModel.self) private var app
    let detail: Detail
    let player: Player?
    let showRaw: Bool
    let onRename: (Segment) -> Void
    let onDetail: (Detail) -> Void
    let onPrompt: (ClosedRange<Int>) -> Void
    let onEdit: (Segment) -> Void

    /// Range selection (web: select text → 「複製這段為 Prompt」): long-press starts it, tapping another line moves its end.
    @State private var anchor: Int?
    @State private var end: Int?
    private var selected: ClosedRange<Int>? { anchor.map { a in min(a, end ?? a)...max(a, end ?? a) } }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Group {
                    if Status.busy(detail.recording.status) || detail.recording.status == "error" {
                        Section { notice }
                    }
                    if detail.segments.isEmpty {
                        Text(Status.busy(detail.recording.status) ? "逐字稿產生中…" : "沒有逐字稿內容。")
                            .foregroundStyle(Color(.inkMuted)).accessibilityIdentifier("transcript.empty")
                    }
                    if !detail.segments.isEmpty {
                        Section { SpeakerLegend(detail: detail, onDetail: onDetail) }
                    }
                    Section {
                        ForEach(Array(detail.segments.enumerated()), id: \.element.id) { i, seg in
                            SegmentRow(index: i, segment: seg, speaker: speaker(seg.speakerId), showRaw: showRaw,
                                       active: seg.id == activeId, selected: selected?.contains(i) == true,
                                       onSeek: { if anchor != nil { end = i } else { seek(seg) } }, onRename: { onRename(seg) })
                                .id(seg.id)
                                .contextMenu {
                                    Button { anchor = i; end = i } label: { Label("從這句開始選取", systemImage: "text.badge.plus") }
                                    Button { onEdit(seg) } label: { Label("編輯文字", systemImage: "pencil") }
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
                .kirokuRows()
            }
            .kirokuList()
            .listStyle(.plain)
            .safeAreaInset(edge: .bottom) { if let selected { selectionBar(selected) } }
            .onChange(of: detail.segments.count) { anchor = nil; end = nil }
            .onChange(of: activeId) { _, id in
                guard let id, player?.isPlaying == true else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func selectionBar(_ r: ClosedRange<Int>) -> some View {
        let segs = detail.segments
        let span = segs.indices.contains(r.upperBound)
            ? Prompt.fmtDur(Double(segs[r.lowerBound].startMs) / 1000) + "–" + Prompt.fmtDur(Double(segs[r.upperBound].endMs) / 1000) : ""
        return VStack(alignment: .leading, spacing: 6) {
            Text("已選 \(r.count) 句（\(span)）· 點其他句子調整範圍").font(.caption).foregroundStyle(Color(.inkMuted))
                .accessibilityIdentifier("selection.info")
            HStack {
                Button("取消") { anchor = nil; end = nil }.accessibilityIdentifier("selection.cancel")
                Spacer()
                Button { onPrompt(r); anchor = nil; end = nil } label: { Label("複製這段為 Prompt", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("selection.copy")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var notice: some View {
        let r = detail.recording
        let text = r.status == "error" ? "處理失敗：\(r.error ?? "未知錯誤")"
            : r.status == "queued" && r.note != nil ? "排隊中：\(r.note!)\(r.notBefore.map { "，預計 " + Prompt.fmtDate($0) + " 後繼續" } ?? "")。"
            : r.status == "queued" && app.noRunner ? "排隊中。" + AppModel.noRunnerText
            : "處理中：\(Status.label(r.status))…（完成後會自動更新）"
        return Label(text,
                     systemImage: r.status == "error" ? "exclamationmark.triangle" : "hourglass")
            .foregroundStyle(r.status == "error" ? Color(.danger) : Color(.warn))
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
                    if sp?.isMe(app.settings.me) == true { Text("（我）").foregroundStyle(Color(.inkMuted)) }
                    if sp?.auto == 1 { Badge(text: "自動") }
                    Text("\(Int((Double(item.ms) / Double(total) * 100).rounded()))%").monospacedDigit().foregroundStyle(Color(.inkMuted))
                    if let sp, let sug = sp.suggest {
                        Text("可能是 \(sug.name)？").font(.callout).foregroundStyle(Color(.warn))
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
            do {
                let d: Detail = try await app.json("POST", "api/segments/\(seg.id)/speaker", ["name": name, "scope": "all"])
                onDetail(d)
            } catch { app.fail(error) }
        }
    }
}

enum SpeakerColor {
    static let palette: [Color] = [.speaker1, .speaker2, .speaker3, .speaker4, .speaker5, .speaker6, .speaker7, .speaker8]
    static func of(_ id: Int?) -> Color { id.map { palette[$0 % palette.count] } ?? .gray }
}

struct SegmentRow: View {
    @Environment(AppModel.self) private var app
    let index: Int
    let segment: Segment
    let speaker: Speaker?
    let showRaw: Bool
    let active: Bool
    var selected = false
    let onSeek: () -> Void
    let onRename: () -> Void

    var body: some View {
        let name = speaker?.displayName ?? "未知講者"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: onSeek) { Text(Prompt.fmtDur(Double(segment.startMs) / 1000)).monospacedDigit() }
                    .foregroundStyle(Color(.inkMuted))
                    .accessibilityLabel("從 \(Prompt.fmtDur(Double(segment.startMs) / 1000)) 播放")
                Button(action: onRename) {
                    HStack(spacing: 4) {
                        Text(name).bold().foregroundStyle(SpeakerColor.of(segment.speakerId))
                        if speaker?.isMe(app.settings.me) == true { Text("（我）").foregroundStyle(Color(.inkMuted)) }
                        if speaker?.auto == 1 { Badge(text: "自動") }
                    }
                }
                .accessibilityLabel("講者：\(name)\(speaker?.isMe(app.settings.me) == true ? "（我）" : "")\(speaker?.auto == 1 ? "（依聲紋自動辨識）" : "")，點擊重新命名")
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
        .listRowBackground(selected ? Color.accentColor.opacity(0.25) : active ? Color(.selection) : Color(.surface))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                Group {
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
                        if people.isEmpty { Text("尚無紀錄").foregroundStyle(Color(.inkMuted)) }
                        ForEach(people, id: \.self) { n in
                            Button(n) { text = n }
                        }
                    }
                    if let error { Section { Text(error).foregroundStyle(Color(.danger)) } }
                }
                .kirokuRows()
            }
            .kirokuList()
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
    var segments: [Segment] = []
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 6) {
            if !segments.isEmpty {
                SpeakerBands(segments: segments, duration: player.duration, time: scrub ?? player.time)
                    .padding(.horizontal, 2)
            }
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
                        ForEach([Float(0.75), 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }
                } label: {
                    Text("\(player.rate.formatted())×").monospacedDigit()
                }
                .accessibilityLabel("播放速度")
                Text(Prompt.fmtDur(player.duration)).monospacedDigit().foregroundStyle(Color(.inkMuted))
            }
            .font(.callout)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Speaker turns along the timeline (web: .bands): faint ahead of the playhead, solid behind it.
struct SpeakerBands: View {
    let segments: [Segment]
    let duration: Double
    let time: Double

    var body: some View {
        Canvas { ctx, size in
            let d = duration > 0 ? duration : Double(segments.last?.endMs ?? 0) / 1000
            guard d > 0 else { return }
            let x = { (ms: Int) in CGFloat(Double(ms) / 1000 / d) * size.width }
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.secondary.opacity(0.12)))
            for (played, opacity) in [(false, 0.28), (true, 1.0)] {
                var c = ctx
                if played { c.clip(to: Path(CGRect(x: 0, y: 0, width: CGFloat(min(1, time / d)) * size.width, height: size.height))) }
                for s in segments {
                    let rect = CGRect(x: x(s.startMs), y: 0, width: max(size.width * 0.0015, x(s.endMs) - x(s.startMs)), height: size.height)
                    c.fill(Path(rect), with: .color(SpeakerColor.of(s.speakerId).opacity(opacity)))
                }
            }
        }
        .frame(height: 6)
        .clipShape(.rect(cornerRadius: 3))
        .accessibilityHidden(true)
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
    @State private var deleting: Summary?

    var body: some View {
        List {
            Group {
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
                    if let error { Text(error).foregroundStyle(Color(.danger)) }
                }
                if detail.summaries.isEmpty {
                    Text("還沒有摘要。").foregroundStyle(Color(.inkMuted))
                }
                ForEach(detail.summaries.sorted { $0.id > $1.id }) { s in
                    Section {
                        switch s.status {
                        case "done": MarkdownView(markdown: s.contentMd ?? "")
                        case "error": Text("錯誤：\(s.error ?? "")").foregroundStyle(Color(.danger))
                        default: Label(s.status == "queued" ? app.queuedText : "產生中，請稍候…", systemImage: "hourglass").foregroundStyle(Color(.warn))
                        }
                    } header: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(templateName(s.templateId) + " · " + languageName(s.language))
                                    if s.status != "done" { Badge(text: Status.label(s.status), busy: s.status != "error", error: s.status == "error") }
                                }
                                if let c = s.createdAt { Text(Prompt.fmtDate(c)).font(.caption2).accessibilityIdentifier("summary.\(s.id).date") }
                            }
                            Spacer()
                            if s.status == "done", let md = s.contentMd {
                                Button { UIPasteboard.general.string = md } label: { Image(systemName: "doc.on.doc") }
                                    .accessibilityLabel("複製摘要")
                            }
                            Button { deleting = s } label: { Image(systemName: "trash") }
                                .accessibilityLabel("刪除摘要")
                                .accessibilityIdentifier("summary.\(s.id).delete")
                        }
                    }
                }
            }
            .kirokuRows()
        }
        .kirokuList()
        .buttonStyle(.borderless)
        .alert("刪除這份摘要？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { s in
            Button("刪除", role: .destructive) { Task { await delete(s) } }
        }
        .onAppear { language = app.settings.summaryLang } // web: sumLang()
        .onAppear { if let first = meta?.templates.first, !(meta?.templates.contains { $0.id == template } ?? false) { template = first.id } }
    }

    private func templateName(_ id: String) -> String { meta?.templates.first { $0.id == id }?.name ?? id }
    private func languageName(_ id: String) -> String { meta?.languages.first { $0.id == id }?.name ?? id }

    private func delete(_ s: Summary) async {
        do {
            let _: Ignored = try await app.json("DELETE", "api/summaries/\(s.id)")
            onChange()
        } catch { app.fail(error) }
    }

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
                Group {
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
                        Text(Prompt.estimateText(est)).foregroundStyle(est.warn ? AnyShapeStyle(Color(.warn)) : AnyShapeStyle(Color(.inkMuted)))
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
                .kirokuRows()
            }
            .kirokuList()
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

// MARK: - Header: folder path + title (tap to rename, like the web's d-title)

struct DetailHeader: View {
    let recording: Recording
    let folderPath: String
    let onRename: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(folderPath, systemImage: "folder")
                .font(.caption).foregroundStyle(Color(.inkMuted))
                .accessibilityIdentifier("detail.folder")
            if editing {
                TextField("標題", text: $text)
                    .font(.title3.bold())
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { finish() }
                    .onChange(of: focused) { _, f in if !f { finish() } } // leaving the field saves, like the web's blur
                    .onAppear { focused = true }
                    .accessibilityIdentifier("detail.titleField")
            } else {
                Button { text = recording.title; editing = true } label: {
                    Text(recording.title).font(.title3.bold()).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("點擊重新命名")
                .accessibilityIdentifier("detail.title")
            }
            if recording.deletedAt != nil {
                Label("這筆錄音在垃圾桶中。", systemImage: "trash").font(.callout).foregroundStyle(Color(.warn))
                    .accessibilityIdentifier("detail.trashed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// An empty or unchanged title is ignored.
    private func finish() {
        guard editing else { return }
        editing = false
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty, v != recording.title { onRename(v) }
    }
}

// MARK: - Segment text edit (saved as the cleaned text, like the web)

struct SegmentEditSheet: View {
    let segment: Segment
    let onSaved: (Segment) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var confirmDiscard = false
    @FocusState private var focused: Bool
    private let original: String

    init(segment: Segment, text: String, onSaved: @escaping (Segment) -> Void) {
        self.segment = segment
        self.onSaved = onSaved
        original = text
        _text = State(initialValue: text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    TextField("逐字稿文字", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                        .focused($focused)
                        .accessibilityIdentifier("segment.edit.text")
                }
                .kirokuRows()
            }
            .kirokuList()
            .navigationTitle("編輯文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if text != original { confirmDiscard = true } else { dismiss() } }
                        .accessibilityIdentifier("segment.edit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { Task { await save() } }.disabled(saving).accessibilityIdentifier("segment.edit.save")
                }
            }
            .alert("有未儲存的變更", isPresented: $confirmDiscard) {
                Button("放棄", role: .destructive) { dismiss() }
                Button("繼續編輯", role: .cancel) {}
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(text != original)
        .presentationDetents([.medium, .large])
    }

    /// Empty or unchanged text is ignored.
    private func save() async {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v != original else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            let seg: Segment = try await app.json("PATCH", "api/segments/\(segment.id)", ["text": v])
            onSaved(seg)
            dismiss()
        } catch { app.fail(error) }
    }
}
