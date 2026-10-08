import SwiftUI

/// 最近 / 全部 / 未分類 / a folder / 垃圾桶 — the web's views (`#/recent`, `#/all`, `#/none`, `#/folder/<id>`, `#/trash`).
enum Scope: Hashable {
    case recent, all, unfiled, folder(Int), trash

    var query: [URLQueryItem] {
        switch self {
        case .recent: [URLQueryItem(name: "view", value: "recent")]
        case .all: []
        case .unfiled: [URLQueryItem(name: "folder", value: "none")]
        case .folder(let id): [URLQueryItem(name: "folder", value: String(id))]
        case .trash: [URLQueryItem(name: "trash", value: "1")]
        }
    }

    /// Remembered across launches like the web's `tally.view`.
    var storageKey: String {
        switch self {
        case .recent: "recent"
        case .all: "all"
        case .unfiled: "none"
        case .trash: "trash"
        case .folder(let id): "folder:\(id)"
        }
    }

    init?(storageKey s: String) {
        switch s {
        case "recent": self = .recent
        case "all": self = .all
        case "none": self = .unfiled
        case "trash": self = .trash
        default:
            guard s.hasPrefix("folder:"), let id = Int(s.dropFirst(7)) else { return nil }
            self = .folder(id)
        }
    }

    static let defaultsKey = "tally.view"
    static func saved() -> Scope { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Scope.init(storageKey:)) ?? .recent }
    func save() { UserDefaults.standard.set(storageKey, forKey: Self.defaultsKey) }
}

/// tally:// links, the app's version of the web's hash routes: tally://[recent|all|unfiled|trash|folder/<id>][/rec/<id>[/summary]][?ms=<ms>]
/// and tally://ask[/<id>]. tally://rec/<id>?ms=<ms> is also what Ask citations use.
enum DeepLink: Equatable {
    case open(scope: Scope?, recording: Int?, summary: Bool, ms: Int?)
    case ask(Int?)

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "tally" else { return nil }
        var parts = ([url.host() ?? ""] + url.pathComponents).filter { !$0.isEmpty && $0 != "/" }
        if parts.first == "ask" {
            guard parts.count <= 2 else { return nil }
            if parts.count == 2 { guard let id = Int(parts[1]) else { return nil }; self = .ask(id) } else { self = .ask(nil) }
            return
        }
        var scope: Scope?
        switch parts.first {
        case "recent": scope = .recent; parts.removeFirst()
        case "all": scope = .all; parts.removeFirst()
        case "unfiled": scope = .unfiled; parts.removeFirst()
        case "trash": scope = .trash; parts.removeFirst()
        case "folder":
            guard parts.count >= 2, let id = Int(parts[1]) else { return nil }
            scope = .folder(id); parts.removeFirst(2)
        default: break
        }
        var rec: Int?, summary = false
        if parts.first == "rec" {
            guard parts.count >= 2, let id = Int(parts[1]) else { return nil }
            rec = id; parts.removeFirst(2)
            if parts.first == "summary" { summary = true; parts.removeFirst() }
        }
        guard parts.isEmpty, scope != nil || rec != nil else { return nil }
        let ms = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ms" }?.value.flatMap(Int.init)
        self = .open(scope: scope, recording: rec, summary: summary, ms: rec == nil ? nil : ms)
    }

    /// Link to a recording (detail ⋯ →「複製連結」).
    static func recording(_ id: Int, summary: Bool) -> String { "tally://rec/\(id)" + (summary ? "/summary" : "") }
}

/// A recording pushed on the library's stack (opened from the list or a link).
struct RecRoute: Hashable {
    var id: Int
    var summary = false
    var ms: Int?
}

