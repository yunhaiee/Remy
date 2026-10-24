import Foundation

/// A wake-only utterance authorizes one continuation for eight seconds. Cooking mode may explicitly open conversation. Tentative transcripts may prefetch but cannot authorize actions.
public struct ChefWakeGate: Sendable {
    private var continuationUntil: Double = -.infinity
    public init() {}
    public static func hasPrefix(_ text: String) -> Bool {
        text.lowercased().range(of: #"^\W*(?:hey[ ,]+)?(chef|chief|shef|remy|remi)\b"#, options: .regularExpression) != nil
    }
    public mutating func accept(_ text: String, now: Double, conversationOpen: Bool = false) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.hasPrefix(value) {
            let body = value.replacingOccurrences(of: #"(?i)^\W*(?:hey[ ,]+)?(chef|chief|shef|remy|remi)\b[\s,.!?]*"#, with: "", options: .regularExpression)
            continuationUntil = body.isEmpty ? now + 8 : -.infinity
            return body
        }
        guard !value.isEmpty, conversationOpen || now <= continuationUntil else { return nil }
        continuationUntil = -.infinity
        return value
    }
}

/// Only whole affirmative/negative replies are shortcuts. Questions and qualifications go to Gemma.
public enum CookingReadinessReply {
    public enum Decision: Equatable { case ready, wait }
    public static func parse(_ text: String) -> Decision? {
        let body = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        if ["yes", "yeah", "yep", "yup", "sure", "okay", "ok", "ready", "i'm ready", "i am ready", "yes i'm ready", "yes i am ready", "let's go", "lets go", "let's cook", "let's do it", "sounds good", "absolutely", "go ahead", "yes please", "yes let's cook", "yeah let's do it"].contains(body) { return .ready }
        if ["no", "nope", "not yet", "wait", "hold on", "one moment", "give me a second", "i'm not ready", "i am not ready", "not right now"].contains(body) { return .wait }
        return nil
    }
}
