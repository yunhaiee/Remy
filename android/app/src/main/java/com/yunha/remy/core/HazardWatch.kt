package com.yunha.remy.core

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import org.json.JSONArray
import org.json.JSONObject

// Kotlin port of RemyCore (Contracts.Point2, ItemBox, HazardWatch.swift). Pure math, no Android types,
// so the same tests run in JUnit. Keep it 1:1 with the Swift source.

data class Point2(val x: Double, val y: Double) {
    val isValid: Boolean get() = x.isFinite() && y.isFinite() && x in 0.0..1.0 && y in 0.0..1.0
    fun distance(other: Point2): Double = hypot(x - other.x, y - other.y)
}

/** Where Gemma found an item, as fractions of the image (top-left origin), the same space as the hand landmarks. */
data class ItemBox(val label: String, val x: Double, val y: Double, val width: Double, val height: Double) {
    val center: Point2 get() = Point2(x + width / 2, y + height / 2)

    companion object {
        /**
         * Gemma 4 answers "What's the bounding box for the X" with box_2d [ymin, xmin, ymax, xmax] on a 0-1000 grid,
         * as a JSON list (sometimes in a ```json fence) or a single object. A box covering nearly the whole image is
         * dropped: that is Gemma not knowing, not a location.
         */
        fun parse(text: String): List<ItemBox> {
            val start = text.indexOfFirst { it == '[' || it == '{' }
            val end = text.indexOfLast { it == ']' || it == '}' }
            if (start < 0 || end <= start) return emptyList()
            val json = text.substring(start, end + 1)
            val raws: List<JSONObject> = try {
                if (json.startsWith("[")) JSONArray(json).let { array -> (0 until array.length()).map { array.getJSONObject(it) } }
                else listOf(JSONObject(json))
            } catch (_: Exception) { return emptyList() }
            return raws.mapNotNull { raw ->
                val box = raw.optJSONArray("box_2d") ?: return@mapNotNull null
                if (box.length() != 4) return@mapNotNull null
                val v = (0 until 4).map { (box.optDouble(it).coerceIn(0.0, 1000.0)) / 1000 }
                if (v.any { it.isNaN() }) return@mapNotNull null
                val (top, left, bottom, right) = v
                if (!(bottom > top && right > left && (bottom - top) * (right - left) < 0.9)) return@mapNotNull null
                val label = raw.optString("label", "").replace(Regex("^the ", RegexOption.IGNORE_CASE), "")
                ItemBox(label, left, top, right - left, bottom - top)
            }
        }
    }
}

/**
 * Something hot on the counter as a box in the camera picture, in the same normalized space as the hand landmarks.
 * Gemma finds it once; the fast loop then checks every hand frame against it, with no model call.
 */
data class HazardZone(val label: String, val x: Double, val y: Double, val width: Double, val height: Double) {
    constructor(box: ItemBox, label: String? = null) : this(label ?: box.label, box.x, box.y, box.width, box.height)

    val center: Point2 get() = Point2(x + width / 2, y + height / 2)

    /** Two names for one object ("pot" and "pan" on the same box) must not become two zones that alarm twice. */
    fun overlaps(other: HazardZone, threshold: Double = 0.6): Boolean {
        val w = max(0.0, min(x + width, other.x + other.width) - max(x, other.x))
        val h = max(0.0, min(y + height, other.y + other.height) - max(y, other.y))
        val intersection = w * h
        val union = width * height + other.width * other.height - intersection
        return union > 0 && intersection / union >= threshold
    }

    /** Inside the box, or within `margin` of it (a hand about to touch counts). */
    fun contains(point: Point2, margin: Double): Boolean =
        point.x >= x - margin && point.x <= x + width + margin && point.y >= y - margin && point.y <= y + height + margin

    /** Landmark and skeletal-segment intersection in normalized image coordinates. */
    fun intersectsHand(points: List<Point2>): Boolean {
        if (points.any { it.isValid && contains(it, 0.0) }) return true
        if (points.size != 21 || !points.all { it.isValid }) return false
        return EDGES.any { (a, b) ->
            val start = points[a]; val end = points[b]
            var lower = 0.0; var upper = 1.0
            val dx = end.x - start.x; val dy = end.y - start.y
            for ((p, q) in listOf(-dx to start.x - x, dx to x + width - start.x, -dy to start.y - y, dy to y + height - start.y)) {
                if (abs(p) < 1e-12) { if (q < 0) return@any false; continue }
                val ratio = q / p
                if (p < 0) lower = max(lower, ratio) else upper = min(upper, ratio)
                if (lower > upper) return@any false
            }
            true
        }
    }

