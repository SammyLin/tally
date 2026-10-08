import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「存到 Kiroku」 share extension: copies the shared audio / video files into the App Group inbox with a title,
/// folder and language. It never uploads (extensions get little memory and time); the app queues the files the
/// next time it becomes active.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] cancelled in
            guard let ctx = self?.extensionContext else { return }
            if cancelled { ctx.cancelRequest(withError: CocoaError(.userCancelled)) } else { ctx.completeRequest(returningItems: nil) }
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { await model.load(providers) }
    }
}

nonisolated struct StagedFile: Identifiable, Sendable {
    let id = UUID()
    let dir: URL      // Inbox/.tmp-<id>/
    let name: String
    let size: Int64
}

@Observable final class ShareModel {
    static let maxItems = 20

    var files: [StagedFile] = []
    var loading = true
    var error: String?
    var saved = false
    var title = ""
    var folderId: Int?
    var language = Inbox.defaultLanguage ?? "zh"
    let folders = Inbox.cachedFolders()
    var skipped = 0
    @ObservationIgnored var finish: (Bool) -> Void = { _ in }

    /// Copies each file into the inbox's staging dir right away (the provider's file is only valid inside its
    /// callback), so sizes are known and 儲存 only has to write the sidecar and rename.
    func load(_ providers: [NSItemProvider]) async {
        defer { loading = false }
        guard let inbox = Inbox.directory else { error = "無法存取 Kiroku 的共用空間。"; return }
        let media = providers.filter { Self.mediaType($0) != nil }
        skipped = max(0, media.count - Self.maxItems) + (providers.count - media.count)
        for p in media.prefix(Self.maxItems) {
            do { files.append(try await Self.stage(p, in: inbox)) } catch { self.error = "無法讀取檔案：\(error.localizedDescription)" }
        }
        if files.count == 1 { title = (files[0].name as NSString).deletingPathExtension }
        if files.isEmpty, error == nil { error = "沒有可儲存的音訊或影片檔。" }
    }

    func save() {
        let now = Date.now
        do {
            for f in files {
                let meta = Inbox.Sidecar(title: files.count == 1 ? title : (f.name as NSString).deletingPathExtension,
                                         folderId: folderId, language: language, createdAt: now)
                try Inbox.encoder.encode(meta).write(to: f.dir.appending(path: Inbox.sidecarName), options: .atomic)
                let done = f.dir.deletingLastPathComponent().appending(path: String(f.dir.lastPathComponent.dropFirst(Inbox.tmpPrefix.count)))
                try FileManager.default.moveItem(at: f.dir, to: done)
            }
        } catch {
            self.error = "儲存失敗：\(error.localizedDescription)"
            return
        }
        files = []
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            finish(false)
        }
    }

    func cancel() {
        for f in files { try? FileManager.default.removeItem(at: f.dir) }
        finish(true)
    }

    nonisolated private static func mediaType(_ p: NSItemProvider) -> UTType? {
        p.registeredContentTypes.first { $0.conforms(to: .audio) || $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent) }
    }

    // nonisolated: the provider calls back on its own queue, where the copy runs (off the main thread)
    nonisolated private static func stage(_ p: NSItemProvider, in inbox: URL) async throws -> StagedFile {
        guard let type = mediaType(p) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let dir = inbox.appending(path: Inbox.tmpPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suggested = p.suggestedName
        return try await withCheckedThrowingContinuation { cont in
            _ = p.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else { cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                // copy before returning: the system deletes `url` afterwards. copyItem streams, so big files are fine.
                var name = url.lastPathComponent
                if let s = suggested, !s.isEmpty {
                    name = (s as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? "\(s).\(url.pathExtension)" : s
                }
                name = name.replacingOccurrences(of: "/", with: "-")
                let dst = dir.appending(path: name)
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    let size = (try? FileManager.default.attributesOfItem(atPath: dst.path(percentEncoded: false))[.size] as? Int64) ?? 0
                    cont.resume(returning: StagedFile(dir: dir, name: name, size: size))
                } catch {
                    try? FileManager.default.removeItem(at: dir)
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("存到 Kiroku")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: model.cancel).disabled(model.saved).accessibilityIdentifier("share.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("儲存", action: model.save)
                            .disabled(model.loading || model.saved || model.files.isEmpty)
                            .accessibilityIdentifier("share.save")
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if model.saved {
            ContentUnavailableView("已存到 Kiroku，開啟 App 後會上傳", systemImage: "checkmark.circle")
                .accessibilityIdentifier("share.done")
        } else {
            Form {
                Section {
                    ForEach(model.files) { f in
                        LabeledContent(f.name, value: ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                    }
                    if model.loading { ProgressView() }
                } footer: {
                    if model.skipped > 0 { Text("略過 \(model.skipped) 個項目（只收音訊／影片，最多 \(ShareModel.maxItems) 個）。") }
                }
                if model.files.count == 1 {
                    Section("標題") {
                        TextField("標題", text: $model.title).accessibilityIdentifier("share.title")
                    }
                }
                if !model.files.isEmpty {
                    Section {
                        if !model.folders.isEmpty {
                            Picker("資料夾", selection: $model.folderId) {
                                Text("未分類").tag(Int?.none)
                                ForEach(model.folders, id: \.id) { f in
                                    Text(String(repeating: "　", count: f.depth) + f.name).tag(Int?.some(f.id))
                                }
                            }
                            .accessibilityIdentifier("share.folder")
                        }
                        Picker("轉錄語言", selection: $model.language) {
                            ForEach(STTLang.all, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("share.language")
                    }
                }
                if let e = model.error {
                    Section { Text(e).foregroundStyle(.red) }
                }
            }
        }
    }
}
