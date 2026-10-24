import Foundation

/// A request to look at an item, never evidence that the item is present.
public struct IngredientPresentationCue: Equatable, Sendable {
    public let ingredientID: String?

    public static func parse(_ text: String, ingredients: [Ingredient]) -> Self? {
        let body = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"^\W*((hey|ok|okay|yes) )?(chef|chief|shef|remy|remi)\b[, ]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if ["what is this", "what's this", "identify this", "check this", "check my ingredients", "check ingredients", "first ingredient", "next ingredient"].contains(body) {
            return Self(ingredientID: nil)
        }
        let prefixes = ["here's ", "heres ", "here is ", "these are ", "this is ", "i have ", "i've got ", "i got "]
        guard let prefix = prefixes.first(where: { body.hasPrefix($0) }) else { return nil }
        var subject = String(body.dropFirst(prefix.count))
        for article in ["the ", "my ", "an ", "a "] where subject.hasPrefix(article) {
            subject = String(subject.dropFirst(article.count)); break
        }
        if ["first ingredient", "next ingredient", "ingredient", "first one", "next one"].contains(subject) {
            return Self(ingredientID: nil)
        }
        let matches = ingredients.filter { IngredientVisualIdentity.sameFood(subject, $0.name) || IngredientVisualIdentity.sameFood(subject, $0.id) }
        if matches.count == 1 { return Self(ingredientID: matches[0].id) }
        let words = subject.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 6,
              !words.contains(where: { ["not", "and", "how", "why", "problem", "question"].contains($0) }) else { return nil }
        return Self(ingredientID: nil)
    }
}

/// Identity from image evidence, independent of the cook's spoken guess and COCO detector labels.
public struct IngredientVisualIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let confidence: Double
    public let evidence: String
    /// [top, left, bottom, right], Gemma's documented 0...1000 image grid.
    public let box_2d: [Double]

    public init(name: String, confidence: Double, evidence: String, box_2d: [Double]) {
        self.name = name; self.confidence = confidence; self.evidence = evidence; self.box_2d = box_2d
    }

    public static func decode(_ text: String) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: modelJSON(text))
        guard !value.name.isEmpty, value.name.count <= 60, value.evidence.count <= 300,
              value.confidence.isFinite, (0...1).contains(value.confidence),
              value.box_2d.isEmpty || value.box != nil else { throw CoreError.invalidObservation }
        return value
    }
    public var box: ItemBox? {
        guard box_2d.count == 4, box_2d.allSatisfy({ $0.isFinite && (0...1000).contains($0) }),
              box_2d[2] > box_2d[0], box_2d[3] > box_2d[1] else { return nil }
        return ItemBox(label: name, x: box_2d[1] / 1000, y: box_2d[0] / 1000,
                       width: (box_2d[3] - box_2d[1]) / 1000, height: (box_2d[2] - box_2d[0]) / 1000)
    }
    /// Confidence is an uncalibrated model report; agreement with a second crop is also required.
    public var isSupported: Bool {
        confidence >= 0.8 && box != nil && evidence.count >= 6 && !Self.isUnknown(name)
            && !Self.isAmbiguous(evidence)
    }
    public func isCorroborated(by verification: IngredientVisualVerification) -> Bool {
        guard isSupported, verification.matches, verification.confidence >= 0.8,
              verification.evidence.count >= 6, !Self.isAmbiguous(verification.evidence),
              Self.sameFood(name, verification.name) else { return false }
        // White powder or a clear liquid cannot prove its identity from appearance alone.
        if ["salt", "sugar", "oil"].contains(Self.canonical(name)) {
            let text = (evidence + " " + verification.evidence).lowercased()
            let labelled = text.contains("label") || text.contains("printed") || text.contains("package text")
            let saltContainer = ["salt shaker", "salt grinder", "salt bottle"].contains(name.lowercased())
                && text.contains("crystal") && !text.contains("pepper")
            guard labelled || saltContainer else { return false }
        }
        return true
    }
    public func confirmedIngredient(in ingredients: [Ingredient], verification: IngredientVisualVerification) -> Ingredient? {
        guard isCorroborated(by: verification) else { return nil }
        let matches = ingredients.filter { Self.sameFood(name, $0.name) || Self.sameFood(name, $0.id) }
        return matches.count == 1 ? matches[0] : nil
    }
    private static func isUnknown(_ text: String) -> Bool { ["unknown", "none", "uncertain", "food", "produce", "vegetable", "fruit"].contains(canonical(text)) }
    private static func isAmbiguous(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["maybe", "might be", "could be", "not clear", "uncertain", "cannot tell", "can't tell"].contains { lower.contains($0) }
    }
    public static func sameFood(_ a: String, _ b: String) -> Bool {
        let left = canonical(a), right = canonical(b)
        return !left.isEmpty && !isUnknown(left) && left == right
    }
    public static func canonical(_ text: String) -> String {
        let value = text.lowercased().replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let aliases: [String: String] = [
            "onions": "onion", "red onion": "onion", "yellow onion": "onion", "white onion": "onion", "purple onion": "onion",
            "cucumbers": "cucumber", "sliced cucumber": "cucumber", "whole cucumber": "cucumber",
            "tomatoes": "tomato", "cherry tomato": "tomato", "cherry tomatoes": "tomato", "roma tomato": "tomato",
            "lemons": "lemon", "lemon half": "lemon", "cooked pasta": "pasta", "dry pasta": "pasta", "dried pasta": "pasta",
            "salt shaker": "salt", "salt grinder": "salt", "salt bottle": "salt",
            "boxed pasta": "pasta", "pasta box": "pasta", "box of pasta": "pasta", "rotini box": "pasta", "box of rotini": "pasta",
            "rotini": "pasta", "fusilli": "pasta", "penne": "pasta", "spaghetti": "pasta",
            "table salt": "salt", "apples": "apple", "oranges": "orange", "bananas": "banana"
        ]
        return aliases[value] ?? value
    }
}

public struct IngredientVisualVerification: Codable, Equatable, Sendable {
    public let matches: Bool
    public let name: String
    public let confidence: Double
    public let evidence: String
    public init(matches: Bool, name: String, confidence: Double, evidence: String) {
        self.matches = matches; self.name = name; self.confidence = confidence; self.evidence = evidence
    }
    public static func decode(_ text: String) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: modelJSON(text))
        guard !value.name.isEmpty, value.name.count <= 60, value.evidence.count <= 300,
              value.confidence.isFinite, (0...1).contains(value.confidence) else { throw CoreError.invalidObservation }
        return value
    }
}

/// Exact short product labels only. A recipe sentence or "salt-free" claim is not a salt label.
public enum PackageIngredientLabel {
    public static func food(_ text: String) -> String? {
        let label = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[®™]"#, with: "", options: .regularExpression)
        if ["salt", "sea salt", "table salt", "iodized salt", "pink salt", "himalayan pink salt", "rock salt"].contains(label) { return "salt" }
        if ["pasta", "rotini", "fusilli", "penne", "spaghetti", "whole wheat rotini", "gluten free rotini"].contains(label) { return "pasta" }
        return nil
    }
}