    companion object {
        private val EDGES = listOf(0 to 1, 1 to 2, 2 to 3, 3 to 4, 0 to 5, 5 to 6, 6 to 7, 7 to 8, 5 to 9, 9 to 10, 10 to 11, 11 to 12,
            9 to 13, 13 to 14, 14 to 15, 15 to 16, 13 to 17, 17 to 18, 18 to 19, 19 to 20, 17 to 0)

        /**
         * Whether a name Gemma gave for "something hot" is heat at all. A 2B model also lists knives and boards when
         * asked what could hurt; a knife is handled on purpose while cutting and must not sound the heat alarm.
         */
        fun looksHot(name: String): Boolean {
            val lower = name.lowercase()
            val heat = listOf("pot", "pan", "kettle", "cooker", "skillet", "wok", "stove", "burner", "oven", "toaster", "grill",
                "griddle", "steam", "boil", "fryer", "hot plate", "hotplate", "electric", "heater", "teapot",
                "microwave", "flame", "fire", "element")
            return heat.any { lower.contains(it) } && !lower.contains("knife") && !lower.contains("blade")
        }
    }
}

/**
 * Requires a reliable, current hand. Default mode requires all 21 landmarks inside;
 * overlap mode accepts visible valid landmarks or skeletal segments, with configurable dwell.
 * The separately configured proximity mode accepts a landmark in an expanded image-space box.
 * After an alert, observed proximity/contact prevents rearming until the hand has stayed clear.
 */
class HazardWatch {
    /** All MediaPipe landmarks, ordered 0...20, including the wrist at index 0. */
    data class Hand(val id: String, val points: List<Point2>, val isReliable: Boolean = true)

    /** Optional image-space buffer. Zero preserves the whole-hand rule. */
    var proximityMargin = 0.0
    var anyPartOverlap = false
    var minimumContactDuration = 0.0
    /** Level-triggered mode: return the active zone on every overlapping frame after dwell, with no cooldown. */
    var holdsAlertUntilExit = false
    val hasContact: Boolean get() = contactSince.isNotEmpty()
    private var contactSince = mutableMapOf<String, Double>()
    /** Maximum capture-to-check age; old frames must not sound a current warning. */
    var maximumFrameAge = 0.3
    /** Shortest gap between two alarms for one zone. */
    var cooldown = 2.0
    /** How long a hand must stay completely clear before the zone can alarm again. */
    var rearmAfter = 1.0
    private val lastAlert = mutableMapOf<String, Double>()
    private var clearSince = mutableMapOf<String, Double>()
    private var lastSampleTime: Double? = null

    fun reset() { clearSince.clear(); contactSince.clear(); lastSampleTime = null }

