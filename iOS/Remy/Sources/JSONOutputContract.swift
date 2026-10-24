import Foundation

/// Give a data example instead of a raw schema: E2B can echo a schema verbatim when it is in the prompt.
/// Only required fields appear here; task instructions describe optional fields and observed values.
enum JSONOutputContract {
    static func instruction(schema: String) -> String {
        guard let data = schema.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: example(object), options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else { return "\nReturn one JSON object with the requested fields, without markdown." }
        return "\nReturn exactly one JSON DATA object, not a JSON Schema. No markdown or commentary. "
            + "Use this shape, replacing example values with the answer and empty lists when nothing is visible:\n" + text
    }

    /// Remove wrappers around one complete JSON object; never repair values, incomplete JSON or multiple objects.
    static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = trimmed
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            guard lines.count >= 3, ["```", "```json"].contains(lines[0]), lines.last == "```" else { return trimmed }
            content = lines.dropFirst().dropLast().joined(separator: "\n")
        } else if trimmed.contains("```") { return trimmed }
        if (try? JSONSerialization.jsonObject(with: Data(content.utf8))) != nil { return content }
        guard !content.hasPrefix("["), !content.hasPrefix("\""), let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end else { return content }
        let prefix = content[..<start], suffix = content[content.index(after: end)...]
        guard !prefix.contains(where: { "{}[]".contains($0) }), !suffix.contains(where: { "{}[]".contains($0) }) else { return content }
        let object = String(content[start...end])
        guard (try? JSONSerialization.jsonObject(with: Data(object.utf8))) is [String: Any] else { return content }
        return object
    }

    private static func example(_ schema: [String: Any]) -> Any {
        if let values = schema["enum"] as? [Any], let first = values.first { return first }
        switch schema["type"] as? String {
        case "object":
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = schema["required"] as? [String] ?? Array(properties.keys)
            return Dictionary(uniqueKeysWithValues: required.compactMap { key in
                properties[key].map { (key, example($0)) }
            })
        case "array":
            guard (schema["minItems"] as? Int ?? 0) > 0, let item = schema["items"] as? [String: Any] else { return [Any]() }
            return [example(item)]
        case "boolean": return false
        case "number": return 0.5
        case "integer": return 0
        default: return "value"
        }
    }
}
