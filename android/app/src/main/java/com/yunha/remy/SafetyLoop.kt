package com.yunha.remy

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import com.yunha.remy.core.CookerSafetyTargets
import com.yunha.remy.core.CookingSession
import com.yunha.remy.core.EvidenceOrigin
import com.yunha.remy.core.FastObjectPresentation
import com.yunha.remy.core.FingerCurlWatch
import com.yunha.remy.core.FingerFlexion
import com.yunha.remy.core.GestureHoldWatch
import com.yunha.remy.core.GuidancePillArbiter
import com.yunha.remy.core.HandContinuity
import com.yunha.remy.core.HandDisplayPose
import com.yunha.remy.core.HandPoint3
import com.yunha.remy.core.HazardWatch
import com.yunha.remy.core.HazardZone
import com.yunha.remy.core.ItemBox
import com.yunha.remy.core.KnifeAssociation
import com.yunha.remy.core.KnifeCandidate
import com.yunha.remy.core.KnifeCandidateGate
import com.yunha.remy.core.KnifeHandWatch
import com.yunha.remy.core.Point2
import com.yunha.remy.core.ReachTracker
import com.yunha.remy.ui.AgentActivity.Kind
import com.yunha.remy.ui.RemyState
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** One camera frame's hands, as AppModel.receive gets them on iPhone. Times in seconds (elapsedRealtimeNanos). */
data class TrackedHand(val id: String, val points: List<Point2>, val world: List<HandPoint3>, val gesture: String?) {
    val pointMap: Map<Int, Point2> get() = points.withIndex().associate { it.index to it.value }
}

/** One EfficientDet-Lite0 result: display boxes (score 0.5 or more) and every knife detection (0.25 or more). */
data class ObjectSample(val boxes: List<ItemBox>, val knifeCandidates: List<KnifeCandidate>, val time: Double, val aspect: Double, val elapsedMs: Double)

fun uptime(): Double = SystemClock.elapsedRealtimeNanos() / 1e9

/**
 * The fast loop of AppModel.swift (receive, receiveKnife, updateCookerContactAlarm, syncHeldSafetyPresentation,
 * seedSafetyFromDetector) on Android, on the main thread. No model call happens here.
 *
 * Apple Vision object tracking does not exist on Android, so tracked boxes are re-detected instead: EfficientDet-Lite0
 * runs at 10 Hz and corrects the knife and detector-seeded hot boxes when the same object is found again; a box the
 * detector stops finding is shown as reacquiring and cannot sound an alarm. Gemma-located boxes stay where Gemma put them.
 */
