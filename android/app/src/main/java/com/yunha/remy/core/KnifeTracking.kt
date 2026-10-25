package com.yunha.remy.core

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

// Kotlin port of ChefCore/KnifeTracking.swift. Times in seconds.

data class KnifeCandidate(val box: ItemBox, val score: Double)

/** Geometry and semantic gates for one persistent knife target. Does not infer blade edges. */
object KnifeAssociation {
    private val KNIFE = Regex("""\b(?:knife|knives)\b""")
    fun isKnife(label: String): Boolean = KNIFE.containsMatchIn(label.lowercase())

    fun valid(box: ItemBox): Boolean =
        isKnife(box.label) && listOf(box.x, box.y, box.width, box.height).all { it.isFinite() } &&
            box.x >= 0 && box.y >= 0 && box.width > 0 && box.height > 0 &&
            box.x + box.width <= 1 && box.y + box.height <= 1 &&
            box.width * box.height > 0.00002 && box.width * box.height < 0.85

    fun iou(a: ItemBox, b: ItemBox): Double {
        val area = max(0.0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x)) * max(0.0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        val union = a.width * a.height + b.width * b.height - area
        return if (union > 0) area / union else 0.0
    }

    fun matches(candidate: ItemBox, previous: ItemBox): Boolean {
        if (!valid(candidate) || !valid(previous)) return false
        val ratio = candidate.width * candidate.height / (previous.width * previous.height)
        if (ratio !in 0.15..6.0) return false
        val distance = hypot(candidate.center.x - previous.center.x, candidate.center.y - previous.center.y)
        return iou(candidate, previous) >= 0.05 || distance <= max(0.12, hypot(previous.width, previous.height) * 0.65)
    }

    fun select(candidates: List<KnifeCandidate>, previous: ItemBox?): KnifeCandidate? {
        val valid = candidates.filter { valid(it.box) && it.score.isFinite() && it.score in 0.25..1.0 }
        if (previous != null) {
            fun cost(c: KnifeCandidate) = hypot(c.box.center.x - previous.center.x, c.box.center.y - previous.center.y) +
                (1 - iou(c.box, previous)) * 0.2 - c.score * 0.02
            return valid.filter { matches(it.box, previous) }.minByOrNull(::cost)
        }
        return valid.maxWithOrNull(compareBy<KnifeCandidate> { it.score }.thenBy { it.box.width * it.box.height })
    }
}

/** A weak classifier hit must agree across three fresh detections; a strong hit can seed immediately. */
class KnifeCandidateGate {
    private var previous: ItemBox? = null
    private var lastTime: Double? = null
    private var consecutive = 0

    fun reset() { previous = null; lastTime = null; consecutive = 0 }

    fun accepts(candidate: KnifeCandidate, time: Double): Boolean {
        if (!KnifeAssociation.valid(candidate.box) || !candidate.score.isFinite() || candidate.score !in 0.25..1.0 || !time.isFinite()) { reset(); return false }
        lastTime?.let { if (time <= it) return false }
        val last = lastTime; val prev = previous
        consecutive = if (last != null && time - last <= 0.35 && prev != null && KnifeAssociation.matches(candidate.box, prev)) consecutive + 1 else 1
        previous = candidate.box; lastTime = time
        return candidate.score >= 0.5 || consecutive >= 3
    }
}

/** Image-space final-joint-to-tip overlap only. Does not infer blade edges or physical contact. */
class KnifeHandWatch {
    var hasContact = false; private set
    private var targetID: String? = null
    private var lastFrame: Double? = null
    private var cooldownUntil = Double.NEGATIVE_INFINITY
    var alertActive = false; private set

    fun reset() { hasContact = false; targetID = null; lastFrame = null; cooldownUntil = Double.NEGATIVE_INFINITY; alertActive = false }

