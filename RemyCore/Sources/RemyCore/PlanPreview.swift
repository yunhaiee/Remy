import Foundation

/// What can already be shown from a recipe plan Gemma is still writing: the dish, the ingredient list once it is
/// complete, and every step whose JSON object has closed. Nothing here is validated; the finished plan still is.
public struct PlanPreview: Equatable, Sendable {
    public var dish: String?
    public var ingredients: [Ingredient] = []
    public var steps: [RecipeStep] = []

    public init(streamed text: String) {
        if let range = text.range(of: #""dish"\s*:\s*"([^"\\]*)""#, options: .regularExpression) {
            let match = String(text[range])
            dish = match.split(separator: "\"").dropFirst(2).first.map(String.init)
        }
        guard let ingredientsStart = text.range(of: #""ingredients"\s*:\s*\["#, options: .regularExpression) else { return }
        let afterIngredients = text[ingredientsStart.upperBound...]
        ingredients = Self.closedObjects(in: afterIngredients, stopAtArrayEnd: true).compactMap { Self.decode(Ingredient.self, $0) }
        guard let stepsStart = text.range(of: #""steps"\s*:\s*\["#, options: .regularExpression) else { return }
        steps = Self.closedObjects(in: text[stepsStart.upperBound...], stopAtArrayEnd: true).compactMap { Self.decode(RecipeStep.self, $0) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: Substring) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Top-level `{...}` objects in an array body, skipping braces inside strings. Stops at the array's `]`.
    private static func closedObjects(in text: Substring, stopAtArrayEnd: Bool) -> [Substring] {
        var objects: [Substring] = []
        var depth = 0, inString = false, escaped = false
        var start: Substring.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0, let begin = start { objects.append(text[begin...index]); start = nil }
            } else if char == "]" && depth == 0 && stopAtArrayEnd {
                break
            }
            index = text.index(after: index)
        }
        return objects
    }
}
