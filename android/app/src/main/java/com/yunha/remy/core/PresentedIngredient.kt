package com.yunha.remy.core

/** A request to look at an item, never evidence that the item is present. */
data class IngredientPresentationCue(val ingredientID: String?) {
    companion object {
        // Wake words kept exactly as the Swift source on this branch defines them for this cue.
        private val WAKE = Regex("^\\W*((hey|ok|okay|yes) )?(chef|chief|shef)\\b[, ]*")

        fun parse(text: String, ingredients: List<Ingredient>): IngredientPresentationCue? {
            val body = text.lowercase().replace("’", "'")
                .replace(WAKE, "")
                .replace(Regex("[^a-z0-9' ]"), " ")
                .split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            if (body in listOf("what is this", "what's this", "identify this", "check this", "check my ingredients", "check ingredients", "first ingredient", "next ingredient")) {
                return IngredientPresentationCue(null)
            }
            val prefixes = listOf("here's ", "heres ", "here is ", "these are ", "this is ", "i have ", "i've got ", "i got ")
            val prefix = prefixes.firstOrNull { body.startsWith(it) } ?: return null
            var subject = body.drop(prefix.length)
            for (article in listOf("the ", "my ", "an ", "a ")) {
                if (subject.startsWith(article)) { subject = subject.drop(article.length); break }
            }
            if (subject in listOf("first ingredient", "next ingredient", "ingredient", "first one", "next one")) {
                return IngredientPresentationCue(null)
            }
            val matches = ingredients.filter { IngredientVisualIdentity.sameFood(subject, it.name) || IngredientVisualIdentity.sameFood(subject, it.id) }
            if (matches.size == 1) return IngredientPresentationCue(matches[0].id)
            val words = subject.split(" ").filter { it.isNotEmpty() }
            if (words.isEmpty() || words.size > 6 || words.any { it in listOf("not", "and", "how", "why", "problem", "question") }) return null
            return IngredientPresentationCue(null)
        }
    }
}

