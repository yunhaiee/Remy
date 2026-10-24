import AVFoundation

/// Records the cook's spoken answer as 16 kHz mono WAV for Gemma's own audio input; no speech service is used.
/// The temporary file is deleted as soon as it has been read.
@MainActor final class VoiceInput: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    private var startRequestID = UUID()
    var onRecordingEnded: ((Bool) -> Void)?
    private var recorder: AVAudioRecorder?
    private var interruptionObserver: NSObjectProtocol?
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("remy-answer.wav")

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if let onRecordingEnded = self.onRecordingEnded { onRecordingEnded(false) }
                else { _ = self.stop() }
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func start() async throws {
        guard !isStarting, recorder == nil else { throw VoiceError.failed }
        let request = UUID(); startRequestID = request; isStarting = true
        defer { if startRequestID == request { isStarting = false } }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard startRequestID == request else { throw CancellationError() }
        guard allowed else { throw VoiceError.denied }
        let session = AVAudioSession.sharedInstance()
        // Speaker output keeps the chef audible while the microphone is configured.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        // Keep the send/stop tap tactile while the microphone is active.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.record(forDuration: 12) else { throw VoiceError.failed }
        self.recorder = recorder; isRecording = true
    }

    /// Returns nil for recordings too short to hold an answer.
    func stop() -> Data? {
        startRequestID = UUID(); isStarting = false
        let active = recorder
        recorder = nil; isRecording = false
        active?.delegate = nil; active?.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), data.count > 16_000 else { return nil }
        return data
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let active = self.recorder, ObjectIdentifier(active) == id else { return }
            if let onRecordingEnded = self.onRecordingEnded { onRecordingEnded(flag) }
            else { _ = self.stop() }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        audioRecorderDidFinishRecording(recorder, successfully: false)
    }

    enum VoiceError: LocalizedError {
        case denied, failed
        var errorDescription: String? {
            self == .denied ? "Allow microphone access in Settings to answer out loud." : "Could not start recording."
        }
    }
}
