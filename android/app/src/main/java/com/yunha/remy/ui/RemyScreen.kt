package com.yunha.remy.ui

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
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.yunha.remy.RemyModel
import com.yunha.remy.SafetyLoop
import com.yunha.remy.core.CookingSession
import com.yunha.remy.core.FingerFlexion
import com.yunha.remy.core.GuidancePillArbiter
import com.yunha.remy.core.HandFinger
import com.yunha.remy.core.Point2
import com.yunha.remy.uptime
import kotlinx.coroutines.delay

/** What the screen can ask the app to do; MainActivity implements it. */
interface RemyActions {
    fun toggleVideo()
    fun toggleMic()
    fun primary()
    fun rescanHazards()
    fun setResolution(height: Int)
    fun setHandsFree(on: Boolean)
    fun textTest()
    fun describeCamera()
    fun reset()
    fun saveDishSummary(bitmap: android.graphics.Bitmap)
}

/** LandscapeChrome in GlassControlDock.swift: 43.5 dp circles inside 54 dp touch targets, 6 dp apart. */
internal object Chrome {
    val controlDiameter = (58 * 0.75).dp
    val touchSize = 54.dp
    val controlGap = 6.dp
    val dockWidth = touchSize * 3 + controlGap * 2
    val pillWidth = dockWidth - (touchSize - controlDiameter)
}

/**
 * The iPhone landscape screen (ContentView.swift, landscape branch): full-bleed camera and overlay, the guidance pill
 * top centre (tap: Session) with the left-hand curl panel under it, the Gemma drawer on the left edge, and one bottom
 * row: the dock (video, microphone, sparkle) at the left, the primary action in the middle, Session and Settings at the right.
 */
@Composable
fun RemyScreen(state: RemyState, preview: PreviewView, actions: RemyActions, session: @Composable () -> Unit, model: RemyModel) {
    @Suppress("UNUSED_VARIABLE") val version = state.sessionVersion
    val cooking = model.session
    Box(Modifier.fillMaxSize().background(AppTheme.background)) {
        if (state.videoOn) AndroidView({ preview }, Modifier.fillMaxSize())
        CameraOverlay(state, model, Modifier.fillMaxSize())
        if (state.planning) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)))
        if (state.markSaltLocation && state.videoOn) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                AppText("Tap the ${cooking.step?.guardItem ?: "item"}", appText(17.sp, FontWeight.Medium, Color.White),
                    Modifier.glass(RoundedCornerShape(50)).padding(12.dp))
            }
        }

        Column(Modifier.fillMaxSize()) {
            GuidancePill(state, model, Modifier.align(Alignment.CenterHorizontally).padding(top = 14.dp, start = 24.dp, end = 24.dp)) { state.sessionOpen = true }
            val showCurl = (cooking.phase == CookingSession.Phase.COOKING && !cooking.isComplete && cooking.currentStep == 1) || state.leftFingerFlexion.isNotEmpty()
            if (showCurl) LeftHandFlexionHUD(state, Modifier.align(Alignment.CenterHorizontally).padding(top = 6.dp))
            Spacer(Modifier.weight(1f))
            Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(horizontalArrangement = Arrangement.spacedBy(Chrome.controlGap)) {
                    DockButton(actions::toggleVideo) { videoGlyph(state.videoOn, Color.White) }
                    DockButton(actions::toggleMic) { micGlyph(state.listenerOn || state.recording, state.hearing, Color.White) }
                    DockButton({ state.drawerOpen = !state.drawerOpen }) {
                        val path = sparklePath(Size(size.width * 0.72f, size.height * 0.72f)).apply { translate(Offset(size.width * 0.14f, size.height * 0.14f)) }
                        drawPath(path, Color.White, style = Stroke(1.6.dp.toPx()))
                    }
                }
                Spacer(Modifier.weight(1f).widthIn(min = 12.dp))
                PrimaryAction(state, actions::primary)
                Spacer(Modifier.weight(1f).widthIn(min = 12.dp))
                Row(Modifier.width(Chrome.dockWidth), horizontalArrangement = Arrangement.spacedBy(Chrome.controlGap), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(Chrome.touchSize * 2 + Chrome.controlGap).height(Chrome.touchSize)
                        .clickable(remember { MutableInteractionSource() }, null) { state.sessionOpen = true }, contentAlignment = Alignment.Center) {
                        Box(Modifier.width(Chrome.touchSize * 2 + Chrome.controlGap - (Chrome.touchSize - Chrome.controlDiameter)).height(Chrome.controlDiameter)
                            .glass(RoundedCornerShape(50)), contentAlignment = Alignment.Center) {
                            AppText("Session", appText(14.sp, FontWeight.Medium, Color.White), maxLines = 1)
                        }
                    }
                    DockButton({ state.settingsOpen = true }) { gearGlyph(Color.White) }
                }
            }
        }
        if (state.isLoaded || state.activity.entries.isNotEmpty()) AgentDrawer(state, Modifier.align(Alignment.CenterStart))
        StatusStrip(state, Modifier.align(Alignment.BottomCenter).padding(bottom = 64.dp, start = 200.dp, end = 200.dp))

        if (state.sessionOpen) SheetFrame("Your session", { state.sessionOpen = false }) { session() }
        if (state.settingsOpen) SettingsSheet(state, actions, model)
        if (state.evidenceOpen) EvidenceSheet(state, model)
        if (state.showsDishSummary) FinishedDishSummary(state, model, actions)
    }
}

