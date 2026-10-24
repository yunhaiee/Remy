import AVFoundation
import Combine
import AudioToolbox
import CoreHaptics
import UIKit

@MainActor final class AudioCoach: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var speechBeat: UInt = 0
    var enabled = true { didSet { if !enabled { stop() } } }
    var voiceAvailable: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix("en") }
    }
    /// Called with true when the chef starts talking and false when it stops, so the microphone can ignore it.
    var onSpeaking: ((Bool) -> Void)?
    /// Each line actually spoken (after the throttle), for the activity log.
    var onSay: ((String) -> Void)?
    /// When the chef last finished talking; a reply soon after counts as addressed to the chef.
    private(set) var lastFinished = 0.0
    private let speech = AVSpeechSynthesizer()
    private var lastSpoken = 0.0
    /// The sentence being spoken. isSpeaking can still read true inside didFinish, so this decides when talking ends.
    private var current: ObjectIdentifier?
    override init() { super.init(); speech.delegate = self }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if id == self.current { self.isSpeaking = true } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if id == self.current { self.speechBeat &+= 1 } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
    /// Only the end of the latest sentence ends talking; a cancelled earlier sentence does not.
    private func finished(_ id: ObjectIdentifier) {
        guard id == current else { return }
        clearSpeechState()
    }

    private func clearSpeechState() {
        guard current != nil else { return }
        current = nil; isSpeaking = false
        lastFinished = ProcessInfo.processInfo.systemUptime
        onSpeaking?(false)
    }

    func say(_ text: String, priority: Bool = false) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard priority || now - lastSpoken > 5 else { return }
        if speech.isSpeaking {
            guard priority else { return }
            speech.stopSpeaking(at: .immediate)
        }
        lastSpoken = now
        onSay?(text)
        // Use an installed system voice. Airplane-mode voice verification is part of the device gate.
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice.speechVoices().first { $0.language == "en-US" && $0.quality == .default }
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.52; utterance.pitchMultiplier = 0.87
        current = ObjectIdentifier(utterance)
        onSpeaking?(true)
        speech.speak(utterance)
    }

    func captureThinking() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if enabled { AudioServicesPlaySystemSound(1108) }
        say("Thinking.", priority: true)
    }

    func alarm() {
        // System sound and haptics bypass Gemma and speech synthesis. The mic stays muted through the beep (it
        // must not be heard as a command) and the reply window does not reopen.
        speech.stopSpeaking(at: .immediate)
        current = nil; isSpeaking = false
        onSpeaking?(true)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if enabled { AudioServicesPlaySystemSound(1005) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.current == nil else { return }
            self.onSpeaking?(false)
        }
    }

    private var safetyHapticEngine: CHHapticEngine?
    private var safetyHapticPlayer: CHHapticAdvancedPatternPlayer?
    private var safetyHapticTask: Task<Void, Never>?
    private var safetyHapticsWanted = false
    private var safetyWarningUtterance: ObjectIdentifier?
    private var lastHapticAttempt = -Double.infinity

    /// Haptics-only Core Haptics shares the current recording session, without changing its route.
    /// Speech occurs once per entry; vibration is held until the owner explicitly clears it.
    func beginHeldSafetyWarning(_ text: String) {
        guard !safetyHapticsWanted else { return }
        safetyHapticsWanted = true
        say(text, priority: true); safetyWarningUtterance = current
        startContinuousSafetyHaptics()
        safetyHapticTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.safetyHapticsWanted else { return }
                if self.safetyHapticPlayer == nil {
                    if ProcessInfo.processInfo.systemUptime - self.lastHapticAttempt >= 1 { self.startContinuousSafetyHaptics() }
                    if self.safetyHapticPlayer == nil { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
    private func startContinuousSafetyHaptics() {
        lastHapticAttempt = ProcessInfo.processInfo.systemUptime
        guard safetyHapticsWanted, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if safetyHapticEngine == nil {
                let engine = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
                engine.playsHapticsOnly = true; engine.isAutoShutdownEnabled = true
                engine.resetHandler = { [weak self] in
                    Task { @MainActor in self?.safetyHapticPlayer = nil; self?.safetyHapticEngine = nil }
                }
                engine.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in self?.safetyHapticPlayer = nil }
                }
                safetyHapticEngine = engine
            }
            guard let engine = safetyHapticEngine else { return }
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ], relativeTime: 0, duration: 1)
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            player.loopEnabled = true; player.loopEnd = 1
            try player.start(atTime: CHHapticTimeImmediate)
            safetyHapticPlayer = player
            print("REMY_SAFETY_HAPTICS continuous started")
        } catch {
            safetyHapticPlayer = nil; safetyHapticEngine = nil
            print("REMY_SAFETY_HAPTICS pulse fallback code=\((error as NSError).code)")
        }
    }
    func endHeldSafetyWarning() {
        guard safetyHapticsWanted || safetyHapticPlayer != nil else { return }
        safetyHapticsWanted = false
        safetyHapticTask?.cancel(); safetyHapticTask = nil
        try? safetyHapticPlayer?.stop(atTime: CHHapticTimeImmediate); safetyHapticPlayer = nil
        if let owned = safetyWarningUtterance, current == owned { stop() }
        safetyWarningUtterance = nil
        print("REMY_SAFETY_HAPTICS stopped")
    }

    func stop() { speech.stopSpeaking(at: .immediate); clearSpeechState() }
}