    /**
     * The approached/entered zone for a complete hand, if armed. `time` is the matching camera frame's
     * monotonic capture timestamp and `now` is the current monotonic clock, in seconds.
     */
    fun check(hands: List<Hand>, zones: List<HazardZone>, time: Double, now: Double): HazardZone? {
        if (!(time.isFinite() && now.isFinite() && maximumFrameAge.isFinite() && maximumFrameAge >= 0 &&
                now >= time && now - time <= maximumFrameAge)) {
            // A tracking gap is not evidence that the hand stayed clear during that gap.
            clearSince.clear(); contactSince.clear()
            return null
        }
        lastSampleTime?.let { if (time <= it) return null }
        lastSampleTime?.let { previous -> if (time - previous > maximumFrameAge) contactSince.clear() }
        lastSampleTime = time
        if (zones.isEmpty()) contactSince.clear()
        val counts = hands.groupingBy { it.id }.eachCount()
        val completeHands = hands.filter { hand ->
            hand.isReliable && hand.id.isNotEmpty() && hand.id != "unknown" && counts[hand.id] == 1 &&
                (if (anyPartOverlap) hand.points.size in 1..21 && hand.points.any { it.isValid }
                 else hand.points.size == 21 && hand.points.all { it.isValid })
        }
        val activePrefixes = zones.mapIndexed { index, zone -> "${zone.label}#$index|" }
        contactSince = contactSince.filterKeys { key -> activePrefixes.any { key.startsWith(it) } }.toMutableMap()
        var hit: HazardZone? = null
        for ((zoneIndex, zone) in zones.withIndex()) {
            if (!(zone.x.isFinite() && zone.y.isFinite() && zone.width.isFinite() && zone.height.isFinite() &&
                    zone.x >= 0 && zone.y >= 0 && zone.width > 0 && zone.height > 0 &&
                    zone.x + zone.width <= 1 && zone.y + zone.height <= 1)) continue
            val margin = if (proximityMargin.isFinite()) min(0.15, max(0.0, proximityMargin)) else 0.0
            val contacting = completeHands.filter { hand ->
                if (anyPartOverlap) zone.intersectsHand(hand.points)
                else if (margin > 0) hand.points.any { zone.contains(it, margin) }
                else hand.points.all { zone.contains(it, 0.0) }
            }
            val prefix = "${zone.label}#$zoneIndex|"
            val keys = contacting.map { prefix + it.id }.toSet()
            for (key in contactSince.keys.toList()) if (key.startsWith(prefix) && key !in keys) contactSince.remove(key)
            for (key in keys) if (key !in contactSince) contactSince[key] = time
            val sustained = keys.any { time - (contactSince[it] ?: time) >= max(0.0, minimumContactDuration) }
            // Partial or uncertain hands cannot fire, but observed contact must not re-arm a
            // previously fired zone while that hand is still handling it.
            val touching = hands.any { hand ->
                (anyPartOverlap && hand.points.all { it.isValid } && zone.intersectsHand(hand.points)) ||
                    hand.points.any { it.isValid && zone.contains(it, margin) }
            }
            val clearFor = clearSince[zone.label]?.let { time - it }
            val armed = lastAlert[zone.label] == null || (clearFor ?: 0.0) >= rearmAfter
            val rested = time - (lastAlert[zone.label] ?: Double.NEGATIVE_INFINITY) >= cooldown
            if (hit == null && sustained && (holdsAlertUntilExit || (armed && rested))) {
                lastAlert[zone.label] = time
                hit = zone
            }
            if (touching) clearSince.remove(zone.label)
            else if (zone.label !in clearSince) clearSince[zone.label] = time
        }
        return hit
    }
}

/** Visible vessel names that can supply a real heat-caution box. */
object CookerSafetyTargets {
    val queries = listOf("pot", "pan", "electric cooker", "kettle", "cup", "bowl")
    private val vessel = Regex("""\b(pots?|pans?|cooker|kettle|cups?|mugs?|bowls?|hot ?plate|stove|burner)\b""")

    fun zones(boxes: List<ItemBox>): List<HazardZone> {
        val zones = mutableListOf<HazardZone>()
        for (box in boxes) {
            if (!vessel.containsMatchIn(box.label.lowercase()) || !(box.x.isFinite() && box.y.isFinite() &&
                    box.width.isFinite() && box.height.isFinite() && box.x >= 0 && box.y >= 0 && box.width > 0 &&
                    box.height > 0 && box.x + box.width <= 1 && box.y + box.height <= 1)) continue
            val zone = HazardZone(box)
            if (zones.none { it.overlaps(zone) }) zones.add(zone)
        }
        return zones.take(2)
    }
}

/** Explicit power reports only. Questions, negations and future intentions must not arm a warning. */
enum class CookerPowerCommand {
    ON, OFF;

    companion object {
        fun parse(text: String): CookerPowerCommand? {
            if (text.contains("?")) return null
            val words = text.lowercase().replace("’", "'").replace("'s", " is")
                .replace(Regex("[^a-z0-9' ]"), " ")
                .split(" ").filter { it.isNotEmpty() }.joinToString(" ")
            val target = """(?:the |my )?(?:kettle|cooker|stove|pot|cup|bowl|hot ?plate|burner|it)"""
            val report = """(?:(?:i |i've |i have |we |we've |we have )?(?:just |already )?(?:turned|switched|powered) (?:""" + target +
                """ (?:back )?(on|off)|(on|off) """ + target + """)|""" + target +
                """ (?:is |was |has been |s )?(?:now |back )?(?:turned |switched |powered )?(on|off)(?: now| again)?)"""
            val pattern = "^(?:okay |ok |yes |and )?$report(?: please| now| again| thanks)?$"
            val match = Regex(pattern).find(words) ?: return null
            val state = match.groupValues.drop(1).firstOrNull { it.isNotEmpty() } ?: return null
            return if (state == "on") ON else OFF
        }
    }
}
