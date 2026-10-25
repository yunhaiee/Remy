package com.yunha.remy.ui

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.yunha.remy.core.DishAssessment
import com.yunha.remy.core.FingerBend
import com.yunha.remy.core.HandDisplayPose
import com.yunha.remy.core.HazardZone
import com.yunha.remy.core.ItemBox

/** Gemma's work as it happens, for the drawer (AgentActivity.swift). Kept in memory only, capped at 80 rows. */
class AgentActivity {
    enum class Kind(val label: String) {
        HEARD("Heard"), GEMMA("Gemma"), TOOL("Tool"), VISION("Vision"), PLAN("Plan"), REFLEX("Reflex"), GESTURE("Gesture"),
        SAYS("Chef says"), SYSTEM("System")
    }
    enum class State { RUNNING, DONE, FAILED }
    data class Entry(val id: Long, val kind: Kind, val title: String, val detail: String, val ms: Double?, val state: State)

    val entries = mutableStateListOf<Entry>()
    private var next = 0L
    private val started = mutableMapOf<Long, Long>()

    /** A call that is now running; `finish` it with what came back. */
    fun begin(kind: Kind, title: String, detail: String = ""): Long {
        val id = next++
        started[id] = SystemClock.elapsedRealtime()
        append(Entry(id, kind, title, detail, null, State.RUNNING))
        return id
    }

    fun finish(id: Long, detail: String, ms: Double? = null, failed: Boolean = false) {
        val index = entries.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return
        val elapsed = ms ?: started.remove(id)?.let { (SystemClock.elapsedRealtime() - it).toDouble() }
        entries[index] = entries[index].copy(detail = detail, ms = elapsed, state = if (failed) State.FAILED else State.DONE)
    }

    fun log(kind: Kind, title: String, detail: String = "", ms: Double? = null) = append(Entry(next++, kind, title, detail, ms, State.DONE))

    private fun append(entry: Entry) {
        entries.add(entry)
        while (entries.size > 80) entries.removeAt(0)
    }
}

/** Everything the landscape screen draws. Written on the main thread by MainActivity. */
class RemyState {
    val activity = AgentActivity()

    // Camera and the fast loop. Times are SystemClock.elapsedRealtimeNanos() in seconds, the camera's clock.
    var imageAspect by mutableStateOf(4f / 3f)
    /** Display-only hands (HandContinuity), observed or briefly estimated, and the frame they belong to. */
    var hands by mutableStateOf<List<HandDisplayPose>>(emptyList())
    var handsTime by mutableDoubleStateOf(0.0)
    /** Watched hot surfaces as located (not expanded); the 120% safety boundary is drawn and checked. */
    var zones by mutableStateOf<List<HazardZone>>(emptyList())
    var recoveringZones by mutableStateOf<List<HazardZone>>(emptyList())
    /** Items Gemma located, drawn for a few seconds. */
    var boxes by mutableStateOf<List<ItemBox>>(emptyList())
    /** Fresh EfficientDet-Lite0 boxes (score 0.5 or more) and the frame time they came from. */
    var liveObjects by mutableStateOf<List<ItemBox>>(emptyList())
    var liveObjectsTime by mutableDoubleStateOf(0.0)
    var videoOn by mutableStateOf(true)

    // The pill. `line` is Remy's own line (chefLine on iPhone); safety and hints are arbitrated on top of it.
    var line by mutableStateOf("Tell me what we're making.")
    var gemmaSeconds by mutableStateOf<Double?>(null)
    var working by mutableStateOf(false)
    /** Held hot-surface warning: a fresh hand overlaps the expanded hot box. */
    var hotAlert by mutableStateOf(false)
    /** A short alert banner (reach warning) while now < alertUntil. */
    var alertUntil by mutableDoubleStateOf(0.0)
    var alertTitle by mutableStateOf("")
    var alertSubtitle by mutableStateOf("")

    var knifeBox by mutableStateOf<ItemBox?>(null)
    var knifeAlert by mutableStateOf(false)
    var knifeRecovering by mutableStateOf(false)
    /** Left-hand curl estimates and the curl hint, during cooking only. */
    var leftFingerFlexion by mutableStateOf<List<FingerBend>>(emptyList())
    var fingerCurlHint by mutableStateOf<String?>(null)
    var markSaltLocation by mutableStateOf(false)

