import SwiftUI
import UniformTypeIdentifiers

/// 最近 / 全部 / 未分類 / a folder / 垃圾桶, with search, pull to refresh and polling while processing.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var scope = Scope.saved()
    @State private var query = ""
    @State private var recordings: [Recording] = []
    @State private var folders: [Folder] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var showRecord = false
    @State private var showSettings = false
    @State private var showRunners = false
    @State private var showImporter = false
    @State private var showFolders = false
    @State private var showAsk = false
    @State private var pendingImport: [URL] = []
    @State private var path: [RecRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    if let runners = app.runners {
                        Button { showRunners = true } label: { RunnerStatusRow(runners: runners) }
                            .accessibilityIdentifier("library.runners")
                    }
                    UploadsSection()
                    if let error {
                        Section {
                            Label(recordings.isEmpty ? "無法載入清單：\(error)" : error, systemImage: "exclamationmark.triangle").foregroundStyle(Color(.danger))
                            if recordings.isEmpty { Button("重試") { Task { await load() } } }
                        }
                    }
                    Section {
                        ForEach(recordings) { r in
                            NavigationLink(value: RecRoute(id: r.id)) {
                                // inside a folder view the folder is implied
                                RecordingRow(recording: r, folder: folderID == nil ? r.folderId.flatMap { fid in folders.first { $0.id == fid }?.name } : nil)
                            }
                            .accessibilityIdentifier("recording.\(r.id)")
                        }
                    } header: {
                        if !recordings.isEmpty { Text("\(recordings.count) 筆").accessibilityIdentifier("library.count") }
                    } footer: {
                        if loaded && recordings.isEmpty && error == nil { Text(emptyText).accessibilityIdentifier("library.empty") }
                    }
                }
                .kirokuRows()
            }
            .kirokuList()
            .navigationTitle(title)
            .navigationDestination(for: RecRoute.self) { DetailView(id: $0.id, seekMs: $0.ms, summary: $0.summary).id($0) } // a link may replace the open one
            .searchable(text: $query, prompt: "搜尋標題或逐字稿")
            .refreshable { await load() }
            .task { await app.loadSettings() }
            .task {
                while !Task.isCancelled { // header runner status (web: every 15 s)
                    await app.loadRunners()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .onAppear(perform: openLink)
            .onChange(of: app.link) { openLink() }
            .onChange(of: showRecord) { openLink() }
            .onChange(of: showSettings) { openLink() }
            .task(id: LoadKey(scope: scope, query: query)) {
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) } // debounce typing (web: 250 ms)
                while !Task.isCancelled {
                    await load()
                    // poll while anything is still being processed (web: every 3 s)
                    try? await Task.sleep(for: .seconds(recordings.contains { Status.busy($0.status) } ? 3 : 30))
                }
            }
            .toolbar { toolbar }
            .onChange(of: scope) { _, s in s.save() }
            .onChange(of: path) { _, p in if p.isEmpty { Task { await load() } } } // back from a detail that may have moved/trashed it
            #if DEBUG
            .onAppear { // screenshots / smoke tests: `-open <recording id>`
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-open"), i + 1 < args.count, let id = Int(args[i + 1]), path.isEmpty { path = [RecRoute(id: id)] }
            }
            #endif
            .safeAreaInset(edge: .bottom) { recordButton }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie, .audiovisualContent],
                          allowsMultipleSelection: true) { result in
                importFiles(result)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showFolders) { FoldersSheet(scope: $scope, folders: folders) { await load() } }
            .sheet(isPresented: Binding(get: { !pendingImport.isEmpty }, set: { if !$0 { pendingImport = [] } })) {
                LanguageSheet(title: pendingImport.count > 1 ? "匯入 \(pendingImport.count) 個檔案" : "匯入「\(pendingImport.first?.lastPathComponent ?? "")」",
                              okLabel: "開始上傳", initial: app.sttLang) { [urls = pendingImport] lang in startImport(urls, language: lang) }
            }
            .sheet(isPresented: $showRunners) { RunnersView() }
            .sheet(isPresented: $showAsk) { AskView() }
            .fullScreenCover(isPresented: $showRecord, onDismiss: { Task { await load() } }) {
                RecordView(folders: folders, defaultFolder: folderID, defaultLanguage: app.sttLang)
            }
            .fullScreenCover(isPresented: loginBinding) {
                if let url = app.baseURL {
                    LoginView(url: url) { jwt in app.loggedIn(token: jwt, for: url) } onCancel: {
                        Task { await app.changeBackend() }
                    }
                }
            }
        }
    }

    private struct LoadKey: Hashable { var scope: Scope; var query: String }

    /// Don't cover an ongoing recording with the login screen; it shows once the recorder closes.
    private var loginBinding: Binding<Bool> {
        Binding(get: { app.needsLogin && !showRecord }, set: { _ in })
    }

    /// tally:// links (web: route()). Never interrupts a recording or unsaved settings: those wait until closed.
    private func openLink() {
        guard let link = app.link, !showRecord, !showSettings else { return }
        switch link {
        case .ask:
            showFolders = false; showRunners = false
            if !showAsk { showAsk = true } // AskView consumes the link (also when it is already open)
        case .open(let s, let rec, let summary, let ms):
            app.link = nil
            showAsk = false; showFolders = false; showRunners = false
            if case .folder(let id) = s, loaded, !folders.contains(where: { $0.id == id }) {
                app.toast = "找不到這個資料夾"
                scope = .all
            } else if let s {
                scope = s
            }
            path = rec.map { [RecRoute(id: $0, summary: summary, ms: ms)] } ?? []
        }
    }

    private var folderID: Int? { if case .folder(let id) = scope { id } else { nil } }

    private var title: String {
        switch scope {
        case .recent: "最近"
        case .all: "全部"
        case .unfiled: "未分類"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "資料夾"
        case .trash: "垃圾桶"
        }
    }

    private var emptyText: String {
        if scope == .trash { return "垃圾桶是空的" }
        if !query.isEmpty { return "找不到符合的錄音" }
        if scope == .unfiled || folderID != nil { return "這裡沒有錄音" }
        return "還沒有錄音。按下方的錄音鍵開始，或從「檔案」匯入。"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) { KirokuMark(height: 18) }
        ToolbarItem(placement: .topBarLeading) {
            Button { showFolders = true } label: { Label("資料夾", systemImage: "sidebar.left") }
                .accessibilityIdentifier("library.folders")
        }
        ToolbarItem(placement: .topBarLeading) {
            Button { showAsk = true } label: { Label("問問看", systemImage: "bubble.left.and.text.bubble.right") }
                .accessibilityIdentifier("library.ask")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showImporter = true } label: { Label("從檔案匯入", systemImage: "square.and.arrow.down") }
            Button { showSettings = true } label: { Label("設定", systemImage: "gearshape") }
        }
    }

    private var recordButton: some View {
        Button { showRecord = true } label: {
            Image(systemName: "mic.fill")
                .font(.title.weight(.semibold))
                .foregroundStyle(Color(.onAccent)) // white on light Rec, navy on dark Rec
                .frame(width: 72, height: 72)
                .background(Color(.rec), in: .circle)
                .shadow(radius: 4, y: 2)
        }
        .accessibilityLabel("開始錄音")
        .accessibilityIdentifier("library.record")
        .padding(.bottom, 8)
    }

    private func load() async {
        do {
            var q = scope.query
            if !query.isEmpty { q.append(URLQueryItem(name: "q", value: query)) }
            async let list: [Recording] = app.get("api/recordings", query: q)
            async let fs: [Folder] = app.get("api/folders")
            (recordings, folders) = try await (list, fs)
            error = nil
            if case .folder(let id) = scope, !folders.contains(where: { $0.id == id }) { scope = .unfiled } // deleted elsewhere
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// The web asks for the language first (「匯入「name」」 / 「匯入 N 個檔案」 → 開始上傳); cancel imports nothing.
    private func importFiles(_ result: Result<[URL], Error>) {
        do { pendingImport = try result.get() } catch { self.error = "匯入失敗：\(error.localizedDescription)" }
    }

    private func startImport(_ urls: [URL], language: String) {
        let folder = folderID
        Task {
            do {
                for url in urls { try await app.uploads.importFile(url, folderId: folder, language: language) }
            } catch {
                self.error = "匯入失敗：\(error.localizedDescription)"
            }
        }
    }
}

struct RecordingRow: View {
    let recording: Recording
    var folder: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title).font(.headline).lineLimit(2)
                Spacer()
                if recording.hasSummary == true {
                    Image(systemName: "doc.text").foregroundStyle(Color(.inkMuted)).accessibilityLabel("有摘要")
                }
            }
            HStack(spacing: 8) {
                Text(Prompt.fmtShort(recording.createdAt))
                if let d = recording.durationS { Text(Prompt.fmtDur(d)).monospacedDigit() }
                if recording.status != "done" {
                    Badge(text: Status.label(recording.status) + (recording.status == "queued" && recording.note != nil ? " · 等待額度" : ""),
                          busy: recording.status != "error", error: recording.status == "error")
                }
                if let folder { Label(folder, systemImage: "folder").lineLimit(1) }
            }
            .font(.subheadline)
            .foregroundStyle(Color(.inkMuted))
            if let top = recording.topSpeakers, !top.isEmpty {
                Text(top.map { "\($0.name ?? "未知講者") \($0.pct ?? 0)%" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Local files still on their way up, with per-item progress.
struct UploadsSection: View {
    @Environment(AppModel.self) private var app
    @State private var deleting: UploadItem?

    var body: some View {
        let queue = app.uploads
        if !queue.items.isEmpty {
            Section("上傳佇列") {
                ForEach(queue.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).lineLimit(1)
                        if let p = queue.progress[item.id] {
                            ProgressView(value: p).accessibilityLabel("上傳進度")
                        } else if let err = item.error {
                            Text("\(err)（將自動重試）").font(.caption).foregroundStyle(Color(.warn))
                        } else {
                            Text(app.needsLogin ? "等待登入" : "等待上傳").font(.caption).foregroundStyle(Color(.inkMuted))
                        }
                    }
                    .accessibilityIdentifier("upload.item")
                    .swipeActions(allowsFullSwipe: false) {
                        Button("刪除", role: .destructive) { deleting = item }
                    }
                }
            }
            .confirmationDialog("刪除後這份錄音就不見了（還沒上傳）。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { item in
                Button("刪除「\(item.title)」", role: .destructive) { queue.remove(item) }
            }
        }
    }
}

/// Header status (web: [data-runners]): 「N 台 runner 在線」 / 「沒有 runner 在線」 and 「排隊 N」; warns when work waits
/// with nothing online.
struct RunnerStatusRow: View {
    let runners: Runners

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(runners.online > 0 ? Color(.ok) : .gray).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(runners.headline).foregroundStyle(runners.warn ? AnyShapeStyle(Color(.warn)) : AnyShapeStyle(.primary))
            if runners.waiting > 0 { Badge(text: "排隊 \(runners.waiting)", busy: true) }
            if runners.warn { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(.warn)).accessibilityLabel("有工作在等待") }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看 Runner 狀態")
    }
}