/** A 43.5 dp glass circle around a line glyph, inside a 54 dp touch target (FrostedControlStyle). */
@Composable
private fun DockButton(onTap: () -> Unit, glyph: DrawScope.() -> Unit) {
    Box(Modifier.size(Chrome.touchSize).clickable(remember { MutableInteractionSource() }, null, onClick = onTap), contentAlignment = Alignment.Center) {
        Box(Modifier.size(Chrome.controlDiameter).glass(CircleShape), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(20.dp)) { glyph() }
        }
    }
}

/** PrimaryAction(compact: true): the Gemma gradient capsule, pill-width, one line of 14 sp medium white. */
@Composable
private fun PrimaryAction(state: RemyState, onTap: () -> Unit) {
    Box(Modifier.width(Chrome.dockWidth).height(Chrome.touchSize)
        .clickable(remember { MutableInteractionSource() }, null, enabled = state.primaryEnabled, onClick = onTap), contentAlignment = Alignment.Center) {
        Box(Modifier.width(Chrome.pillWidth).height(Chrome.controlDiameter).alpha(if (state.primaryEnabled) 1f else 0.45f)
            .background(AppTheme.gradient, RoundedCornerShape(50)).padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
            AppText(if (!state.isLoaded && !state.isLoading) "Set up Remy" else state.primaryTitle, appText(14.sp, FontWeight.Medium, Color.White), maxLines = 1)
        }
    }
}

private val HAND_CHAINS = listOf(listOf(0, 1, 2, 3, 4), listOf(0, 5, 6, 7, 8), listOf(5, 9, 10, 11, 12), listOf(9, 13, 14, 15, 16), listOf(13, 17, 18, 19, 20), listOf(0, 17))

/** displayRect(fill: true): the camera image scaled to cover the screen, centred (PreviewView FILL_CENTER). */
private fun imageRect(size: Size, aspect: Float): Rect {
    val width = maxOf(size.width, size.height * aspect); val height = width / aspect
    return Rect(Offset((size.width - width) / 2, (size.height - height) / 2), Size(width, height))
}