    fun clearContact(time: Double? = null) {
        val at = time ?: lastFrame
        if (alertActive && at != null && at.isFinite()) cooldownUntil = max(cooldownUntil, at + 1)
        hasContact = false; alertActive = false; targetID = null; lastFrame = null
    }

    /** Immediate held alert for any left-hand overlap. Exit or missing evidence resets immediately. */
    fun update(targetID: String, box: ItemBox, hands: List<Map<Int, Point2>>, time: Double, now: Double): Boolean {
        if (!(time.isFinite() && now.isFinite() && now >= time && now - time <= 0.25 && KnifeAssociation.valid(box))) {
            clearContact(now); return false
        }
        lastFrame?.let { if (time <= it) return alertActive }
        this.targetID = targetID; lastFrame = time
        hasContact = hands.any { overlaps(box, it) }
        if (!hasContact) {
            if (alertActive) cooldownUntil = time + 1
            alertActive = false; return false
        }
        if (!alertActive && time < cooldownUntil) return false
        alertActive = true
        return true
    }

    companion object {
        private val EDGES = listOf(0 to 1, 1 to 2, 2 to 3, 3 to 4, 0 to 5, 5 to 6, 6 to 7, 7 to 8, 5 to 9, 9 to 10, 10 to 11, 11 to 12,
            9 to 13, 13 to 14, 14 to 15, 15 to 16, 13 to 17, 17 to 18, 18 to 19, 19 to 20, 17 to 0)

        fun eligibleHand(id: String, allIDs: List<String>): Boolean = id == "left" && allIDs.count { it == id } == 1

        fun overlaps(box: ItemBox, points: Map<Int, Point2>): Boolean {
            if (!KnifeAssociation.valid(box)) return false
            val zone = HazardZone(box)
            if (points.values.any { it.isValid && zone.contains(it, 0.0) }) return true
            if (EDGES.any { (a, b) ->
                    val start = points[a]; val end = points[b]
                    if (start == null || end == null || !start.isValid || !end.isValid) return@any false
                    var lower = 0.0; var upper = 1.0
                    val dx = end.x - start.x; val dy = end.y - start.y
                    for ((p, q) in listOf(-dx to start.x - box.x, dx to box.x + box.width - start.x,
                            -dy to start.y - box.y, dy to box.y + box.height - start.y)) {
                        if (abs(p) < 1e-12) { if (q < 0) return@any false; continue }
                        val ratio = q / p
                        if (p < 0) lower = max(lower, ratio) else upper = min(upper, ratio)
                        if (lower > upper) return@any false
                    }
                    true
                }) return true
            // Include the palm interior, even when a small knife box fits between the landmarks/edges.
            val palm = listOf(0, 5, 9, 13, 17).mapNotNull { points[it] }
            if (palm.size != 5 || !palm.all { it.isValid }) return false
            return listOf(Point2(box.x, box.y), Point2(box.x + box.width, box.y),
                Point2(box.x + box.width, box.y + box.height), Point2(box.x, box.y + box.height)).any { corner ->
                var inside = false
                for (i in palm.indices) {
                    val a = palm[i]; val b = palm[(i + 1) % palm.size]
                    if ((a.y > corner.y) != (b.y > corner.y) && corner.x < (b.x - a.x) * (corner.y - a.y) / (b.y - a.y) + a.x) inside = !inside
                }
                inside
            }
        }

        /**
         * Each overlapping finger gets its own curl exemption; an unrelated extended finger cannot undo it.
         * Palm/wrist overlap alone does not trigger a finger-curl warning.
         */
        fun overlapsUncurledFinger(box: ItemBox, points: Map<Int, Point2>, bends: List<FingerBend>): Boolean =
            HandFinger.entries.withIndex().any { (index, finger) ->
                val bend = bends.firstOrNull { it.finger == finger }
                if (bend != null && FingerFlexion.isCurled(bend)) return@any false
                val base = 1 + index * 4
                overlaps(box, points.filterKeys { it in base..base + 3 })
            }
    }
}