enum FolderTree {
    /// Depth-first, siblings by name — the web's sidebar tree as an indented list. `exclude` drops a folder and its subtree.
    static func flatten(_ all: [Folder], exclude: Set<Int> = []) -> [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ parent: Int?, _ depth: Int) {
            for f in all.filter({ $0.parentId == parent }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            where !exclude.contains(f.id) {
                out.append((f, depth))
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    static func descendants(_ id: Int, in all: [Folder]) -> [Folder] {
        all.filter { $0.parentId == id }.flatMap { [$0] + descendants($0.id, in: all) }
    }

    /// Root → folder, e.g. 「客戶 / 2026」; 未分類 for no folder.
    static func path(_ id: Int?, in all: [Folder]) -> String {
        var names: [String] = []
        var cur = id
        while let c = cur, let f = all.first(where: { $0.id == c }), names.count < 50 {
            names.insert(f.name, at: 0)
            cur = f.parentId
        }
        return names.isEmpty ? "未分類" : names.joined(separator: " / ")
    }

    /// Same check as the web's moveFolder: not into itself or one of its subfolders.
    static func canMove(_ id: Int, to parent: Int?, in all: [Folder]) -> Bool {
        guard let parent else { return true }
        return parent != id && !descendants(id, in: all).contains { $0.id == parent }
    }

    /// The web's delete confirm, split into title and message.
    static func deleteConfirm(_ f: Folder, in all: [Folder]) -> (title: String, message: String) {
        let sub = descendants(f.id, in: all)
        let n = ([f] + sub).reduce(0) { $0 + $1.count }
        return ("刪除資料夾「\(f.name)」" + (sub.isEmpty ? "" : "及其 \(sub.count) 個子資料夾") + "？",
                n > 0 ? "其中 \(n) 筆錄音會移到「未分類」（不會刪除）。" : "")
    }
}

// MARK: - Navigator + folder management (the web's sidebar)

struct FoldersSheet: View {
    @Binding var scope: Scope
    let folders: [Folder]
    let reload: () async -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var naming: Naming?
    @State private var name = ""
    @State private var moving: Folder?
    @State private var deleting: Folder?

    enum Naming: Identifiable {
        case create(parent: Folder?), rename(Folder)
        var id: String { switch self { case .create(let p): "c\(p?.id ?? 0)"; case .rename(let f): "r\(f.id)" } }
        var title: String {
            switch self {
            case .create(nil): "新資料夾名稱"
            case .create(let p?): "在「\(p.name)」中新增資料夾"
            case .rename: "資料夾名稱"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        nav("最近", "clock", .recent)
                        nav("全部", "tray.full", .all)
                        nav("未分類", "tray", .unfiled)
                    }
                    Section {
                        ForEach(FolderTree.flatten(folders), id: \.folder.id) { item in
                            folderRow(item.folder, depth: item.depth)
                        }
                        if folders.isEmpty { Text("尚無資料夾").foregroundStyle(Color(.inkMuted)) }
                    } header: {
                        HStack {
                            Text("資料夾")
                            Spacer()
                            Button { startNaming(.create(parent: nil)) } label: { Image(systemName: "plus") }
                                .accessibilityLabel("新增資料夾")
                                .accessibilityIdentifier("folders.add")
                        }
                    }
                    Section { nav("垃圾桶", "trash", .trash) }
                }
                .kirokuRows()
            }
            .kirokuList()
            .navigationTitle("資料夾")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }), presenting: naming) { n in
                TextField("名稱", text: $name).accessibilityIdentifier("folder.name")
                Button("取消", role: .cancel) {}
                Button(n.isCreate ? "建立" : "儲存") { Task { await submit(n) } }.accessibilityIdentifier("folder.name.ok")
            }
            .alert(deleting.map { FolderTree.deleteConfirm($0, in: folders).title } ?? "",
                   isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { f in
                Button("刪除", role: .destructive) { Task { await delete(f) } }
            } message: { f in
                Text(FolderTree.deleteConfirm(f, in: folders).message)
            }
            .sheet(item: $moving) { f in
                FolderPicker(title: "移動「\(f.name)」到", rootLabel: "最上層", rootIcon: "square.stack", folders: folders,
                             exclude: [f.id], current: f.parentId) { parent in
                    Task { await move(f, to: parent) }
                }
            }
        }
        .modifier(ToastOverlay())
    }

    private func nav(_ label: String, _ icon: String, _ s: Scope) -> some View {
        Button { scope = s; dismiss() } label: {
            Label(label, systemImage: icon).foregroundStyle(scope == s ? Color.accentColor : .primary)
        }
        .accessibilityAddTraits(scope == s ? .isSelected : [])
    }

    private func folderRow(_ f: Folder, depth: Int) -> some View {
        HStack {
            Button { scope = .folder(f.id); dismiss() } label: {
                HStack {
                    Label(f.name, systemImage: "folder").foregroundStyle(scope == .folder(f.id) ? Color.accentColor : .primary)
                    Spacer()
                    if f.count > 0 { Text("\(f.count)").foregroundStyle(Color(.inkMuted)).monospacedDigit() }
                }
                .contentShape(.rect)
            }
            .padding(.leading, CGFloat(depth) * 18)
            Menu {
                Button { startNaming(.create(parent: f)) } label: { Label("新增子資料夾", systemImage: "folder.badge.plus") }
                Button { startNaming(.rename(f)) } label: { Label("重新命名", systemImage: "pencil") }
                Button { moving = f } label: { Label("移動到…", systemImage: "folder") }
                Button(role: .destructive) { deleting = f } label: { Label("刪除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").padding(.leading, 8)
            }
            .accessibilityLabel("「\(f.name)」的動作")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("folder.\(f.name)")
    }

    private func startNaming(_ n: Naming) {
        if case .rename(let f) = n { name = f.name } else { name = "" }
        naming = n
    }

    private func submit(_ n: Naming) async {
        let v = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        do {
            switch n {
            case .create(let parent):
                let f: Folder = try await app.json("POST", "api/folders", ["name": v, "parent_id": parent?.id])
                await reload()
                scope = .folder(f.id) // web: opens the new folder
                dismiss()
            case .rename(let f):
                guard v != f.name else { return }
                let _: Folder = try await app.json("PATCH", "api/folders/\(f.id)", ["name": v])
                await reload()
            }
        } catch { app.fail(error) }
    }

    private func move(_ f: Folder, to parent: Int?) async {
        guard FolderTree.canMove(f.id, to: parent, in: folders) else { app.toast = "不能移到自己或子資料夾內"; return }
        guard parent != f.parentId else { return }
        do {
            let _: Folder = try await app.json("PATCH", "api/folders/\(f.id)", ["parent_id": parent])
            app.toast = "已移到「\(parent.flatMap { p in folders.first { $0.id == p }?.name } ?? "最上層")」"
            await reload()
        } catch { app.fail(error) }
    }

    private func delete(_ f: Folder) async {
        let gone = Set([f.id] + FolderTree.descendants(f.id, in: folders).map(\.id))
        do {
            let _: Ignored = try await app.json("DELETE", "api/folders/\(f.id)")
            if case .folder(let cur) = scope, gone.contains(cur) { scope = .unfiled }
            app.toast = "已刪除資料夾"
            await reload()
        } catch { app.fail(error) }
    }
}

private extension FoldersSheet.Naming {
    var isCreate: Bool { if case .create = self { true } else { false } }
}

/// The web's pickFolder dialog: root row (未分類 or 最上層) + the tree, current one marked, `exclude` subtrees hidden.
struct FolderPicker: View {
    let title: String
    let rootLabel: String
    var rootIcon = "tray"
    let folders: [Folder]
    var exclude: Set<Int> = []
    let current: Int?
    let onPick: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Group {
                    row(rootLabel, rootIcon, nil, depth: 0)
                    ForEach(FolderTree.flatten(folders, exclude: exclude), id: \.folder.id) { item in
                        row(item.folder.name, "folder", item.folder.id, depth: item.depth)
                    }
                    if folders.allSatisfy({ exclude.contains($0.id) }) {
                        Text("還沒有資料夾，可在「資料夾」旁按 + 新增。").font(.footnote).foregroundStyle(Color(.inkMuted))
                    }
                }
                .kirokuRows()
            }
            .kirokuList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ label: String, _ icon: String, _ id: Int?, depth: Int) -> some View {
        Button { dismiss(); onPick(id) } label: {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                if id == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("目前位置") }
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
        .padding(.leading, CGFloat(depth) * 18)
        .accessibilityIdentifier("pick.\(label)")
    }
}

