import Foundation
func object(_ schema: String) throws -> [String: Any] {
 let instruction = JSONOutputContract.instruction(schema: schema)
 let data = Data(instruction.components(separatedBy: "\n").last!.utf8)
 return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}
let hot = try object(#"{"type":"object","properties":{"hot":{"type":"array","items":{"type":"string"}}},"required":["hot"]}"#)
precondition((hot["hot"] as? [String]) == [])
precondition(hot["type"] == nil && hot["properties"] == nil, "The model must see data, not schema metadata")
let nested = try object(#"{"type":"object","properties":{"dish":{"type":"string"},"optional":{"type":"string"},"steps":{"type":"array","minItems":1,"items":{"type":"object","properties":{"kind":{"type":"string","enum":["do","ask"]},"done":{"type":"boolean"},"score":{"type":"number"}},"required":["kind","done","score"]}}},"required":["dish","steps"]}"#)
precondition(nested["optional"] == nil)
let step = (nested["steps"] as! [[String: Any]])[0]
precondition(step["kind"] as? String == "do" && step["done"] as? Bool == false && step["score"] as? Double == 0.5)
precondition(JSONOutputContract.clean("```json\n{\"hot\":[]}\n```") == "{\"hot\":[]}")
precondition(JSONOutputContract.clean("```json\n{\"hot\":[]}").hasPrefix("```"), "Never repair a truncated reply into a passing value")
precondition(JSONOutputContract.instruction(schema:"invalid").contains("JSON object"))
precondition(JSONOutputContract.clean("Here is the result:\n{\"hot\":[]}\nNothing else was identified.") == "{\"hot\":[]}")
precondition(JSONOutputContract.clean("{\"hot\":[]} {\"hot\":[\"pot\"]}") == "{\"hot\":[]} {\"hot\":[\"pot\"]}", "Reject multiple objects rather than choosing one")
precondition(JSONOutputContract.clean("Here: {\"nested\":{\"ok\":true}") == "Here: {\"nested\":{\"ok\":true}", "Do not close a partial root")
precondition(JSONOutputContract.clean("[{\"hot\":[]}]") == "[{\"hot\":[]}]", "Never coerce an array to an object")
precondition(JSONOutputContract.clean("Result: {\"line\":\"a } or { literal\",\"hot\":[]}") == "{\"line\":\"a } or { literal\",\"hot\":[]}")
precondition(JSONOutputContract.clean("{\"hot\":[]}}") == "{\"hot\":[]}}", "Do not discard unmatched braces")
precondition(JSONOutputContract.clean("\"{}\"") == "\"{}\"", "Never coerce a JSON string to an object")
print("JSON response-contract regression checks passed.")
