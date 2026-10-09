import ClerkKit
import Foundation
import Observation
import Security
import WebKit

/// App-wide state: which backend, the Access token, and the shared recorder / upload queue.
@Observable final class AppModel {
    enum Phase { case setup, main }

    /// Kiroku Cloud (multi-user, Clerk sign-in). DEBUG runs can point it elsewhere with `-cloudURL http://127.0.0.1:8800`.
    static var cloudURL: URL { UserDefaults.standard.string(forKey: "cloudURL").flatMap(URL.init(string:)) ?? URL(string: "https://kiroku.3mi.ai")! }

    var phase: Phase
    var baseURL: URL?
    private(set) var token: String?
    /// Signed in to Kiroku Cloud with Clerk: requests carry `Authorization: Bearer <session token>` instead of `cf-access-token`.
    private(set) var cloud = UserDefaults.standard.string(forKey: "backendMode") == "cloud"
    /// Access said our token is missing or expired; the UI shows the login screen.
    var needsLogin = false
    var extraHeaders: [String: String] = [:]
    /// App-wide toast (web: toast()); shown over every screen so it survives popping back to the list.
    var toast: String?
    /// Server settings (web: SET); sttLang is the default for record / import / retranscribe, `me` marks 「（我）」.
    var settings = AppSettings() { didSet { Inbox.defaultLanguage = settings.sttLang } } // for the share extension's picker
    var sttLang: String { settings.sttLang }
    /// GET /api/runners, refreshed every 15 s by the library (web: S.runners).
    var runners: Runners?
    /// A tally:// link waiting to be opened (LibraryView / AskView consume it).
    var link: DeepLink?

    static let noRunnerText = "目前沒有 runner 在線，會等 runner 上線後自動處理。"
    /// web noRunner(): known runner status and none online.
    var noRunner: Bool { runners.map { !$0.runners.contains(where: \.online) } ?? false }
    /// Notice for queued work (recording / summary / ask), like the web's 「排隊中。」 + NO_RUNNER.
    var queuedText: String { noRunner ? "排隊中。" + Self.noRunnerText : "排隊中…" }

    let recorder = Recorder()
    @ObservationIgnored lazy var uploads = UploadQueue(app: self)

    init() {
        let saved = UserDefaults.standard.string(forKey: "backendURL").flatMap(URL.init(string:))
        baseURL = saved
        token = Keychain.read()
        phase = saved == nil ? .setup : .main
        if cloud {
            if let key = UserDefaults.standard.string(forKey: "clerkPublishableKey") { Self.configureClerk(key) } else { cloud = false; phase = .setup }
        }
        #if DEBUG
        // Automated testing only: `-serviceToken` + TALLY_CF_CLIENT_ID / TALLY_CF_CLIENT_SECRET in the environment.
        let env = ProcessInfo.processInfo.environment
        if ProcessInfo.processInfo.arguments.contains("-serviceToken"),
           let id = env["TALLY_CF_CLIENT_ID"], let secret = env["TALLY_CF_CLIENT_SECRET"] {
            extraHeaders = ["CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret]
        }
        #endif
    }

    var backend: Backend? { baseURL.map { Backend(base: $0, token: token, extraHeaders: extraHeaders) } }

    /// Origin used in "copy as prompt" source links, same as the web's location.origin.
    var origin: String {
        guard let u = baseURL, let scheme = u.scheme, let host = u.host() else { return "" }
        return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
    }

    // MARK: API wrappers: every call funnels through here so an expired token flips the app to login.

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await call { try await $0.get(path, query: query) }
    }

    func json<T: Decodable>(_ method: String, _ path: String, _ body: [String: Any?] = [:], query: [URLQueryItem] = []) async throws -> T {
        try await call { try await $0.json(method, path, body, query: query) }
    }

    /// web fail(): errors as a longer toast.
    func fail(_ error: Error) {
        if error is CancellationError { return }
        toast = "錯誤：" + error.localizedDescription
    }

    func call<T>(_ op: (Backend) async throws -> T) async throws -> T {
        do {
            return try await op(authed())
        } catch APIError.authRequired {
            authExpired()
            throw APIError.authRequired
        }
    }

