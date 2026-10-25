package com.yunha.remy.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * A complete ingredient list, ready for review before any cooking instructions exist.
 * It is distinct from a validated RecipePlan: an ingredient draft cannot start cooking.
 */
data class IngredientDraft(val dish: String, val ingredients: List<Ingredient>) {

    val problems: List<String> get() {
        val found = mutableListOf<String>()
        if (dish.trim().isEmpty() || dish.length > 80) found.add("dish name must be 1-80 characters")
        if (ingredients.size !in 1..20) found.add("list 1-20 ingredients")
        if (ingredients.map { it.id }.toSet().size != ingredients.size) found.add("ingredient ids must be unique")
        val names = ingredients.map { it.name.trim().lowercase() }
        if (names.toSet().size != names.size) found.add("list each ingredient only once")
        for (ingredient in ingredients) {
            if (!ID_PATTERN.containsMatchIn(ingredient.id)) found.add("ingredient ids must be short lowercase identifiers")
            if (ingredient.name.trim().isEmpty() || ingredient.name.length > 40) found.add("ingredient names must be 1-40 characters")
            if (ingredient.amount.length > 30) found.add("ingredient amounts must be at most 30 characters")
        }
        return found
    }

    /**
     * Validated app instructions for the exact fixed pasta-salad recipe. Other dishes and edits
     * still use local Gemma; this is never reported as generated model output.
     */
    val presetInstructions: RecipePlan? get() {
        val preset = preset(dish) ?: return null
        if (ingredients != preset.ingredients) return null
        return RecipePlan(dish, ingredients, listOf(
            RecipeStep(id = "cook_pasta", title = "Start the pasta",
                instruction = "Pour water into the pot, turn on the electric cooker, and add the pasta.",
                doneWhen = "pot filled with water, cooker switched on and pasta added", tool = "pot",
                warning = "Keep hands clear of the cooker and steam."),
            RecipeStep(id = "prepare", title = "Dice the vegetables",
                instruction = "Dice the onion, cucumber and tomato into consistent 1 cm pieces.",
                doneWhen = "vegetables diced into consistent 1 cm pieces",
                wrongSize = "whole vegetables or pieces larger than 1 cm", tool = "chef's knife"),
            RecipeStep(id = "finish_dish", title = "Mix and finish",
                instruction = "Add all the ingredients together, mix, and juice the lemon. Show the dish to the camera and tell me when it's ready.",
                needs = listOf("cook_pasta", "prepare"), doneWhen = "cook presents the finished dish and says it is ready"),
        ))
    }

    fun toJsonObject(): JSONObject = JSONObject().put("dish", dish)
        .put("ingredients", JSONArray().apply { ingredients.forEach { put(it.toJsonObject()) } })

    companion object {
        private val ID_PATTERN = Regex("^[a-z][a-z0-9_]{0,23}$")

        fun decode(text: String): IngredientDraft {
            val o = Json.parseObject(modelJSON(text))
            val decoded = IngredientDraft(Json.str(o, "dish"), Json.objects(o, "ingredients").map(Ingredient::fromJsonObject))
            val draft = IngredientDraft(decoded.dish.trim(), decoded.ingredients.map {
                Ingredient(it.id, it.name.replace("_", " ").trim(), it.amount.trim())
            })
            if (draft.problems.isNotEmpty()) throw CoreError.InvalidPlan(draft.problems)
            return draft
        }

        // Match only an unqualified dish request. Allergies, exclusions, additions, servings and
        // other modifiers must reach the local model instead of being overwritten by this preset.
        private val PLAIN_REQUEST = Regex("^(?:(?:please |lets |let us |can you |can we |could you |i want to |i would like to |id like to |we want to )?(?:make|cook)(?: me)? |(?:i want|i would like|id like) |(?:a )?recipe for )?(?:a )?(?:cold )?pasta salad(?: please)?$")

        /** The cook-requested app preset, not a model inference result. Other dishes use the local model. */
        fun preset(request: String): IngredientDraft? {
            val words = request.lowercase()
                .replace(Regex("['’]"), "")
                .replace(Regex("[^a-z0-9]+"), " ")
                .trim()
            if (!PLAIN_REQUEST.containsMatchIn(words)) return null
            return IngredientDraft("Pasta salad", listOf(
                Ingredient("pasta", "pasta", "200 g"),
                Ingredient("lemon", "lemon", "1"),
                Ingredient("onion", "onion", "1 small"),
                Ingredient("cucumber", "cucumber", "1"),
                Ingredient("tomato", "tomato", "2"),
            ))
        }
    }
}

/**
 * Second-stage output contains instructions only, so the model never regenerates or renames
 * the ingredient list the cook is already reviewing.
 */
data class RecipeInstructions(val steps: List<RecipeStep>) {
    fun toJsonObject(): JSONObject = JSONObject().put("steps", JSONArray().apply { steps.forEach { put(it.toJsonObject()) } })
    fun toJson(): String = toJsonObject().toString()

    companion object {
        fun decode(text: String, draft: IngredientDraft): RecipePlan {
            if (draft.problems.isNotEmpty()) throw CoreError.InvalidPlan(draft.problems)
            val parsed = Json.parse(modelJSON(text))
            if (parsed !is JSONObject || Json.keys(parsed) != setOf("steps")) {
                throw CoreError.InvalidPlan(listOf("return only steps; the supplied ingredient list is already fixed"))
            }
            val instructions = RecipeInstructions(Json.objects(parsed, "steps").map(RecipeStep::fromJsonObject))
            val plan = RecipePlan(draft.dish, draft.ingredients, instructions.steps).normalized
            // Normalization can add a forgotten seasoning. A stage-two response must never silently add
            // ingredients after the cook reviewed the list; request a corrected instruction set instead.
            if (plan.ingredients != draft.ingredients) {
                throw CoreError.InvalidPlan(listOf("instructions introduced or changed an ingredient; use only the provided list"))
            }
            if (plan.problems.isNotEmpty()) throw CoreError.InvalidPlan(plan.problems)
            val hasSalt = draft.ingredients.any { Regex("\\bsalt\\b").containsMatchIn((it.id + " " + it.name).lowercase()) }
            if (!hasSalt) {
                val text = plan.steps.joinToString(" ") { listOf(it.title, it.instruction, it.question, it.doneWhen, it.guardItem, it.saves).joinToString(" ") }
                if (Regex("\\bsalt(?:ed|y)?\\b").containsMatchIn(text.lowercase())) {
                    throw CoreError.InvalidPlan(listOf("salt is not in the supplied ingredient list; omit it and any salt-preference question"))
                }
            }
            val allowed = draft.ingredients.flatMap { listOf(it.id.replace("_", " "), it.name) }.map { it.lowercase() }
            if (!plan.steps.filter { it.isGuarded }.all { step -> allowed.any { CookingSession.sameFood(it, step.guardItem.lowercase()) } }) {
                throw CoreError.InvalidPlan(listOf("a guarded addition uses an ingredient outside the fixed list"))
            }
            return plan
        }
    }
}
