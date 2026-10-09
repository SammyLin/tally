import ClerkKit
import ClerkKitUI
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
            .modifier(ToastOverlay())
            .environment(app)
            .task { app.uploads.adoptInbox(); app.uploads.kick() } // also adopts recordings left over from a killed session
            .onChange(of: scenePhase) { _, phase in if phase == .active { app.uploads.adoptInbox(); app.uploads.kick() } }
            .onOpenURL { url in if let l = DeepLink(url) { app.link = l } } // tally:// links (web: hash routes)
        }
    }
}

/// First launch / 切換連線方式: two ways to use the same app (web: the landing's 「兩種用法」).
/// Kiroku Cloud (Clerk account, sign up or sign in) or the user's own server (self-hosted, optionally behind Access).
struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var busy = false
    @State private var message: String?
    /// Cloud is reachable but nobody is signed in: offer 註冊 / 登入.
    @State private var cloudChoices = false
    @State private var cloudMode: AuthView.Mode?

    static let compareURL = URL(string: "https://kiroku.3mi.ai/?about#compare")!
    static let setupGuideURL = URL(string: "https://github.com/SammyLin/tally/blob/main/docs/SETUP.md")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        KirokuLockup(size: 44)
                        Text("錄音、逐字稿與摘要，一個地方記下所有對話。")
                            .font(.body)
                            .foregroundStyle(Color(.onChromeMuted))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 48)

                    VStack(spacing: 14) {
                        cloudChoice
                        NavigationLink(value: "selfhost") {
                            ChoiceLabel(title: "連線到自己的伺服器", subtitle: "輸入你架設的 Kiroku 網址", systemImage: "server.rack", primary: false)
                        }
                        .accessibilityIdentifier("connect.selfhost")
                        .disabled(busy)
                    }

                    Link("兩者差別", destination: Self.compareURL)
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("connect.compare")
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .toolbar(.hidden, for: .navigationBar)
            .kirokuNavyScreen() // first screen = the logo: lockup on navy (web: .landing)
            .navigationDestination(for: String.self) { _ in SelfHostConnectView() }
            .sheet(item: $cloudMode) { mode in
                CloudSignIn(mode: mode) { cloudMode = nil; app.cloudSignedIn() } onCancel: { cloudMode = nil }
                    .interactiveDismissDisabled()
            }
        }
    }

    @ViewBuilder private var cloudChoice: some View {
        VStack(spacing: 10) {
            Button(action: connectCloud) {
                ChoiceLabel(title: "使用 Kiroku Cloud", subtitle: "註冊帳號，由我們代管儲存與處理", systemImage: "cloud", primary: true, busy: busy)
            }
            .accessibilityIdentifier("connect.cloud")
            .disabled(busy)
            if cloudChoices {
                HStack(spacing: 10) {
                    Button { cloudMode = .signUp } label: { Text("註冊").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Color(.brandNavy))
                        .accessibilityIdentifier("cloud.signUp")
                    Button { cloudMode = .signIn } label: { Text("登入").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("cloud.signIn")
                }
                .font(.body.weight(.semibold))
            }
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color(.danger))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("connect.error")
            }
        }
    }

    private func connectCloud() {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                if try await app.prepareCloud() { app.cloudSignedIn() } else { cloudChoices = true }
            } catch {
                message = "無法連線到 Kiroku Cloud：\(error.localizedDescription)"
            }
        }
    }
}

/// A full-width choice on the welcome screen: title + one line saying what it means. One primary (seafoam) per screen.
private struct ChoiceLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let primary: Bool
    var busy = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).opacity(0.8)
            }
            Spacer(minLength: 0)
            if busy { ProgressView().tint(primary ? Color(.brandNavy) : nil) } else { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).accessibilityHidden(true) }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 64)
        .foregroundStyle(primary ? Color(.brandNavy) : Color(.brandIvory))
        .background(primary ? Color(.brandSeafoam) : Color(.surface), in: .rect(cornerRadius: 14))
        .overlay { if !primary { RoundedRectangle(cornerRadius: 14).strokeBorder(Color(.onChromeMuted).opacity(0.4)) } }
        .contentShape(.rect(cornerRadius: 14))
    }
}

