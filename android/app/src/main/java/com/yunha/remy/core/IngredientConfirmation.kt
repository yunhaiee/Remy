package com.yunha.remy.core

import java.text.Normalizer

/**
 * A deliberately small local shortcut for pantry review while the on-device model prepares
 * instructions. Parse only an already-addressed utterance body, after the caller removes the
 * wake word. Other conversation stays with the chef instead of guessing from keywords.
 */
data class IngredientConfirmation(val ingredientID: String, val status: PantryStatus) {
    companion object {
        private val PREFIXES = listOf(
            "i don't have " to PantryStatus.MISSING, "i dont have " to PantryStatus.MISSING, "i do not have " to PantryStatus.MISSING,
            "i have " to PantryStatus.SEEN, "got " to PantryStatus.SEEN, "no " to PantryStatus.MISSING,
        )

        fun parse(utterance: String, ingredients: List<Ingredient>): IngredientConfirmation? {
            // An explicit question is not a statement that the ingredient is available or missing.
            if (utterance.contains("?")) return null
            val text = normalize(utterance)
            if (text.isEmpty()) return null
            val subject: String
            val status: PantryStatus
            val match = PREFIXES.firstOrNull { text.startsWith(it.first) }
            if (match != null) {
                subject = text.drop(match.first.length); status = match.second
            } else if (text.endsWith(" is missing")) {
                subject = text.dropLast(" is missing".length); status = PantryStatus.MISSING
            } else return null
            if (subject.isEmpty()) return null
            val candidates = ingredients.filter { ingredient ->
                ingredient.id.isNotEmpty() && (normalize(ingredient.name) == subject || normalize(ingredient.id) == subject)
            }
            // The full subject must name exactly one current ingredient, without quantities, plural
            // guessing, articles, conjunction splitting, substitutions, or substring matching.
            if (candidates.size != 1) return null
            return IngredientConfirmation(candidates[0].id, status)
        }

        private fun normalize(text: String): String =
            Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()
                .replace("’", "'")
                .replace(Regex("[^\\p{L}\\p{N}' ]"), " ")
                .split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
    }
}
