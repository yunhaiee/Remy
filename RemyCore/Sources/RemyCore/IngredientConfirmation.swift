import Foundation

/// A deliberately small local shortcut for pantry review while the on-device model prepares
/// instructions. Parse only an already-addressed utterance body, after the caller removes the
/// wake word. Other conversation stays with the chef instead of guessing from keywords.
public struct IngredientConfirmation: Equatable, Sendable {
    public let ingredientID: String
    public let status: PantryStatus

    public static func parse(_ utterance: String, ingredients: [Ingredient]) -> IngredientConfirmation? {
        // An explicit question is not a statement that the ingredient is available or missing.
        guard !utterance.contains("?") else { return nil }
        let text = normalize(utterance)
        guard !text.isEmpty else { return nil }
        let prefixes: [(String, PantryStatus)] = [
            ("i don't have ", .missing), ("i dont have ", .missing), ("i do not have ", .missing),
            ("i have ", .seen), ("got ", .seen), ("no ", .missing)
        ]
        let subject: String
        let status: PantryStatus
        if let (prefix, value) = prefixes.first(where: { text.hasPrefix($0.0) }) {
            subject = String(text.dropFirst(prefix.count)); status = value
        } else if text.hasSuffix(" is missing") {
            subject = String(text.dropLast(" is missing".count)); status = .missing
        } else { return nil }
        guard !subject.isEmpty else { return nil }
        let candidates = ingredients.filter { ingredient in
            !ingredient.id.isEmpty &&
            (normalize(ingredient.name) == subject || normalize(ingredient.id) == subject)
        }
        // The full subject must name exactly one current ingredient, without quantities, plural
        // guessing, articles, conjunction splitting, substitutions, or substring matching.
        guard candidates.count == 1, let ingredient = candidates.first else { return nil }
        return IngredientConfirmation(ingredientID: ingredient.id, status: status)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
