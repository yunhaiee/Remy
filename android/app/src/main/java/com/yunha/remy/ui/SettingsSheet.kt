package com.yunha.remy.ui

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** A glass sheet over the camera with a title and Done, like the iPhone's NavigationStack sheets. */
@Composable
fun SheetFrame(title: String, onDone: () -> Unit, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f))
        .clickable(remember { MutableInteractionSource() }, null, onClick = onDone), contentAlignment = Alignment.Center) {
        Column(Modifier.width(600.dp).fillMaxHeight().padding(vertical = 18.dp).background(AppTheme.surface, RoundedCornerShape(22.dp))
            .border(1.dp, AppTheme.outline, RoundedCornerShape(22.dp))
            .clickable(remember { MutableInteractionSource() }, null) {}) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                AppText(title, appText(17.sp, FontWeight.Medium), Modifier.weight(1f))
                AppText("Done", appText(15.sp, FontWeight.Medium, AppTheme.accent),
                    Modifier.clickable(remember { MutableInteractionSource() }, null, onClick = onDone))
            }
            Box(Modifier.padding(horizontal = 20.dp)) { content() }
        }
    }
}

/** BrainView in ContentView.swift: the same sections and items, in the same order and words. */
@Composable
fun SettingsSheet(state: RemyState, actions: RemyActions, model: com.yunha.remy.RemyModel) {
    var confirmReset by remember { mutableStateOf(false) }
    SheetFrame("Settings", { state.settingsOpen = false }) {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item { Eyebrow("Remy", AppTheme.secondary) }
            item { ToggleRow("Hands-free voice", null, state.handsFree) { actions.setHandsFree(it) } }
            item { ToggleRow("Watch the board automatically", null, state.automaticChecks, enabled = state.isLoaded) { state.automaticChecks = it } }
            item { ToggleRow("Object boxes", "Shows everyday object detections independently of safety monitoring.", state.objectBoxes) { state.objectBoxes = it } }
            item { ToggleRow("Fire safety · box & alerts", "Warns as soon as a hand enters a hot-surface box, after step 1 until the dish is complete, alongside knife tracking. Reporting power off keeps heat caution active. Switch Fire safety off here to pause.", state.safetyAlerts) { state.safetyAlerts = it; model.safetyToggled() } }
            item { ToggleRow("Knife tracking · box & warning", "Silent orange warning and vibration for an overlapping left finger below its curl cutoff: thumb 10%, other fingers 25%. The banner lasts one second; vibration clears immediately on exit, with one second before re-triggering. Independent of Object boxes and Fire safety.", state.knifeTracking) { state.knifeTracking = it; model.safety.resetKnifeTracking(); model.safety.sessionChanged() } }
            item { ToggleRow("Spoken responses", null, state.spokenResponses) { model.setSpoken(it) } }
            item { ToggleRow("Short recipes (up to 5 steps)", null, state.shortRecipes) { state.shortRecipes = it } }
            item { ToggleRow("Pasta-salad demo preset", "“Make pasta salad” uses the fixed five ingredients and three app-written steps. Off, Gemma plans every dish.", state.demoPreset) { state.demoPreset = it } }
            item { ToggleRow("Hand gestures", "Thumbs up (hold 1 second): next. Thumbs down: back. Open palm (hold): quiet.", state.gestures) { state.gestures = it } }

            item { Spacer(Modifier.height(8.dp)); Eyebrow("Camera", AppTheme.secondary) }
            item { ValueRow("Camera", "Pixel rear camera (GoPro HERO12 input is iPhone-only)") }
            item {
                Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    AppText("Hand tracking resolution", appText(15.sp), Modifier.weight(1f))
                    for (value in listOf(480, 720)) Chip("${value}p", state.handResolution == value) { actions.setResolution(value) }
                }
            }

            item { Spacer(Modifier.height(8.dp)); Eyebrow("Look", AppTheme.secondary) }
            item {
                Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    AppText("Controls over the video", appText(15.sp), Modifier.weight(1f))
                    Chip("Dark glass", !GlassStyle.light) { GlassStyle.light = false }
                    Chip("Light glass", GlassStyle.light) { GlassStyle.light = true }
                }
            }

            item { Spacer(Modifier.height(8.dp)); Eyebrow("Gemma on this Pixel", AppTheme.secondary) }
            item { ValueRow("Model", if (state.isLoaded || state.isLoading) "Gemma 4 E2B" else "Not loaded: push the Tensor bundle over adb") }
            item { ToggleRow("Schema-constrained decoding", "LiteRT enforces the JSON schema token by token. Off, the schema is only described in the prompt (default, after a native crash seen on one iPhone). Not available in LiteRT-LM 0.18.0 for Android.", state.constrainedDecoding, enabled = false) { } }
            item { if (state.isLoaded) ValueRow("Running on", state.lmBackend ?: "") else AppText(if (state.isLoading) "Loading Gemma…" else "Load Gemma: reopen Remy after pushing the bundle", appText(15.sp, FontWeight.Medium, AppTheme.accent)) }

            item { Spacer(Modifier.height(8.dp)); Eyebrow("Session", AppTheme.secondary) }
            item { ActionRow("Evidence") { state.evidenceOpen = true } }
            item { ActionRow("Run local text test", enabled = state.isLoaded && !state.isBusy) { actions.textTest() } }
            item { ActionRow("Describe the live camera image", enabled = state.isLoaded && !state.isBusy) { actions.describeCamera() } }
            if (state.smokePassed) item { AppText("Local test passed", appText(15.sp, color = AppTheme.accent)) }
            if (state.rawResponse.isNotEmpty()) item { AppText(state.rawResponse, appText(13.sp, color = AppTheme.secondary), maxLines = 4) }
            item { ActionRow("Reset recipe and memory", color = Color.Red) { confirmReset = true } }
            item { Spacer(Modifier.height(12.dp)) }
        }
    }
    if (confirmReset) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)).clickable(remember { MutableInteractionSource() }, null) { confirmReset = false },
            contentAlignment = Alignment.Center) {
            Column(Modifier.width(320.dp).background(AppTheme.surfaceHigh, RoundedCornerShape(14.dp)).padding(18.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                AppText("Start a fresh session?", appText(15.sp, FontWeight.Medium, AppTheme.secondary))
                AppText("Reset recipe and memory", appText(17.sp, FontWeight.Medium, Color.Red),
                    Modifier.clickable(remember { MutableInteractionSource() }, null) { confirmReset = false; actions.reset(); state.settingsOpen = false }.padding(6.dp))
                AppText("Cancel", appText(17.sp, FontWeight.Medium, AppTheme.accent),
                    Modifier.clickable(remember { MutableInteractionSource() }, null) { confirmReset = false }.padding(6.dp))
            }
        }
    }
}

