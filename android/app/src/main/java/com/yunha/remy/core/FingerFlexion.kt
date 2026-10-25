package com.yunha.remy.core

import kotlin.math.PI
import kotlin.math.acos
import kotlin.math.exp
import kotlin.math.roundToInt
import kotlin.math.sqrt

// Kotlin port of ChefCore/FingerFlexion.swift. Times in seconds.

/** Camera-estimated 3D landmark. No pressure or calibrated joint-angle measurement is implied. */
data class HandPoint3(val x: Double, val y: Double, val z: Double) {
    val isFinite: Boolean get() = x.isFinite() && y.isFinite() && z.isFinite()
}

enum class HandFinger(val raw: String) {
    THUMB("thumb"), INDEX("index"), MIDDLE("middle"), RING("ring"), PINKY("pinky");
    val title: String get() = raw.replaceFirstChar { it.uppercase() }
}

data class FingerBend(val finger: HandFinger, val fraction: Double) {
    /** Visual curl proxy: zero is straight, one is strongly bent. Not a clinical range of motion. */
    val percent: Int get() = (fraction * 100).roundToInt()
}

object FingerFlexion {
    fun curledThresholdPercent(finger: HandFinger): Int = if (finger == HandFinger.THUMB) 10 else 25

    fun isCurled(value: FingerBend): Boolean =
        value.fraction.isFinite() && value.fraction in 0.0..1.0 && value.percent >= curledThresholdPercent(value.finger)

    private fun bend(a: HandPoint3, b: HandPoint3, c: HandPoint3): Double? {
        if (!a.isFinite || !b.isFinite || !c.isFinite) return null
        val u = Triple(a.x - b.x, a.y - b.y, a.z - b.z); val v = Triple(c.x - b.x, c.y - b.y, c.z - b.z)
        val lengths = sqrt(u.first * u.first + u.second * u.second + u.third * u.third) *
            sqrt(v.first * v.first + v.second * v.second + v.third * v.third)
        if (lengths <= 1e-10) return null
        val cosine = maxOf(-1.0, minOf(1.0, (u.first * v.first + u.second * v.second + u.third * v.third) / lengths))
        return PI - acos(cosine)
    }

    fun estimate(points: List<HandPoint3>): List<FingerBend> {
        if (points.size != 21) return emptyList()
        return HandFinger.entries.mapIndexedNotNull { i, finger ->
            val base = 1 + i * 4
            val first = bend(points[base], points[base + 1], points[base + 2]) ?: return@mapIndexedNotNull null
            val last = bend(points[base + 1], points[base + 2], points[base + 3]) ?: return@mapIndexedNotNull null
            val maximum = if (finger == HandFinger.THUMB) 140.0 else 180.0
            FingerBend(finger, maxOf(0.0, minOf(1.0, (first + last) * 180 / PI / maximum)))
        }
    }
}

/** A cheap frame-driven smoother with short persistence; no model call or speech. */
class FingerCurlWatch {
    var values: List<FingerBend> = emptyList(); private set
    var extended: List<HandFinger> = emptyList(); private set
    private val since = mutableMapOf<HandFinger, Double>()
    private var previousTime: Double? = null

    fun reset() { values = emptyList(); extended = emptyList(); since.clear(); previousTime = null }

    val guidance: String? get() {
        if (extended.isEmpty()) return null
        if (extended.size >= 3) return "Try curling your fingertips inward."
        return "Try curling your ${extended.joinToString(" and ") { it.raw }} inward."
    }

    fun update(points: List<HandPoint3>, time: Double, now: Double) {
        if (!(time.isFinite() && now.isFinite() && now >= time && now - time <= 0.25)) { reset(); return }
        previousTime?.let { if (time <= it) return }
        previousTime?.let { if (time - it > 0.25) reset() }
        val dt = previousTime?.let { time - it } ?: 1.0
        previousTime = time
        val measured = FingerFlexion.estimate(points)
        if (measured.isEmpty()) { reset(); return }
        val alpha = 1 - exp(-dt / 0.07)
        values = measured.map { value ->
            val old = values.firstOrNull { it.finger == value.finger }?.fraction ?: value.fraction
            FingerBend(value.finger, old + alpha * (value.fraction - old))
        }
        val active = mutableListOf<HandFinger>()
        for (finger in HandFinger.entries) {
            val value = values.firstOrNull { it.finger == finger }
            if (value == null) { since.remove(finger); continue }
            if (!FingerFlexion.isCurled(value)) {
                if (finger !in since) since[finger] = time
                if (time - (since[finger] ?: time) >= 0.12) active.add(finger)
            } else since.remove(finger)
        }
        extended = active
    }
}