class SafetyLoop(private val context: Context, private val state: RemyState, private val scope: CoroutineScope, private val model: RemyModel) {
    private val continuity = HandContinuity()
    private var continuityAspect = 0.0
    private val hazardWatch = HazardWatch()
    private val gestureHoldWatch = GestureHoldWatch()
    private val fingerCurlWatch = FingerCurlWatch()
    private val knifeContactWatch = KnifeHandWatch()
    private val trackers = mutableMapOf<String, ReachTracker>()
    private val vibrator = context.getSystemService(Vibrator::class.java)
    private val tone = runCatching { ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80) }.getOrNull()

    // Hot surfaces: the located boxes, where they came from, and when the detector last confirmed them.
    private data class HotTrack(val zone: HazardZone, val fromDetector: Boolean, val seen: Double)
    private var hotTracks = listOf<HotTrack>()
    private var lastFastHazardSeed = 0.0
    /** Step 1 of the preset: located but not shown or armed until the cook confirms the cooker is on. */
    var cookerCandidate: Pair<HazardZone, String>? = null
    private var cookerAlarmLastFrame = 0.0
    private var heldOwner: GuidancePillArbiter.Source? = null
    private var heldSpeech = false

    // The knife: one target re-detected at 10 Hz (Vision tracking on iPhone).
    private data class KnifeTrack(val id: String, val box: ItemBox, val seen: Double, val grounded: Boolean)
    private var knifeTrack: KnifeTrack? = null
    private var recentKnife: KnifeTrack? = null
    private val knifeGate = KnifeCandidateGate()
    private var knifeEpoch = UUID.randomUUID().toString()
    private var knifeSession: String? = null
    private var knifeTrackTime = 0.0
    private var knifeAlarmLastFrame = 0.0
    private var fingerFlexionTime = 0.0
    var latestFrameTime = 0.0; private set

    init {
        // The watchdogs: a stopped frame stream clears held alarms and stale overlays within a few frames.
        scope.launch {
            while (true) {
                delay(80)
                val now = uptime()
                if (state.knifeAlert && now - knifeAlarmLastFrame > 0.25) { knifeContactWatch.clearContact(now); clearKnifeAlarm() }
                if (state.knifeBox != null && now - knifeTrackTime >= 0.35) { state.knifeBox = null; knifeContactWatch.clearContact(now); clearKnifeAlarm() }
                if (state.hotAlert && (!state.videoOn || !hotWatchEnabled || now - cookerAlarmLastFrame > 0.3)) clearCookerContactAlarm()
                if (state.leftFingerFlexion.isNotEmpty() && now - fingerFlexionTime > 0.25) clearFingerFlexion()
                if (state.liveObjects.isNotEmpty() && now - state.liveObjectsTime >= 0.5) state.liveObjects = emptyList()
            }
        }
    }

    private val session: CookingSession get() = model.session
    val hotWatchEnabled: Boolean get() = state.safetyAlerts && session.cookerSafetyArmed
    val knifeTrackingActive: Boolean get() =
        state.knifeTracking && state.videoOn && session.phase == CookingSession.Phase.COOKING && !session.isComplete
    val hazardsEmpty: Boolean get() = hotTracks.isEmpty()
    val hasHotContact: Boolean get() = hazardWatch.hasContact

    // ---- Session changes (syncCookerSafety, syncKnifeTracking) ---------------------------------------------------

    fun sessionChanged() {
        if (knifeSession != session.id) { knifeSession = session.id; resetKnifeTracking() }
        if (!knifeTrackingActive) { knifeTrack = null; state.knifeBox = null; knifeContactWatch.reset(); clearKnifeAlarm() }
        syncCookerSafety()
        if (session.phase != CookingSession.Phase.COOKING || session.isComplete) clearFingerFlexion()
    }

    fun syncCookerSafety() {
        if (!hotWatchEnabled) clearCookerContactAlarm()
        if (!state.safetyAlerts) { setHot(emptyList()); cookerCandidate = null; hazardWatch.reset(); return }
        if (session.phase != CookingSession.Phase.COOKING || session.isComplete) { setHot(emptyList()); cookerCandidate = null; hazardWatch.reset(); return }
        if (!session.cookerSafetyArmed) { setHot(emptyList()); hazardWatch.reset() }
        else if (hotTracks.isEmpty()) cookerCandidate?.takeIf { it.second == session.id }?.let { setHot(listOf(HotTrack(it.first, false, uptime()))) }
    }

    fun resetKnifeTracking() {
        knifeEpoch = UUID.randomUUID().toString(); knifeTrack = null; recentKnife = null; knifeGate.reset()
        state.knifeBox = null; knifeContactWatch.reset(); clearKnifeAlarm()
    }

    /** The camera moved, paused or switched: nothing located before can be trusted (CameraService.onMovement). */
    fun invalidateGeometry() {
        clearCookerContactAlarm(); setHot(emptyList()); cookerCandidate = null; hazardWatch.reset()
        state.boxes = emptyList(); trackers.clear(); continuity.reset(); resetKnifeTracking()
    }

    private fun setHot(tracks: List<HotTrack>) {
        hotTracks = tracks
        publishHot(uptime())
    }

    private fun publishHot(time: Double) {
        val active = hotTracks.filter { !it.fromDetector || time - it.seen <= 0.35 }.map { it.zone }
        val recovering = hotTracks.filter { it.fromDetector && time - it.seen > 0.35 }.map { it.zone }
        if (active != state.zones) state.zones = active
        if (recovering != state.recoveringZones) state.recoveringZones = recovering
    }

    /** Gemma (or the detector fast path) located hot items: watch them from now on. */
    fun markHotZones(zones: List<HazardZone>, replace: Boolean) {
        val now = uptime()
        val kept = if (replace) emptyList() else hotTracks.filter { old -> zones.none { it.label == old.zone.label || it.overlaps(old.zone) } }
        hazardWatch.reset()
        setHot(kept + zones.map { HotTrack(it, false, now) })
    }

    // ---- Detector results (FastObjectDetector.onResult) ------------------------------------------------------------

    fun receiveObjects(sample: ObjectSample) {
        state.liveObjects = sample.boxes; state.liveObjectsTime = sample.time; state.detectorMs = sample.elapsedMs
        seedSafetyFromDetector(sample)
        correctHotTracks(sample)
        if (knifeTrackingActive) offerKnifeCandidates(sample.knifeCandidates, sample.time)
    }

    /** Cup/bowl detector boxes are already sufficient for the requested demo proxy; start from that exact frame. */
    private fun seedSafetyFromDetector(sample: ObjectSample) {
        if (!hotWatchEnabled || !state.videoOn || hotTracks.any { !it.fromDetector || sample.time - it.seen <= 0.35 } ||
            sample.time - lastFastHazardSeed <= 0.4 || uptime() - sample.time >= 0.3) return
        var zones = CookerSafetyTargets.zones(sample.boxes)
        val recovering = state.recoveringZones
        if (recovering.isNotEmpty()) zones = zones.filter { candidate -> recovering.any { it.overlaps(candidate, 0.1) } }
        if (zones.isEmpty()) return
        lastFastHazardSeed = sample.time
        clearCookerContactAlarm(); cookerCandidate = null; hazardWatch.reset()
        setHot(zones.map { HotTrack(it, true, sample.time) })
    }

    /** Re-detection in place of Vision tracking: a detector box of the same vessel class moves its hot box. */
    private fun correctHotTracks(sample: ObjectSample) {
        if (hotTracks.none { it.fromDetector }) return
        val found = CookerSafetyTargets.zones(sample.boxes)
        hotTracks = hotTracks.mapNotNull { track ->
            if (!track.fromDetector) return@mapNotNull track
            val match = found.filter { it.overlaps(track.zone, 0.1) }.maxByOrNull { overlap(it, track.zone) }
            when {
                match != null -> HotTrack(match.copy(label = track.zone.label), true, sample.time)
                sample.time - track.seen > 1.25 -> null
                else -> track
            }
        }
        publishHot(sample.time)
    }

    private fun overlap(a: HazardZone, b: HazardZone): Double {
        val w = maxOf(0.0, minOf(a.x + a.width, b.x + b.width) - maxOf(a.x, b.x))
        val h = maxOf(0.0, minOf(a.y + a.height, b.y + b.height) - maxOf(a.y, b.y))
        return w * h
    }

    /** Redetection corrects the existing target only when geometry agrees (CameraService.offerKnifeCandidates). */
    private fun offerKnifeCandidates(candidates: List<KnifeCandidate>, time: Double) {
        if (uptime() - time >= 0.3) return
        val previous = knifeTrack?.box
        val candidate = KnifeAssociation.select(candidates, previous) ?: run { knifeGate.reset(); return }
        if (!knifeGate.accepts(candidate, time)) return
        seedKnife(candidate.box, time, grounded = false)
    }

    /** Gemma found the knife ("Which knife?"): track that box (seedGroundedKnife). */
    fun seedGroundedKnife(box: ItemBox) {
        if (!knifeTrackingActive) return
        seedKnife(box, uptime(), grounded = true)
    }

    private fun seedKnife(box: ItemBox, time: Double, grounded: Boolean) {
        if (!KnifeAssociation.valid(box)) return
        val current = knifeTrack; val recent = recentKnife
        val id = when {
            current != null && KnifeAssociation.matches(box, current.box) -> current.id
            recent != null && time - recent.seen < 2 && KnifeAssociation.matches(box, recent.box) -> recent.id
            else -> UUID.randomUUID().toString()
        }
        val track = KnifeTrack(id, ItemBox("knife", box.x, box.y, box.width, box.height), time, grounded)
        knifeTrack = track; recentKnife = track
    }

    /** The knife target for this frame: healthy while re-detected, reacquiring for one second, then gone. */
    private fun knifeSample(time: Double): Pair<KnifeTrack, Boolean>? {
        val track = knifeTrack ?: return null
        val age = time - track.seen
        val healthy = if (track.grounded) age <= 10 else age <= 0.45
        if (healthy) return track to false
        if (age <= (if (track.grounded) 11.0 else 1.45)) return track to true
        knifeTrack = null
        return null
    }

    // ---- Frames (AppModel.receive) ---------------------------------------------------------------------------------

    fun receive(hands: List<TrackedHand>, time: Double, aspect: Double) {
        if (!state.videoOn) return
        latestFrameTime = time
        val now = uptime()
        if (kotlin.math.abs(aspect - continuityAspect) > 0.02) { continuity.reset(); continuityAspect = aspect }
        state.hands = continuity.update(hands.map { HandDisplayPose(it.id, it.pointMap) }, time)
        state.handsTime = time
        val session = session
        if (session.phase == CookingSession.Phase.INGREDIENTS) {
            // The last pre-focus hand callback may still arrive. Keep its video, never its actions.
            if (trackers.isNotEmpty()) trackers.clear()
            gestureHoldWatch.reset(); clearFingerFlexion()
            return
        }
        publishHot(time)
        val knife = if (knifeTrackingActive) knifeSample(time) else null
        if (knife != null) {
            knifeTrackTime = time
            val (track, recovering) = knife
            if (state.knifeBox != track.box) state.knifeBox = track.box
            if (state.knifeRecovering != recovering) state.knifeRecovering = recovering
        } else if (state.knifeBox != null) { state.knifeBox = null; knifeContactWatch.clearContact(now); clearKnifeAlarm() }

        // Reach: an approach to the marked guarded item (salt) after it was added.
        val ids = hands.map { it.id }
        for (id in trackers.keys.toList()) if (id !in ids) trackers[id]?.reset()
        for (hand in hands) {
            if (hand.id == "unknown" || ids.count { it == hand.id } != 1) continue
            val tracker = trackers.getOrPut(hand.id) { ReachTracker() }
            val warning = tracker.update(hand.points.getOrNull(8), time, session.zone, session.guardArmed)
            if (warning && time > state.alertUntil) reachWarning(time, now)
        }

        // Gestures: one continuous held pose, from a fresh uniquely identified hand, never during an alert.
        val gestureHand = hands.firstOrNull { h -> h.id != "unknown" && ids.count { it == h.id } == 1 && h.gesture in GESTURES }
        val allowed = state.gestures && time > state.alertUntil && !(session.cookerSafetyArmed && hazardWatch.hasContact)
        gestureHoldWatch.update(if (allowed) gestureHand?.gesture else null, if (allowed) gestureHand?.id else null, time, now)
            ?.let { model.perform(it) }

        updateFingerFlexion(hands, time, now)

        // Knife: match the same frame's bend estimates to the overlapping left finger before alarming.
        if (knife != null && !knife.second) {
            val box = knife.first.box
            val touching = hands.filter { KnifeHandWatch.eligibleHand(it.id, ids) }.mapNotNull { hand ->
                val bends = if (state.gripHints) state.leftFingerFlexion else FingerFlexion.estimate(hand.world)
                hand.pointMap.takeIf { KnifeHandWatch.overlapsUncurledFinger(box, it, bends) }
            }
            updateKnifeAlarm(knifeContactWatch.update(knife.first.id, box, touching, time, now), time, now)
        } else { knifeContactWatch.clearContact(now); clearKnifeAlarm() }

        // Hot surface: warn on the first fresh overlapping frame of the 120% boundary, held until the hand leaves.
        if (hotWatchEnabled) {
            val armed = session.cookerSafetyArmed
            hazardWatch.proximityMargin = 0.0; hazardWatch.anyPartOverlap = armed; hazardWatch.minimumContactDuration = 0.0
            hazardWatch.holdsAlertUntilExit = armed; hazardWatch.cooldown = if (armed) 6.0 else 2.0
            val watched = hands.map { HazardWatch.Hand(it.id, it.points, it.id != "unknown") }
            val zone = hazardWatch.check(watched, state.zones.map { it.expanded(1.2) }, time, now)
            updateCookerContactAlarm(zone, time, now)
        } else clearCookerContactAlarm()

        model.frameTick(time)
    }

    private fun reachWarning(time: Double, now: Double) {
        val item = session.step?.guardItem ?: "that"
        state.alertUntil = time + 2; state.alertCount++
        state.alertTitle = "Already added $item"; state.alertSubtitle = "Taste it first."
        state.line = "Already added $item. Taste it first!"
        session.record("Fast visual loop detected an approach to the marked $item location.", EvidenceOrigin.SYSTEM)
        alarmSound()
        val latency = (now - time) * 1000
        state.lastReflexMs = latency
        Log.i(TAG, String.format("REMY_REFLEX %s %.0f ms after the frame", item, latency))
        state.activity.log(Kind.REFLEX, "Reaching for the $item again", "alarm from the fast loop, no model call", latency)
    }

    /** AudioCoach.alarm: the beep and a haptic bypass Gemma and speech; the mic ignores the beep. */
    private fun alarmSound() {
        model.speaker.stop()
        model.listener.setMuted(true)
        vibrator?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK))
        if (state.spokenResponses) tone?.startTone(ToneGenerator.TONE_PROP_BEEP2, 400)
        scope.launch { delay(1500); if (!state.speaking) model.listener.setMuted(false) }
    }

    private fun updateFingerFlexion(hands: List<TrackedHand>, time: Double, now: Double) {
        val ids = hands.map { it.id }
        val hand = hands.firstOrNull { KnifeHandWatch.eligibleHand(it.id, ids) }
        if (!state.gripHints || !state.videoOn || session.phase != CookingSession.Phase.COOKING || session.isComplete || hand == null) {
            clearFingerFlexion(); return
        }
        fingerCurlWatch.update(hand.world, time, now)
        state.leftFingerFlexion = fingerCurlWatch.values; state.fingerCurlHint = fingerCurlWatch.guidance
        if (state.leftFingerFlexion.isEmpty()) { clearFingerFlexion(); return }
        fingerFlexionTime = time
    }

    fun clearFingerFlexion() {
        fingerCurlWatch.reset()
        if (state.leftFingerFlexion.isNotEmpty()) state.leftFingerFlexion = emptyList()
        if (state.fingerCurlHint != null) state.fingerCurlHint = null
    }

    // ---- Held warnings (updateKnifeAlarm, updateCookerContactAlarm, syncHeldSafetyPresentation) ---------------------

    private fun updateKnifeAlarm(active: Boolean, time: Double, now: Double) {
        if (!active) { clearKnifeAlarm(); return }
        knifeAlarmLastFrame = time
        val entered = !state.knifeAlert
        state.knifeAlert = true
        syncHeldSafetyPresentation()
        if (!entered) return
        state.alertCount++
        val latency = (now - time) * 1000
        state.lastReflexMs = latency
        Log.i(TAG, String.format("REMY_REFLEX knife %.0f ms after the frame", latency))
        state.activity.log(Kind.REFLEX, "Left hand is near the knife",
            "An overlapping left finger is below its curl cutoff; silent alert with one-second re-trigger cooldown, no model call", latency)
    }

    private fun clearKnifeAlarm() {
        if (!state.knifeAlert) return
        state.knifeAlert = false
        syncHeldSafetyPresentation()
    }

    private fun updateCookerContactAlarm(zone: HazardZone?, time: Double, now: Double) {
        if (zone == null) { clearCookerContactAlarm(); return }
        cookerAlarmLastFrame = time
        val entered = !state.hotAlert
        state.hotAlert = true
        syncHeldSafetyPresentation()
        if (!entered) return
        state.alertCount++
        session.record("Held safety warning: fresh hand overlap at the marked ${zone.label}.", EvidenceOrigin.SYSTEM)
        val latency = (now - time) * 1000
        state.lastReflexMs = latency
        Log.i(TAG, String.format("REMY_REFLEX hot %s %.0f ms after the frame", zone.label, latency))
    }

    fun clearCookerContactAlarm() {
        if (!state.hotAlert) return
        state.hotAlert = false
        hazardWatch.reset()
        syncHeldSafetyPresentation()
    }

    private fun syncHeldSafetyPresentation() {
        val owner = if (state.knifeAlert) GuidancePillArbiter.Source.KNIFE else if (state.hotAlert) GuidancePillArbiter.Source.SAFETY else null
        if (owner != heldOwner) {
            endHeldSafetyWarning()
            if (owner != null) beginHeldSafetyWarning(if (owner == GuidancePillArbiter.Source.KNIFE) null else COOKER_WARNING)
            else if (heldOwner != null) state.alertUntil = 0.0
            heldOwner = owner
        }
        if (owner == null) return
        state.alertUntil = uptime() + 0.35
        state.alertTitle = if (owner == GuidancePillArbiter.Source.KNIFE) "Left hand is near the knife" else "Hot Surface"
        state.alertSubtitle = "Move your hand clear."
    }

    /** Speech once per entry (hot surface only); vibration held until the owner clears it. */
    private fun beginHeldSafetyWarning(text: String?) {
        heldSpeech = text != null
        if (text != null) model.speaker.say(text, priority = true)
        vibrator?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 1000), intArrayOf(0, 204), 0))
    }

    private fun endHeldSafetyWarning() {
        vibrator?.cancel()
        if (heldSpeech && state.speaking) model.speaker.stop()
        heldSpeech = false
    }

    fun shutdown() { vibrator?.cancel(); tone?.release() }

    companion object {
        private const val TAG = "Remy"
        const val COOKER_WARNING = "Be careful of the pot on the stove!"
        private val GESTURES = setOf("Thumb_Up", "Thumb_Down", "Open_Palm")

        /** visibleObjectBoxes on iPhone: Gemma's boxes, then fresh detector boxes; no knife boxes while cooking. */
        fun visibleObjectBoxes(state: RemyState, phase: CookingSession.Phase, now: Double): List<ItemBox> {
            if (!state.objectBoxes) return emptyList()
            val live = if (state.videoOn && now - state.liveObjectsTime < 0.5) state.liveObjects else emptyList()
            val fast = live.filter { box ->
                state.boxes.none { it.label.lowercase() == box.label.lowercase() } &&
                    (phase != CookingSession.Phase.INGREDIENTS || FastObjectPresentation.isSpecificIdentityReliable(box.label))
            }.map(FastObjectPresentation::displayBox)
            return (state.boxes + fast).filter { phase != CookingSession.Phase.COOKING || !KnifeAssociation.isKnife(it.label) }
        }
    }
}