    /// The backend with credentials for one request. Cloud: a Clerk session token, fetched per request (the SDK caches it
    /// and refreshes it before its 60 s expiry), so long-running work like the upload queue never sends a stale one.
    func authed() async throws -> Backend {
        guard var b = backend else { throw APIError.http(0, "尚未設定後端") }
        if cloud {
            let clerk = Clerk.shared
            if clerk.client == nil { _ = try? await clerk.refreshClient() } // cold start: the session isn't loaded yet
            guard let jwt = try await clerk.auth.getToken() else { throw APIError.authRequired }
            b.extraHeaders["Authorization"] = "Bearer \(jwt)"
        }
        return b
    }

    /// Cloud media playback: fresh credentials per range request (see MediaLoader). nil = AVPlayer's own headers / cookie.
    var mediaHeaders: (@Sendable () async throws -> [String: String])? {
        guard cloud else { return nil }
        return { [self] in try await authed().authHeaders }
    }

    func loadSettings() async {
        if let s: AppSettings = try? await get("api/settings") { settings = s }
    }

    func loadRunners() async {
        if let r: Runners = try? await get("api/runners") { runners = r }
    }

    func authExpired() {
        setToken(nil)
        needsLogin = true
    }

    // MARK: Connect / login

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host() != nil else { return nil }
        return u
    }

    enum Probe { case ok, login }

    /// Checks a backend: reachable with the current credentials, or Access wants a login.
    func probe(_ url: URL) async throws -> Probe {
        let b = Backend(base: url, token: url == baseURL ? token : nil, extraHeaders: extraHeaders)
        do {
            let _: Templates = try await b.get("api/templates")
            return .ok
        } catch APIError.authRequired {
            return .login
        }
    }

    func connected(to url: URL) {
        if url != baseURL { setToken(nil); uploads.resetServerState() }
        baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: "backendURL")
        needsLogin = false
        phase = .main
        uploads.kick()
    }

    func loggedIn(token jwt: String, for url: URL) {
        if url != baseURL {
            uploads.resetServerState()
            baseURL = url
            UserDefaults.standard.set(url.absoluteString, forKey: "backendURL")
        }
        setToken(jwt)
        needsLogin = false
        phase = .main
        uploads.kick()
    }

    func logout() async {
        if cloud {
            try? await Clerk.shared.auth.signOut()
            cloud = false
            UserDefaults.standard.removeObject(forKey: "backendMode")
            phase = .setup // the cloud sign-in lives on the connect screen
        }
        setToken(nil)
        await LoginWebView.clearCookies()
        needsLogin = true
    }

    func changeBackend() async {
        await logout()
        needsLogin = false
        phase = .setup
    }

    // MARK: Kiroku Cloud

    private static var clerkConfigured = false

    /// Clerk can be configured once per process; there is a single cloud, so its key never changes at runtime.
    static func configureClerk(_ publishableKey: String) {
        guard !clerkConfigured else { return }
        clerkConfigured = true
        Clerk.configure(publishableKey: publishableKey)
        UserDefaults.standard.set(publishableKey, forKey: "clerkPublishableKey")
    }

    /// GET /api/config on the cloud backend and set up Clerk. Returns true if a Clerk session already exists.
    func prepareCloud() async throws -> Bool {
        let cfg: ServerConfig = try await Backend(base: Self.cloudURL).get("api/config")
        guard cfg.authMode == "clerk", let key = cfg.clerkPublishableKey else { throw APIError.http(0, "這個後端不是 Kiroku Cloud") }
        Self.configureClerk(key)
        _ = try? await Clerk.shared.refreshClient()
        return Clerk.shared.session != nil
    }

    func cloudSignedIn() {
        cloud = true
        UserDefaults.standard.set("cloud", forKey: "backendMode")
        connected(to: Self.cloudURL)
    }

    private func setToken(_ t: String?) {
        token = t
        if let t { Keychain.write(t) } else { Keychain.delete() }
    }
}

/// One generic-password item holding the Access JWT. AfterFirstUnlock so uploads work while the phone is locked.
nonisolated enum Keychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "ai.3mi.tally",
                                               kSecAttrAccount as String: "cf-access-token"] }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
