import Foundation
import Observation
import UIKit

/// A local file waiting to reach the backend. The file stays in Documents until `complete` succeeds.
nonisolated struct UploadItem: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var path: String          // relative to Documents
    var filename: String      // sent to the Worker; its stem becomes the title
    var folderId: Int?
    var language: String?     // zh|en|ja|auto; nil = the settings default (older queue files have none)
    var size: Int64
    var recordingId: Int?     // set once POST /api/uploads succeeded
    var partSize: Int64?
    var etags: [Int: String] = [:]
    var attempts = 0
    var nextTry: Date?
    var error: String?

    var url: URL { URL.documentsDirectory.appending(path: path) }
    var title: String { (filename as NSString).deletingPathExtension }
}

nonisolated enum Parts {
    /// 1-based parts covering `size` bytes in `partSize` chunks (last one smaller).
    static func ranges(size: Int64, partSize: Int64) -> [(part: Int, offset: Int64, length: Int)] {
        guard size > 0, partSize > 0 else { return [] }
        let count = Int((size + partSize - 1) / partSize)
        return (0..<count).map { i in
            let offset = Int64(i) * partSize
            return (i + 1, offset, Int(min(partSize, size - offset)))
        }
    }

    /// Reads one part off the main actor; only that slice is ever in memory.
    @concurrent static func read(_ url: URL, offset: Int64, length: Int) async throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(offset))
        return try fh.read(upToCount: length) ?? Data()
    }

    /// Retry delay: 5 s, 10 s, 20 s … capped at 10 min.
    static func backoff(attempt: Int) -> TimeInterval { min(600, 5 * pow(2, Double(max(0, attempt - 1)))) }
}

/// Persistent upload queue (Application Support/uploads.json), one file at a time, parts sequential,
/// retried with backoff forever; a token expiry pauses it until the user logs in again.
@Observable final class UploadQueue {
    private(set) var items: [UploadItem] = []
    private(set) var progress: [UUID: Double] = [:]
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var bgTasks: Set<UIBackgroundTaskIdentifier> = [] // a cancelled run can overlap the next

    private static let store = URL.applicationSupportDirectory.appending(path: "uploads.json")

