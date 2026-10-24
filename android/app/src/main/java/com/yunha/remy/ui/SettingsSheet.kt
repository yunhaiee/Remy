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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Settings and a read-only Evidence section, as a glass sheet over the camera. */
@Composable
fun SettingsSheet(state: RemyState, onResolution: (Int) -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f))
        .clickable(remember { MutableInteractionSource() }, null) { state.settingsOpen = false }, contentAlignment = Alignment.Center) {
        Column(Modifier.width(560.dp).fillMaxHeight().padding(vertical = 18.dp).background(AppTheme.surface, RoundedCornerShape(22.dp))
            .border(1.dp, AppTheme.outline, RoundedCornerShape(22.dp))
            .clickable(remember { MutableInteractionSource() }, null) {}) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                AppText("Settings", appText(17.sp, FontWeight.Medium), Modifier.weight(1f))
                AppText("Done", appText(15.sp, FontWeight.Medium, AppTheme.accent),
                    Modifier.clickable(remember { MutableInteractionSource() }, null) { state.settingsOpen = false })
            }
            LazyColumn(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                item { Eyebrow("Remy") }
                item { ToggleRow("Object boxes", "Boxes Gemma located, with their labels.", state.objectBoxes) { state.objectBoxes = it } }
                item { ToggleRow("Safety box & alerts", "Looks for hot things and warns when a hand stays on one for a second.", state.safetyAlerts) { state.safetyAlerts = it } }
                item { ToggleRow("Spoken responses", "Says the warning out loud.", state.spokenResponses) { state.spokenResponses = it } }
                item {
                    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        AppText("Hand tracking resolution", appText(15.sp), Modifier.weight(1f))
                        for (value in listOf(480, 720)) {
                            val selected = state.handResolution == value
                            AppText("${value}p", appText(13.sp, FontWeight.Medium, if (selected) AppTheme.background else AppTheme.text),
                                Modifier.padding(start = 6.dp).background(if (selected) AppTheme.accentLight else AppTheme.surfaceHigh, RoundedCornerShape(50))
                                    .clickable(remember { MutableInteractionSource() }, null) { onResolution(value) }
                                    .padding(horizontal = 12.dp, vertical = 6.dp))
                        }
                    }
                }
                item { Spacer(Modifier.height(8.dp)); Eyebrow("Evidence") }
                val rows = listOf(
                    "Device" to "${Build.MANUFACTURER} ${Build.MODEL} · ${Build.SOC_MODEL}",
                    "Android" to "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                    "Runtime" to "LiteRT-LM ${com.yunha.remy.BuildConfig.LITERT_LM_VERSION}",
                    "Language model" to (state.lmBackend ?: "not loaded"),
                    "Vision encoder" to (state.visionBackend ?: "not loaded"),
                    "Hands" to "MediaPipe Hand Landmarker · LiteRT · CPU",
                    "Load" to (state.loadMs?.let { "$it ms" } ?: "not measured yet"),
                    "Prefill" to (state.prefillTps?.let { String.format("%.0f tok/s", it) } ?: "not measured yet"),
                    "Decode" to (state.decodeTps?.let { String.format("%.1f tok/s", it) } ?: "not measured yet"),
                    "First token" to (state.ttft?.let { String.format("%.2f s", it) } ?: "not measured yet"),
                    "Gemma calls" to (state.medianCallMs?.let { "median $it ms of the last ${state.callMs.size}" } ?: "none yet"),
                    "Reflex" to (state.lastReflexMs?.let { String.format("%.0f ms, frame to alarm", it) } ?: "not measured yet"),
                    "Hands rate" to if (state.handFps > 0) String.format("%.0f fps · %.0f ms per frame", state.handFps, state.handMs) else "not measured yet",
                    "Network" to (state.networkBytes?.let { if (it == 0L) "Network calls this session: 0" else "Network traffic this session: $it bytes" } ?: "not measured yet"),
                )
                items(rows) { (name, value) ->
                    Row(Modifier.fillMaxWidth()) {
                        AppText(name, appText(14.sp, color = AppTheme.secondary), Modifier.width(150.dp))
                        AppText(value, appText(14.sp), Modifier.weight(1f))
                    }
                }
                item { Spacer(Modifier.height(12.dp)) }
            }
        }
    }
}

@Composable
private fun ToggleRow(title: String, detail: String, on: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null) { set(!on) }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            AppText(title, appText(15.sp))
            AppText(detail, appText(12.sp, color = AppTheme.secondary))
        }
        // A plain capsule switch in our colours.
        Box(Modifier.width(44.dp).height(26.dp).background(if (on) AppTheme.accent else AppTheme.surfaceHigh, RoundedCornerShape(50))
            .border(1.dp, AppTheme.outlineStrong, RoundedCornerShape(50)).padding(3.dp),
            contentAlignment = if (on) Alignment.CenterEnd else Alignment.CenterStart) {
            Box(Modifier.size(20.dp).background(Color.White, CircleShape))
        }
    }
}
