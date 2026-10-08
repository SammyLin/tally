import SwiftUI
import UIKit

/// Citations in an Ask answer: [[id@mm:ss]] / [[id@h:mm:ss]], several may share one bracket (web: renderAnswer).
nonisolated enum Cite {
    nonisolated(unsafe) static let bracket = /\[\[([^\]]+)\]\]/
    nonisolated(unsafe) static let part = /(\d+)\s*@\s*(\d+(?::\d{1,2}){1,2})/

    /// (recording id, ms) for each citation in one bracket's inner text.
    static func parse(_ inner: Substring) -> [(id: Int, ms: Int)] {
        inner.matches(of: part).compactMap { m in
            guard let id = Int(m.1) else { return nil }
            return (id, m.2.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) } * 1000)
        }
    }

    /// Rewrites citations as Markdown links tally://rec/<id>?ms=<ms> labelled 「title mm:ss」 (「錄音 #id」 when unknown).
    /// Within a line, a citation of the same recording as the one before it shows the time only (web: short chips).
    static func linkify(_ md: String, titles: [Int: String]) -> String {
        md.components(separatedBy: "\n").map { line in
            var last: Int?
            return line.replacing(bracket) { m in
                let cites = parse(m.1)
                if cites.isEmpty { return String(m.0) }
                return cites.map { c in
                    let t = Prompt.fmtDur(Double(c.ms) / 1000)
                    let label = last == c.id ? t : "\(titles[c.id] ?? "錄音 #\(c.id)") \(t)"
                    last = c.id
                    return "[\(escape(label))](tally://rec/\(c.id)?ms=\(c.ms))"
                }.joined(separator: " ")
            }.replacing(/(\(tally:\/\/rec\/[^)]*\))\[/) { "\($0.1) [" } // adjacent brackets: keep chips apart
        }.joined(separator: "\n")
    }

    private static func escape(_ s: String) -> String {
        s.replacing(/[\[\]\\*_`]/) { "\\" + $0.0 }
    }

    /// tally://rec/<id>?ms=<ms> → (id, ms).
    static func target(_ url: URL) -> (id: Int, ms: Int?)? {
        guard url.scheme == "tally", url.host() == "rec", let id = Int(url.lastPathComponent) else { return nil }
        let ms = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ms" }?.value.flatMap(Int.init)
        return (id, ms)
    }
}

enum AskRoute: Hashable {
    case ask(Int)
    case recording(Int, ms: Int?)
}

/// 問問看: questions across every recording, answered by a runner with citations (web: #/ask).
struct AskView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AskRoute] = []
    @State private var asks: [Ask]?
    @State private var error: String?
    @State private var question = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    static let examples = ["志明上個月答應了什麼？", "客戶在哪幾場會議提過價格？"]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    Section {
                        TextField("問所有錄音，例如：" + Self.examples[0], text: $question, axis: .vertical)
                            .lineLimit(2...6)
                            .focused($focused)
                            .submitLabel(.send)
                            .onChange(of: question) { _, q in
                                // Return sends (web: Enter); a vertical TextField inserts it as a newline
                                if q.contains("\n") { question = q.replacing("\n", with: ""); send() }
                                else if q.count > 1000 { question = String(q.prefix(1000)) }
                            }
                            .accessibilityLabel("問題")
                            .accessibilityIdentifier("ask.input")
                        Button(action: send) {
                            HStack { Text("送出"); if sending { Spacer(); ProgressView() } }
                        }
                        .disabled(sending || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ask.send")
                    } footer: {
                        Text("會先找出相關錄音，再讀逐字稿回答，每句都附出處。")
                    }
                    Section("試試") {
                        ForEach(Self.examples, id: \.self) { q in
                            Button(q) { question = q; focused = true }
                        }
                    }
                    Section {
                        if let asks {
                            if asks.isEmpty { Text("還沒有提問").foregroundStyle(Color(.inkMuted)).accessibilityIdentifier("ask.empty") }
                            ForEach(asks) { a in
                                NavigationLink(value: AskRoute.ask(a.id)) { AskRow(ask: a) }
                                    .accessibilityIdentifier("ask.\(a.id)")
                            }
                        } else if let error {
                            Text("無法載入：\(error)").foregroundStyle(Color(.danger))
                            Button("重試") { Task { await load() } }
                        } else {
                            ProgressView()
                        }
                    } header: {
                        if let n = asks?.count, n > 0 { Text("\(n) 筆") }
                    }
                }
                .kirokuRows()
            }
            .kirokuList()
            .navigationTitle("問問看").kirokuChrome()
            .navigationBarTitleDisplayMode(.inline)
            .kirokuToolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .refreshable { await load() }
            .task(id: path.isEmpty) {
                guard path.isEmpty else { return }
                while !Task.isCancelled {
                    await load()
                    // poll while a question is being answered (web: every 3 s)
                    try? await Task.sleep(for: .seconds(asks?.contains { Status.busy($0.status) } == true ? 3 : 30))
                }
            }
            .navigationDestination(for: AskRoute.self) { route in
                switch route {
                case .ask(let id): AskDetailView(id: id)
                case .recording(let id, let ms): DetailView(id: id, seekMs: ms)
                }
            }
        }
        .modifier(ToastOverlay())
        .onAppear(perform: openLink)
        .onChange(of: app.link) { openLink() }
    }

    /// tally://ask[/<id>]: the list, or that question on top of it.
    private func openLink() {
        guard case .ask(let id) = app.link else { return }
        app.link = nil
        path = id.map { [.ask($0)] } ?? []
    }

    private func load() async {
        do { asks = try await app.get("api/asks"); error = nil }
        catch is CancellationError {}
        catch let e as URLError where e.code == .cancelled {}
        catch { self.error = error.localizedDescription }
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !sending else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                struct Created: Decodable { var id: Int }
                let r: Created = try await app.json("POST", "api/asks", ["question": q])
                question = ""
                focused = false
                path.append(.ask(r.id))
            } catch { app.fail(error) }
        }
    }
}

private struct AskRow: View {
    let ask: Ask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ask.question).font(.headline).lineLimit(2)
            if let p = ask.preview, !p.isEmpty { Text(p).font(.subheadline).foregroundStyle(Color(.inkMuted)).lineLimit(2) }
            HStack(spacing: 8) {
                Text(Prompt.fmtShort(ask.createdAt))
                if ask.status != "done" {
                    Badge(text: Ask.statusLabels[ask.status] ?? ask.status, busy: ask.status != "error", error: ask.status == "error")
                }
            }
            .font(.caption).foregroundStyle(Color(.inkMuted))
        }
        .accessibilityElement(children: .combine)
    }
}

/// One question: waiting / failed (重試) / the answer with citation links and 參考錄音.
struct AskDetailView: View {
    let id: Int

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var ask: Ask?
    @State private var notFound = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var citation: Citation?

    struct Citation: Hashable { var id: Int; var ms: Int? }

    var body: some View {
        Group {
            if let ask { content(ask) }
            else if notFound { ContentUnavailableView("找不到這個提問。", systemImage: "questionmark.bubble") }
            else if let error {
                ContentUnavailableView {
                    Label("無法載入", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("重試") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
            } else { ProgressView() }
        }
        .navigationTitle("問問看").kirokuChrome()
        .navigationBarTitleDisplayMode(.inline)
        .kirokuToolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let md = ask?.answerMd {
                    Button { UIPasteboard.general.string = md; app.toast = "已複製" } label: { Label("複製回答", systemImage: "doc.on.doc") }
                        .accessibilityIdentifier("ask.copy")
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("刪除提問", systemImage: "trash") }
                    .accessibilityIdentifier("ask.delete")
                    .disabled(ask == nil)
            }
        }
        .navigationDestination(item: $citation) { c in DetailView(id: c.id, seekMs: c.ms) } // opens there, plays from that time
        .alert("刪除這個提問？", isPresented: $confirmDelete) {
            Button("刪除", role: .destructive) { Task { await delete() } }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(ask.map { Status.busy($0.status) } == true ? 3 : 60))
            }
        }
    }

    @ViewBuilder private func content(_ a: Ask) -> some View {
        let titles = Dictionary((a.recordings ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { x, _ in x })
        List {
            Group {
                Section {
                    Text(a.question).font(.headline).accessibilityIdentifier("ask.question")
                    Text(Prompt.fmtDate(a.createdAt)).font(.caption).foregroundStyle(Color(.inkMuted))
                }
                Section {
                    switch a.status {
                    case "queued": Label(app.queuedText, systemImage: "hourglass").foregroundStyle(Color(.warn))
                    case "running": Label("思考中：正在找出相關錄音、閱讀逐字稿…", systemImage: "hourglass").foregroundStyle(Color(.warn))
                    case "error":
                        Text("回答失敗：\(a.error ?? "未知錯誤")").foregroundStyle(Color(.danger))
                        Button("重試") { Task { await retry() } }.accessibilityIdentifier("ask.retry")
                    default:
                        MarkdownView(markdown: Cite.linkify(a.answerMd ?? "", titles: titles))
                            .accessibilityIdentifier("ask.answer")
                    }
                }
                // sources still in the database (purged ones are absent from `recordings`)
                let used = a.status == "done" ? (a.sources ?? []).filter { titles[$0] != nil } : []
                if !used.isEmpty {
                    Section("參考錄音") {
                        ForEach(used, id: \.self) { rid in
                            NavigationLink(value: AskRoute.recording(rid, ms: nil)) {
                                Label(titles[rid] ?? "錄音 #\(rid)", systemImage: "waveform")
                            }
                            .accessibilityIdentifier("ask.source.\(rid)")
                        }
                    }
                }
            }
            .kirokuRows()
        }
        .kirokuList()
        .environment(\.openURL, OpenURLAction { url in
            guard let t = Cite.target(url) else { return .systemAction }
            citation = Citation(id: t.id, ms: t.ms)
            return .handled
        })
    }

    private func load() async {
        do { ask = try await app.get("api/asks/\(id)"); notFound = false; error = nil }
        catch is CancellationError {}
        catch let e as URLError where e.code == .cancelled {}
        catch APIError.http(404, _) { ask = nil; notFound = true }
        catch { if ask == nil { self.error = error.localizedDescription } }
    }

    private func retry() async {
        do { let _: Ignored = try await app.json("POST", "api/asks/\(id)/retry"); await load() }
        catch { app.fail(error) }
    }

    private func delete() async {
        do { let _: Ignored = try await app.json("DELETE", "api/asks/\(id)"); dismiss() }
        catch { app.fail(error) }
    }
}
