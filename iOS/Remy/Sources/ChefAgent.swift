import Foundation
import LiteRTLM
import RemyCore

/// Gemma as a conversational chef: it answers in its own words and acts through tools (Gemma 4 function calling),
/// instead of picking from a fixed intent menu. It sees the recipe state, the last few turns, and only the tools that
/// make sense right now (fewer tools keep a 2B model accurate). The app, not the model, carries out each tool call.
enum ChefAgent {
    struct Turn: Sendable { let cook: String; let chef: String }
    struct Action: Sendable { let name: String; let arguments: [String: String] }
    struct Reply {
        let speech: String
        let actions: [Action]
        let elapsedMS: Double
        /// The cook's message and the model's reply (with its tool calls), for sending tool results back.
        let exchange: [Message]
    }

    static func respond(to heard: String, session: CookingSession, history: [Turn], runner: GemmaRunner) async throws -> Reply {
        let prompt = Message(heard)
        let available = tools(session)
        var result: (reply: Message, elapsedMS: Double)
        do {
            result = try await runner.converse(system: system(session), history: messages(history), tools: available,
                                               prompt: prompt, maxTokens: 96)
        } catch {
            // The model chose a tool but wrote its arguments loosely (call:save_preference{value:mild}); LiteRT-LM's
            // parser rejects that. The intended call is in the error text, so recover it instead of losing it.
            let calls = recoveredCalls("\(error)")
            guard !calls.isEmpty else { throw error }
            result = (Message(contents: [Content](), role: .model, toolCalls: calls), 0)
        }
        var exchange = [prompt, result.reply]
        var elapsed = result.elapsedMS
        // A 2B model sometimes describes an action instead of calling the tool ("I will update your ingredient
        // list now", "Mark added."). Give that back once and ask it to act; tool names are never spoken.
        let names = available.map { type(of: $0).name }
        let said = result.reply.toString
        if result.reply.toolCalls.isEmpty, promisesAction(said, toolNames: names) {
            let nudge = Message("You said you would do that but did not call a tool. Call the right tool now.")
            let retry = try await runner.converse(system: system(session), history: messages(history) + exchange,
                                                  tools: available, prompt: nudge, maxTokens: 64)
            elapsed += retry.elapsedMS
            if !retry.reply.toolCalls.isEmpty { result = (retry.reply, result.elapsedMS); exchange += [nudge, retry.reply] }
        }
        // Nothing said and nothing done would leave the cook in silence: ask once more for a spoken answer.
        if result.reply.toolCalls.isEmpty, spoken(said, toolNames: names).isEmpty {
            let nudge = Message("Answer the cook out loud in one or two sentences, or call a tool.")
            let retry = try await runner.converse(system: system(session), history: messages(history) + exchange,
                                                  tools: available, prompt: nudge, maxTokens: 72)
            elapsed += retry.elapsedMS
            result = (retry.reply, result.elapsedMS); exchange += [nudge, retry.reply]
        }
        let actions = result.reply.toolCalls.map { call in
            Action(name: call.name, arguments: call.arguments.mapValues { "\($0)" })
        }
        let speech = spoken(result.reply.toString, toolNames: names)
        return Reply(speech: speech, actions: actions, elapsedMS: elapsed, exchange: exchange)
    }

