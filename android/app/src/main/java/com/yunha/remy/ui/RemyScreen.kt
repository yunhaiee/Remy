package com.yunha.remy.ui

import android.os.Build
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.yunha.remy.core.Point2

private val HAND_EDGES = listOf(0 to 1, 1 to 2, 2 to 3, 3 to 4, 0 to 5, 5 to 6, 6 to 7, 7 to 8, 5 to 9, 9 to 10, 10 to 11, 11 to 12,
    9 to 13, 13 to 14, 14 to 15, 15 to 16, 13 to 17, 17 to 18, 18 to 19, 19 to 20, 0 to 17)

/** The iPhone landscape screen (ContentView.swift): full-bleed camera, overlay, pill, drawer, dock. */
@Composable
fun RemyScreen(state: RemyState, preview: PreviewView, onToggleVideo: () -> Unit, onLookAgain: () -> Unit, onResolution: (Int) -> Unit) {
    Box(Modifier.fillMaxSize().background(AppTheme.background)) {
        if (state.videoOn) AndroidView({ preview }, Modifier.fillMaxSize())
        CameraOverlay(state, Modifier.fillMaxSize())

        GuidancePill(state, Modifier.align(Alignment.TopCenter).padding(top = 14.dp, start = 96.dp, end = 96.dp))
        AgentDrawer(state, Modifier.align(Alignment.CenterStart))

        Row(Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 14.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            DockButton(onToggleVideo) { videoGlyph(state.videoOn, AppTheme.text) }
            DockButton(onLookAgain) { lookAgainGlyph(AppTheme.text) }
            DockButton({ state.drawerOpen = !state.drawerOpen }) {
                val path = sparklePath(Size(size.width * 0.6f, size.height * 0.6f)).apply { translate(Offset(size.width * 0.2f, size.height * 0.2f)) }
                drawPath(path, AppTheme.text, style = Stroke(1.6.dp.toPx()))
            }
        }
        Box(Modifier.align(Alignment.BottomStart).padding(start = 16.dp, bottom = 14.dp)) {
            DockButton({ state.settingsOpen = true }) { gearGlyph(AppTheme.text) }
        }
        StatusStrip(state, Modifier.align(Alignment.BottomCenter).padding(bottom = 26.dp, start = 80.dp, end = 180.dp))

        if (state.settingsOpen) SettingsSheet(state, onResolution)
    }
}

/** A 44 dp glass circle around a line glyph. */
@Composable
private fun DockButton(onTap: () -> Unit, glyph: DrawScope.() -> Unit) {
    Box(Modifier.size(44.dp).glass(CircleShape).clickable(remember { MutableInteractionSource() }, null, onClick = onTap),
        contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(22.dp)) { glyph() }
    }
}

@Composable
private fun CameraOverlay(state: RemyState, modifier: Modifier) {
    val measurer = rememberTextMeasurer()
    val alerting = state.reflexMs != null
    Canvas(modifier) {
        // PreviewView FILL_CENTER: the 4:3 camera image scaled to cover the screen, centred.
        val scale = maxOf(size.width / state.imageAspect, size.height)
        val imageW = scale * state.imageAspect; val imageH = scale
        val image = Rect(Offset((size.width - imageW) / 2, (size.height - imageH) / 2), Size(imageW, imageH))
        fun px(p: Point2) = Offset(image.left + p.x.toFloat() * image.width, image.top + p.y.toFloat() * image.height)

        for (zone in state.zones) {
            val rect = Rect(px(Point2(zone.x, zone.y)), px(Point2(zone.x + zone.width, zone.y + zone.height)))
            val corner = CornerRadius(10.dp.toPx())
            if (alerting) drawRoundRect(AppTheme.safety.copy(alpha = 0.25f), rect.topLeft, rect.size, corner)
            drawRoundRect(AppTheme.safety, rect.topLeft, rect.size, corner,
                style = Stroke((if (alerting) 4f else 2.5f).dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(8.dp.toPx(), 5.dp.toPx()))))
            tag(measurer, "Hot surface", rect, AppTheme.safety, AppTheme.onSafety)
        }
        if (state.objectBoxes) for (box in state.boxes) {
            val rect = Rect(px(Point2(box.x, box.y)), px(Point2(box.x + box.width, box.y + box.height)))
            drawRoundRect(AppTheme.accent, rect.topLeft, rect.size, CornerRadius(10.dp.toPx()), style = Stroke(3.dp.toPx()))
            if (box.label.isNotEmpty()) tag(measurer, box.label, rect, AppTheme.accent, Color.White)
        }
        for (hand in state.hands) {
            if (hand.size == 21) for ((a, b) in HAND_EDGES) {
                if (hand[a].isValid && hand[b].isValid) drawLine(AppTheme.accentLight, px(hand[a]), px(hand[b]), 2.dp.toPx())
            }
            for (p in hand) if (p.isValid) drawCircle(AppTheme.accentLight, 3.dp.toPx(), px(p))
        }
    }
}

private fun DrawScope.tag(measurer: TextMeasurer, title: String, rect: Rect, fill: Color, text: Color) {
    val layout = measurer.measure(title, appText(13.sp, FontWeight.Medium, text))
    val w = layout.size.width + 14.dp.toPx(); val h = layout.size.height + 6.dp.toPx()
    val top = maxOf(0f, rect.top - h - 8.dp.toPx())
    drawRoundRect(fill, Offset(rect.left, top), Size(w, h), CornerRadius(h / 2))
    drawText(layout, topLeft = Offset(rect.left + 7.dp.toPx(), top + 3.dp.toPx()))
}

