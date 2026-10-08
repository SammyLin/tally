import SwiftUI

@main
struct TallyApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch app.phase {
                case .setup: ConnectView()
                case .main: LibraryView()
                }
            }
            .environment(app)
            .task { app.uploads.kick() } // also adopts recordings left over from a killed session
            .onChange(of: scenePhase) { _, phase in if phase == .active { app.uploads.kick() } }
        }
    }
}

/// First launch / change backend: 「連線到你的 Tally」.
struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var busy = false
    @State private var message: String?
    @State private var loginURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://records.example.com", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(connect)
                        .accessibilityIdentifier("connect.url")
                } header: {
                    Text("後端網址")
                } footer: {
                    Text("你自己架設的 Tally（Cloudflare Worker）網址。若有 Cloudflare Access 保護，下一步會請你登入。")
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("connect.error") }
                }
                Section {
                    Button(action: connect) {
                        HStack {
                            Text("連線")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("connect.submit")
                    .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("連線到你的 Tally")
            .onAppear { if address.isEmpty { address = app.baseURL?.absoluteString ?? AppModel.defaultBackend } }
            .sheet(item: $loginURL) { url in
                LoginView(url: url) { jwt in
                    loginURL = nil
                    Task { await verify(url, token: jwt) }
                } onCancel: {
                    loginURL = nil
                }
                .interactiveDismissDisabled()
            }
        }
    }

    private func connect() {
        guard let url = AppModel.normalize(address) else { message = "網址格式不正確"; return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                switch try await app.probe(url) {
                case .ok: app.connected(to: url)
                case .login: loginURL = url
                }
            } catch {
                message = "無法連線：\(error.localizedDescription)"
            }
        }
    }

    private func verify(_ url: URL, token: String) async {
        busy = true
        defer { busy = false }
        do {
            let _: Templates = try await Backend(base: url, token: token, extraHeaders: app.extraHeaders).get("api/templates")
            app.loggedIn(token: token, for: url)
        } catch {
            message = "登入後仍無法存取：\(error.localizedDescription)"
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmChange = false

    var body: some View {
        NavigationStack {
            Form {
                Section("後端") {
                    LabeledContent("網址", value: app.baseURL?.absoluteString ?? "—")
                    LabeledContent("登入", value: app.token != nil ? "Cloudflare Access" : (app.extraHeaders.isEmpty ? "不需要登入" : "Service token（測試）"))
                    Button("變更後端…") { confirmChange = true }
                    if app.token != nil {
                        Button("登出", role: .destructive) { Task { await app.logout(); dismiss() } }
                    }
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
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("變更後端會登出目前的帳號。尚未上傳的錄音會上傳到新的後端。", isPresented: $confirmChange, titleVisibility: .visible) {
                Button("變更後端", role: .destructive) { Task { await app.changeBackend() } }
            }
        }
    }
}

struct RunnersView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var data: Runners?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let q = data?.queued {
                        Text("排隊中：\(q.recordings) 份錄音、\(q.summaries) 份摘要、\(q.asks ?? 0) 個提問\((q.vocab ?? 0) > 0 ? "、詞彙分析" : "")")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Runner 是在 Mac 上處理轉文字、分辨說話者與摘要的程式。沒有 runner 在線時，新的錄音會排隊，等 runner 上線後自動處理。")
                }
                Section {
                    if let runners = data?.runners {
                        if runners.isEmpty { Text("還沒有 runner 連線過。").foregroundStyle(.secondary) }
                        let latest = Self.latestBuild(runners)
                        ForEach(runners, id: \.name) { r in
                            RunnerRow(runner: r, latest: latest)
                                .swipeActions {
                                    if !r.online {
                                        Button("移除", role: .destructive) { Task { await remove(r) } }
                                    }
                                }
                        }
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Runner 狀態")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .refreshable { await load() }
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }

    private func load() async {
        do { data = try await app.get("api/runners"); error = nil } catch { self.error = error.localizedDescription }
    }

    private func remove(_ r: Runners.Runner) async {
        do {
            let _: Ignored = try await app.json("DELETE", "api/runners/\(r.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? r.name)")
            data?.runners.removeAll { $0.name == r.name }
        } catch { self.error = error.localizedDescription }
    }

    /// Newest build among runners seen in the last week; older ones are flagged.
    static func latestBuild(_ rs: [Runners.Runner]) -> String? {
        rs.filter { $0.agoS < 7 * 86400 }.compactMap(\.versionTime).max()
    }
}

private struct RunnerRow: View {
    let runner: Runners.Runner
    let latest: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(runner.online ? .green : .gray).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(runner.name).bold()
                    if let stt = runner.stt { Badge(text: stt == "groq" ? "Groq" : "本機 Whisper") }
                    version
                }
                Text(what).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(runner.name)，\(runner.online ? "在線" : "離線")，\(what)")
    }

    @ViewBuilder private var version: some View {
        if let v = runner.version {
            let old = latest != nil && runner.versionTime != nil && runner.versionTime! < latest!
            Badge(text: (old ? "需要更新 · " : "") + v, busy: old)
        } else {
            Badge(text: "版本未知（舊版）", busy: true)
        }
    }

    private var what: String {
        guard runner.online else { return "離線 · 最後連線 " + Self.ago(runner.agoS) }
        guard let j = runner.job else { return "閒置，等待工作" }
        switch j.kind {
        case "recording": return "處理中：#\(j.id)「\(j.title ?? "")」· \(Status.label(j.status ?? ""))"
        case "ask": return "回答提問：「\(j.title ?? "")」"
        case "vocab": return "分析詞彙"
        default: return "產生摘要：#\(j.recordingId ?? 0)「\(j.title ?? "")」"
        }
    }

    static func ago(_ s: Int) -> String {
        s < 60 ? "剛剛" : s < 3600 ? "\(s / 60) 分鐘前" : s < 86400 ? "\(s / 3600) 小時前" : "\(s / 86400) 天前"
    }
}

struct Badge: View {
    let text: String
    var busy = false
    var error = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(error ? .red : busy ? .orange : .secondary)
            .background((error ? Color.red : busy ? .orange : .secondary).opacity(0.12), in: .capsule)
    }
}
