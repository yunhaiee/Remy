import AVFoundation
import Speech

/// Apple's on-device speech-to-text for the hands-free microphone. It is fed while the cook is still talking, so the
/// words are ready about when they stop; Gemma then spends its time on seeing and thinking, not transcribing.
/// One analyzer per utterance. Calls arrive on the listener's queue; `finish` is awaited from the app.
@available(iOS 26, *)
final class AppleSpeech: LiveTranscriber, @unchecked Sendable {
    private let locale: Locale
    private let analyzerFormat: AVAudioFormat
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var session: Session?
    private var _hints: [String] = []
    private var _onPartial: (@Sendable (UUID, String) -> Void)?
    var onPartial: (@Sendable (UUID, String) -> Void)? {
        get { lock.withLock { _onPartial } }
        set { lock.withLock { _onPartial = newValue } }
    }
    /// Words to expect (wake word, commands, the recipe's ingredients); they bias recognition toward them.
    var hints: [String] {
        get { lock.withLock { _hints } }
        set { lock.withLock { _hints = newValue } }
    }

    private struct Session {
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        let text: Task<String, Error>
        let converter: AVAudioConverter?
    }

    private init(locale: Locale, format: AVAudioFormat) { self.locale = locale; analyzerFormat = format }

    /// nil when this phone cannot transcribe English on device; the app then falls back to Gemma.
    /// The first run downloads Apple's English speech model (needs a network once).
    static func prepare() async -> AppleSpeech? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { return nil }
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        if await AssetInventory.status(forModules: [probe]) != .installed {
            print("REMY_SPEECH downloading the on-device English model")
            do { try await AssetInventory.assetInstallationRequest(supporting: [probe])?.downloadAndInstall() }
            catch { print("REMY_SPEECH model download failed: \(error.localizedDescription)"); return nil }
        }
        guard await AssetInventory.status(forModules: [probe]) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else { return nil }
        print("REMY_SPEECH ready (\(locale.identifier), \(format))")
        return AppleSpeech(locale: locale, format: format)
    }

    /// Speech started: open a fresh analyzer and send what was heard so far (the pre-roll).
    func begin(_ samples: [Int16]) {
        cancel()
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let context = AnalysisContext()
        context.contextualStrings[.general] = hints
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber], analysisContext: context)
        let progress = onPartial, utteranceID = UUID()
        let text = Task {
            var words = ""
            for try await result in transcriber.results {
                let current = String(result.text.characters)
                progress?(utteranceID, (words + " " + current).trimmingCharacters(in: .whitespacesAndNewlines))
                if result.isFinal { words += " " + current }
            }
            return words.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let converter = micFormat == analyzerFormat ? nil : AVAudioConverter(from: micFormat, to: analyzerFormat)
        lock.withLock { session = Session(analyzer: analyzer, input: input, text: text, converter: converter) }
        append(samples)
    }

    func append(_ samples: [Int16]) {
        guard let session = lock.withLock({ session }), let buffer = buffer(samples, converter: session.converter) else { return }
        session.input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Speech ended: detach this utterance now (the next one may start at once) and finish recognizing it.
    /// The task gives the words, or nil if recognition failed.
    func end() -> Task<String?, Never>? {
        guard let session = lock.withLock({ () -> Session? in defer { session = nil }; return session }) else { return nil }
        session.input.finish()
        return Task {
            do {
                try await session.analyzer.finalizeAndFinishThroughEndOfInput()
                return try await session.text.value
            } catch {
                print("REMY_SPEECH failed: \(error.localizedDescription)"); return nil
            }
        }
    }

    /// Too short, or the chef started talking: throw the utterance away.
    func cancel() {
        guard let session = lock.withLock({ () -> Session? in defer { session = nil }; return session }) else { return }
        session.input.finish(); session.text.cancel()
        Task { await session.analyzer.cancelAndFinishNow() }
    }

    private func buffer(_ samples: [Int16], converter: AVAudioConverter?) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let mic = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = mic.int16ChannelData else { return nil }
        mic.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter else { return mic }
        let capacity = AVAudioFrameCount(Double(samples.count) * analyzerFormat.sampleRate / 16_000) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return mic
        }
        return out
    }
}
