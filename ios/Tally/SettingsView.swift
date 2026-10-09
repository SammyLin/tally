import ClerkKit
import SwiftUI
import UIKit

/// Vocabulary editing rules (web: addVocab / sttVocabFit / vocabHint).
nonisolated enum Vocab {
    static let maxTerms = 200
    static let maxLength = 50
    static let separators: Set<Character> = [",", "，", "、", "\n"]

    /// Adds every term in `text` (split on , ， 、 newline); returns an error message for the first rejected term.
    static func add(_ text: String, to list: inout [String]) -> String? {
        var message: String?
        for w in text.split(whereSeparator: { separators.contains($0) }).map({ $0.trimmingCharacters(in: .whitespaces) }) where !w.isEmpty {
            if w.unicodeScalars.count > maxLength { message = message ?? "「\(w.prefix(20))…」超過 50 字"; continue }
            if list.contains(w) { continue }
            if list.count >= maxTerms { return message ?? "詞彙最多 200 個" }
            list.append(w)
        }
        return message
    }

    /// Mirrors the runner's sttPrompt: 1 token per non-ASCII rune + ceil(ASCII chars / 4).
    static func tokens(_ s: String) -> Int {
        let ascii = s.unicodeScalars.filter(\.isASCII).count
        return s.unicodeScalars.count - ascii + (ascii + 3) / 4
    }

    static let zhPrompt = "好，那我們開始今天的會議。這一季的 roadmap 跟 API 進度，大家有什麼想法？"

    /// How many terms fit in the 200-token speech-recognition prompt (zh starts with an example sentence; terms joined by 、).
    static func fit(lang: String, vocab: [String]) -> Int {
        var p = lang == "zh" ? zhPrompt : "", n = 0
        for w in vocab {
            let q = p + (n > 0 ? "、" : "") + w
            if tokens(q) > 200 { break }
            p = q
            n += 1
        }
        return n
    }

    static func hint(lang: String, vocab: [String]) -> String {
        let m = vocab.count, n = fit(lang: lang, vocab: vocab)
        if m == 0 { return "用於語音辨識、逐字稿整理與摘要。沒有詞彙就不使用。" }
        return n == m ? "\(m) 個詞都會送進語音辨識" : "前 \(n) 個詞會送進語音辨識，其餘 \(m - n) 個只用於整理與摘要"
    }
}

