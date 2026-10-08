import AVFoundation
import Observation
import UniformTypeIdentifiers

/// Streams /media/{id} with HTTP Range (AVPlayer seeks by itself). Auth: the Access JWT as a CF_Authorization
/// cookie (public AVURLAssetHTTPCookiesKey) plus the same headers the API uses (AVURLAssetHTTPHeaderFieldsKey,
/// long-standing but undocumented; needed for the DEBUG service-token headers).
@Observable final class Player {
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var rate: Float = 1 { didSet { if isPlaying { player.rate = rate } } }

    @ObservationIgnored let player: AVPlayer
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var loader: MediaLoader? // the resource loader holds its delegate weakly

    /// `freshHeaders` (Kiroku Cloud): credentials expire within a minute, so media goes through MediaLoader,
    /// which asks for fresh headers on every range request.
    init(url: URL, backend: Backend, fallbackDuration: Double?, freshHeaders: (@Sendable () async throws -> [String: String])? = nil) {
        let asset: AVURLAsset
        if let freshHeaders, let loaderURL = MediaLoader.wrap(url) {
            let loader = MediaLoader(headers: freshHeaders)
            asset = AVURLAsset(url: loaderURL)
            asset.resourceLoader.setDelegate(loader, queue: .global(qos: .userInitiated))
            self.loader = loader
        } else {
            var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": backend.authHeaders]
            if let token = backend.token, let host = url.host(),
               let cookie = HTTPCookie(properties: [.name: "CF_Authorization", .value: token, .domain: host, .path: "/", .secure: "TRUE"]) {
                options[AVURLAssetHTTPCookiesKey] = [cookie]
            }
            asset = AVURLAsset(url: url, options: options)
        }
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        duration = fallbackDuration ?? 0
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t) }
        }
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    private func tick(_ t: CMTime) {
        time = t.seconds.isFinite ? t.seconds : 0
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        isPlaying = player.timeControlStatus != .paused
    }

    func toggle() {
        if isPlaying { player.pause(); isPlaying = false } else { play() }
    }

    func play() {
        // never steal the session from an ongoing recording (playAndRecord already allows playback)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio)
        }
        try? session.setActive(true)
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func seek(_ seconds: Double, play: Bool = false) {
        let s = max(0, duration > 0 ? min(seconds, duration) : seconds)
        time = s
        player.seek(to: CMTime(seconds: s, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        if play { self.play() }
    }

    func skip(_ delta: Double) { seek(time + delta) }
}

/// Serves an AVURLAsset whose URL has a `kiroku-` scheme prefix: each AVFoundation byte-range request is fetched from
/// the real http(s) URL in chunks, with headers fetched per chunk (Clerk session tokens live 60 s; a playback lasts longer).
nonisolated final class MediaLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    private static let prefix = "kiroku-"
    private static let chunk: Int64 = 2 << 20
    let headers: @Sendable () async throws -> [String: String]

    init(headers: @escaping @Sendable () async throws -> [String: String]) { self.headers = headers }

    static func wrap(_ url: URL) -> URL? { swapScheme(url) { prefix + $0 } }

    private static func swapScheme(_ url: URL, _ f: (String) -> String) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme else { return nil }
        c.scheme = f(scheme)
        return c.url
    }

    /// "bytes 0-1/12345" → 12345
    static func total(contentRange: String?) -> Int64? {
        contentRange?.split(separator: "/").last.flatMap { Int64($0) }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        nonisolated(unsafe) let request = loadingRequest // AVFoundation allows answering from any thread
        Task { await serve(request) }
        return true
    }

    private func serve(_ r: AVAssetResourceLoadingRequest) async {
        guard let url = r.request.url.flatMap({ Self.swapScheme($0) { String($0.dropFirst(Self.prefix.count)) } }) else {
            return r.finishLoading(with: URLError(.badURL))
        }
        var offset = r.dataRequest?.requestedOffset ?? 0
        var end: Int64? = r.dataRequest.map { $0.requestsAllDataToEndOfResource ? nil : $0.requestedOffset + Int64($0.requestedLength) } ?? 2
        do {
            while end.map({ offset < $0 }) ?? true, !r.isCancelled {
                var req = URLRequest(url: url)
                for (k, v) in try await headers() { req.setValue(v, forHTTPHeaderField: k) }
                req.setValue("bytes=\(offset)-\(min(offset + Self.chunk, end ?? .max) - 1)", forHTTPHeaderField: "Range")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 206, !data.isEmpty,
                      let total = Self.total(contentRange: http.value(forHTTPHeaderField: "Content-Range")) else {
                    throw URLError(.badServerResponse)
                }
                if let info = r.contentInformationRequest, info.contentLength == 0 {
                    info.contentType = http.mimeType.flatMap { UTType(mimeType: $0)?.identifier }
                    info.contentLength = total
                    info.isByteRangeAccessSupported = true
                }
                end = min(end ?? total, total)
                guard let dataRequest = r.dataRequest else { break }
                dataRequest.respond(with: data)
                offset += Int64(data.count)
            }
            r.finishLoading()
        } catch {
            r.finishLoading(with: error)
        }
    }
}
