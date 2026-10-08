import AVFoundation
import Observation
import UIKit

/// Records AAC m4a into Documents/Recordings. Keeps going in the background (UIBackgroundModes audio),
/// resumes itself after interruptions (calls, Siri) and survives route changes (AirPods in/out).
@Observable final class Recorder {
    enum State { case idle, recording, paused }

    private(set) var state = State.idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0 // 0...1
    /// The system interrupted us (call); we resume automatically when it ends.
    private(set) var interrupted = false
    private(set) var fileURL: URL?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var starting = false // a second tap during the permission await must not start another

    var isActive: Bool { state != .idle }

    static var directory: URL {
        let dir = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum RecordError: LocalizedError {
        case denied, failed
        var errorDescription: String? {
            switch self {
            case .denied: "沒有麥克風權限。請到「設定 › Tally」開啟麥克風。"
            case .failed: "無法開始錄音。"
            }
        }
    }

    func start() async throws {
        guard state == .idle, !starting else { return }
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecordError.denied }
        let session = AVAudioSession.sharedInstance()
        // Built-in (or wired) mic; AirPods connect as A2DP output only, so plugging them in mid-meeting never
        // swaps the input to a low-quality Bluetooth mic.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        let url = Self.directory.appending(path: "\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else { throw RecordError.failed }
        recorder = rec
        fileURL = url
        elapsed = 0
        state = .recording
        observe()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if recorder?.record() == true { state = .recording }
    }

    /// Stops and returns the finished file (already on disk in Documents).
    @discardableResult func stop() -> URL? {
        recorder?.stop()
        let url = fileURL
        recorder = nil
        fileURL = nil
        state = .idle
        interrupted = false
        level = 0
        ticker?.invalidate()
        ticker = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    private func tick() {
        guard let rec = recorder else { return }
        elapsed = rec.currentTime > 0 ? rec.currentTime : elapsed
        if state == .recording && !interrupted {
            rec.updateMeters()
            level = max(0, min(1, (rec.averagePower(forChannel: 0) + 50) / 50))
        } else {
            level = 0
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    if type == .began { self.interrupted = true } else { self.resumeAfterInterruption() }
                }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                // a route change can stop the recorder (e.g. wired headset unplugged); keep recording on the new route
                MainActor.assumeIsolated {
                    guard let self, self.state == .recording, !self.interrupted, let rec = self.recorder, !rec.isRecording else { return }
                    rec.record()
                }
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                // the recorder is dead after a media-services reset; keep what we have (the file is valid up to here)
                MainActor.assumeIsolated { self?.pause() }
            },
            // swiped away mid-recording: finalize the m4a (moov atom) so the next launch can queue it
            nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recorder?.stop() }
            },
            // a resume that failed in the background (the system can refuse) is retried when the app comes back
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.interrupted == true { self?.resumeAfterInterruption() } }
            },
        ]
    }

    private func resumeAfterInterruption() {
        guard state != .idle else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if state == .recording, recorder?.record() != true { return }
            interrupted = false
        } catch {
            // stays `interrupted`; retried on didBecomeActive
        }
    }
}
