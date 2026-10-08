import Foundation

// Compiled into both the app and the KirokuShare extension.

/// Transcription languages (web: LANGS); POST /api/uploads and retranscribe take the id.
nonisolated enum STTLang {
    static let all: [(id: String, name: String)] = [("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("auto", "自動偵測")]
}

/// Files shared into Kiroku from the share sheet, handed over through the App Group container:
/// `Inbox/<uuid>/<original name>` + `Inbox/<uuid>/meta.json`. The extension builds an entry in `Inbox/.tmp-<uuid>/`
/// and renames it into place once the file and sidecar are written, so an entry without the dot is always complete.
/// The app adopts entries into its upload queue (`UploadQueue.adoptInbox`). The app also caches the folder list
/// and default language here for the extension's pickers.
nonisolated enum Inbox {
    static let group = "group.ai.3mi.tally"
    static let sidecarName = "meta.json"
    static let tmpPrefix = ".tmp-"

    struct Sidecar: Codable, Equatable, Sendable {
        var title: String
        var folderId: Int?
        var language: String?
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case title, folderId = "folder_id", language, createdAt = "created_at"
        }
    }

    /// A folder as the extension's picker shows it (already flattened into tree order by the app).
    struct CachedFolder: Codable, Hashable, Sendable {
        var id: Int
        var name: String
        var depth: Int
    }

    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var directory: URL? { container?.appending(path: "Inbox", directoryHint: .isDirectory) }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    // MARK: Cache written by the app, read by the extension

    static func cache(folders: [CachedFolder]) {
        guard let url = container?.appending(path: "folders.json"), let data = try? encoder.encode(folders) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func cachedFolders() -> [CachedFolder] {
        guard let url = container?.appending(path: "folders.json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([CachedFolder].self, from: data)) ?? []
    }

    static var defaultLanguage: String? {
        get { UserDefaults(suiteName: group)?.string(forKey: "sttLang") }
        set { UserDefaults(suiteName: group)?.set(newValue, forKey: "sttLang") }
    }

    // MARK: Adoption (app side)

    /// Hands every complete entry under `inbox` to `enqueue` and removes the entry afterwards.
    /// `enqueue(file, filename, folderId, language)` gets the file already moved to `imports/<uuid>/<name>`
    /// and must persist it before returning. Rules:
    /// - `.tmp-*` dirs are in progress (or a killed extension's leftovers, removed after a day);
    /// - a missing or unreadable sidecar still adopts the file under its own name, so nothing is lost;
    /// - if `imports/<uuid>/<name>` already exists the file was moved by an earlier run (the queue adopts
    ///   leftovers under Imports at launch), so it is not queued twice;
    /// - a file that cannot be moved keeps its entry for the next run.
    /// Returns the number of files queued.
    @discardableResult
    static func adopt(from inbox: URL, to imports: URL, now: Date = .now,
                      enqueue: (URL, String, Int?, String?) -> Void) -> Int {
        let fm = FileManager.default
        var queued = 0
        for entry in (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if entry.lastPathComponent.hasPrefix(tmpPrefix) {
                let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
                if now.timeIntervalSince(created) > 86400 { try? fm.removeItem(at: entry) }
                continue
            }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let sidecar = (try? Data(contentsOf: entry.appending(path: sidecarName))).flatMap { try? decoder.decode(Sidecar.self, from: $0) }
            let files = ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != sidecarName } // a shared ".take1.m4a" is a real file, not a hidden one
            var ok = true
            for f in files {
                let dir = imports.appending(path: entry.lastPathComponent, directoryHint: .isDirectory)
                let dst = dir.appending(path: f.lastPathComponent)
                if fm.fileExists(atPath: dst.path(percentEncoded: false)) { try? fm.removeItem(at: f); continue }
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try fm.moveItem(at: f, to: dst)
                } catch {
                    ok = false
                    continue
                }
                enqueue(dst, filename(for: f.lastPathComponent, title: files.count == 1 ? sidecar?.title : nil),
                        sidecar?.folderId, sidecar?.language)
                queued += 1
            }
            if ok { try? fm.removeItem(at: entry) }
        }
        return queued
    }

    /// The Worker titles a recording by the filename's stem, so the chosen title becomes the stem.
    static func filename(for original: String, title: String?) -> String {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !t.isEmpty else { return original }
        let ext = (original as NSString).pathExtension
        return ext.isEmpty ? t : "\(t).\(ext)"
    }
}
