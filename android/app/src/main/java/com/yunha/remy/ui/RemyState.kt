package com.yunha.remy.ui

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.yunha.remy.core.HazardZone
import com.yunha.remy.core.ItemBox
import com.yunha.remy.core.Point2

/** Gemma's work as it happens, for the drawer (AgentActivity.swift). Kept in memory only, capped at 80 rows. */
class AgentActivity {
    enum class Kind(val label: String) { HEARD("Heard"), GEMMA("Gemma"), TOOL("Tool"), VISION("Vision"), PLAN("Plan"), REFLEX("Reflex"), GESTURE("Gesture") }
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

    // Camera and the fast loop.
    var imageAspect by mutableStateOf(4f / 3f)
    var hands by mutableStateOf<List<List<Point2>>>(emptyList())
    var zones by mutableStateOf<List<HazardZone>>(emptyList())
    var boxes by mutableStateOf<List<ItemBox>>(emptyList())
    var videoOn by mutableStateOf(true)

    // The pill.
    var line by mutableStateOf("Starting the camera…")
    var gemmaSeconds by mutableStateOf<Double?>(null)
    var reflexMs by mutableStateOf<Double?>(null)
    var working by mutableStateOf(false)

    // Chrome.
    var drawerOpen by mutableStateOf(false)
    var settingsOpen by mutableStateOf(false)

    // Settings.
    var objectBoxes by mutableStateOf(true)
    var safetyAlerts by mutableStateOf(true)
    var spokenResponses by mutableStateOf(true)
    var handResolution by mutableIntStateOf(480)

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
    var handFps by mutableDoubleStateOf(0.0)
    var handMs by mutableDoubleStateOf(0.0)
    var thermalHeadroom by mutableStateOf<Float?>(null)
    var airplaneMode by mutableStateOf<Boolean?>(null)
    var networkBytes by mutableStateOf<Long?>(null)

    val medianCallMs: Long? get() = callMs.sorted().let { if (it.isEmpty()) null else it[it.size / 2] }
}
