import Foundation
import Testing
@testable import Tally

struct InboxTests {
    let root = URL.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)", directoryHint: .isDirectory)
    var inbox: URL { root.appending(path: "Inbox", directoryHint: .isDirectory) }
    var imports: URL { root.appending(path: "Imports", directoryHint: .isDirectory) }

    typealias Queued = (file: URL, name: String, folder: Int?, lang: String?)

    @discardableResult
    func entry(_ id: String, file: String = "voice.m4a", sidecar: String?) throws -> URL {
        let dir = inbox.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: dir.appending(path: file))
        if let sidecar { try Data(sidecar.utf8).write(to: dir.appending(path: Inbox.sidecarName)) }
        return dir
    }

    func adopt() -> [Queued] {
        var out: [Queued] = []
        Inbox.adopt(from: inbox, to: imports) { out.append(($0, $1, $2, $3)) }
        return out
    }

    func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path(percentEncoded: false)) }

    @Test func sidecarAppliesTitleFolderLanguage() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try entry("A", sidecar: #"{"title":"週會","folder_id":7,"language":"en","created_at":"2026-10-08T01:02:03Z"}"#)
        let q = adopt()
        #expect(q.count == 1)
        #expect(q[0].name == "週會.m4a" && q[0].folder == 7 && q[0].lang == "en")
        #expect(q[0].file == imports.appending(path: "A/voice.m4a"))
        #expect(exists(q[0].file) && !exists(dir))
    }

    @Test func sidecarRoundTripsSnakeCase() throws {
        let s = Inbox.Sidecar(title: "t", folderId: nil, language: "ja", createdAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try Inbox.encoder.encode(s), as: UTF8.self)
        #expect(json.contains("created_at") && json.contains("1970-01-01T00:00:00Z"))
        #expect(try Inbox.decoder.decode(Inbox.Sidecar.self, from: Data(json.utf8)) == s)
    }

    @Test func secondRunQueuesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try entry("A", sidecar: #"{"title":"x","created_at":"2026-10-08T01:02:03Z"}"#)
        #expect(adopt().count == 1)
        #expect(adopt().isEmpty)
    }

    @Test func alreadyMovedFileIsNotQueuedTwice() throws {
        // an earlier run moved the file but the inbox entry survived (e.g. killed before removing it)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try entry("A", sidecar: #"{"title":"x","created_at":"2026-10-08T01:02:03Z"}"#)
        try FileManager.default.createDirectory(at: imports.appending(path: "A"), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: imports.appending(path: "A/voice.m4a"))
        #expect(adopt().isEmpty)
        #expect(!exists(dir) && exists(imports.appending(path: "A/voice.m4a")))
    }

    @Test func corruptOrMissingSidecarStillKeepsTheFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try entry("A", file: "a.mp3", sidecar: "{not json")
        try entry("B", file: "b.wav", sidecar: nil)
        let q = adopt().sorted { $0.name < $1.name }
        #expect(q.map(\.name) == ["a.mp3", "b.wav"])
        #expect(q.allSatisfy { $0.folder == nil && $0.lang == nil && exists($0.file) })
    }

    @Test func inProgressEntriesAreLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tmp = try entry(Inbox.tmpPrefix + "X", sidecar: nil)
        #expect(adopt().isEmpty)
        #expect(exists(tmp.appending(path: "voice.m4a")))
        // a killed extension's leftover goes after a day
        Inbox.adopt(from: inbox, to: imports, now: .now.addingTimeInterval(2 * 86400)) { _, _, _, _ in }
        #expect(!exists(tmp))
    }

    @Test func dotNamedFileIsQueuedNotDeleted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try entry("A", file: ".take1.m4a", sidecar: nil)
        let q = adopt()
        #expect(q.map(\.name) == [".take1.m4a"])
        #expect(exists(imports.appending(path: "A/.take1.m4a")))
    }

    @Test func blankTitleKeepsOriginalName() {
        #expect(Inbox.filename(for: "New Recording 3.m4a", title: "  ") == "New Recording 3.m4a")
        #expect(Inbox.filename(for: "clip.mov", title: "訪談") == "訪談.mov")
        #expect(Inbox.filename(for: "noext", title: "訪談") == "訪談")
    }
}