/** Identity from image evidence, independent of the cook's spoken guess and COCO detector labels. */
data class IngredientVisualIdentity(
    val name: String,
    val confidence: Double,
    val evidence: String,
    /** [top, left, bottom, right], Gemma's documented 0...1000 image grid. */
    val box_2d: List<Double>,
) {
    val box: ItemBox? get() {
        if (box_2d.size != 4 || !box_2d.all { it.isFinite() && it in 0.0..1000.0 } || box_2d[2] <= box_2d[0] || box_2d[3] <= box_2d[1]) return null
        return ItemBox(name, box_2d[1] / 1000, box_2d[0] / 1000, (box_2d[3] - box_2d[1]) / 1000, (box_2d[2] - box_2d[0]) / 1000)
    }

    /** Confidence is an uncalibrated model report; agreement with a second crop is also required. */
    val isSupported: Boolean get() =
        confidence >= 0.8 && box != null && evidence.length >= 6 && !isUnknown(name) && !isAmbiguous(evidence)

    fun isCorroborated(verification: IngredientVisualVerification): Boolean {
        if (!isSupported || !verification.matches || verification.confidence < 0.8 || verification.evidence.length < 6 ||
            isAmbiguous(verification.evidence) || !sameFood(name, verification.name)) return false
        // White powder or a clear liquid cannot prove its identity from appearance alone.
        if (canonical(name) in listOf("salt", "sugar", "oil")) {
            val text = (evidence + " " + verification.evidence).lowercase()
            val labelled = text.contains("label") || text.contains("printed") || text.contains("package text")
            val saltContainer = name.lowercase() in listOf("salt shaker", "salt grinder", "salt bottle") &&
                text.contains("crystal") && !text.contains("pepper")
            if (!(labelled || saltContainer)) return false
        }
        return true
    }

    fun confirmedIngredient(ingredients: List<Ingredient>, verification: IngredientVisualVerification): Ingredient? {
        if (!isCorroborated(verification)) return null
        val matches = ingredients.filter { sameFood(name, it.name) || sameFood(name, it.id) }
        return if (matches.size == 1) matches[0] else null
    }

    companion object {
        fun decode(text: String): IngredientVisualIdentity {
            val o = Json.parseObject(modelJSON(text))
            val boxArray = Json.arr(o, "box_2d")
            val box = (0 until boxArray.length()).map { (boxArray.opt(it) as? Number)?.toDouble() ?: throw org.json.JSONException("box_2d") }
            val value = IngredientVisualIdentity(Json.str(o, "name"), Json.num(o, "confidence"), Json.str(o, "evidence"), box)
            if (value.name.isEmpty() || value.name.length > 60 || value.evidence.length > 300 || !value.confidence.isFinite() ||
                value.confidence !in 0.0..1.0 || !(value.box_2d.isEmpty() || value.box != null)) throw CoreError.InvalidObservation()
            return value
        }

        private fun isUnknown(text: String): Boolean =
            canonical(text) in listOf("unknown", "none", "uncertain", "food", "produce", "vegetable", "fruit")

        private fun isAmbiguous(text: String): Boolean {
            val lower = text.lowercase()
            return listOf("maybe", "might be", "could be", "not clear", "uncertain", "cannot tell", "can't tell").any { lower.contains(it) }
        }

        fun sameFood(a: String, b: String): Boolean {
            val left = canonical(a); val right = canonical(b)
            return left.isNotEmpty() && !isUnknown(left) && left == right
        }

        private val ALIASES = mapOf(
            "onions" to "onion", "red onion" to "onion", "yellow onion" to "onion", "white onion" to "onion", "purple onion" to "onion",
            "cucumbers" to "cucumber", "sliced cucumber" to "cucumber", "whole cucumber" to "cucumber",
            "tomatoes" to "tomato", "cherry tomato" to "tomato", "cherry tomatoes" to "tomato", "roma tomato" to "tomato",
            "lemons" to "lemon", "lemon half" to "lemon", "cooked pasta" to "pasta", "dry pasta" to "pasta", "dried pasta" to "pasta",
            "salt shaker" to "salt", "salt grinder" to "salt", "salt bottle" to "salt",
            "boxed pasta" to "pasta", "pasta box" to "pasta", "box of pasta" to "pasta", "rotini box" to "pasta", "box of rotini" to "pasta",
            "rotini" to "pasta", "fusilli" to "pasta", "penne" to "pasta", "spaghetti" to "pasta",
            "table salt" to "salt", "apples" to "apple", "oranges" to "orange", "bananas" to "banana",
        )

        fun canonical(text: String): String {
            val value = text.lowercase().replace("_", " ").split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            return ALIASES[value] ?: value
        }
    }
}

data class IngredientVisualVerification(val matches: Boolean, val name: String, val confidence: Double, val evidence: String) {
    companion object {
        fun decode(text: String): IngredientVisualVerification {
            val o = Json.parseObject(modelJSON(text))
            val value = IngredientVisualVerification(Json.bool(o, "matches"), Json.str(o, "name"), Json.num(o, "confidence"), Json.str(o, "evidence"))
            if (value.name.isEmpty() || value.name.length > 60 || value.evidence.length > 300 || !value.confidence.isFinite() ||
                value.confidence !in 0.0..1.0) throw CoreError.InvalidObservation()
            return value
        }
    }
}

/** Exact short product labels only. A recipe sentence or "salt-free" claim is not a salt label. */
object PackageIngredientLabel {
    fun food(text: String): String? {
        val label = text.lowercase().trim().replace(Regex("[®™]"), "")
        if (label in listOf("salt", "sea salt", "table salt", "iodized salt", "pink salt", "himalayan pink salt", "rock salt")) return "salt"
        if (label in listOf("pasta", "rotini", "fusilli", "penne", "spaghetti", "whole wheat rotini", "gluten free rotini")) return "pasta"
        return null
    }
}
