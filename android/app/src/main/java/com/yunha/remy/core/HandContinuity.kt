package com.yunha.remy.core

import kotlin.math.exp
import kotlin.math.hypot

// Kotlin port of ChefCore/HandContinuity.swift. Times in seconds.

/** Display-only continuity. Never substitute these poses for observed safety or gesture evidence. */
data class HandDisplayPose(val id: String, val points: Map<Int, Point2>, val estimated: Boolean = false, val observationAge: Double = 0.0)

class HandContinuity {
    private data class Track(val pose: HandDisplayPose, val observedAt: Double, val center: Point2, val velocity: Point2, val observations: Int)

    private var tracks = mutableMapOf<String, Track>()
    private var serial = 0
    private var lastTime: Double? = null
    val maximumPredictionAge = 0.20

    fun reset() { tracks = mutableMapOf(); serial = 0; lastTime = null }

    private fun center(points: Map<Int, Point2>): Point2 {
        val palm = listOf(0, 5, 9, 13, 17).mapNotNull { points[it] }
        return Point2(palm.sumOf { it.x } / palm.size, palm.sumOf { it.y } / palm.size)
    }

    private fun valid(pose: HandDisplayPose): Boolean =
        !pose.estimated && pose.points.size == 21 && (0 until 21).all { pose.points[it]?.isValid == true }

    fun update(observations: List<HandDisplayPose>, time: Double): List<HandDisplayPose> {
        if (!time.isFinite()) { reset(); return emptyList() }
        lastTime?.let { if (time <= it) return emptyList() }
        lastTime?.let { if (time - it > maximumPredictionAge) tracks.clear() }
        lastTime = time
        tracks = tracks.filterValues { time - it.observedAt <= maximumPredictionAge }.toMutableMap()
        val usable = observations.filter(::valid).take(2)
        val ordered = usable.sortedBy { if (it.id == "unknown") 1 else 0 }
        val used = mutableSetOf<String>(); val output = mutableListOf<HandDisplayPose>()
        for (observation in ordered) {
            val measuredCenter = center(observation.points)
            val reliableID = observation.id in listOf("left", "right") && usable.count { it.id == observation.id } == 1
            var oldID: String? = null
            if (reliableID && tracks[observation.id] != null && observation.id !in used) oldID = observation.id
            if (oldID == null) {
                oldID = tracks.filter { (key, track) -> key !in used &&
                    (!reliableID || key !in listOf("left", "right")) && measuredCenter.distance(track.center) < 0.12 }
                    .minByOrNull { measuredCenter.distance(it.value.center) }?.key
            }
            val id = when {
                reliableID -> observation.id
                oldID != null -> oldID
                else -> { serial += 1; "visual-$serial" }
            }
            val points = observation.points.toMutableMap(); var velocity = Point2(0.0, 0.0); var count = 1
            val previous = oldID?.let { tracks[it] }
            if (oldID != null && previous != null) {
                val dt = time - previous.observedAt; val distance = measuredCenter.distance(previous.center)
                if (dt > 0 && dt <= 0.12 && distance < 0.25) {
                    val vx = (measuredCenter.x - previous.center.x) / dt; val vy = (measuredCenter.y - previous.center.y) / dt
                    val speed = hypot(vx, vy); val limit = if (speed > 1.5) 1.5 / speed else 1.0
                    velocity = Point2(vx * limit, vy * limit)
                    val alpha = if (speed > 0.8) 0.92 else 1 - exp(-dt / 0.022)
                    for ((index, point) in observation.points) {
                        val old = previous.pose.points[index] ?: continue
                        points[index] = Point2(old.x + alpha * (point.x - old.x), old.y + alpha * (point.y - old.y))
                    }
                    count = previous.observations + 1
                }
                used.add(oldID)
                if (oldID != id) tracks.remove(oldID)
            }
            val pose = HandDisplayPose(id, points)
            tracks[id] = Track(pose, time, measuredCenter, velocity, count)
            used.add(id); output.add(pose)
        }
        for ((id, track) in tracks.entries.sortedByDescending { it.value.observedAt }.map { it.key to it.value }) {
            if (id in used) continue
            if (output.size >= 2 || track.observations < 2) continue
            val age = time - track.observedAt
            if (!(age > 0 && age <= maximumPredictionAge)) continue
            // Coast from the last measured pose, with deceleration and a strict displacement cap.
            val horizon = 0.10 * (1 - exp(-age / 0.10))
            var dx = track.velocity.x * horizon; var dy = track.velocity.y * horizon
            val length = hypot(dx, dy)
            if (length > 0.08) { dx *= 0.08 / length; dy *= 0.08 / length }
            val points = track.pose.points.mapValues { Point2(it.value.x + dx, it.value.y + dy) }
            if (points[0]?.isValid != true) continue
            output.add(HandDisplayPose(id, points.filterValues { it.isValid }, estimated = true, observationAge = age))
        }
        val visible = output.map { it.id }.toSet()
        tracks = tracks.filterKeys { it in visible }.toMutableMap()
        return output
    }
}