    /// Tool calls written as call:name{key:value,...} inside an error message.
    static func recoveredCalls(_ text: String) -> [ToolCall] {
        guard let regex = try? NSRegularExpression(pattern: #"call:([a-z_]+)\{([^}]*)\}"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let name = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  let body = Range(match.range(at: 2), in: text).map({ String(text[$0]) }), seen.insert(name + body).inserted else { return nil }
            var arguments: [String: Any] = [:]
            for pair in body.split(separator: ",") {
                let parts = pair.split(separator: ":", maxSplits: 1).map {
                    $0.replacingOccurrences(of: "<|\"|>", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
                if parts.count == 2 { arguments[parts[0]] = parts[1] }
            }
            return ToolCall(name: name, id: name, arguments: arguments)
        }
    }

    static func promisesAction(_ text: String, toolNames: [String]) -> Bool {
        let lower = text.lowercased()
        // Only real tool names (snake_case, whole words); bare words like "look" or "find" are ordinary speech.
        if toolNames.contains(where: { $0.contains("_") && lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) { return true }
        return lower.range(of: #"\b(i will|i'll|i can|let me|let's|lets|i am going to|i'm going to|i have|i've)\b.{0,30}\b(update|change|add|remove|swap|substitute|mark|check|find|look|save|move|start)"#,
                           options: .regularExpression) != nil
    }

    /// The reply without sentences that name a tool: those are the model talking about its plumbing.
    static func spoken(_ text: String, toolNames: [String]) -> String {
        let sentences = text.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        let kept = sentences.filter { sentence in
            !sentence.isEmpty && !toolNames.contains { name in
                // "hot_object" or "Hot object." said as plumbing; plain words like "look" stay.
                name.contains("_") && (sentence.lowercased().contains(name)
                    || sentence.lowercased() == name.replacingOccurrences(of: "_", with: " ")
                    || sentence.lowercased().hasPrefix(name.replacingOccurrences(of: "_", with: " ") + " "))
            }
        }
        guard kept.count != sentences.filter({ !$0.isEmpty }).count else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return kept.map { $0 + "." }.joined(separator: " ")
    }

    /// Tool results go back to Gemma (role "tool") and it says what they mean in its own words.
    /// It may also act on what it learned (the camera shows a hot pot → hot_object); those calls are returned.
    static func followUp(_ results: [(String, String)], to reply: Reply, session: CookingSession, history: [Turn],
                         runner: GemmaRunner) async throws -> (speech: String, actions: [Action]) {
        let content = results.map { ["type": "tool_response", "name": $0.0, "response": $0.1] }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["role": "tool", "content": content]), as: UTF8.self)
        let available = tools(session)
        let names = available.map { type(of: $0).name }
        let toolMessage = try Conversation.jsonToMessage(json)
        var result = try await runner.converse(system: system(session), history: messages(history) + reply.exchange,
                                               tools: available, prompt: toolMessage, maxTokens: 72)
        let said = result.reply.toString
        // "All ingredients are here. Let's start cooking." without the call: ask once to act.
        if result.reply.toolCalls.isEmpty, promisesAction(said, toolNames: names) {
            let nudge = Message("You said you would do that but did not call a tool. Call the right tool now.")
            let retry = try await runner.converse(system: system(session),
                                                  history: messages(history) + reply.exchange + [toolMessage, result.reply],
                                                  tools: available, prompt: nudge, maxTokens: 48)
            if !retry.reply.toolCalls.isEmpty { result = (retry.reply, result.elapsedMS) }
        }
        let actions = result.reply.toolCalls.map { Action(name: $0.name, arguments: $0.arguments.mapValues { "\($0)" }) }
        return (spoken(said, toolNames: names), actions)
    }

    /// What the chef said in a turn, for the history. A turn with only tool calls is remembered as a short spoken
    /// sentence; a placeholder like "(done)" gets copied back by the model.
    static func remembered(_ speech: String, actions: [Action]) -> String {
        if !speech.isEmpty { return speech }
        let done = actions.map { action -> String in
            switch action.name {
            case "next_step": return "On to the next step."
            case "previous_step": return "Back one step."
            case "save_preference": return "Got it, \(action.arguments["value"] ?? "noted")."
            case "mark_added": return "Noted, it's in."
            case "find": return "There it is."
            case "look", "check_step", "check_ingredients": return "Let me look."
            case "plan_recipe": return "Planning \(action.arguments["dish"] ?? "it") now."
            case "start_cooking": return "Let's start cooking."
            default: return "Done."
            }
        }
        return done.first ?? "Okay."
    }

    private static func messages(_ history: [Turn]) -> [Message] {
        history.suffix(4).flatMap { [Message($0.cook, role: .user), Message($0.chef, role: .model)] }
    }

    static func system(_ session: CookingSession) -> String {
        var lines = ["""
        You are Remy, a warm, quick cooking coach running on the cook's iPhone. You speak out loud, so answer in one or \
        two short sentences, under 30 words, with no lists or markdown. Use a tool when the cook wants something done; \
        otherwise just answer. Listen to what the cook actually asked and respond to that.
        - "I don't have X" means X is missing: suggest one substitute and call substitute_ingredient right away (the \
        recipe and the screen update), or remove_ingredient if they want to skip it. Only substitute something the \
        cook has or very likely has; "with what I have" or "skip it" means call remove_ingredient for each missing one. Never add_ingredient for this. \
        add_ingredient is only for something the recipe left out that the cook asks you to add.
        - Where something is, or which tool or knife to use: call find, so it is boxed on the screen. The camera finds
        knives by size, not by name, so for a knife always say "the biggest knife" (chopping, dicing, slicing) or "the
        smallest knife" (peeling, small or fine work). Other items by their name.
        - The cook says they have an ingredient, or confirms one you were unsure about: call have_ingredient.
        - When every ingredient is ready and the cook wants to go on, call start_cooking.
        - After a tool reports what the camera saw, tell the cook in your own words what is there and what is missing.
        - You cannot see by yourself. When asked what is visible right now, call look (or find for one item); never \
        answer from earlier turns.
        - Burns, cuts, smoke or a pot boiling over: give the safety step first.
        - Something hot on the counter (a pot, pan, kettle, stove), seen or mentioned: call hot_object with it, so \
        the cook is warned the moment a hand gets close. Asked whether anything is dangerous: call look first.
        - General cooking questions (heat, timing, technique, swaps): answer from your own knowledge, confidently.
        - Never invent steps the recipe does not have.
        """]
        switch session.phase {
        case .needsDish:
            lines.append("No dish yet. If the cook asks you to choose, pick one simple dish yourself and plan it.")
        case .ingredients, .cooking:
            guard let plan = session.plan else { break }
            let pantry = plan.ingredients.map { item -> String in
                let status = session.pantry[item.id]?.status.rawValue ?? "unchecked"
                return "\(item.name) (\(item.amount), \(status))"
            }
            lines.append("Dish: \(plan.dish). Ingredients: \(pantry.joined(separator: ", ")).")
            if session.phase == .ingredients {
                lines.append("Now: checking ingredients before cooking.")
                if session.ingredientsCollected {
                    lines.append("All ingredients are ready. You asked Ready to cook? An affirmative reply means call start_cooking. If the cook says wait, do not start.")
                }
            } else if let step = session.step {
                lines.append("Now: step \(session.currentStep + 1) of \(plan.steps.count): \(step.title). \(step.kind == .ask ? "You asked: \(step.question)" : step.instruction)")
                if session.isComplete {
                    lines.append("The dish is complete. Congratulate the cook and answer follow-up questions; do not repeat the last instruction as unfinished.")
                }
                if step.kind == .ask {
                    lines.append("You just asked the cook: \"\(step.question)\" Their next words are most likely the answer, even if short " +
                                 "(\"a little\", \"medium\"): call save_preference with it.")
                }
                if step.isGuarded {
                    lines.append("This step adds \(step.guardItem) once and it cannot come back out. If the cook says they already added it, call mark_added.")
                }
            }
        }
        if !session.unavailable.isEmpty {
            lines.append("The cook does not have: \(session.unavailable.joined(separator: ", ")). Never suggest these.")
        }
        let preferences = session.preferences.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        if !preferences.isEmpty { lines.append("The cook said before: \(preferences.joined(separator: "; ")).") }
        return lines.joined(separator: "\n")
    }

    static func tools(_ session: CookingSession) -> [Tool] {
        switch session.phase {
        case .needsDish: return [PlanRecipe(), LookAtCamera(), FindItem(), MarkHot()]
        case .ingredients:
            return [CheckIngredients(), HaveIngredient(), SubstituteIngredient(), RemoveIngredient(), AddIngredient(), StartCooking(),
                    LookAtCamera(), FindItem(), MarkHot(), PlanRecipe()]
        case .cooking where session.isComplete:
            return [PlanRecipe(), LookAtCamera(), FindItem(), MarkHot()]
        case .cooking where session.step?.kind == .ask:
            // The chef just asked the cook something: the camera tools do not fit, so the answer is the clear choice.
            return [SavePreference(), NextStep(), PreviousStep(), RepeatStep(), SubstituteIngredient(), RemoveIngredient()]
        case .cooking where session.step?.isGuarded == true && !session.salted:
            // Until the seasoning is recorded, "I added it" must arm the reach warning rather than move on.
            return [MarkAdded(), PreviousStep(), RepeatStep(), CheckStep(), LookAtCamera(), FindItem(), MarkHot()]
        case .cooking:
            var tools: [Tool] = [NextStep(), PreviousStep(), RepeatStep(), CheckStep(), LookAtCamera(), FindItem(),
                                 SubstituteIngredient(), RemoveIngredient(), MarkHot()]
            return tools
        }
    }
}

// The app runs every call itself (automatic tool calling is off), so `run` is never used.
struct PlanRecipe: Tool {
    static let name = "plan_recipe"
    static let description = "Plan a recipe and start it. Use for the dish the cook names, or one you pick when they ask you to choose."
    @ToolParam(description: "The dish, for example cold pasta salad") var dish: String
    init() {}
    func run() async throws -> Any { "" }
}
struct CheckIngredients: Tool {
    static let name = "check_ingredients"
    static let description = "Look at the counter with the camera and check which ingredients are there."
    init() {}
    func run() async throws -> Any { "" }
}
struct SubstituteIngredient: Tool {
    static let name = "substitute_ingredient"
    static let description = "The cook does not have an ingredient: replace it with another in the list and the steps."
    @ToolParam(description: "The ingredient in the recipe, for example red wine vinegar") var ingredient: String
    @ToolParam(description: "What to use instead, for example apple cider vinegar") var substitute: String
    init() {}
    func run() async throws -> Any { "" }
}
struct HaveIngredient: Tool {
    static let name = "have_ingredient"
    static let description = "The cook says they have an ingredient (\"that's the salt\", \"I've got the pasta\"): mark it as ready."
    @ToolParam(description: "The ingredient they have") var ingredient: String
    init() {}
    func run() async throws -> Any { "" }
}
struct AddIngredient: Tool {
    static let name = "add_ingredient"
    static let description = "Put an extra ingredient on the list, only when the cook asks you to add one."
    @ToolParam(description: "The ingredient") var ingredient: String
    @ToolParam(description: "How much, for example 1 or to taste") var amount: String
    init() {}
    func run() async throws -> Any { "" }
}
struct RemoveIngredient: Tool {
    static let name = "remove_ingredient"
    static let description = "The cook wants to skip an ingredient: take it off the list."
    @ToolParam(description: "The ingredient to leave out") var ingredient: String
    init() {}
    func run() async throws -> Any { "" }
}
struct StartCooking: Tool {
    static let name = "start_cooking"
    static let description = "The cook is ready: start the first step."
    init() {}
    func run() async throws -> Any { "" }
}
struct NextStep: Tool {
    static let name = "next_step"
    static let description = "The cook says the current step is finished. Only then."
    init() {}
    func run() async throws -> Any { "" }
}
struct PreviousStep: Tool {
    static let name = "previous_step"
    static let description = "Go back one step."
    init() {}
    func run() async throws -> Any { "" }
}
struct RepeatStep: Tool {
    static let name = "repeat_step"
    static let description = "Say the current step again."
    init() {}
    func run() async throws -> Any { "" }
}
struct CheckStep: Tool {
    static let name = "check_step"
    static let description = "Look at the cutting board with the camera and judge the current step."
    init() {}
    func run() async throws -> Any { "" }
}
struct LookAtCamera: Tool {
    static let name = "look"
    static let description = "Answer a question about what the camera can see right now."
    @ToolParam(description: "The cook's question") var question: String
    init() {}
    func run() async throws -> Any { "" }
}
struct FindItem: Tool {
    static let name = "find"
    static let description = "Show where an item is on the counter by drawing a box around it."
    @ToolParam(description: "The item; for a knife, the biggest knife or the smallest knife") var item: String
    init() {}
    func run() async throws -> Any { "" }
}
struct SavePreference: Tool {
    static let name = "save_preference"
    static let description = "Save the cook's answer to the question you asked."
    @ToolParam(description: "The answer in 1 to 4 words, for example mild") var value: String
    init() {}
    func run() async throws -> Any { "" }
}
struct MarkHot: Tool {
    static let name = "hot_object"
    static let description = "Mark a hot object on the counter (pot, pan, kettle, stove) so the cook is warned instantly when a hand gets close."
    @ToolParam(description: "The hot object, for example pot") var item: String
    init() {}
    func run() async throws -> Any { "" }
}
struct MarkAdded: Tool {
    static let name = "mark_added"
    static let description = "The cook says they already added the seasoning for this step."
    init() {}
    func run() async throws -> Any { "" }
}
