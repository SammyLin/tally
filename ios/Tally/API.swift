import Foundation

// MARK: - Models (field names match web/src/index.ts and runner.ts; decoded with convertFromSnakeCase)

nonisolated struct Recording: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String
    var filename: String
    var durationS: Double?
    var status: String
    var error: String?
    var createdAt: String
    var deletedAt: String?
    var folderId: Int?
    var hasSummary: Bool?          // list only
    var topSpeakers: [TopSpeaker]? // list only

    struct TopSpeaker: Codable, Hashable, Sendable { var name: String?; var pct: Int? }
}

nonisolated struct Speaker: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var label: String?
    var displayName: String
    var personId: Int?
    var auto: Int?
    var suggest: Suggest?

    struct Suggest: Codable, Hashable, Sendable { var personId: Int; var name: String; var score: Double? }
}

nonisolated struct Segment: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var startMs: Int
    var endMs: Int
    var speakerId: Int?
    var textRaw: String
    var textClean: String?
}

nonisolated struct Summary: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var recordingId: Int
    var templateId: String
    var language: String
    var status: String
    var contentMd: String?
    var error: String?
    var createdAt: String?
}

nonisolated struct Detail: Codable, Sendable {
    var recording: Recording
    var speakers: [Speaker]
    var segments: [Segment]
    var summaries: [Summary]
}

nonisolated struct Folder: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var parentId: Int?
    var name: String
    var count: Int
}

nonisolated struct Named: Codable, Hashable, Sendable { var id: String; var name: String }
nonisolated struct Templates: Codable, Sendable { var templates: [Named]; var languages: [Named] }

nonisolated struct Runners: Codable, Sendable {
    var runners: [Runner]
    var queued: Queued

    struct Runner: Codable, Hashable, Sendable {
        var name: String
        var lastSeen: String?
        var stt: String?
        var version: String?
        var versionTime: String?
        var agoS: Int
        var online: Bool
        var job: Job?
    }
    struct Job: Codable, Hashable, Sendable {
        var kind: String
        var id: Int
        var status: String?
        var title: String?
        var recordingId: Int?
    }
    struct Queued: Codable, Sendable { var recordings: Int; var summaries: Int; var asks: Int?; var vocab: Int? }
}

nonisolated struct UploadStart: Codable, Sendable { var recordingId: Int; var partSize: Int64 }
nonisolated struct Etag: Codable, Sendable { var etag: String }

// MARK: - Status labels (same as the web's STATUS)

nonisolated enum Status {
    static let labels = ["uploading": "上傳中", "queued": "排隊中", "converting": "轉檔中", "transcribing": "轉錄中",
                         "cleaning": "整理中", "done": "完成", "error": "錯誤", "running": "產生中"]
    static func label(_ s: String) -> String { labels[s] ?? s }
    static func busy(_ s: String) -> Bool { s != "done" && s != "error" }
}

// MARK: - Errors / Access detection

nonisolated enum APIError: LocalizedError {
    case authRequired
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .authRequired: "需要重新登入"
        case .http(let code, let msg): msg.isEmpty ? "HTTP \(code)" : msg
        }
    }
    var status: Int? { if case .http(let c, _) = self { c } else { nil } }
}

nonisolated enum Access {
    /// Cloudflare Access answers an unauthenticated (or expired) request with a redirect to its login page, or 401/403.
    static func needsLogin(status: Int, location: String?) -> Bool {
        if status == 401 || status == 403 { return true }
        guard (300..<400).contains(status), let location else { return false }
        if location.contains("/cdn-cgi/access/") { return true }
        guard let host = URL(string: location)?.host?.lowercased() else { return false }
        return host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com")
    }
}

// MARK: - Client

/// Refuses redirects (so an Access 302 surfaces as-is) and reports upload progress.
nonisolated final class TaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: (@Sendable (Int64) -> Void)?
    init(progress: (@Sendable (Int64) -> Void)? = nil) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // (the async variant crashes swift-frontend 6.3.3 in SILGen)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?(totalBytesSent)
    }
}

nonisolated struct Backend: Sendable {
    var base: URL
    var token: String?
    var extraHeaders: [String: String] = [:]

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false // the token travels in a header only; logout must really log out
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c, delegate: TaskDelegate(), delegateQueue: nil)
    }()

    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()

    var authHeaders: [String: String] {
        var h = extraHeaders
        if let token { h["cf-access-token"] = token }
        return h
    }

    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        for (k, v) in authHeaders { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// Sends a request; `upload` bodies go through URLSession's upload task so progress is reported.
    func send(_ req: URLRequest, upload: Data? = nil, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        let delegate = TaskDelegate(progress: progress)
        let (data, resp) = if let upload {
            try await Self.session.upload(for: req, from: upload, delegate: delegate)
        } else {
            try await Self.session.data(for: req, delegate: delegate)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(0, "沒有回應") }
        if Access.needsLogin(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location")) {
            throw APIError.authRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError.http(http.statusCode, detail ?? "HTTP \(http.statusCode)")
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try Self.decoder.decode(T.self, from: await send(request(path, query: query)))
    }

    /// JSON body; the Worker requires Content-Type: application/json on every non-GET JSON request.
    func json<T: Decodable>(_ method: String, _ path: String, _ body: [String: Any?] = [:]) async throws -> T {
        var req = request(path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues { $0 ?? NSNull() })
        return try Self.decoder.decode(T.self, from: await send(req))
    }
}

/// For endpoints whose result we ignore ({ok:true} etc.).
nonisolated struct Ignored: Decodable, Sendable { init(from decoder: Decoder) throws {} }
