package com.yunha.remy.core

import org.json.JSONObject

// Kotlin port of ChefCore/DishAssessment.swift and ReachTracker.swift / FastObjectPresentation.swift.

class AssessmentException(message: String) : Exception(message)

/** Separate observation from judgment so the review must first inspect the actual image. */
data class DishPhotoEvidence(val dishVisible: Boolean, val ingredients: String, val cuts: String, val presentation: String, val uncertainty: String) {
    fun toJson(): String = JSONObject().put("dishVisible", dishVisible).put("ingredients", ingredients).put("cuts", cuts)
        .put("presentation", presentation).put("uncertainty", uncertainty).toString()

    companion object {
        fun decode(text: String): DishPhotoEvidence {
            val o = Json.parseObject(modelJSON(text))
            val value = DishPhotoEvidence(Json.bool(o, "dishVisible"), Json.str(o, "ingredients"), Json.str(o, "cuts"),
                Json.str(o, "presentation"), Json.str(o, "uncertainty"))
            if (!listOf(value.ingredients, value.cuts, value.presentation, value.uncertainty).all { it.trim().isNotEmpty() && it.length <= 500 }) {
                throw AssessmentException("missing summary")
            }
            return value
        }
    }
}

data class DishAssessment(val dishVisible: Boolean, val stars: Double, val summary: String, val ingredientBalance: String,
                          val cutConsistency: String, val portionPresentation: String, val improvements: String) {
    fun toJsonObject(): JSONObject = JSONObject().put("dishVisible", dishVisible).put("stars", stars).put("summary", summary)
        .put("ingredientBalance", ingredientBalance).put("cutConsistency", cutConsistency)
        .put("portionPresentation", portionPresentation).put("improvements", improvements)

    companion object {
        fun decode(text: String): DishAssessment {
            val o = Json.parseObject(modelJSON(text))
            val value = DishAssessment(Json.bool(o, "dishVisible"), Json.num(o, "stars"), Json.str(o, "summary"),
                Json.str(o, "ingredientBalance"), Json.str(o, "cutConsistency"), Json.str(o, "portionPresentation"), Json.str(o, "improvements"))
            if (!value.stars.isFinite() || value.stars !in 0.0..5.0 || !(value.dishVisible || value.stars == 0.0)) throw AssessmentException("invalid rating")
            val sections = listOf(value.summary, value.ingredientBalance, value.cutConsistency, value.portionPresentation, value.improvements)
            if (!sections.all { s -> s.trim().isNotEmpty() && s.length <= 140 && s.split(Regex("\\s+")).filter { it.isNotEmpty() }.size <= 22 }) {
                throw AssessmentException("missing summary")
            }
            return value
        }
    }
}

/** A declaration, not a question or a qualified "almost ready". */
object DishReadySignal {
    private val PATTERN = Regex("^(?:(?:okay|ok|yes) )?(?:ready(?: now| for the camera| to show you)?|(?:i'm|i am|we're|we are|it's|it is|the dish is|my dish is|the salad is) ready(?: now)?|(?:i'm|i am|we're|we are) done(?: mixing)?|all done|done|finished|(?:here's|here is) (?:my|the) dish (?:it's|it is) ready)$")
    fun matches(text: String): Boolean {
        if (text.contains("?")) return false
        val words = text.lowercase().replace("’", "'").replace(Regex("[^a-z' ]"), " ")
            .split(" ").filter { it.isNotEmpty() }.joinToString(" ")
        return PATTERN.containsMatchIn(words)
    }
}

/** Predicts an image-plane approach, not a physical collision. Call separately for each tracked hand. */
class ReachTracker {
    private var previous: Point2? = null
    private var previousTime: Double? = null
    private var lastAlert = Double.NEGATIVE_INFINITY

    fun reset() { previous = null; previousTime = null }

    fun update(point: Point2?, time: Double, zone: GuardZone?, armed: Boolean): Boolean {
        if (!time.isFinite() || point == null || !point.isValid) { reset(); return false }
        val prev = previous; val prevTime = previousTime
        previous = point; previousTime = time
        if (!armed || zone == null || !zone.isValid || prev == null || prevTime == null) return false
        val dt = time - prevTime
        if (dt !in 0.015..0.3 || time - lastAlert <= 3) return false
        val speed = point.distance(prev) / dt
        if (!(speed >= 0.08 && speed <= 3 && point.distance(zone.center) < prev.distance(zone.center))) return false
        val projected = Point2(point.x + (point.x - prev.x) / dt * 0.25, point.y + (point.y - prev.y) / dt * 0.25)
        // Distance from the zone to the complete predicted path avoids skipping over a small zone.
        val dx = projected.x - point.x; val dy = projected.y - point.y
        val length2 = dx * dx + dy * dy
        if (length2 <= 0) return false
        val t = maxOf(0.0, minOf(1.0, ((zone.center.x - point.x) * dx + (zone.center.y - point.y) * dy) / length2))
        val nearest = Point2(point.x + t * dx, point.y + t * dy)
        if (!zone.contains(nearest)) return false
        lastAlert = time; return true
    }
}

/**
 * Presentation policy for a generic COCO detector, not ingredient recognition. COCO has no
 * cucumber, onion, tomato, or lemon class; those can be forced into a visually similar class.
 */
object FastObjectPresentation {
    private val produce = setOf("banana", "apple", "orange", "broccoli", "carrot")
    private val preparedFood = setOf("sandwich", "hot dog", "pizza", "donut", "cake")

    fun displayLabel(detectorLabel: String): String {
        val normalized = detectorLabel.trim().lowercase()
        if (normalized in produce) return "Produce"
        if (normalized in preparedFood) return "Food"
        return detectorLabel
    }

    fun isSpecificIdentityReliable(detectorLabel: String): Boolean {
        val normalized = detectorLabel.trim().lowercase()
        return normalized.isNotEmpty() && normalized !in listOf("produce", "food") && normalized !in produce && normalized !in preparedFood
    }

    fun displayBox(box: ItemBox): ItemBox = ItemBox(displayLabel(box.label), box.x, box.y, box.width, box.height)
}
