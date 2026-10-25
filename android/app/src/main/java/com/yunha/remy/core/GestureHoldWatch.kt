package com.yunha.remy.core

/** Fresh observed gestures only. One held pose produces one command until released. Times in seconds. */
class GestureHoldWatch {
    private var gesture: String? = null
    private var handID: String? = null
    private var since = 0.0
    private var fired = false
    private var lastFrame: Double? = null
    private var quietUntil = Double.NEGATIVE_INFINITY

    fun reset() {
        gesture = null; handID = null; since = 0.0; fired = false; lastFrame = null; quietUntil = Double.NEGATIVE_INFINITY
    }

    private fun clearPose() { gesture = null; handID = null; fired = false }

    /** MediaPipe gesture name ("Thumb_Up", "Thumb_Down", "Open_Palm") when a held pose fires, otherwise null. */
    fun update(gesture: String?, handID: String?, time: Double, now: Double): String? {
        if (!(time.isFinite() && now.isFinite() && now >= time && now - time <= 0.3)) {
            clearPose(); lastFrame = null; return null
        }
        if (!(lastFrame?.let { time > it } ?: true)) { clearPose(); return null }
        lastFrame?.let { if (time - it > 0.3) clearPose() }
        lastFrame = time
        if (gesture == null || gesture !in listOf("Thumb_Up", "Thumb_Down", "Open_Palm") ||
            handID == null || handID.isEmpty() || handID == "unknown") { clearPose(); return null }
        if (gesture != this.gesture || handID != this.handID) {
            this.gesture = gesture; this.handID = handID; since = time; fired = false
        }
        val hold = if (gesture == "Thumb_Down") 0.6 else 1.0
        if (fired || time - since < hold || time < quietUntil) return null
        fired = true; quietUntil = time + 2.5
        return gesture
    }
}
