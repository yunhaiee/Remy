import AVFoundation

/// Speech-to-text fed while the cook talks (AppleSpeech). Called on the listener's queue.
protocol LiveTranscriber: AnyObject {
    func begin(_ samples: [Int16])
    func append(_ samples: [Int16])
    func end() -> Task<String?, Never>?
    func cancel()
}

/// Always-on microphone for hands-free cooking. It finds where someone starts and stops talking (energy-based,
/// with an adaptive noise floor) and hands each utterance to Gemma as a 16 kHz mono WAV. Nothing is saved.
/// While the chef is speaking the microphone is ignored, so the chef never answers itself.
final class HandsFreeListener: ObservableObject, @unchecked Sendable {
    @Published private(set) var isOn = false
    @Published private(set) var hearing = false
    /// The chef is talking, so the microphone is paused.
    @Published private(set) var chefTalking = false
    /// Delivered on the main queue: the audio, and the live transcriber's words when there is one.
    var onUtterance: ((Data, Task<String?, Never>?) -> Void)?
    /// Set before `start`. Without it, the app transcribes the WAV with Gemma.
    var live: LiveTranscriber?

    @MainActor private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "remy.listener")
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let bufferSlots = DispatchSemaphore(value: 4)
    @MainActor private var starting = false
    @MainActor private var wanted = false
    @MainActor private var startID = UUID()
    @MainActor private var tapInstalled = false
    @MainActor private var configurationObserver: NSObjectProtocol?
    @MainActor private var interruptionObserver: NSObjectProtocol?
    @MainActor private var voiceProcessingActive = false
    @MainActor private var voiceProcessingFallbackCode: Int?
    @MainActor private var inputSampleRate = 0.0
    @MainActor private var inputChannels = 0
    @MainActor private var startStage = "idle"
    @MainActor private var failureStage: String?
    @MainActor private var errorCode: Int?
    private let deliveryLock = NSLock()
    // The lock protects delivery state shared by the audio queue and MainActor.
    private var graphGeneration = UUID()
    private var receivedBuffers: UInt64 = 0
    private var lastBufferTime: Double?
    // Everything below is touched only on `queue`.
    private var muted = false
    private var mutedSince = 0.0
    private var mutedUntil = 0.0
    private var noiseFloor: Float = 0.005
    private var preroll: [Int16] = []
    private var utterance: [Int16] = []
    private var loudChunks = 0
    private var quietSeconds = 0.0
    private var speaking = false
    private var lastLog = 0.0, peakSinceLog: Float = 0, chunksSinceLog = 0

    private let onsetRatio: Float = 3.2, minimumLevel: Float = 0.012
    private let endSilence = 0.45, maxSeconds = 10.0, minSeconds = 0.2, prerollSeconds = 0.3

    @MainActor func start() async throws {
        guard !isOn, !starting else { return }
        let request = UUID(); startID = request; starting = true; wanted = true
        defer { if startID == request { starting = false } }
        failureStage = nil; errorCode = nil; startStage = "record permission"
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard startID == request, wanted, !Task.isCancelled else { throw CancellationError() }
        guard allowed else {
            wanted = false; recordFailure(VoiceInput.VoiceError.denied)
            throw VoiceInput.VoiceError.denied
        }
        installInterruptionObserver()
        do {
            let session = AVAudioSession.sharedInstance()
            startStage = "session category"
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP])
            startStage = "recording haptics"
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            startStage = "session activation"
            try session.setActive(true)
            try startEngine()
        } catch { recordFailure(error); wanted = false; stopEngine(); throw error }
        isOn = true
    }

    @MainActor private func installInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            Task { @MainActor in
                guard let self, self.wanted else { return }
                if type == .began { self.stopEngine(); self.isOn = false }
                if type == .ended { self.restart(reason: "interruption ended") }
            }
        }
    }

    @MainActor private func stopEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        deliveryLock.withLock { graphGeneration = UUID(); receivedBuffers = 0; lastBufferTime = nil }
        engine.stop()
        voiceProcessingActive = false
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }

    @MainActor private func startEngine() throws {
        voiceProcessingFallbackCode = nil
        do { try configureEngine(voiceProcessing: true) }
        catch {
            voiceProcessingFallbackCode = (error as NSError).code
            print("REMY_MIC voice processing unavailable, using standard input (code \((error as NSError).code))")
            // A failed processing graph is never reused. Preserve microphone availability on
            // routes that reject Voice I/O, without claiming noise suppression is active.
            try configureEngine(voiceProcessing: false)
        }
    }

    @MainActor private func configureEngine(voiceProcessing: Bool) throws {
        stopEngine()
        startStage = "voice processing session mode"
        try AVAudioSession.sharedInstance().setMode(voiceProcessing ? .voiceChat : .default)
        // Reusing the stopped input graph can retain a rejected route format (-10868).
        // Read the current hardware format from a new graph for every start and recovery.
        engine = AVAudioEngine()
        let observedEngine = ObjectIdentifier(engine)
        let generation = deliveryLock.withLock { graphGeneration }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, ObjectIdentifier(self.engine) == observedEngine,
                      self.deliveryLock.withLock({ self.graphGeneration == generation }), self.wanted, !self.starting, !self.engine.isRunning else { return }
                self.restart(reason: "configuration change")
            }
        }
        startStage = "input format and converter"
        let input = engine.inputNode
        if voiceProcessing {
            startStage = "voice processing setup"
            // Must be enabled while stopped, before reading the format or installing the tap:
            // Voice I/O can change both the input format and the output route.
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingBypassed = false
            input.isVoiceProcessingAGCEnabled = true
            var ducking = input.voiceProcessingOtherAudioDuckingConfiguration
            ducking.enableAdvancedDucking = false
            ducking.duckingLevel = .min
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
        }
        startStage = "input format and converter"
        let inputFormat = input.outputFormat(forBus: 0)
        inputSampleRate = inputFormat.sampleRate.isFinite ? inputFormat.sampleRate : 0
        inputChannels = Int(inputFormat.channelCount)
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              AVAudioSession.sharedInstance().isInputAvailable,
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw MicError.unavailableRoute
        }
        queue.async {
            guard self.deliveryLock.withLock({ self.graphGeneration == generation }) else { return }
            self.live?.cancel(); self.converter = converter; self.reset(); self.preroll = []
        }
        let size = AVAudioFrameCount(max(2048, inputFormat.sampleRate * 0.1))
        startStage = "tap installation"
        if #available(iOS 27, *) {
            // Unlike the deprecated void API, this reports a failed tap as a catchable error.
            try input.installAudioTap(onBus: 0, bufferSize: size, format: nil) { [weak self] buffer, _ in
                guard let self, self.bufferSlots.wait(timeout: .now()) == .success else { return }
                self.queue.async {
                    defer { self.bufferSlots.signal() }
                    self.process(AVAudioPCMBuffer(copying: buffer), generation: generation)
                }
            }
        } else {
            input.installTap(onBus: 0, bufferSize: size, format: inputFormat) { [weak self] buffer, _ in
                guard let self, self.bufferSlots.wait(timeout: .now()) == .success else { return }
                // Audio buffers belong to the render callback; do not enqueue their mutable storage.
                guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                    self.bufferSlots.signal(); return
                }
                copy.frameLength = buffer.frameLength
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for (from, to) in zip(source, target) {
                    if let source = from.mData, let target = to.mData { memcpy(target, source, Int(from.mDataByteSize)) }
                }
                self.queue.async { defer { self.bufferSlots.signal() }; self.process(copy, generation: generation) }
            }
        }
        tapInstalled = true
        startStage = "engine start"
        do { engine.prepare(); try engine.start() }
        catch { stopEngine(); throw error }
        voiceProcessingActive = input.isVoiceProcessingEnabled && !input.isVoiceProcessingBypassed
        failureStage = nil; errorCode = nil; startStage = "running"
        print("REMY_MIC voice processing \(voiceProcessingActive ? "enabled" : "disabled")")
        print("REMY_MIC started \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
    }

    @MainActor private func restart(reason: String, attempt: Int = 1) {
        guard wanted, !starting else { return }
        let request = startID
        print("REMY_MIC restarting after \(reason) (attempt \(attempt))")
        do {
            startStage = "session activation"
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine(); isOn = true
        } catch {
            recordFailure(error); stopEngine(); isOn = false
            print("REMY_MIC restart failed: \(error.localizedDescription)")
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.startID == request else { return }
                    self.restart(reason: reason, attempt: attempt + 1)
                }
            } else { stop() }
        }
    }

    @MainActor func stop() {
        wanted = false; starting = false; startID = UUID()
        isOn = false; hearing = false
        stopEngine()
        queue.async { self.live?.cancel(); self.reset(); self.preroll = []; self.converter = nil }
        print("REMY_MIC stopped")
    }

    @MainActor private func recordFailure(_ error: Error) {
        failureStage = startStage; errorCode = (error as NSError).code
        print("REMY_MIC failure stage=\(startStage) code=\((error as NSError).code)")
    }

    /// A live engine flag alone does not prove that the microphone is delivering audio.
    @MainActor var hasFreshAudio: Bool {
        let delivery = deliveryLock.withLock { (receivedBuffers, lastBufferTime) }
        guard isOn, engine.isRunning, tapInstalled, delivery.0 > 0, let last = delivery.1 else { return false }
        return ProcessInfo.processInfo.systemUptime - last < 1
    }

    /// Local health metadata only: no samples, loudness, words, route identifiers or user content.
    @MainActor func healthSnapshot() -> [String: Any] {
        let delivery = deliveryLock.withLock { (receivedBuffers, lastBufferTime) }
        var snapshot: [String: Any] = [
            "isOn": isOn, "engineRunning": engine.isRunning, "tapInstalled": tapInstalled,
            "starting": starting, "wanted": wanted, "voiceProcessingActive": voiceProcessingActive, "inputSampleRate": inputSampleRate,
            "inputChannels": inputChannels, "receivedBuffers": delivery.0,
            "lastBufferAgeSeconds": NSNull(), "hasFreshAudio": hasFreshAudio
        ]
        if let last = delivery.1 { snapshot["lastBufferAgeSeconds"] = max(0, ProcessInfo.processInfo.systemUptime - last) }
        if let voiceProcessingFallbackCode { snapshot["voiceProcessingFallbackCode"] = voiceProcessingFallbackCode }
        if let failureStage { snapshot["failureStage"] = failureStage }
        if let errorCode { snapshot["errorCode"] = errorCode }
        return snapshot
    }

    private enum MicError: LocalizedError {
        case unavailableRoute
        var errorDescription: String? { "The microphone route is not ready. Reconnect the audio device and try again." }
    }

    /// True while the chef talks; audio is dropped until shortly after it stops (room echo).
    func setMuted(_ value: Bool) {
        DispatchQueue.main.async { self.chefTalking = value }
        queue.async {
            self.muted = value
            if value { self.mutedSince = ProcessInfo.processInfo.systemUptime; if self.speaking { self.live?.cancel() }; self.reset() }
            else { self.mutedUntil = ProcessInfo.processInfo.systemUptime + 0.35 }
        }
    }

    private func reset() {
        utterance = []; loudChunks = 0; quietSeconds = 0
        if speaking { speaking = false; DispatchQueue.main.async { self.hearing = false } }
    }

    private func process(_ buffer: AVAudioPCMBuffer, generation: UUID) {
        guard deliveryLock.withLock({ graphGeneration == generation }),
              let samples = convert(buffer), !samples.isEmpty else { return }
        let current = deliveryLock.withLock {
            guard graphGeneration == generation else { return false }
            receivedBuffers += 1; lastBufferTime = ProcessInfo.processInfo.systemUptime
            return true
        }
        guard current else { return }
        // Safety net: no chef sentence lasts 20 s, so a pause that long means a missed "finished" event.
        if muted && ProcessInfo.processInfo.systemUptime - mutedSince > 20 {
            print("REMY_MIC unmuting after 20 s with no end-of-speech event")
            muted = false; DispatchQueue.main.async { self.chefTalking = false }
        }
        if muted || ProcessInfo.processInfo.systemUptime < mutedUntil {
            preroll = []
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLog > 2 { print("REMY_MIC muted (chef speaking)"); lastLog = now }
            return
        }
        let seconds = Double(samples.count) / 16_000
        let rms = sqrt(samples.reduce(Float(0)) { $0 + pow(Float($1) / 32768, 2) } / Float(samples.count))
        let loud = rms > max(noiseFloor * onsetRatio, minimumLevel)
        peakSinceLog = max(peakSinceLog, rms); chunksSinceLog += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLog > 2 {
            print(String(format: "REMY_MIC chunks %d · peak %.4f · floor %.4f · threshold %.4f · speaking %@",
                         chunksSinceLog, peakSinceLog, noiseFloor, max(noiseFloor * onsetRatio, minimumLevel), speaking ? "yes" : "no"))
            lastLog = now; peakSinceLog = 0; chunksSinceLog = 0
        }

        if !speaking {
            // The floor follows the room only while nobody is talking.
            // The floor follows a quiet room quickly and a loud room slowly, so constant noise (a busy hall) stops
            // counting as speech after a few seconds.
            noiseFloor = loud ? noiseFloor * 0.995 + rms * 0.005 : noiseFloor * 0.95 + rms * 0.05
            loudChunks = loud ? loudChunks + 1 : 0
            preroll.append(contentsOf: samples)
            if preroll.count > Int(prerollSeconds * 16_000) { preroll.removeFirst(preroll.count - Int(prerollSeconds * 16_000)) }
            guard loudChunks >= 2 else { return }
            speaking = true; utterance = preroll; quietSeconds = 0
            live?.begin(preroll)
            DispatchQueue.main.async { self.hearing = true }
            return
        }
        utterance.append(contentsOf: samples)
        live?.append(samples)
        quietSeconds = loud ? 0 : quietSeconds + seconds
        let length = Double(utterance.count) / 16_000
        guard quietSeconds >= endSilence || length >= maxSeconds else { return }
        let finished = utterance
        reset(); preroll = []
        guard length - quietSeconds >= minSeconds else { live?.cancel(); return }
        print(String(format: "REMY_MIC utterance %.1f s", length))
        let wav = Self.wav(finished), words = live?.end()
        DispatchQueue.main.async { self.onUtterance?(wav, words) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard let converter, buffer.format == converter.inputFormat,
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard let data = output.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// The 16-bit samples of a 16 kHz mono WAV made by `wav` (44-byte header).
    static func samples(fromWAV data: Data) -> [Int16] {
        guard data.count > 44 else { return [] }
        return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