/// 「連線到自己的伺服器」: the self-hosted URL, and the Cloudflare Access login when the server asks for one.
struct SelfHostConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var busy = false
    @State private var message: String?
    @State private var loginURL: URL?

    var body: some View {
        Form {
            Group {
                Section {
                    TextField("伺服器網址", text: $address, prompt: Text(verbatim: "https://records.example.com").foregroundStyle(Color(.inkMuted)))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(connect)
                        .accessibilityIdentifier("connect.url")
                } header: {
                    Text("伺服器網址")
                } footer: {
                    Text("你自己架設的 Kiroku 網址。若有 Cloudflare Access 保護，下一步會請你登入。")
                }
                if let message {
                    Section { Text(message).foregroundStyle(Color(.danger)).accessibilityIdentifier("connect.error") }
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
                } footer: {
                    Link("還沒有伺服器？自架指南", destination: ConnectView.setupGuideURL)
                        .font(.footnote.weight(.semibold))
                        .padding(.top, 8)
                }
            }
            .kirokuRows()
        }
        .kirokuList()
        .navigationTitle("連線到自己的伺服器").kirokuChrome()
        .toolbar(.visible, for: .navigationBar)
        .kirokuNavyScreen()
        .onAppear {
            // the last self-hosted server, never Kiroku Cloud's own URL
            if address.isEmpty, let u = app.baseURL, u != AppModel.cloudURL { address = u.absoluteString }
        }
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

/// Kiroku Cloud sign-up / sign-in: Clerk's prebuilt AuthView (email code; Apple / Google if enabled on the Clerk instance).
struct CloudSignIn: View {
    var mode: AuthView.Mode = .signIn
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        AuthView(mode: mode, isDismissible: false, onAuthComplete: onDone)
            .environment(Clerk.shared)
            .safeAreaInset(edge: .top) {
                HStack { Button("取消", action: onCancel).accessibilityIdentifier("cloud.cancel"); Spacer() }
                    .padding(.horizontal)
            }
            .kirokuNavyScreen() // web: Clerk mounts inside the navy .landing
    }
}

extension AuthView.Mode: @retroactive Identifiable { public var id: String { rawValue } }
extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct RunnersView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private var data: Runners? { app.runners }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        if let q = data?.queued {
                            Text("排隊中：\(q.recordings) 份錄音、\(q.summaries) 份摘要、\(q.asks ?? 0) 個提問\((q.vocab ?? 0) > 0 ? "、詞彙分析" : "")")
                                .foregroundStyle(Color(.inkMuted))
                        }
                    } footer: {
                        Text("Runner 是在 Mac 上處理轉文字、分辨說話者與摘要的程式。沒有 runner 在線時，新的錄音會排隊，等 runner 上線後自動處理。")
                    }
                    Section {
                        if let runners = data?.runners {
                            if runners.isEmpty { Text("還沒有 runner 連線過。").foregroundStyle(Color(.inkMuted)) }
                            let latest = Self.latestBuild(runners)
                            ForEach(runners, id: \.name) { r in
                                // only an offline runner can be removed; it comes back by itself if it connects again
                                RunnerRow(runner: r, latest: latest, onRemove: r.online || app.cloud ? nil : { Task { await remove(r) } })
                            }
                        } else if let error {
                            Text(error).foregroundStyle(Color(.danger))
                        } else {
                            ProgressView()
                        }
                    }
                }
                .kirokuRows()
            }
            .kirokuList()
            .navigationTitle("Runner 狀態").kirokuChrome()
            .navigationBarTitleDisplayMode(.inline)
            .kirokuToolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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
        do { app.runners = try await app.get("api/runners"); error = nil } catch { self.error = error.localizedDescription }
    }

    private func remove(_ r: Runners.Runner) async {
        do {
            let _: Ignored = try await app.json("DELETE", "api/runners/\(r.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? r.name)")
            app.runners?.runners.removeAll { $0.name == r.name }
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
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            info
            Spacer(minLength: 0)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("移除 \(runner.name)")
                    .accessibilityHint("從清單移除（重新連線時會自動出現）")
                    .accessibilityIdentifier("runner.remove.\(runner.name)")
            }
        }
    }

    private var info: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(runner.online ? Color(.ok) : .gray).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(runner.name).bold()
                    if let stt = runner.stt { Badge(text: stt == "groq" ? "Groq" : "本機 Whisper") }
                    version
                }
                Text(what).font(.subheadline).foregroundStyle(Color(.inkMuted))
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
            .foregroundStyle(error ? AnyShapeStyle(Color(.danger)) : busy ? AnyShapeStyle(Color(.warn)) : AnyShapeStyle(Color(.inkMuted)))
            .background((error ? Color(.danger) : busy ? Color(.warn) : .secondary).opacity(0.12), in: .capsule)
    }
}
