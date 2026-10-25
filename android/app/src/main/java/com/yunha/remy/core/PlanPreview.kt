package com.yunha.remy.core

/**
 * What can already be shown from a recipe plan Gemma is still writing: the dish, the ingredient list once it is
 * complete, and every step whose JSON object has closed. Nothing here is validated; the finished plan still is.
 */
data class PlanPreview(
    val dish: String? = null,
    val ingredients: List<Ingredient> = emptyList(),
    val steps: List<RecipeStep> = emptyList(),
) {
    companion object {
        private val DISH = Regex("\"dish\"\\s*:\\s*\"([^\"\\\\]*)\"")
        private val INGREDIENTS = Regex("\"ingredients\"\\s*:\\s*\\[")
        private val STEPS = Regex("\"steps\"\\s*:\\s*\\[")

        /** Swift `PlanPreview(streamed:)`. */
        fun streamed(text: String): PlanPreview {
            val dish = DISH.find(text)?.groupValues?.get(1)?.ifEmpty { null }
            val ingredientsStart = INGREDIENTS.find(text) ?: return PlanPreview(dish)
            val ingredients = closedObjects(text, ingredientsStart.range.last + 1).mapNotNull { json ->
                try { Ingredient.fromJsonObject(Json.parseObject(json)) } catch (_: Exception) { null }
            }
            val stepsStart = STEPS.find(text) ?: return PlanPreview(dish, ingredients)
            val steps = closedObjects(text, stepsStart.range.last + 1).mapNotNull { json ->
                try { RecipeStep.fromJsonObject(Json.parseObject(json)) } catch (_: Exception) { null }
            }
            return PlanPreview(dish, ingredients, steps)
        }

        /** Top-level `{...}` objects in an array body, skipping braces inside strings. Stops at the array's `]`. */
        private fun closedObjects(text: String, from: Int): List<String> {
            val objects = mutableListOf<String>()
            var depth = 0; var inString = false; var escaped = false
            var start = -1
            var index = from
            while (index < text.length) {
                val char = text[index]
                if (inString) {
                    if (escaped) escaped = false else if (char == '\\') escaped = true else if (char == '"') inString = false
                } else if (char == '"') {
                    inString = true
                } else if (char == '{') {
                    if (depth == 0) start = index
                    depth += 1
                } else if (char == '}') {
                    depth -= 1
                    if (depth == 0 && start >= 0) { objects.add(text.substring(start, index + 1)); start = -1 }
                } else if (char == ']' && depth == 0) {
                    break
                }
                index += 1
            }
            return objects
        }
    }
}
