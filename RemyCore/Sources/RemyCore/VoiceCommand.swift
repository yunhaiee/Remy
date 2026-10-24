import Foundation

/// Who a transcribed utterance is for, and the few bare commands that skip the model.
/// Everything said to the chef goes to Gemma (ChefAgent), which understands it in context and acts through tools.
/// Keyword rules inside sentences made the chef obtuse ("I still see vinegar in the ingredients list, can you change
/// that?" ran an ingredient check), so the only shortcuts left are whole utterances like "next" or "go back", where
/// skipping a model call saves time and cannot be misread.
/// For the chef = starts with "Chef", or a reply within 10 s of the chef speaking.
public struct VoiceCommand: Equatable, Sendable {
    public enum Intent: String, Sendable {
        case startCooking, next, previous, `repeat`, wake, agent, ignore
    }
    public let intent: Intent
    /// For `agent`: the words for the chef, without the wake word.
    public let value: String
    public init(intent: Intent, value: String) { self.intent = intent; self.value = value }

    /// - Parameter secondsSinceChefSpoke: a reply soon after the chef talked counts as addressed without "chef".
    public static func parse(_ transcript: String, phase: CookingSession.Phase, secondsSinceChefSpoke: Double) -> VoiceCommand {
        let text = transcript.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        guard startsWithWakeWord(text) || secondsSinceChefSpoke <= 10, !text.isEmpty else { return .init(intent: .ignore, value: "") }
        let body = text.replacingOccurrences(of: #"^((hey|ok|okay|yes) )?(chef|chief|shef|remy|remi)\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // "Chef…" and a pause: the end-of-speech cut it off. The chef answers "Yes?" so the rest counts as addressed.
        if body.isEmpty { return .init(intent: .wake, value: "") }
        let command = body.replacingOccurrences(of: #"\b(please|now|then|okay|ok)\b"#, with: "", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        switch (phase, command) {
        case (.cooking, "next"), (.cooking, "next step"), (.cooking, "done"), (.cooking, "i'm done"), (.cooking, "what's next"),
             (.cooking, "whats next"):
            return .init(intent: .next, value: "")
        case (.cooking, "go back"), (.cooking, "back"), (.cooking, "previous step"):
            return .init(intent: .previous, value: "")
        case (.cooking, "repeat"), (.cooking, "repeat that"), (.cooking, "say that again"), (.cooking, "again"):
            return .init(intent: .repeat, value: "")
        case (.ingredients, "start cooking"), (.ingredients, "let's cook"), (.ingredients, "let's start"), (.ingredients, "let's start cooking"),
             (.ingredients, "next"), (.ingredients, "next step"), (.ingredients, "let's go"), (.ingredients, "let's go to the next step"):
            return .init(intent: .startCooking, value: "")
        default:
            return .init(intent: .agent, value: body)
        }
    }

    /// "Chef, …", "Hey chef …", "OK chef …": the cook is talking to the chef.
    public static func startsWithWakeWord(_ transcript: String) -> Bool {
        // "Chief" and "Shef" are how speech recognition often hears "Chef".
        transcript.lowercased().range(of: #"^\W*((hey|ok|okay|yes) )?(chef|chief|shef|remy|remi)\b"#, options: .regularExpression) != nil
    }
}