@Composable
private fun Chip(title: String, selected: Boolean, onTap: () -> Unit) {
    AppText(title, appText(13.sp, FontWeight.Medium, if (selected) AppTheme.background else AppTheme.text),
        Modifier.padding(start = 6.dp).background(if (selected) AppTheme.accentLight else AppTheme.surfaceHigh, RoundedCornerShape(50))
            .clickable(remember { MutableInteractionSource() }, null, onClick = onTap).padding(horizontal = 12.dp, vertical = 6.dp))
}

/** EvidenceView: what is actually running, the session events and the last raw Gemma reply. */
@Composable
fun EvidenceSheet(state: RemyState, model: com.yunha.remy.RemyModel) {
    @Suppress("UNUSED_VARIABLE") val version = state.sessionVersion
    SheetFrame("Evidence", { state.evidenceOpen = false }) {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item { AppText("What is actually running", appText(15.sp, FontWeight.Medium, AppTheme.accent)) }
            val speed = if (state.prefillTps != null) String.format("prefill %.0f tok/s · decode %.1f tok/s · first token %.2f s",
                state.prefillTps, state.decodeTps ?: 0.0, state.ttft ?: 0.0) else null
            item { ValueRow("Gemma", if (state.isLoaded) "Gemma 4 E2B · LiteRT-LM ${com.yunha.remy.BuildConfig.LITERT_LM_VERSION} · ${state.lmBackend}" else "Not loaded") }
            if (speed != null) item { AppText("Last call: $speed", appText(13.sp)) }
            val rows = listOf(
                "Image tokens" to "Set by the Tensor bundle's vision encoder (the iPhone sends 140 per image)",
                "Structured output" to "JSON parsing and validation; native constraints disabled",
                "Function calling" to "16 tools, the app runs each call",
                "Reflex latency" to (state.lastReflexMs?.let { String.format("%.0f ms, frame to alarm", it) } ?: "not measured yet"),
                "Audio in" to "Gemma hears answers to its questions",
                "Speculative decoding" to "off",
                "Fast vision" to "MediaPipe · LiteRT · CPU" + (if (state.handFps > 0) String.format(" · hands %.0f fps", state.handFps) else "") +
                    (state.detectorMs?.let { String.format(" · objects %.0f ms", it) } ?: ""),
                "Network path" to (state.networkBytes?.let { if (it == 0L) "No network traffic this session" else "Network traffic this session: $it bytes" } ?: "not measured yet"),
            )
            items(rows) { (name, value) -> ValueRow(name, value) }
            item { AppText("Network availability is not proof of airplane mode. Inference uses local files; only model download uses the internet.", appText(12.sp)) }
            item { ToggleRow("Left-hand finger curl guidance", null, state.gripHints) { state.gripHints = it; if (!it) model.safety.clearFingerFlexion() } }
            item { AppText("Live camera estimates: 0% straight to 100% curled. Curl hints stop at 10% for the thumb and 25% for other fingers. Step 2 keeps the panel visible; unavailable readings show dashes. These are not measured joint angles or pressure.", appText(12.sp)) }

            item { Spacer(Modifier.height(8.dp)); AppText("This Pixel", appText(15.sp, FontWeight.Medium, AppTheme.accent)) }
            val pixel = listOf(
                "Image input" to "Gemma 4 vision encoder on ${state.visionBackend ?: "not loaded"}",
                "Speech" to state.speechPath,
                "Gestures" to state.gestureModel,
                "Object boxes" to state.detectorModel,
                "Airplane mode" to (state.airplaneMode?.let { if (it) "on" else "off" } ?: "unknown"),
                "Device" to "${Build.MANUFACTURER} ${Build.MODEL} · ${Build.SOC_MODEL} · Android ${Build.VERSION.RELEASE}",
                "Load" to (state.loadMs?.let { "$it ms" } ?: "not measured yet"),
                "Gemma calls" to (state.medianCallMs?.let { "median $it ms of the last ${state.callMs.size}" } ?: "none yet"),
                "This session" to "${state.gemmaCalls} Gemma calls · ${state.toolCalls} tool calls · ${state.visionChecks} vision checks · ${state.boxCount} boxes · ${state.audioCalls} audio",
                "Thermal" to (state.thermalHeadroom?.takeIf { !it.isNaN() }?.let { String.format("headroom %.2f", it) } ?: "not reported"),
            )
            items(pixel) { (name, value) -> ValueRow(name, value) }

            item { Spacer(Modifier.height(8.dp)); AppText("Session events", appText(15.sp, FontWeight.Medium, AppTheme.accent)) }
            val events = model.session.events.reversed()
            items(events) { event ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    AppText(event.message, appText(15.sp))
                    AppText("${event.origin.raw.uppercase()} · ${java.text.DateFormat.getTimeInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(event.timestamp))}",
                        appText(12.sp, color = AppTheme.secondary))
                }
            }
            item { Spacer(Modifier.height(8.dp)); AppText("Last raw Gemma response", appText(15.sp, FontWeight.Medium, AppTheme.accent)) }
            item { AppText(state.rawResponse.ifEmpty { "No response yet" }, appText(12.sp)) }
            item { Spacer(Modifier.height(12.dp)) }
        }
    }
}

