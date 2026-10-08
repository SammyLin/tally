import Foundation
import Testing
@testable import Tally

/// Expected strings were produced by running web/public/index.html's buildPrompt on the same fixture
/// (node 25 / ICU 78, TZ=UTC, origin https://records.example.com). Regenerate them if the web format changes.
/// The date uses a thin space (U+2009) between date and time: that is what current ICU (node, Safari, iOS) prints
/// for zh-TW; fmtDate uses the same CLDR skeleton, so app and web stay in step if it changes again.
@MainActor struct PromptTests {
    static let fixture = #"""
{"recording":{"id":42,"title":"週會 Weekly sync","filename":"a.m4a","duration_s":3725.6,"status":"done","error":null,"created_at":"2026-10-08 06:30:12","deleted_at":null,"folder_id":null},
"speakers":[{"id":7,"label":"spk0","display_name":"Alice","person_id":1,"auto":0,"suggest":null},{"id":8,"label":"spk1","display_name":"Speaker 2","person_id":null,"auto":1,"suggest":{"person_id":3,"name":"Bob","score":0.61}}],
"segments":[
{"id":1,"start_ms":0,"end_ms":4000,"speaker_id":7,"text_raw":"大家好 ","text_clean":"大家好，"},
{"id":2,"start_ms":4000,"end_ms":9000,"speaker_id":7,"text_raw":"we start","text_clean":"We start"},
{"id":3,"start_ms":9000,"end_ms":12000,"speaker_id":7,"text_raw":"now","text_clean":null},
{"id":4,"start_ms":12000,"end_ms":30000,"speaker_id":8,"text_raw":"好的","text_clean":"好的。"},
{"id":5,"start_ms":30000,"end_ms":31000,"speaker_id":null,"text_raw":"嗯","text_clean":"嗯"},
{"id":6,"start_ms":31000,"end_ms":32000,"speaker_id":null,"text_raw":"  ","text_clean":"  "},
{"id":7,"start_ms":3700000,"end_ms":3705000,"speaker_id":7,"text_raw":"結束","text_clean":"結束。"}],
"summaries":[{"id":9,"recording_id":42,"template_id":"meeting","language":"zh-TW","status":"done","content_md":"\n# 重點\n- 一\n## 待辦\n###### 六\n#不是標題\n","error":null,"created_at":"2026-10-08 07:00:00"},
{"id":8,"recording_id":42,"template_id":"other","language":"en","status":"done","content_md":"Plain","error":null,"created_at":"2026-10-08 07:00:00"},
{"id":7,"recording_id":42,"template_id":"meeting","language":"zh-TW","status":"queued","content_md":null,"error":null,"created_at":"2026-10-08 07:00:00"}]}
"""#

    static let expectedDefault = #"""
以下是一份錄音的摘要與逐字稿，請根據內容回答我接下來的問題。

# 週會 Weekly sync
- 日期：2026/10/08\#u{2009}06:30
- 長度：1:02:05
- 參與者：Speaker 2、Alice、未知講者
- 來源：https://records.example.com/#/rec/42

## 摘要（會議摘要）

## 重點
- 一
### 待辦
###### 六
#不是標題

## 摘要（other）

Plain

## 逐字稿

[00:00] Alice：大家好，We start now
[00:12] Speaker 2：好的。
[00:30] 未知講者：嗯
[1:01:40] Alice：結束。

"""#

    static let expectedCustom = #"""
請摘要

# 週會 Weekly sync
- 日期：2026/10/08\#u{2009}06:30
- 長度：1:02:05
- 參與者：Speaker 2、Alice、未知講者
- 來源：https://records.example.com/#/rec/42

## 逐字稿

Alice：大家好we start now
Speaker 2：好的
未知講者：嗯
Alice：結束

"""#

    static let expectedRange = #"""
# 週會 Weekly sync
- 日期：2026/10/08\#u{2009}06:30
- 長度：1:02:05
- 片段：00:04–00:30
- 參與者：Speaker 2、Alice
- 來源：https://records.example.com/#/rec/42

## 逐字稿

[00:04] Alice：We start now
[00:12] Speaker 2：好的。

"""#

    let detail = try! Backend.decoder.decode(Detail.self, from: Data(fixture.utf8))
    let templates = [Named(id: "meeting", name: "會議摘要")]
    let utc = TimeZone(identifier: "UTC")!

    @Test func defaultOptionsMatchWeb() {
        let out = Prompt.build(detail, PromptOptions(), origin: "https://records.example.com", templates: templates, timeZone: utc)
        #expect(out == Self.expectedDefault)
    }

    @Test func customOptionsMatchWeb() {
        let o = PromptOptions(summary: false, transcript: true, ts: false, raw: true, intro: "custom", custom: "  請摘要  ")
        let out = Prompt.build(detail, o, origin: "https://records.example.com", templates: templates, timeZone: utc)
        #expect(out == Self.expectedCustom)
    }

    /// A selected span (web: selected transcript text): no summaries even when enabled, transcript forced on.
    @Test func rangeMatchesWeb() {
        let o = PromptOptions(summary: true, transcript: false, ts: true, raw: false, intro: "none", custom: "")
        let out = Prompt.build(detail, o, origin: "https://records.example.com", templates: templates, range: 1...3, timeZone: utc)
        #expect(out == Self.expectedRange)
    }

    @Test func estimateMatchesWeb() {
        let e = Prompt.estimate(Self.expectedDefault)
        #expect(e.chars == 317 && e.tokens == 151 && !e.warn)
    }

    @Test func helpers() {
        #expect(Prompt.fmtDur(59.9) == "00:59")
        #expect(Prompt.fmtDur(3600) == "1:00:00")
        #expect(Prompt.joinTxt("abc", "def") == "abc def")
        #expect(Prompt.joinTxt("中文", "abc") == "中文abc")
        #expect(Prompt.fileName("a/b:c") == "a_b_c.md")
    }
}
