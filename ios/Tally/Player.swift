import AVFoundation
import Observation

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

    init(url: URL, backend: Backend, fallbackDuration: Double?) {
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": backend.authHeaders]
        if let token = backend.token, let host = url.host(),
           let cookie = HTTPCookie(properties: [.name: "CF_Authorization", .value: token, .domain: host, .path: "/", .secure: "TRUE"]) {
            options[AVURLAssetHTTPCookiesKey] = [cookie]
        }
        player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: options)))
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