    // The finished-dish review (FinishedDishSummaryView).
    var showsDishSummary by mutableStateOf(false)
    var finishedDishPhoto by mutableStateOf<android.graphics.Bitmap?>(null)
    var finishedDishName by mutableStateOf("")
    var dishAssessment by mutableStateOf<DishAssessment?>(null)
    var dishReviewLoading by mutableStateOf(false)
    var dishReviewError by mutableStateOf<String?>(null)
    var dishSummaryMessage by mutableStateOf<String?>(null)
    /** The careful-ingredient crop Gemma is checking, in normalized image space. */
    var presentedBox by mutableStateOf<ItemBox?>(null)

    // Chrome.
    var drawerOpen by mutableStateOf(false)
    var settingsOpen by mutableStateOf(false)
    var sessionOpen by mutableStateOf(false)
    var evidenceOpen by mutableStateOf(false)
    var stepsOpen by mutableStateOf(false)

    // Model and the bottom action (PrimaryAction in ContentView.swift).
    var isLoaded by mutableStateOf(false)
    var isLoading by mutableStateOf(false)
    var isBusy by mutableStateOf(false)
    var planning by mutableStateOf(false)
    var planningDish by mutableStateOf("")
    var planIngredients by mutableStateOf<List<String>>(emptyList())
    var planSteps by mutableStateOf<List<String>>(emptyList())
    var primaryTitle by mutableStateOf("Set up Remy")
    var primaryEnabled by mutableStateOf(true)
    var dishRequest by mutableStateOf("")
    var status by mutableStateOf("Loading Gemma…")
    var rawResponse by mutableStateOf("")
    var lastHeard by mutableStateOf("")
    var smokePassed by mutableStateOf(false)
    /** Bumped whenever the cooking session changes, so session views recompose. */
    var sessionVersion by mutableIntStateOf(0)

    // Voice.
    var listenerOn by mutableStateOf(false)
    var hearing by mutableStateOf(false)
    var speaking by mutableStateOf(false)
    var recording by mutableStateOf(false)
    var understanding by mutableStateOf(false)
    var ingredientChecking by mutableStateOf(false)
    var instructionsPreparing by mutableStateOf(false)
    var speechPath by mutableStateOf("not started")

    // Settings, in the iPhone order.
    var handsFree by mutableStateOf(true)
    var automaticChecks by mutableStateOf(false)
    var objectBoxes by mutableStateOf(true)
    var safetyAlerts by mutableStateOf(true)
    var knifeTracking by mutableStateOf(true)
    var spokenResponses by mutableStateOf(true)
    var shortRecipes by mutableStateOf(true)
    var demoPreset by mutableStateOf(true)
    var gestures by mutableStateOf(true)
    /** Evidence: "Left-hand finger curl guidance" (gripHints on iPhone). */
    var gripHints by mutableStateOf(true)
    var constrainedDecoding by mutableStateOf(false)
    var handResolution by mutableIntStateOf(480)
    var gestureModel by mutableStateOf("not loaded")
    var detectorModel by mutableStateOf("not loaded")

    // This session's tally, counted where each call returns.
    var gemmaCalls by mutableIntStateOf(0)
    var toolCalls by mutableIntStateOf(0)
    var visionChecks by mutableIntStateOf(0)
    var boxCount by mutableIntStateOf(0)
    var audioCalls by mutableIntStateOf(0)

    // Evidence, all from live values.
    var lmBackend by mutableStateOf<String?>(null)
    var visionBackend by mutableStateOf<String?>(null)
    var onNpu by mutableStateOf(false)
    var loadMs by mutableStateOf<Long?>(null)
    var prefillTps by mutableStateOf<Double?>(null)
    var decodeTps by mutableStateOf<Double?>(null)
    var ttft by mutableStateOf<Double?>(null)
    val callMs = mutableStateListOf<Long>()
    var lastReflexMs by mutableStateOf<Double?>(null)
    var alertCount by mutableIntStateOf(0)
    var detectorMs by mutableStateOf<Double?>(null)
    var handFps by mutableDoubleStateOf(0.0)
    var handMs by mutableDoubleStateOf(0.0)
    var thermalHeadroom by mutableStateOf<Float?>(null)
    var airplaneMode by mutableStateOf<Boolean?>(null)
    var networkBytes by mutableStateOf<Long?>(null)

    val medianCallMs: Long? get() = callMs.sorted().let { if (it.isEmpty()) null else it[it.size / 2] }
}
