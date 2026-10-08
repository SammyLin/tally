import Foundation
import Testing
@testable import Tally

struct CiteTests {
    @Test func parsesMinutesHoursAndSharedBrackets() {
        let c = Cite.parse("3@01:05, 4 @ 1:02:03")
        #expect(c.map(\.id) == [3, 4])
        #expect(c.map(\.ms) == [65_000, 3_723_000])
        #expect(Cite.parse("not a cite").isEmpty)
    }

    @Test func linkifyUsesTitlesAndShortensRepeats() {
        let md = "價格談過 [[3@01:05]][[3@02:00]]，另見 [[9@00:10]]\n下一行 [[3@00:01]] [[x]]"
        let out = Cite.linkify(md, titles: [3: "週會 [A]"])
        #expect(out == "價格談過 [週會 \\[A\\] 01:05](tally://rec/3?ms=65000) [02:00](tally://rec/3?ms=120000)，另見 [錄音 #9 00:10](tally://rec/9?ms=10000)\n下一行 [週會 \\[A\\] 00:01](tally://rec/3?ms=1000) [[x]]")
    }

    @Test func linkTargets() {
        let t = Cite.target(URL(string: "tally://rec/12?ms=5000")!)
        #expect(t?.id == 12 && t?.ms == 5000)
        #expect(Cite.target(URL(string: "tally://rec/12")!)?.ms == nil)
        #expect(Cite.target(URL(string: "https://example.com/rec/12")!) == nil)
    }
}

struct VocabTests {
    @Test func addSplitsDedupesAndLimits() {
        var list = ["Tally"]
        #expect(Vocab.add("Groq, Tally，Whisper、 ,sherpa", to: &list) == nil)
        #expect(list == ["Tally", "Groq", "Whisper", "sherpa"])
        #expect(Vocab.add(String(repeating: "長", count: 51), to: &list)?.hasSuffix("超過 50 字") == true)
        var full = (0..<200).map { "w\($0)" }
        #expect(Vocab.add("one more", to: &full) == "詞彙最多 200 個")
        #expect(full.count == 200)
    }

    /// Reference values from the web's sttVocabFit (node, same inputs).
    @Test func fitMatchesTheWeb() {
        #expect(Vocab.tokens(Vocab.zhPrompt) == 33)
        let zh = (0..<60).map { "詞彙\($0)" }, en = (0..<120).map { "Term\($0)" }
        #expect(Vocab.fit(lang: "zh", vocab: zh) == 48)
        #expect(Vocab.fit(lang: "en", vocab: zh) == 58)
        #expect(Vocab.fit(lang: "zh", vocab: en) == 68)
        #expect(Vocab.fit(lang: "ja", vocab: en) == 81)
        #expect(Vocab.hint(lang: "zh", vocab: []) == "用於語音辨識、逐字稿整理與摘要。沒有詞彙就不使用。")
        #expect(Vocab.hint(lang: "zh", vocab: ["a", "b"]) == "2 個詞都會送進語音辨識")
        #expect(Vocab.hint(lang: "zh", vocab: zh) == "前 48 個詞會送進語音辨識，其餘 12 個只用於整理與摘要")
    }
}

struct SettingsModelTests {
    @Test func decodesWithDefaultsAndSendsNullMe() throws {
        let s = try Backend.decoder.decode(AppSettings.self, from: Data(#"{"stt_lang":"en","content_focus":"重點","me":7}"#.utf8))
        #expect(s.sttLang == "en" && s.contentFocus == "重點" && s.me == 7 && s.cleanup && s.vocab.isEmpty)
        #expect(s.summaryLang == "en")
        var t = s
        t.me = nil
        t.sttLang = "auto"
        #expect(t.summaryLang == "zh-TW")
        let body = t.body
        #expect(body.keys.count == 8)
        #expect(body["me"]! == nil) // present, null: PUT clears 我是誰
    }

    @Test func meMarker() {
        let sp = Speaker(id: 1, label: nil, displayName: "王小明", personId: 4, auto: nil, suggest: nil)
        #expect(sp.isMe(4))
        #expect(!sp.isMe(nil))
        #expect(!Speaker(id: 2, label: nil, displayName: "x", personId: nil, auto: nil, suggest: nil).isMe(nil))
    }

    @Test func decodesAskDetail() throws {
        let json = #"{"id":2,"question":"Q","status":"done","created_at":"2026-10-08 01:00:00","answer_md":"A [[1@00:05]]","error":null,"sources":[1],"recordings":[{"id":1,"title":"會議","deleted":0}]}"#
        let a = try Backend.decoder.decode(Ask.self, from: Data(json.utf8))
        #expect(a.sources == [1] && a.recordings?.first?.title == "會議" && a.preview == nil)
    }
}