@Composable
private fun CameraOverlay(state: RemyState, model: RemyModel, modifier: Modifier) {
    val measurer = rememberTextMeasurer()
    @Suppress("UNUSED_VARIABLE") val version = state.sessionVersion
    val cooking = model.session
    Canvas(modifier.pointerInput(Unit) {
        detectTapGestures { tap ->
            if (!state.markSaltLocation) return@detectTapGestures
            val rect = imageRect(Size(size.width.toFloat(), size.height.toFloat()), state.imageAspect)
            if (!rect.contains(tap)) return@detectTapGestures
            model.placeSalt(Point2(((tap.x - rect.left) / rect.width).toDouble(), ((tap.y - rect.top) / rect.height).toDouble()))
        }
    }) {
        if (!state.videoOn) return@Canvas
        val image = imageRect(size, state.imageAspect)
        fun px(p: Point2) = Offset(image.left + p.x.toFloat() * image.width, image.top + p.y.toFloat() * image.height)
        val now = uptime()

        // Hands: observed solid, briefly estimated dashed and fading, with the reach point ring.
        if (now - state.handsTime < 0.20) for (hand in state.hands) {
            val opacity = if (hand.estimated) maxOf(0.2, 0.65 - hand.observationAge * 2).toFloat() else 0.7f
            val dash = if (hand.estimated) PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())) else null
            for (chain in HAND_CHAINS) {
                val path = Path(); var connected = false
                for (joint in chain) {
                    val p = hand.points[joint] ?: run { connected = false; null } ?: continue
                    val at = px(p)
                    if (connected) path.lineTo(at.x, at.y) else path.moveTo(at.x, at.y)
                    connected = true
                }
                drawPath(path, AppTheme.accentLight.copy(alpha = opacity), style = Stroke(1.5.dp.toPx(), pathEffect = dash))
            }
            for (p in hand.points.values) drawCircle(AppTheme.accentLight.copy(alpha = if (hand.estimated) opacity else 1f), 2.5.dp.toPx(), px(p))
            if (hand.estimated) hand.points[0]?.let { wrist ->
                val label = measurer.measure("Estimating", appText(11.sp, FontWeight.Medium, Color.White.copy(alpha = 0.8f)))
                val at = px(wrist)
                drawText(label, topLeft = Offset(at.x - label.size.width / 2, at.y + 18.dp.toPx() - label.size.height / 2))
            }
            hand.points[8]?.let { reach ->
                drawCircle(AppTheme.accentLight.copy(alpha = if (hand.estimated) opacity else 1f), 8.dp.toPx(), px(reach), style = Stroke(2.dp.toPx()))
            }
        }
        // The guarded item's marked location (salt).
        cooking.zone?.let { zone ->
            val center = px(zone.center); val rx = (zone.radius * image.width).toFloat(); val ry = (zone.radius * image.height).toFloat()
            val armed = cooking.guardArmed
            drawOval(AppTheme.accent.copy(alpha = if (armed) 0.25f else 0.1f), Offset(center.x - rx, center.y - ry), Size(rx * 2, ry * 2))
            drawOval(if (armed) AppTheme.accent else AppTheme.accentLight, Offset(center.x - rx, center.y - ry), Size(rx * 2, ry * 2),
                style = Stroke(2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx()))))
        }
        // Safety zones stay dashed red and labelled while watched, drawn at the 120% boundary that triggers.
        val alerting = state.hotAlert
        for ((zone, recovering) in state.zones.map { it to false } + state.recoveringZones.map { it to true }) {
            val e = zone.expanded(1.2)
            val rect = Rect(px(Point2(e.x, e.y)), px(Point2(e.x + e.width, e.y + e.height)))
            val corner = CornerRadius(10.dp.toPx())
            if (alerting) drawRoundRect(AppTheme.safety.copy(alpha = 0.22f), rect.topLeft, rect.size, corner)
            drawRoundRect(AppTheme.safety, rect.topLeft, rect.size, corner,
                style = Stroke((if (alerting) 4f else 2.5f).dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(8.dp.toPx(), 5.dp.toPx()))))
            tag(measurer, if (recovering) "Hot Surface · reacquiring" else "Hot Surface", rect, AppTheme.safety, AppTheme.onSafety)
        }
        state.knifeBox?.let { box ->
            val rect = Rect(px(Point2(box.x, box.y)), px(Point2(box.x + box.width, box.y + box.height)))
            val corner = CornerRadius(6.dp.toPx())
            if (state.knifeAlert) drawRoundRect(AppTheme.warning.copy(alpha = 0.22f), rect.topLeft, rect.size, corner)
            drawRoundRect(AppTheme.warning, rect.topLeft, rect.size, corner,
                style = Stroke((if (state.knifeAlert) 4f else 2.5f).dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(8.dp.toPx(), 5.dp.toPx()))))
            tag(measurer, if (state.knifeRecovering) "Knife · reacquiring" else "Knife", rect, AppTheme.warning, Color.White)
        }
        // Items Gemma located and fresh detector boxes, in the same normalized space as the hands.
        for (box in SafetyLoop.visibleObjectBoxes(state, cooking.phase, now)) {
            val rect = Rect(px(Point2(box.x, box.y)), px(Point2(box.x + box.width, box.y + box.height)))
            drawRoundRect(AppTheme.accent, rect.topLeft, rect.size, CornerRadius(10.dp.toPx()), style = Stroke(3.dp.toPx()))
            if (box.label.isNotEmpty()) tag(measurer, box.label, rect, AppTheme.accent, Color.White)
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

/**
 * CookingGuidancePill: every producer submits to GuidancePillArbiter; the pill shows the winner. A knife event owns it
 * for one second, a held hot-surface or reach alert while active, Remy's speech over curl hints, and the idle line.
 */
@Composable
private fun GuidancePill(state: RemyState, model: RemyModel, modifier: Modifier, onTap: () -> Unit) {
    @Suppress("UNUSED_VARIABLE") val version = state.sessionVersion
    val arbiter = remember { GuidancePillArbiter() }
    var current by remember { mutableStateOf<GuidancePillArbiter.Entry?>(null) }
    val sessionKey = model.session.id to model.session.phase
    LaunchedEffect(state.videoOn, state.knifeTracking, sessionKey) {
        arbiter.reset()
        while (true) {
            val now = uptime()
            val inputs = buildList {
                add(GuidancePillArbiter.Entry(GuidancePillArbiter.Source.IDLE, state.line))
                if (state.knifeAlert) add(GuidancePillArbiter.Entry(GuidancePillArbiter.Source.KNIFE, "Left hand is near the knife"))
                if (state.hotAlert) add(GuidancePillArbiter.Entry(GuidancePillArbiter.Source.SAFETY, "Hot Surface. Move your hand clear."))
                if (now < state.alertUntil && !state.knifeAlert && !state.hotAlert)
                    add(GuidancePillArbiter.Entry(GuidancePillArbiter.Source.SAFETY, "${state.alertTitle}. ${state.alertSubtitle}"))
                if (state.speaking || state.hearing || state.understanding || state.recording)
                    add(GuidancePillArbiter.Entry(GuidancePillArbiter.Source.CHEF, state.line))
                state.fingerCurlHint?.let { add(GuidancePillArbiter.Entry(GuidancePillArbiter.Source.CURL, it)) }
            }
            arbiter.update(inputs, now)
            current = arbiter.current
            delay(50)
        }
    }
    val source = current?.source ?: GuidancePillArbiter.Source.IDLE
    val alertColor = if (source == GuidancePillArbiter.Source.KNIFE) AppTheme.warning else AppTheme.safety
    val reflexMs = if (source == GuidancePillArbiter.Source.KNIFE || source == GuidancePillArbiter.Source.SAFETY) (state.lastReflexMs ?: 0.0) else null
    val thinking = state.understanding || state.ingredientChecking || (state.isBusy && !state.instructionsPreparing)
    val text = (current?.text ?: state.line).trim().ifEmpty { "Ready when you are." }
    val shape = RoundedCornerShape(50)
    Row(modifier.widthIn(max = 600.dp).glass(shape, AppTheme.outline)
        .then(if (reflexMs != null) Modifier.border(1.5.dp, alertColor, shape) else Modifier)
        .clickable(remember { MutableInteractionSource() }, null, onClick = onTap)
        .padding(start = 12.dp, end = 22.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        VoiceOrb(when {
            reflexMs != null -> OrbMode.ALERT
            !state.listenerOn -> OrbMode.OFF
            state.speaking -> OrbMode.SPEAKING
            state.hearing -> OrbMode.HEARING
            thinking -> OrbMode.THINKING
            else -> OrbMode.LISTENING
        }, alertColor = alertColor)
        AppText(text, appText(17.sp, color = Color.White), Modifier.weight(1f, fill = false))
        when {
            reflexMs != null -> AppText(String.format("Reflex %.0f ms", reflexMs), appText(12.sp, FontWeight.Medium, alertColor), maxLines = 1)
            state.gemmaSeconds != null -> AppText(String.format("%.1f s", state.gemmaSeconds), appText(12.sp, FontWeight.Medium, AppTheme.secondary), maxLines = 1)
        }
    }
}

/** LeftHandFlexionHUD: compact camera-only curl estimates; a finger below its cutoff shows in warning orange. */
@Composable
private fun LeftHandFlexionHUD(state: RemyState, modifier: Modifier) {
    Column(modifier.glass(RoundedCornerShape(16.dp)).padding(horizontal = 14.dp, vertical = 7.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        AppText("Left hand · estimated curl", appText(10.sp, FontWeight.Medium, Color.White.copy(alpha = 0.8f)), maxLines = 1)
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            for (finger in HandFinger.entries) {
                val value = state.leftFingerFlexion.firstOrNull { it.finger == finger }
                Column(Modifier.widthIn(min = 40.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    AppText(finger.title, appText(10.sp, FontWeight.Medium, Color.White), maxLines = 1)
                    AppText(value?.let { "${it.percent}%" } ?: "—", appText(13.sp, FontWeight.Bold,
                        if (value != null && !FingerFlexion.isCurled(value)) AppTheme.warning else Color.White), maxLines = 1)
                }
            }
        }
    }
}

/** AgentDrawer: a slim tab on the left edge; open, a 320 dp glass panel with Gemma's work, newest at the bottom. */
@Composable
private fun AgentDrawer(state: RemyState, modifier: Modifier) {
    Row(modifier.fillMaxHeight().padding(start = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        AnimatedVisibility(state.drawerOpen, enter = slideInHorizontally { -it } + fadeIn(), exit = slideOutHorizontally { -it } + fadeOut()) {
            Column(Modifier.width(320.dp).fillMaxHeight().padding(vertical = 14.dp).glass(RoundedCornerShape(22.dp)).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Eyebrow("Gemma · live")
                AppText("Gemma 4 E2B · LiteRT-LM · " + (state.lmBackend ?: "Not loaded"), appText(11.sp, color = AppTheme.secondary), maxLines = 1)
                Box(Modifier.fillMaxWidth().height(1.dp).background(AppTheme.outline))
                // The log keeps to what Gemma does; Remy's spoken lines are already in the pill, and system lines are noise.
                val entries = state.activity.entries.filter { it.kind != AgentActivity.Kind.SAYS && it.kind != AgentActivity.Kind.SYSTEM }
                if (entries.isEmpty()) {
                    AppText("Say “Chef…” and the work shows up here as it happens.", appText(13.sp, color = AppTheme.secondary))
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
            Canvas(Modifier.fillMaxSize()) { chevronGlyph(pointsLeft = state.drawerOpen, Color.White) }
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
        Box(Modifier.padding(top = 5.dp).size(8.dp).alpha(if (running) phase else if (entry.kind == AgentActivity.Kind.REFLEX || entry.state == AgentActivity.State.FAILED) 1f else 0.55f)
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

/** Android only: one line of live facts, text only; nothing is shown that was not measured. */
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
