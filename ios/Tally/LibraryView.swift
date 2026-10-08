import SwiftUI
import UniformTypeIdentifiers

/// 最近 / 全部 / 未分類 / a folder (read-only tree), with search, pull to refresh and polling while processing.
enum Scope: Hashable {
    case recent, all, unfiled, folder(Int)

    var query: [URLQueryItem] {
        switch self {
        case .recent: [URLQueryItem(name: "view", value: "recent")]
        case .all: []
        case .unfiled: [URLQueryItem(name: "folder", value: "none")]
        case .folder(let id): [URLQueryItem(name: "folder", value: String(id))]
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var scope = Scope.recent
    @State private var query = ""
    @State private var recordings: [Recording] = []
    @State private var folders: [Folder] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var showRecord = false
    @State private var showSettings = false
    @State private var showRunners = false
    @State private var showImporter = false
    @State private var path: [Int] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                UploadsSection()
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    ForEach(recordings) { r in
                        NavigationLink(value: r.id) { RecordingRow(recording: r) }
                            .accessibilityIdentifier("recording.\(r.id)")
                    }
                } footer: {
                    if loaded && recordings.isEmpty {
                        Text(query.isEmpty ? "還沒有錄音。按下方的錄音鍵開始，或從「檔案」匯入。" : "找不到符合的錄音。")
                    }
                }
            }
            .navigationTitle(title)
            .navigationDestination(for: Int.self) { DetailView(id: $0) }
            .searchable(text: $query, prompt: "搜尋標題或逐字稿")
            .refreshable { await load() }
            .task(id: LoadKey(scope: scope, query: query)) {
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) } // debounce typing
                while !Task.isCancelled {
                    await load()
                    // poll while anything is still being processed (web: every 3 s)
                    try? await Task.sleep(for: .seconds(recordings.contains { Status.busy($0.status) } ? 3 : 30))
                }
            }
            .toolbar { toolbar }
            #if DEBUG
            .onAppear { // screenshots / smoke tests: `-open <recording id>`
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-open"), i + 1 < args.count, let id = Int(args[i + 1]), path.isEmpty { path = [id] }
            }
            #endif
            .safeAreaInset(edge: .bottom) { recordButton }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie, .audiovisualContent],
                          allowsMultipleSelection: true) { result in
                importFiles(result)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showRunners) { RunnersView() }
            .fullScreenCover(isPresented: $showRecord, onDismiss: { Task { await load() } }) {
                RecordView(folders: folders, defaultFolder: folderID)
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

    private var folderID: Int? { if case .folder(let id) = scope { id } else { nil } }

    private var title: String {
        switch scope {
        case .recent: "最近"
        case .all: "全部"
        case .unfiled: "未分類"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "資料夾"
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("檢視", selection: $scope) {
                    Label("最近", systemImage: "clock").tag(Scope.recent)
                    Label("全部", systemImage: "tray.full").tag(Scope.all)
                    Label("未分類", systemImage: "tray").tag(Scope.unfiled)
                }
                if !folders.isEmpty {
                    Picker("資料夾", selection: $scope) {
                        ForEach(FolderTree.flatten(folders), id: \.folder.id) { item in
                            Text(String(repeating: "　", count: item.depth) + item.folder.name + "（\(item.folder.count)）")
                                .tag(Scope.folder(item.folder.id))
                        }
                    }
                }
            } label: {
                Label("資料夾", systemImage: "folder")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showRunners = true } label: { Label("Runner 狀態", systemImage: "server.rack") }
            Button { showImporter = true } label: { Label("從檔案匯入", systemImage: "square.and.arrow.down") }
            Button { showSettings = true } label: { Label("設定", systemImage: "gearshape") }
        }
    }

    private var recordButton: some View {
        Button { showRecord = true } label: {
            Image(systemName: "mic.fill")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.red, in: .circle)
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
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        Task {
            do {
                for url in try result.get() { try await app.uploads.importFile(url, folderId: folderID) }
            } catch {
                self.error = "匯入失敗：\(error.localizedDescription)"
            }
        }
    }
}

enum FolderTree {
    /// Depth-first, siblings by name — the web's sidebar tree as an indented list.
    static func flatten(_ all: [Folder]) -> [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ parent: Int?, _ depth: Int) {
            for f in all.filter({ $0.parentId == parent }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                out.append((f, depth))
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }
}

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title).font(.headline).lineLimit(2)
                Spacer()
                if recording.hasSummary == true {
                    Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityLabel("有摘要")
                }
            }
            HStack(spacing: 8) {
                Text(Prompt.fmtShort(recording.createdAt))
                if let d = recording.durationS { Text(Prompt.fmtDur(d)).monospacedDigit() }
                if recording.status != "done" {
                    Badge(text: Status.label(recording.status), busy: recording.status != "error", error: recording.status == "error")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
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
                            Text("\(err)（將自動重試）").font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(app.needsLogin ? "等待登入" : "等待上傳").font(.caption).foregroundStyle(.secondary)
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