/** LandscapeGuidanceHeader: orb, Remy's line, and the Gemma time or the reflex time on the right. */
@Composable
private fun GuidancePill(state: RemyState, modifier: Modifier) {
    val alerting = state.reflexMs != null
    val shape = RoundedCornerShape(50)
    Row(modifier.widthIn(max = 600.dp).glass(shape, if (alerting) AppTheme.safety else AppTheme.outline)
        .then(if (alerting) Modifier.border(1.5.dp, AppTheme.safety, shape) else Modifier)
        .padding(start = 12.dp, end = 22.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        VoiceOrb(if (alerting) OrbMode.ALERT else if (state.working) OrbMode.THINKING else OrbMode.IDLE)
        AppText(state.line.ifBlank { "Ready when you are." }, appText(17.sp, color = Color.White), Modifier.weight(1f, fill = false), maxLines = 3)
        when {
            state.reflexMs != null -> AppText(String.format("Reflex %.0f ms", state.reflexMs), appText(12.sp, FontWeight.Medium, AppTheme.safety), maxLines = 1)
            state.gemmaSeconds != null -> AppText(String.format("%.1f s", state.gemmaSeconds), appText(12.sp, FontWeight.Medium, AppTheme.secondary), maxLines = 1)
        }
    }
}

/** AgentDrawer: a slim tab on the left edge; open, a 320 dp glass panel with Gemma's work, newest at the bottom. */
@Composable
private fun AgentDrawer(state: RemyState, modifier: Modifier) {
    Row(modifier.fillMaxHeight().padding(start = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        AnimatedVisibility(state.drawerOpen, enter = slideInHorizontally { -it } + fadeIn(), exit = slideOutHorizontally { -it } + fadeOut()) {
            Column(Modifier.width(320.dp).fillMaxHeight().padding(top = 14.dp, bottom = 72.dp).glass(RoundedCornerShape(22.dp)).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Eyebrow("Gemma · live")
                AppText("Gemma 4 E2B · LiteRT-LM · " + (state.lmBackend ?: "loading"), appText(11.sp, color = AppTheme.secondary), maxLines = 1)
                Box(Modifier.fillMaxWidth().height(1.dp).background(AppTheme.outline))
                val entries = state.activity.entries
                if (entries.isEmpty()) {
                    AppText("Gemma's work shows up here as it happens.", appText(13.sp, color = AppTheme.secondary))
                } else {
                    val list = rememberLazyListState()
                    LaunchedEffect(entries.size) { list.animateScrollToItem(entries.size - 1) }
                    LazyColumn(state = list, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(entries, key = { it.id }) { ActivityRow(it) }
                    }
                }
            }
        }
        Box(Modifier.width(22.dp).height(64.dp).glass(RoundedCornerShape(50))
            .clickable(remember { MutableInteractionSource() }, null) { state.drawerOpen = !state.drawerOpen }) {
            Canvas(Modifier.fillMaxSize()) { chevronGlyph(pointsLeft = state.drawerOpen, AppTheme.text) }
        }
    }
}

@Composable
private fun ActivityRow(entry: AgentActivity.Entry) {
    val color = when {
        entry.state == AgentActivity.State.FAILED || entry.kind == AgentActivity.Kind.REFLEX -> AppTheme.warning
        entry.kind == AgentActivity.Kind.TOOL || entry.kind == AgentActivity.Kind.PLAN -> AppTheme.accentLight
        entry.kind == AgentActivity.Kind.HEARD || entry.kind == AgentActivity.Kind.GESTURE -> AppTheme.accent
        else -> AppTheme.secondary
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        val running = entry.state == AgentActivity.State.RUNNING
        val phase by rememberInfiniteTransition(label = "dot").animateFloat(0.35f, 1f, infiniteRepeatable(tween(450), RepeatMode.Reverse), label = "phase")
        Box(Modifier.padding(top = 5.dp).size(8.dp).alpha(if (running) phase else if (color == AppTheme.warning) 1f else 0.55f)
            .background(if (running) AppTheme.accent else color, CircleShape))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                AppText(entry.kind.label.uppercase(), appText(9.sp, FontWeight.Medium, color, 1.2.sp), maxLines = 1)
                Spacer(Modifier.weight(1f))
                when {
                    entry.ms != null -> AppText(if (entry.ms >= 1000) String.format("%.1f s", entry.ms / 1000) else String.format("%.0f ms", entry.ms),
                        appText(10.sp, color = AppTheme.secondary), maxLines = 1)
                    running -> AppText("running", appText(10.sp, color = AppTheme.accentLight), maxLines = 1)
                }
            }
            AppText(entry.title, appText(13.sp, FontWeight.Medium), maxLines = 2)
            if (entry.detail.isNotEmpty()) AppText(entry.detail, appText(12.sp, color = AppTheme.secondary), maxLines = 3)
        }
    }
}

/** One line of live facts, text only; nothing is shown that was not measured. */
@Composable
private fun StatusStrip(state: RemyState, modifier: Modifier) {
    val parts = buildList {
        state.airplaneMode?.let { add(if (it) "Airplane mode" else "Network on") }
        state.lmBackend?.let { add(if (state.onNpu) "NPU" else "GPU/CPU fallback") }
        state.ttft?.let { add(String.format("TTFT %.2f s", it)) }
        state.prefillTps?.let { add(String.format("%.0f tok/s prefill", it)) }
        if (state.handFps > 0) add(String.format("hands %.0f fps", state.handFps))
        state.thermalHeadroom?.takeIf { !it.isNaN() }?.let { add(String.format("thermal %.1f", it)) }
    }
    AppText(parts.joinToString(" · "), appText(11.sp, color = AppTheme.secondary), modifier, maxLines = 1)
}
