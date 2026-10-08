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
    var language: String?          // zh|en|ja|auto; nil = the settings default
    var note: String?              // why it waits (e.g. STT quota), with notBefore
    var notBefore: String?
    var playKey: String?           // set once play.m4a exists: the player can show before processing ends
    var size: Int64?
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

    /// 「（我）」: the speaker is the person picked as 我是誰 in settings.
    func isMe(_ me: Int?) -> Bool { me != nil && personId == me }
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

/// GET/PUT /api/settings (web: SET). PUT takes any subset; `body` sends them all (me: null clears it).
nonisolated struct AppSettings: Codable, Equatable, Sendable {
    var about = ""
    var contentFocus = ""
    var instructions = ""
    var sttLang = "zh"
    var cleanup = true
    var autoLabel = true
    var me: Int?
    var vocab: [String] = []

    init() {}
    /// Missing keys keep the defaults (an older Worker may not know every setting).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? d.about
        contentFocus = try c.decodeIfPresent(String.self, forKey: .contentFocus) ?? d.contentFocus
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? d.instructions
        sttLang = try c.decodeIfPresent(String.self, forKey: .sttLang) ?? d.sttLang
        cleanup = try c.decodeIfPresent(Bool.self, forKey: .cleanup) ?? d.cleanup
        autoLabel = try c.decodeIfPresent(Bool.self, forKey: .autoLabel) ?? d.autoLabel
        me = try c.decodeIfPresent(Int.self, forKey: .me)
        vocab = try c.decodeIfPresent([String].self, forKey: .vocab) ?? d.vocab
    }

    var body: [String: Any?] {
        ["about": about.trimmingCharacters(in: .whitespacesAndNewlines),
         "content_focus": contentFocus.trimmingCharacters(in: .whitespacesAndNewlines),
         "instructions": instructions.trimmingCharacters(in: .whitespacesAndNewlines),
         "stt_lang": sttLang, "cleanup": cleanup, "auto_label": autoLabel, "me": me, "vocab": vocab]
    }

    /// Summary language follows the transcription language (web: sumLang).
    var summaryLang: String { ["en": "en", "ja": "ja"][sttLang] ?? "zh-TW" }
}

/// GET /api/persons: people with voiceprints (web: PERSONS).
nonisolated struct Person: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var prints: Int?
    var speakers: Int?
}

/// GET /api/vocab/suggestions.
nonisolated struct VocabSuggestions: Codable, Sendable {
    var suggestions: [Suggestion]
    var lastScan: Scan?
    var pending: Int

    struct Suggestion: Codable, Hashable, Sendable {
        var term: String
        var misheard: [String]
        var hits: Int
        var recordings: Int
    }
    struct Scan: Codable, Sendable { var at: String?; var status: String; var error: String? }

    var scanning: Bool { ["queued", "running"].contains(lastScan?.status ?? "") }
}

/// 問問看: GET /api/asks rows and GET /api/asks/:id.
nonisolated struct Ask: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var question: String
    var status: String
    var createdAt: String
    var preview: String?          // list only
    var answerMd: String?
    var error: String?
    var sources: [Int]?
    var recordings: [Ref]?

    struct Ref: Codable, Hashable, Sendable { var id: Int; var title: String; var deleted: Int? } // deleted: SQLite 0/1

    static let statusLabels = ["queued": "排隊中", "running": "思考中", "done": "完成", "error": "錯誤"]
}

/// Transcription languages (web: LANGS); POST /api/uploads and retranscribe take the id.
nonisolated enum STTLang {
    static let all: [(id: String, name: String)] = [("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("auto", "自動偵測")]
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

    var online: Int { runners.filter(\.online).count }
    /// The header's 「排隊 N」: recordings + summaries + asks (web: renderRunners).
    var waiting: Int { queued.recordings + queued.summaries + (queued.asks ?? 0) }
    /// 「N 台 runner 在線」 / 「沒有 runner 在線」.
    var headline: String { online > 0 ? "\(online) 台 runner 在線" : "沒有 runner 在線" }
    /// Nothing online but work is waiting: the header warns.
    var warn: Bool { online == 0 && waiting > 0 }
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
    func json<T: Decodable>(_ method: String, _ path: String, _ body: [String: Any?] = [:], query: [URLQueryItem] = []) async throws -> T {
        var req = request(path, method: method, query: query)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues { $0 ?? NSNull() })
        return try Self.decoder.decode(T.self, from: await send(req))
    }
}

/// For endpoints whose result we ignore ({ok:true} etc.).
nonisolated struct Ignored: Decodable, Sendable { init(from decoder: Decoder) throws {} }