/// The web's askLang dialog: language choice (default given), optional note, confirm button.
struct LanguageSheet: View {
    let title: String
    var note = ""
    let okLabel: String
    let onOK: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var language: String

    init(title: String, note: String = "", okLabel: String, initial: String, onOK: @escaping (String) -> Void) {
        self.title = title
        self.note = note
        self.okLabel = okLabel
        self.onOK = onOK
        _language = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Picker("語言", selection: $language) {
                            ForEach(STTLang.all, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    } footer: {
                        if !note.isEmpty { Text(note) }
                    }
                }
                .kirokuRows()
            }
            .kirokuList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    // onOK first: dismiss runs the caller's binding setter, which can clear state onOK reads
                    Button(okLabel) { onOK(language); dismiss() }.accessibilityIdentifier("lang.ok")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Shows `app.toast` at the top (web: toast()). Applied at the root and inside sheets, which cover the root.
struct ToastOverlay: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = app.toast {
                Text(t).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule).padding(.top, 8).padding(.horizontal)
                    .accessibilityIdentifier("toast")
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(for: .seconds(t.hasPrefix("錯誤") ? 5 : 2.6))
                        if app.toast == t { withAnimation { app.toast = nil } }
                    }
            }
        }
        .animation(.default, value: app.toast)
    }
}
