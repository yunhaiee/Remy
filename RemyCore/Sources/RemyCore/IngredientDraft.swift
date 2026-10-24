import Foundation

/// A complete ingredient list, ready for review before any cooking instructions exist.
/// It is distinct from a validated RecipePlan: an ingredient draft cannot start cooking.
public struct IngredientDraft: Codable, Equatable, Sendable {
    public let dish: String
    public let ingredients: [Ingredient]

    public init(dish: String, ingredients: [Ingredient]) {
        self.dish = dish
        self.ingredients = ingredients
    }

    public var problems: [String] {
        var found: [String] = []
        if dish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dish.count > 80 {
            found.append("dish name must be 1-80 characters")
        }
        if !(1...20).contains(ingredients.count) { found.append("list 1-20 ingredients") }
        if Set(ingredients.map(\.id)).count != ingredients.count { found.append("ingredient ids must be unique") }
        let names = ingredients.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if Set(names).count != names.count { found.append("list each ingredient only once") }
        for ingredient in ingredients {
            if ingredient.id.range(of: #"^[a-z][a-z0-9_]{0,23}$"#, options: .regularExpression) == nil {
                found.append("ingredient ids must be short lowercase identifiers")
            }
            if ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ingredient.name.count > 40 {
                found.append("ingredient names must be 1-40 characters")
            }
            if ingredient.amount.count > 30 { found.append("ingredient amounts must be at most 30 characters") }
        }
        return found
    }

    public static func decode(_ text: String) throws -> IngredientDraft {
        let decoded = try JSONDecoder().decode(Self.self, from: try modelJSON(text))
        let draft = IngredientDraft(dish: decoded.dish.trimmingCharacters(in: .whitespacesAndNewlines),
                                    ingredients: decoded.ingredients.map {
            Ingredient(id: $0.id, name: $0.name.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines), amount: $0.amount.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        guard draft.problems.isEmpty else { throw CoreError.invalidPlan(draft.problems) }
        return draft
    }

    /// Validated app instructions for the exact fixed pasta-salad recipe. Other dishes and edits
    /// still use local Gemma; this is never reported as generated model output.
    public var presetInstructions: RecipePlan? {
        guard let preset = Self.preset(for: dish), ingredients == preset.ingredients else { return nil }
        return RecipePlan(dish: dish, ingredients: ingredients, steps: [
            RecipeStep(id: "cook_pasta", title: "Start the pasta",
                instruction: "Pour water into the pot, turn on the electric cooker, and add the pasta. Follow the pasta package cooking time once the water boils.",
                doneWhen: "pot filled with water, cooker switched on and pasta added", tool: "pot",
                warning: "Keep hands clear of the cooker and steam."),
            RecipeStep(id: "prepare", title: "Prepare vegetables and lemon",
                instruction: "While the pasta cooks, dice onion, cucumber and tomato into 1 cm pieces, then juice the lemon.",
                doneWhen: "vegetables diced to 1 cm and lemon juiced",
                wrongSize: "whole vegetables or pieces larger than 1 cm", tool: "chef's knife"),
            RecipeStep(id: "combine", title: "Mix the salad",
                instruction: "When the pasta is cooked according to its package, turn off the cooker. Drain using a colander, let the pasta cool, then mix with the vegetables and lemon juice.",
                needs: ["cook_pasta", "prepare"], doneWhen: "cooker off, pasta drained and cooled, and salad combined",
                warning: "The pot and cooker can remain hot after switching off. Keep hands clear of steam while draining.")
        ])
    }

    /// The cook-requested app preset, not a model inference result. Other dishes use the local model.
    public static func preset(for request: String) -> IngredientDraft? {
        let words = request.lowercased()
            .replacingOccurrences(of: #"['’]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Match only an unqualified dish request. Allergies, exclusions, additions, servings and
        // other modifiers must reach the local model instead of being overwritten by this preset.
        let plainRequest = #"^(?:(?:please |lets |let us |can you |can we |could you |i want to |i would like to |id like to |we want to )?(?:make|cook)(?: me)? |(?:i want|i would like|id like) |(?:a )?recipe for )?(?:a )?(?:cold )?pasta salad(?: please)?$"#
        guard words.range(of: plainRequest, options: .regularExpression) != nil else { return nil }
        return IngredientDraft(dish: "Pasta salad", ingredients: [
            Ingredient(id: "pasta", name: "pasta", amount: "200 g"),
            Ingredient(id: "lemon", name: "lemon", amount: "1"),
            Ingredient(id: "onion", name: "onion", amount: "1 small"),
            Ingredient(id: "cucumber", name: "cucumber", amount: "1"),
            Ingredient(id: "tomato", name: "tomato", amount: "2")
        ])
    }
}

/// Second-stage output contains instructions only, so the model never regenerates or renames
/// the ingredient list the cook is already reviewing.
public struct RecipeInstructions: Codable, Equatable, Sendable {
    public let steps: [RecipeStep]
    public init(steps: [RecipeStep]) { self.steps = steps }

    public static func decode(_ text: String, for draft: IngredientDraft) throws -> RecipePlan {
        guard draft.problems.isEmpty else { throw CoreError.invalidPlan(draft.problems) }
        let json = try modelJSON(text)
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              Set(object.keys) == ["steps"] else {
            throw CoreError.invalidPlan(["return only steps; the supplied ingredient list is already fixed"])
        }
        let instructions = try JSONDecoder().decode(Self.self, from: json)
        let plan = RecipePlan(dish: draft.dish, ingredients: draft.ingredients, steps: instructions.steps).normalized
        // Normalization can add a forgotten seasoning. A stage-two response must never silently add
        // ingredients after the cook reviewed the list; request a corrected instruction set instead.
        guard plan.ingredients == draft.ingredients else {
            throw CoreError.invalidPlan(["instructions introduced or changed an ingredient; use only the provided list"])
        }
        guard plan.problems.isEmpty else { throw CoreError.invalidPlan(plan.problems) }
        let hasSalt = draft.ingredients.contains { ($0.id + " " + $0.name).lowercased().range(of: #"\bsalt\b"#, options: .regularExpression) != nil }
        if !hasSalt {
            let text = plan.steps.map { [$0.title, $0.instruction, $0.question, $0.doneWhen, $0.guardItem, $0.saves].joined(separator: " ") }.joined(separator: " ")
            guard text.lowercased().range(of: #"\bsalt(?:ed|y)?\b"#, options: .regularExpression) == nil else {
                throw CoreError.invalidPlan(["salt is not in the supplied ingredient list; omit it and any salt-preference question"])
            }
        }
        let allowed = draft.ingredients.flatMap { [$0.id.replacingOccurrences(of: "_", with: " "), $0.name] }
            .map { $0.lowercased() }
        guard plan.steps.filter(\.isGuarded).allSatisfy({ step in
            allowed.contains { CookingSession.sameFood($0, step.guardItem.lowercased()) }
        }) else { throw CoreError.invalidPlan(["a guarded addition uses an ingredient outside the fixed list"]) }
        return plan
    }
}
