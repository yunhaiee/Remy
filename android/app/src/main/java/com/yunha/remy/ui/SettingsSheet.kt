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
import androidx.compose.runtime.remember
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

/** BrainView in ContentView.swift: the same sections and items, in the same order. GoPro and Metal are iPhone-only. */
@Composable
fun SettingsSheet(state: RemyState, actions: RemyActions) {
    SheetFrame("Settings", { state.settingsOpen = false }) {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item { Eyebrow("Remy") }
            item { ToggleRow("Hands-free voice", null, state.handsFree) { actions.setHandsFree(it) } }
            item { ToggleRow("Watch the board automatically", null, state.automaticChecks, enabled = state.isLoaded) { state.automaticChecks = it } }
            item { ToggleRow("Object boxes", "Shows everyday object detections independently of safety monitoring.", state.objectBoxes) { state.objectBoxes = it } }
            item { ToggleRow("Fire safety · box & alerts", "Warns when a hand stays on a hot-surface box for one second, held until the hand leaves. Switch Fire safety off here to pause.", state.safetyAlerts) { state.safetyAlerts = it } }
            item { ToggleRow("Knife tracking · box & warning", "Orange box around the knife Gemma located, and a warning and vibration while a left-hand fingertip overlaps it. Independent of Object boxes and Fire safety.", state.knifeTracking) { state.knifeTracking = it } }
            item { ToggleRow("Spoken responses", null, state.spokenResponses) { state.spokenResponses = it } }
            item { ToggleRow("Short recipes (up to 5 steps)", null, state.shortRecipes) { state.shortRecipes = it } }
            item { ToggleRow("Pasta-salad demo preset", "“Make pasta salad” uses the fixed five ingredients and two app-written steps. Off, Gemma plans every dish.", state.demoPreset) { state.demoPreset = it } }
            item { ToggleRow("Hand gestures", "Thumbs up (hold 1 second): next. Thumbs down: back. Open palm (hold): quiet.", state.gestures) { state.gestures = it } }

            item { Spacer(Modifier.height(8.dp)); Eyebrow("Camera") }
            item { ValueRow("Camera", "Pixel rear camera (GoPro input is iPhone-only)") }
            item {
                Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    AppText("Hand tracking resolution", appText(15.sp), Modifier.weight(1f))
                    for (value in listOf(480, 720)) {
                        val selected = state.handResolution == value
                        AppText("${value}p", appText(13.sp, FontWeight.Medium, if (selected) AppTheme.background else AppTheme.text),
                            Modifier.padding(start = 6.dp).background(if (selected) AppTheme.accentLight else AppTheme.surfaceHigh, RoundedCornerShape(50))
                                .clickable(remember { MutableInteractionSource() }, null) { actions.setResolution(value) }
                                .padding(horizontal = 12.dp, vertical = 6.dp))
                    }
                }
            }

            item { Spacer(Modifier.height(8.dp)); Eyebrow("Look") }
            item { ValueRow("Controls over the video", "Dark glass") }

            item { Spacer(Modifier.height(8.dp)); Eyebrow("Gemma on this Pixel") }
            item { ValueRow("Model", if (state.isLoaded) "Gemma 4 E2B" else if (state.isLoading) "Loading…" else "Not loaded") }
            item { ToggleRow("Schema-constrained decoding", "Off: the JSON schema is described in the prompt and the app parses and validates the reply, as on iPhone.", state.constrainedDecoding, enabled = false) { } }
            item { ValueRow("Running on", state.lmBackend ?: "not loaded") }

            item { Spacer(Modifier.height(8.dp)); Eyebrow("Session") }
            item { ActionRow("Evidence") { state.evidenceOpen = true } }
            item { ActionRow("Run local text test", enabled = state.isLoaded && !state.isBusy) { actions.textTest() } }
            item { ActionRow("Describe the live camera image", enabled = state.isLoaded && !state.isBusy) { actions.describeCamera() } }
            item { ActionRow("Look for hot surfaces again", enabled = state.isLoaded) { actions.rescanHazards(); state.settingsOpen = false } }
            if (state.smokePassed) item { AppText("Local test passed", appText(14.sp, color = AppTheme.accent)) }
            if (state.rawResponse.isNotEmpty()) item { AppText(state.rawResponse, appText(13.sp, color = AppTheme.secondary), maxLines = 4) }
            item { ActionRow("Reset recipe and memory", color = AppTheme.safety) { actions.reset(); state.settingsOpen = false } }
            item { Spacer(Modifier.height(12.dp)) }
        }
    }
}

