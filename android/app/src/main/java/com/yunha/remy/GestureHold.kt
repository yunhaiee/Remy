package com.yunha.remy

/** GestureHoldWatch.swift: fresh observed gestures only; one held pose produces one command until released. */
class GestureHold {
    private var gesture: String? = null
    private var handID: String? = null
    private var since = 0.0
    private var fired = false
    private var lastFrame: Double? = null
    private var quietUntil = Double.NEGATIVE_INFINITY

    private fun clearPose() { gesture = null; handID = null; fired = false }

    fun update(next: String?, nextHand: String?, time: Double, now: Double): String? {
        if (!time.isFinite() || !now.isFinite() || now < time || now - time > 0.3) { clearPose(); lastFrame = null; return null }
        val last = lastFrame
        if (last != null && time <= last) { clearPose(); return null }
        if (last != null && time - last > 0.3) clearPose()
        lastFrame = time
        if (next == null || next !in setOf("Thumb_Up", "Thumb_Down", "Open_Palm") || nextHand.isNullOrEmpty() || nextHand == "unknown") { clearPose(); return null }
        if (next != gesture || nextHand != handID) { gesture = next; handID = nextHand; since = time; fired = false }
        val hold = if (next == "Thumb_Down") 0.6 else 1.0
        if (fired || time - since < hold || time < quietUntil) return null
        fired = true; quietUntil = time + 2.5
        return next
    }
}
