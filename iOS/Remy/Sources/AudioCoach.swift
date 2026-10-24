import AVFoundation
import Combine
import AudioToolbox
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

    func stop() { speech.stopSpeaking(at: .immediate); clearSpeechState() }
}
