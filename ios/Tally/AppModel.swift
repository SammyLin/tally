import Foundation
import Observation
import Security
import WebKit

/// App-wide state: which backend, the Access token, and the shared recorder / upload queue.
@Observable final class AppModel {
    enum Phase { case setup, main }

    static let defaultBackend = "https://records.3mi.ai"

    var phase: Phase
    var baseURL: URL?
    private(set) var token: String?
    /// Access said our token is missing or expired; the UI shows the login screen.
    var needsLogin = false
    var extraHeaders: [String: String] = [:]
    /// App-wide toast (web: toast()); shown over every screen so it survives popping back to the list.
    var toast: String?
    /// Server settings (web: SET); sttLang is the default for record / import / retranscribe, `me` marks 「（我）」.
    var settings = AppSettings()
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
        guard let backend else { throw APIError.http(0, "尚未設定後端") }
        do {
            return try await op(backend)
        } catch APIError.authRequired {
            authExpired()
            throw APIError.authRequired
        }
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
        setToken(nil)
        await LoginWebView.clearCookies()
        needsLogin = true
    }

    func changeBackend() async {
        await logout()
        needsLogin = false
        phase = .setup
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
