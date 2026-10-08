import Foundation
import Testing
@testable import Tally

struct MarkdownTests {
    @Test func blocks() {
        let md = """
        # 標題
        第一行
        第二行

        1. 一
        2) 二
          - 子項

        > 引用一
        > 引用二

        ---
        | 項目 | 負責人 |
        |:---|---:|
        | 報價 | 志明 |
        | a \\| b |

        ```swift
        let x = 1
        ```
        """
        #expect(MD.blocks(md) == [
            .heading(1, "標題"), .paragraph("第一行\n第二行"),
            .numbered(indent: 0, number: "1", "一"), .numbered(indent: 0, number: "2", "二"), .bullet(indent: 1, "子項"),
            .quote("引用一\n引用二"), .rule,
            .table(header: ["項目", "負責人"], rows: [["報價", "志明"], ["a | b"]]),
            .code("let x = 1"),
        ])
    }

    @Test func unsafeLinksAreDropped() {
        let a = MD.inline("[ok](https://a.com) [bad](javascript:alert(1)) [cite](tally://rec/1?ms=0)")
        let links = a.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://a.com", "tally://rec/1?ms=0"])
    }
}

struct DeepLinkTests {
    private func p(_ s: String) -> DeepLink? { DeepLink(URL(string: s)!) }

    @Test func routes() {
        #expect(p("tally://rec/5") == .open(scope: nil, recording: 5, summary: false, ms: nil))
        #expect(p("tally://rec/5?ms=5000") == .open(scope: nil, recording: 5, summary: false, ms: 5000))
        #expect(p("tally://folder/3/rec/5/summary") == .open(scope: .folder(3), recording: 5, summary: true, ms: nil))
        #expect(p("tally://trash") == .open(scope: .trash, recording: nil, summary: false, ms: nil))
        #expect(p("tally://unfiled/") == .open(scope: .unfiled, recording: nil, summary: false, ms: nil))
        #expect(p("tally://ask") == .ask(nil))
        #expect(p("tally://ask/7") == .ask(7))
        for bad in ["tally://", "tally://folder", "tally://rec/x", "tally://nope", "https://rec/5", "tally://rec/5/extra"] { #expect(p(bad) == nil, "\(bad)") }
        #expect(DeepLink.recording(5, summary: true) == "tally://rec/5/summary")
    }
}

struct RunnerStatusTests {
    private func rs(_ online: [Bool], q: (Int, Int, Int?)) -> Runners {
        Runners(runners: online.enumerated().map { Runners.Runner(name: "r\($0.offset)", agoS: 0, online: $0.element) },
                queued: .init(recordings: q.0, summaries: q.1, asks: q.2, vocab: 1))
    }

    @Test func headline() {
        let a = rs([true, false, true], q: (1, 2, 3))
        #expect(a.headline == "2 台 runner 在線" && a.waiting == 6 && !a.warn)
        let b = rs([false], q: (1, 0, nil))
        #expect(b.headline == "沒有 runner 在線" && b.waiting == 1 && b.warn)
        #expect(!rs([], q: (0, 0, 0)).warn)
    }

    @Test func queuedNotice() {
        let app = AppModel()
        #expect(app.queuedText == "排隊中…") // unknown runner status: no warning
        app.runners = rs([false], q: (1, 0, 0))
        #expect(app.queuedText == "排隊中。目前沒有 runner 在線，會等 runner 上線後自動處理。")
        app.runners = rs([true], q: (1, 0, 0))
        #expect(app.queuedText == "排隊中…")
    }
}