@Composable
fun ValueRow(name: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        AppText(name, appText(14.sp, color = AppTheme.secondary), Modifier.width(170.dp))
        AppText(value, appText(14.sp), Modifier.weight(1f))
    }
}

@Composable
fun ActionRow(title: String, enabled: Boolean = true, color: Color = AppTheme.accent, onTap: () -> Unit) {
    AppText(title, appText(15.sp, FontWeight.Medium, color), Modifier.fillMaxWidth().alpha(if (enabled) 1f else 0.45f)
        .clickable(remember { MutableInteractionSource() }, null, enabled = enabled, onClick = onTap).padding(vertical = 8.dp))
}

@Composable
fun ToggleRow(title: String, detail: String?, on: Boolean, enabled: Boolean = true, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().alpha(if (enabled) 1f else 0.45f).clickable(remember { MutableInteractionSource() }, null, enabled = enabled) { set(!on) }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            AppText(title, appText(15.sp))
            if (detail != null) AppText(detail, appText(12.sp, color = AppTheme.secondary))
        }
        // A plain capsule switch in our colours.
        Box(Modifier.width(44.dp).height(26.dp).background(if (on) AppTheme.accent else AppTheme.surfaceHigh, RoundedCornerShape(50))
            .border(1.dp, AppTheme.outlineStrong, RoundedCornerShape(50)).padding(3.dp),
            contentAlignment = if (on) Alignment.CenterEnd else Alignment.CenterStart) {
            Box(Modifier.size(20.dp).background(Color.White, CircleShape))
        }
    }
}
