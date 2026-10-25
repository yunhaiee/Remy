package com.yunha.remy.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Give a data example instead of a raw schema: E2B can echo a schema verbatim when it is in the prompt.
 * Only required fields appear here; task instructions describe optional fields and observed values.
 */
object JSONOutputContract {
    fun instruction(schema: String): String {
        val text = try {
            val parsed = Json.parse(schema) as? JSONObject ?: throw IllegalArgumentException()
            Json.sorted(example(parsed))
        } catch (_: Exception) {
            return "\nReturn one JSON object with the requested fields, without markdown."
        }
        return "\nReturn exactly one JSON DATA object, not a JSON Schema. No markdown or commentary. " +
            "Use this shape, replacing example values with the answer and empty lists when nothing is visible:\n" + text
    }

    /** Remove wrappers around one complete JSON object; never repair values, incomplete JSON or multiple objects. */
    fun clean(text: String): String {
        val trimmed = text.trim()
        var content = trimmed
        if (trimmed.startsWith("```")) {
            val lines = splitNewlines(trimmed)
            if (lines.size < 3 || lines[0] !in listOf("```", "```json") || lines.last() != "```") return trimmed
            content = lines.drop(1).dropLast(1).joinToString("\n")
        } else if (trimmed.contains("```")) return trimmed
        if (Json.isJson(content)) return content
        val start = content.indexOf('{')
        val end = content.lastIndexOf('}')
        if (content.startsWith("[") || content.startsWith("\"") || start < 0 || end < 0 || start >= end) return content
        val prefix = content.substring(0, start)
        val suffix = content.substring(end + 1)
        if (prefix.any { it in "{}[]" } || suffix.any { it in "{}[]" }) return content
        val obj = content.substring(start, end + 1)
        val isObject = try { Json.parse(obj) is JSONObject } catch (_: Exception) { false }
        if (!isObject) return content
        return obj
    }

    private fun example(schema: JSONObject): Any {
        val values = schema.opt("enum")
        if (values is JSONArray && values.length() > 0) return values.get(0)
        return when (schema.opt("type") as? String) {
            "object" -> {
                val rawProperties = schema.opt("properties") as? JSONObject
                // Swift casts to [String: [String: Any]]; any non-object property makes the whole map empty.
                val properties: Map<String, JSONObject> = rawProperties?.let { p ->
                    val keys = Json.keys(p)
                    if (keys.all { p.opt(it) is JSONObject }) keys.associateWith { p.getJSONObject(it) } else emptyMap()
                } ?: emptyMap()
                val requiredRaw = schema.opt("required") as? JSONArray
                val required: List<String> = requiredRaw?.let { r ->
                    val list = (0 until r.length()).map { r.opt(it) }
                    if (list.all { it is String }) list.map { it as String } else null
                } ?: properties.keys.toList()
                val out = LinkedHashMap<String, Any>()
                for (key in required) properties[key]?.let { out[key] = example(it) }
                out
            }
            "array" -> {
                val minItems = (schema.opt("minItems") as? Number)?.toInt() ?: 0
                val item = schema.opt("items") as? JSONObject
                if (minItems > 0 && item != null) listOf(example(item)) else emptyList<Any>()
            }
            "boolean" -> false
            "number" -> 0.5
            "integer" -> 0
            else -> "value"
        }
    }
}