/** EvidenceView: what is actually running, the session tally, the LiteRT features in use, and honest limits. */
@Composable
fun EvidenceSheet(state: RemyState) {
    SheetFrame("Evidence", { state.evidenceOpen = false }) {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item { Eyebrow("What is actually running") }
            val speed = if (state.prefillTps != null) String.format("prefill %.0f tok/s · decode %.1f tok/s · first token %.2f s",
                state.prefillTps, state.decodeTps ?: 0.0, state.ttft ?: 0.0) else null
            val rows = listOf(
                "Gemma" to (if (state.isLoaded) "Gemma 4 E2B · LiteRT-LM ${com.yunha.remy.BuildConfig.LITERT_LM_VERSION} · ${state.lmBackend}" else "Not loaded"),
                "Last call" to (speed ?: "not measured yet"),
                "Image input" to "Gemma 4 vision encoder on ${state.visionBackend ?: "not loaded"}",
                "Structured output" to "JSON parsing and validation; native constraints disabled",
                "Function calling" to "16 tools, the app runs each call",
                "Reflex latency" to (state.lastReflexMs?.let { String.format("%.0f ms, frame to alarm", it) } ?: "not measured yet"),
                "Audio in" to "Gemma hears answers to its questions",
                "Speech" to state.speechPath,
                "Fast vision" to "MediaPipe Hand Landmarker · LiteRT · CPU" + (if (state.handFps > 0) String.format(" · %.0f fps", state.handFps) else ""),
                "Gestures" to state.gestureModel,
                "Object boxes" to state.detectorModel,
                "Network path" to (state.networkBytes?.let { if (it == 0L) "Network calls this session: 0" else "Network traffic this session: $it bytes" } ?: "not measured yet"),
                "Airplane mode" to (state.airplaneMode?.let { if (it) "on" else "off" } ?: "unknown"),
                "Device" to "${Build.MANUFACTURER} ${Build.MODEL} · ${Build.SOC_MODEL} · Android ${Build.VERSION.RELEASE}",
                "Load" to (state.loadMs?.let { "$it ms" } ?: "not measured yet"),
                "Gemma calls" to (state.medianCallMs?.let { "median $it ms of the last ${state.callMs.size}" } ?: "none yet"),
                "Thermal" to (state.thermalHeadroom?.takeIf { !it.isNaN() }?.let { String.format("headroom %.2f", it) } ?: "not reported"),
            )
            items(rows) { (name, value) -> ValueRow(name, value) }
            item { AppText("Network availability is not proof of airplane mode. Inference uses local files on this phone.", appText(12.sp, color = AppTheme.secondary)) }
            item { Spacer(Modifier.height(8.dp)); Eyebrow("This session") }
            item {
                AppText("This session: ${state.gemmaCalls} Gemma calls · ${state.toolCalls} tool calls · ${state.visionChecks} vision checks · ${state.boxCount} boxes · ${state.audioCalls} audio",
                    appText(15.sp))
            }
            item { Spacer(Modifier.height(8.dp)); Eyebrow("LiteRT on this Pixel") }
            val features = listOf(
                "LiteRT-LM Engine on " + (state.lmBackend ?: "not loaded"),
                "Conversation API with system instruction and sampler config",
                "Function calling with 16 declared tools, automatic tool calling off",
                "Image input (Content.ImageBytes) with box_2d grounding",
                "Audio input (Content.AudioBytes) for answers to Gemma's questions",
                "Benchmark info: prefill, decode and first-token timing",
                "MediaPipe Tasks on LiteRT: " + listOf("hand landmarks", state.gestureModel.takeIf { it.startsWith("Gesture") }, state.detectorModel.takeIf { it.startsWith("EfficientDet") }).filterNotNull().joinToString(", "),
            )
            items(features) { AppText(it, appText(14.sp)) }
            item { Spacer(Modifier.height(8.dp)); Eyebrow("Honest limits") }
            val limits = listOf(
                "GoPro input and Core ML detectors are iPhone-only and not on this build.",
                "Gemma runs one request at a time; a camera check waits for a running plan or reply.",
                "Hot-surface and knife boxes come from Gemma looks, not continuous tracking; they can lag a moved pan.",
                "Speech recognition uses Android's on-device recognizer when available; otherwise Gemma transcribes the audio.",
            )
            items(limits) { AppText(it, appText(13.sp, color = AppTheme.secondary)) }
            item { Spacer(Modifier.height(8.dp)); Eyebrow("Last raw Gemma response") }
            item { AppText(state.rawResponse.ifEmpty { "No response yet" }, appText(12.sp, color = AppTheme.secondary)) }
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