    init(app: AppModel) {
        self.app = app
        if let d = try? Data(contentsOf: Self.store) {
            do {
                items = try JSONDecoder().decode([UploadItem].self, from: d)
            } catch {
                // keep the unreadable queue for inspection instead of overwriting it; its files are re-adopted below
                let bad = Self.store.appendingPathExtension("bad")
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: Self.store, to: bad)
            }
        }
        adoptOrphans()
    }

    /// Adds a file that already lives under Documents.
    func enqueue(file: URL, filename: String, folderId: Int?, language: String? = nil) {
        let docs = URL.documentsDirectory.standardizedFileURL.path(percentEncoded: false)
        let path = String(file.standardizedFileURL.path(percentEncoded: false).dropFirst(docs.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? Int64) ?? 0
        items.append(UploadItem(path: path, filename: Self.safeName(filename), folderId: folderId, language: language, size: size))
        save()
        kick()
    }

    /// Imports from Files: copy into Documents/Imports (the picker's URL is only valid briefly), then queue.
    func importFile(_ src: URL, folderId: Int?, language: String?) async throws {
        let dst = try await Self.copyIn(src)
        enqueue(file: dst, filename: src.lastPathComponent, folderId: folderId, language: language)
    }

    /// Off the main actor: a large video or an iCloud file that must download first would freeze the UI.
    @concurrent nonisolated private static func copyIn(_ src: URL) async throws -> URL {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let dir = URL.documentsDirectory.appending(path: "Imports/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appending(path: src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    /// Files saved from the share sheet (「存到 Kiroku」) wait in the App Group inbox; queue them with their
    /// title / folder / language. Called at launch and whenever the app becomes active.
    func adoptInbox() {
        guard let inbox = Inbox.directory else { return }
        Inbox.adopt(from: inbox, to: URL.documentsDirectory.appending(path: "Imports", directoryHint: .isDirectory)) { file, name, folder, lang in
            enqueue(file: file, filename: name, folderId: folder, language: lang)
        }
    }

    /// The backend changed: ids, part sizes, etags and folders belong to the old one, so every item starts over
    /// on the new one. (Nothing is sent to the new backend: those ids mean other recordings there.)
    func resetServerState() {
        worker?.cancel() // an in-flight upload must not write the old ids back (update/fail skip when cancelled)
        worker = nil
        progress = [:]
        for i in items.indices {
            items[i].recordingId = nil
            items[i].partSize = nil
            items[i].folderId = nil
            items[i].etags = [:]
        }
        save()
    }

    func remove(_ item: UploadItem) {
        items.removeAll { $0.id == item.id }
        progress[item.id] = nil
        save()
        try? FileManager.default.removeItem(at: item.url)
        if let rid = item.recordingId { Task { let _: Ignored? = try? await app.json("DELETE", "api/uploads/\(rid)") } }
    }

    func retryNow() {
        for i in items.indices { items[i].nextTry = nil }
        save()
        kick()
    }

    /// Starts the worker if idle, or wakes it from a backoff sleep.
    func kick() {
        if worker != nil {
            if sleeping { worker?.cancel(); worker = nil } else { return }
        }
        worker = Task { await run() }
    }

    private func run() async {
        // extra time after the app leaves the foreground; when it runs out the system suspends us and the
        // queue resumes on the next launch/foreground (the handler must end the task or iOS kills the app)
        let bg = UIApplication.shared.beginBackgroundTask(withName: "uploads") { [weak self] in
            self?.bgTasks.forEach { self?.endBackgroundTask($0) }
        }
        bgTasks.insert(bg)
        defer { endBackgroundTask(bg) }
        while !Task.isCancelled, !app.needsLogin, app.backend != nil {
            guard let item = items.min(by: { ($0.nextTry ?? .distantPast) < ($1.nextTry ?? .distantPast) }) else { break }
            if let due = item.nextTry, due > .now {
                sleeping = true
                try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow))
                sleeping = false
                continue
            }
            await upload(item.id)
        }
        if !Task.isCancelled { worker = nil }
    }

    private func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard bgTasks.remove(id) != nil else { return }
        UIApplication.shared.endBackgroundTask(id)
    }

    private func upload(_ id: UUID) async {
        guard var item = items.first(where: { $0.id == id }) else { return }
        do {
            guard FileManager.default.fileExists(atPath: item.url.path(percentEncoded: false)) else {
                throw APIError.http(0, "本機檔案不見了")
            }
            guard item.size > 0 else { throw APIError.http(0, "檔案是空的") }
            if item.recordingId == nil {
                let start: UploadStart = try await app.json("POST", "api/uploads",
                    ["filename": item.filename, "size": item.size, "folder_id": item.folderId, "language": item.language])
                item.recordingId = start.recordingId
                item.partSize = start.partSize
                item.etags = [:]
                update(item)
            }
            guard let rid = item.recordingId, let partSize = item.partSize else { return }
            let parts = Parts.ranges(size: item.size, partSize: partSize)
            for p in parts where item.etags[p.part] == nil {
                let done = Int64(item.etags.count) * partSize
                let data = try await Parts.read(item.url, offset: p.offset, length: p.length)
                let total = Double(item.size)
                let report: @Sendable (Int64) -> Void = { sent in
                    Task { @MainActor in self.progress[id] = Double(done + sent) / total }
                }
                let etag: Etag = try await app.call { b in
                    var req = b.request("api/uploads/\(rid)/\(p.part)", method: "PUT")
                    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    return try Backend.decoder.decode(Etag.self, from: await b.send(req, upload: data, progress: report))
                }
                item.etags[p.part] = etag.etag
                update(item)
            }
            let list = item.etags.sorted { $0.key < $1.key }.map { ["part": $0.key, "etag": $0.value] as [String: Any] }
            do {
                let _: Ignored = try await app.json("POST", "api/uploads/\(rid)/complete", ["parts": list])
            } catch APIError.http(409, _) {
                // already completed (our earlier complete went through but the answer got lost)
            }
            finish(item)
        } catch APIError.authRequired {
            // paused until login; no attempt counted
        } catch {
            fail(&item, error)
        }
    }

    private func fail(_ item: inout UploadItem, _ error: Error) {
        if Task.isCancelled { return }
        // the chosen folder was deleted meanwhile: upload to 未分類 rather than retrying forever
        if item.recordingId == nil, item.folderId != nil, case APIError.http(400, let msg)? = error as? APIError, msg.contains("folder") {
            item.folderId = nil
        }
        if let api = error as? APIError, let status = api.status, let rid = item.recordingId {
            switch status {
            case 409:
                // a part PUT on an upload that is no longer `uploading` (complete's 409 is handled in upload()):
                // the id is not ours to finish, so start a fresh upload — never treat it as done and delete the file
                item.recordingId = nil
                item.etags = [:]
            case 404, 400:
                // the server-side upload is gone or rejects our parts: abort it and start over from part 1
                Task { let _: Ignored? = try? await app.json("DELETE", "api/uploads/\(rid)") }
                item.recordingId = nil
                item.etags = [:]
            default: break
            }
        }
        item.attempts += 1
        item.error = error.localizedDescription
        item.nextTry = .now.addingTimeInterval(Parts.backoff(attempt: item.attempts))
        progress[item.id] = nil
        update(item)
    }

    private func finish(_ item: UploadItem) {
        items.removeAll { $0.id == item.id }
        progress[item.id] = nil
        save()
        try? FileManager.default.removeItem(at: item.url)
        let parent = item.url.deletingLastPathComponent()
        if parent.lastPathComponent != "Recordings" { try? FileManager.default.removeItem(at: parent) } // Imports/<uuid>/
    }

    private func update(_ item: UploadItem) {
        guard !Task.isCancelled, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: Self.store, options: .atomic)
        } catch {
            print("upload queue save failed:", error)
        }
    }

    /// Files on disk that are not in the queue (app killed mid-recording, or an unreadable uploads.json) are queued at launch.
    private func adoptOrphans() {
        let known = Set(items.map(\.path))
        let live = app.recorder.fileURL?.lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: Recorder.directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm" // same as RecordView.defaultTitle
        for f in files where f.pathExtension == "m4a" && !known.contains("Recordings/\(f.lastPathComponent)")
            && f.lastPathComponent != live {
            let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            enqueue(file: f, filename: "錄音 \(fmt.string(from: created)).m4a", folderId: nil)
        }
        // Imports/<uuid>/<original name>
        let imports = URL.documentsDirectory.appending(path: "Imports", directoryHint: .isDirectory)
        for dir in (try? FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                where !known.contains("Imports/\(dir.lastPathComponent)/\(f.lastPathComponent)") {
                enqueue(file: f, filename: f.lastPathComponent, folderId: nil)
            }
        }
    }

    /// The Worker keeps only the part after the last "/" or "\".
    static func safeName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "recording.m4a" : cleaned
    }
}