/// Settings (web: setDlg): AI, 語言與逐字稿, 講者, 詞彙 — saved together with 儲存; people and suggestions act at once.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var saved: AppSettings?
    @State private var draft = AppSettings()
    @State private var loadError: String?
    @State private var persons: [Person] = []
    @State private var personsError: String?
    @State private var suggestions: VocabSuggestions?
    @State private var vocabInput = ""
    @State private var message: String?
    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var confirmChange = false
    @State private var renaming: Person?
    @State private var newName = ""
    @State private var merging: (person: Person, name: String)?
    @State private var deleting: Person?
    @State private var showIntro = false

    private var dirty: Bool {
        saved.map { draft != $0 } == true || !vocabInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            personAlerts(form)
                .navigationTitle("設定").kirokuChrome()
                .navigationBarTitleDisplayMode(.inline)
                .kirokuToolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("關閉") { if dirty { confirmDiscard = true } else { dismiss() } }
                            .accessibilityIdentifier("settings.close")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                            .accessibilityIdentifier("keyboard.done")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("儲存") { Task { await save() } }
                            .disabled(saved == nil || saving)
                            .accessibilityIdentifier("settings.save")
                    }
                }
                .alert("有未儲存的變更", isPresented: $confirmDiscard) {
                    Button("放棄", role: .destructive) { dismiss() }
                    Button("繼續編輯", role: .cancel) {}
                }
                .alert("切換連線方式", isPresented: $confirmChange) {
                    Button("切換", role: .destructive) { Task { await app.changeBackend() } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(Self.switchMessage(pending: app.uploads.items.count))
                }
                .fullScreenCover(isPresented: $showIntro) { IntroView { showIntro = false } }
                .task { await load() }
                .task {
                    // poll while a vocabulary scan runs (web: every 5 s)
                    while !Task.isCancelled {
                        await loadSuggestions()
                        try? await Task.sleep(for: .seconds(suggestions?.scanning == true ? 5 : 60))
                    }
                }
        }
        .interactiveDismissDisabled(dirty)
        .modifier(ToastOverlay())
    }

    private var form: some View {
        Form {
            Group {
                if let message {
                    Section { Text(message).foregroundStyle(Color(.danger)).accessibilityIdentifier("settings.error") }
                }
                if saved != nil {
                    aiSection
                    languageSection
                    speakerSection
                    vocabSection
                    Section {} footer: { Text("設定只影響之後的新工作；既有錄音可重新轉錄或重新產生摘要。") }
                } else if let loadError {
                    Section {
                        Text("無法載入設定：\(loadError)").foregroundStyle(Color(.danger))
                        Button("重試") { Task { await load() } }
                    }
                } else {
                    Section { ProgressView() }
                }
                backendSections
            }
            .kirokuRows()
        }
        .kirokuList()
        .scrollDismissesKeyboard(.immediately)
    }

    private func personAlerts(_ content: some View) -> some View {
        content
            .alert("重新命名講者", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { p in
                TextField("名稱", text: $newName).accessibilityIdentifier("person.name")
                Button("取消", role: .cancel) {}
                Button("確定") {
                    let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !n.isEmpty, n != p.name { Task { await renamePerson(p, to: n, merge: false) } }
                }
            }
            .alert(merging.map { "「\($0.name)」已存在，要合併嗎？" } ?? "", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }),
                   presenting: merging) { m in
                Button("取消", role: .cancel) {}
                Button("合併") { Task { await renamePerson(m.person, to: m.name, merge: true) } }
            }
            .alert(deleting.map { "刪除「\($0.name)」？\($0.prints ?? 0) 個聲紋會一併刪除" } ?? "",
                   isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { p in
                Button("刪除", role: .destructive) { Task { await deletePerson(p) } }
            }
    }

    // MARK: Sections

    private var aiSection: some View {
        Section {
            textArea("關於我", text: $draft.about, prompt: "職稱、領域、錄音用途", id: "settings.about")
            textArea("內容重點", text: $draft.contentFocus, id: "settings.focus")
            textArea("自訂指示", text: $draft.instructions, id: "settings.instructions")
        } header: { Text("AI") } footer: { Text("只用於產生摘要。") }
    }

    private func textArea(_ label: String, text: Binding<String>, prompt: String = "", id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Color(.inkMuted))
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(2...6)
                .onChange(of: text.wrappedValue) { _, v in if v.count > 500 { text.wrappedValue = String(v.prefix(500)) } }
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
        }
    }

    private var languageSection: some View {
        Section("語言與逐字稿") {
            Picker("預設轉錄語言", selection: $draft.sttLang) {
                ForEach(STTLang.all, id: \.id) { Text($0.name).tag($0.id) }
            }
            .accessibilityIdentifier("settings.sttLang")
            Toggle("自動整理逐字稿（錯字、標點）", isOn: $draft.cleanup).accessibilityIdentifier("settings.cleanup")
        }
    }

    private var speakerSection: some View {
        Section {
            Toggle("依聲紋自動標記講者", isOn: $draft.autoLabel).accessibilityIdentifier("settings.autoLabel")
            Picker("我是誰", selection: $draft.me) {
                Text("（未設定）").tag(Int?.none)
                ForEach(persons) { Text($0.name).tag(Int?.some($0.id)) }
            }
            .accessibilityIdentifier("settings.me")
            if let personsError {
                Text("無法載入講者：\(personsError)").foregroundStyle(Color(.inkMuted))
            } else if persons.isEmpty {
                Text("還沒有講者。在逐字稿中為講者命名後會出現在這裡。").foregroundStyle(Color(.inkMuted))
            }
            ForEach(persons) { p in personRow(p) }
        } header: {
            Text("講者")
        } footer: {
            Text("講者的改名、刪除立即生效。")
        }
    }

    private func personRow(_ p: Person) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(p.name)
                    if p.id == saved?.me { Text("（我）").foregroundStyle(Color(.inkMuted)) }
                }
                Text(["\(p.prints ?? 0) 個聲紋", (p.speakers ?? 0) > 0 ? "\(p.speakers!) 位講者" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Color(.inkMuted))
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("改名") { newName = p.name; renaming = p }
                .accessibilityLabel("改名「\(p.name)」")
            Button("刪除", role: .destructive) { deleting = p }
                .accessibilityLabel("刪除「\(p.name)」")
        }
        .buttonStyle(.borderless)
    }

    private var vocabSection: some View {
        Section {
            if let sug = suggestions {
                VStack(alignment: .leading, spacing: 2) {
                    Text("建議加入（加入、忽略立即生效）").font(.caption).foregroundStyle(Color(.inkMuted))
                    if sug.suggestions.isEmpty {
                        Text("還沒有建議。累積更多錄音後會自動分析。").foregroundStyle(Color(.inkMuted))
                    }
                }
                ForEach(sug.suggestions, id: \.term) { s in suggestionRow(s) }
                scanStatus(sug)
            }
            ForEach(draft.vocab, id: \.self) { w in
                HStack {
                    Text(w)
                    Spacer()
                    Button { draft.vocab.removeAll { $0 == w } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(.inkMuted)) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除 \(w)")
                }
            }
            TextField("專有名詞，Return 或逗號加入", text: $vocabInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit { if addVocab(vocabInput) { vocabInput = "" } }
                .onChange(of: vocabInput) { _, v in
                    // a typed separator commits what is before it (web: input handler)
                    guard let i = v.lastIndex(where: { Vocab.separators.contains($0) }) else { return }
                    addVocab(String(v[..<i]))
                    vocabInput = String(v[v.index(after: i)...])
                }
                .accessibilityLabel("新增詞彙")
                .accessibilityIdentifier("vocab.input")
        } header: {
            Text("詞彙")
        } footer: {
            Text(Vocab.hint(lang: draft.sttLang, vocab: draft.vocab)).accessibilityIdentifier("vocab.hint")
        }
    }

    private func suggestionRow(_ s: VocabSuggestions.Suggestion) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.term).bold()
                Text(["出現 \(s.hits) 次", "\(s.recordings) 份錄音",
                      s.misheard.isEmpty ? nil : "曾被聽成「\(s.misheard.prefix(3).joined(separator: "」「"))」"].compactMap { $0 }.joined(separator: "・"))
                    .font(.caption).foregroundStyle(Color(.inkMuted))
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("加入") { Task { await suggestion(s, add: true) } }.accessibilityLabel("加入「\(s.term)」")
            Button("忽略") { Task { await suggestion(s, add: false) } }.accessibilityLabel("忽略「\(s.term)」").foregroundStyle(Color(.inkMuted))
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func scanStatus(_ sug: VocabSuggestions) -> some View {
        let l = sug.lastScan
        let status = sug.scanning ? "分析中…"
            : l?.status == "error" ? "上次分析失敗：\(l?.error ?? "")"
            : l?.at.map { "上次分析：\(Prompt.fmtDate($0))" }
        if status != nil || (!sug.scanning && sug.pending > 0) {
            HStack {
                if let status { Text(status).font(.caption).foregroundStyle(Color(.inkMuted)).accessibilityIdentifier("vocab.scan") }
                Spacer()
                if !sug.scanning && sug.pending > 0 {
                    Button("立即分析") { Task { await scanNow() } }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var backendSections: some View {
        Section("連線方式") {
            LabeledContent("目前使用", value: app.cloud ? "Kiroku Cloud" : "自己的伺服器")
                .accessibilityIdentifier("settings.mode")
            if app.cloud {
                LabeledContent("帳號", value: Clerk.shared.user?.primaryEmailAddress?.emailAddress ?? "—")
            } else {
                LabeledContent("網址", value: app.baseURL?.absoluteString ?? "—")
                LabeledContent("登入", value: app.token != nil ? "Cloudflare Access" : (app.extraHeaders.isEmpty ? "不需要登入" : "Service token（測試）"))
            }
            Button("切換連線方式…") { confirmChange = true }
                .accessibilityIdentifier("settings.switchMode")
        }
        if app.token != nil || app.cloud {
            Section { Button("登出", role: .destructive) { Task { await app.logout(); dismiss() } } }
        }
        Section {
            LabeledContent("等待上傳", value: "\(app.uploads.items.count)")
            if !app.uploads.items.isEmpty { Button("立即重試上傳") { app.uploads.retryNow() } }
        } header: {
            Text("上傳")
        } footer: {
            Text("錄音會保留在手機上，直到上傳完成。")
        }
        Section {
            Button("再看一次介紹") { showIntro = true }
                .accessibilityIdentifier("settings.intro")
            LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        }
    }

    /// Cloud and a self-hosted server are separate places: switching moves nothing (the upload queue follows the new connection).
    static func switchMessage(pending: Int) -> String {
        "Kiroku Cloud 和自己的伺服器是兩個獨立的地方，切換不會搬移任何錄音、逐字稿、聲紋或設定。原本的資料留在原處，切回來就看得到。"
            + (pending > 0 ? "\n\n還有 \(pending) 段錄音尚未上傳，切換後會上傳到新的連線。" : "")
    }

    // MARK: Actions

    private func load() async {
        do {
            let loaded: AppSettings = try await app.get("api/settings")
            saved = loaded
            draft = loaded
            app.settings = loaded
            loadError = nil
        } catch is CancellationError {
        } catch { loadError = error.localizedDescription }
        await loadPersons()
    }

    private func loadPersons() async {
        do { persons = try await app.get("api/persons"); personsError = nil }
        catch is CancellationError {}
        catch { persons = []; personsError = error.localizedDescription }
    }

    private func loadSuggestions() async {
        suggestions = try? await app.get("api/vocab/suggestions") // an old Worker has no suggestions: hide them
    }

    /// false (and `message` set) when a word was rejected; callers keep the input so it is not lost.
    @discardableResult
    private func addVocab(_ text: String) -> Bool {
        guard let m = Vocab.add(text, to: &draft.vocab) else { return true }
        message = m
        return false
    }

    private func save() async {
        guard addVocab(vocabInput) else { return } // keep the word and the sheet open so the error is seen
        vocabInput = ""
        saving = true
        message = nil
        defer { saving = false }
        do {
            let s: AppSettings = try await app.json("PUT", "api/settings", draft.body)
            saved = s
            draft = s
            app.settings = s
            app.toast = "已儲存設定"
            dismiss()
        } catch { message = "無法儲存：\(error.localizedDescription)" }
    }

    /// After a rename / merge / delete: a merge or delete can move or clear `me` (web: personsChanged).
    private func personsChanged(_ list: [Person]? = nil) async {
        if let list { persons = list } else { await loadPersons() }
        if let s: AppSettings = try? await app.get("api/settings") {
            saved?.me = s.me
            app.settings.me = s.me
        }
        if let me = draft.me, !persons.contains(where: { $0.id == me }) { draft.me = saved?.me }
    }

    private func renamePerson(_ p: Person, to name: String, merge: Bool) async {
        message = nil
        do {
            let body: [String: Any?] = merge ? ["name": name, "merge": true] : ["name": name]
            let list: [Person] = try await app.json("PATCH", "api/persons/\(p.id)", body)
            await personsChanged(list)
        } catch APIError.http(409, _) where !merge {
            merging = (p, name)
        } catch { message = error.localizedDescription }
    }

    private func deletePerson(_ p: Person) async {
        message = nil
        do {
            let _: Ignored = try await app.json("DELETE", "api/persons/\(p.id)")
            await personsChanged()
        } catch { message = error.localizedDescription }
    }

    /// 加入 also lands in the editor without touching other unsaved edits; 忽略 just hides it.
    private func suggestion(_ s: VocabSuggestions.Suggestion, add: Bool) async {
        message = nil
        do {
            if add {
                let set: AppSettings = try await app.json("POST", "api/vocab/suggestions/add", ["term": s.term])
                saved = set
                app.settings = set
                if !draft.vocab.contains(s.term) { draft.vocab.append(s.term) }
            } else {
                let _: Ignored = try await app.json("POST", "api/vocab/suggestions/dismiss", ["term": s.term])
            }
            suggestions?.suggestions.removeAll { $0.term == s.term }
        } catch { message = error.localizedDescription }
    }

    private func scanNow() async {
        message = nil
        do { let _: Ignored = try await app.json("POST", "api/vocab/scan") } catch { message = error.localizedDescription }
        await loadSuggestions()
    }
}
