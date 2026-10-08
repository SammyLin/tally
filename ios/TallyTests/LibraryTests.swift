import Foundation
import Testing
@testable import Tally

struct FolderTreeTests {
    // 客戶(1) ─ 2026(2) ─ Q1(3);  內部(4)
    let all = [Folder(id: 1, parentId: nil, name: "客戶", count: 2), Folder(id: 2, parentId: 1, name: "2026", count: 3),
               Folder(id: 3, parentId: 2, name: "Q1", count: 0), Folder(id: 4, parentId: nil, name: "內部", count: 1)]

    @Test func descendantsAreTheWholeSubtree() {
        #expect(Set(FolderTree.descendants(1, in: all).map(\.id)) == [2, 3])
        #expect(FolderTree.descendants(3, in: all).isEmpty)
    }

    @Test func pathFromRoot() {
        #expect(FolderTree.path(3, in: all) == "客戶 / 2026 / Q1")
        #expect(FolderTree.path(nil, in: all) == "未分類")
        #expect(FolderTree.path(99, in: all) == "未分類")
    }

    @Test func cannotMoveIntoItselfOrASubfolder() {
        #expect(!FolderTree.canMove(1, to: 1, in: all))
        #expect(!FolderTree.canMove(1, to: 3, in: all))
        #expect(FolderTree.canMove(3, to: 4, in: all))
        #expect(FolderTree.canMove(3, to: nil, in: all))
    }

    @Test func flattenExcludesSubtree() throws {
        let ids = FolderTree.flatten(all).map(\.folder.id)
        let i = try #require(ids.firstIndex(of: 1))
        #expect(ids.count == 4 && Array(ids[i...].prefix(3)) == [1, 2, 3]) // a subtree follows its parent
        #expect(FolderTree.flatten(all, exclude: [2]).map(\.folder.id).sorted() == [1, 4])
        #expect(FolderTree.flatten(all).first { $0.folder.id == 3 }?.depth == 2)
    }

    @Test func deleteConfirmMatchesWeb() {
        let c = FolderTree.deleteConfirm(all[0], in: all)
        #expect(c.title == "刪除資料夾「客戶」及其 2 個子資料夾？")
        #expect(c.message == "其中 5 筆錄音會移到「未分類」（不會刪除）。")
        let empty = FolderTree.deleteConfirm(all[2], in: all)
        #expect(empty.title == "刪除資料夾「Q1」？" && empty.message.isEmpty)
    }
}

struct ScopeTests {
    @Test func storageKeyRoundTrips() {
        for s in [Scope.recent, .all, .unfiled, .trash, .folder(42)] { #expect(Scope(storageKey: s.storageKey) == s) }
        #expect(Scope(storageKey: "folder:x") == nil)
        #expect(Scope(storageKey: "") == nil)
    }

    @Test func trashQuery() {
        #expect(Scope.trash.query == [URLQueryItem(name: "trash", value: "1")])
    }
}

struct RecordingModelTests {
    @Test func decodesWaitingAndPlayFields() throws {
        let json = #"{"id":7,"title":"t","filename":"t.m4a","duration_s":null,"status":"queued","error":null,"created_at":"2026-10-08 01:00:00","deleted_at":null,"folder_id":null,"language":"en","note":"Groq 額度用完","not_before":"2026-10-08 02:00:00","play_key":"7/play.m4a","size":1234}"#
        let r = try Backend.decoder.decode(Recording.self, from: Data(json.utf8))
        #expect(r.language == "en" && r.note == "Groq 額度用完" && r.notBefore == "2026-10-08 02:00:00")
        #expect(r.playKey == "7/play.m4a" && r.size == 1234)
    }

    @Test func oldUploadQueueWithoutLanguageStillDecodes() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","path":"Recordings/a.m4a","filename":"a.m4a","size":10,"etags":{},"attempts":0}]"#
        let items = try JSONDecoder().decode([UploadItem].self, from: Data(json.utf8))
        #expect(items.first?.language == nil)
    }
}
