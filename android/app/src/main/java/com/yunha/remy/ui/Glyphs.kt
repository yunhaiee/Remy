package com.yunha.remy.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** The Gemma sparkle: four points joined by curves that bow toward the centre (Sparkle in GlassControlDock.swift). */
fun sparklePath(size: Size): Path = Path().apply {
    val cx = size.width / 2; val cy = size.height / 2
    val points = listOf(Offset(cx, 0f), Offset(size.width, cy), Offset(cx, size.height), Offset(0f, cy))
    moveTo(points[0].x, points[0].y)
    for (index in 1..4) { val p = points[index % 4]; quadraticTo(cx, cy, p.x, p.y) }
    close()
}

enum class OrbMode { IDLE, THINKING, ALERT }

/**
 * VoiceOrb: the sparkle turning about the vertical axis like a coin, 30°/s idle, 300°/s while Gemma works,
 * pulsing in the warning colour while an alarm shows.
 */
@Composable
fun VoiceOrb(mode: OrbMode, modifier: Modifier = Modifier) {
    var angle by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(mode) {
        var last = 0L
        while (true) withFrameNanos { now ->
            if (last != 0L && mode != OrbMode.ALERT) {
                val speed = if (mode == OrbMode.THINKING) 300f else 30f
                angle = (angle + speed * (now - last) / 1e9f) % 360f
            }
            last = now
        }
    }
    val pulse by rememberInfiniteTransition(label = "orb").animateFloat(0f, 1f,
        infiniteRepeatable(tween(300, easing = LinearEasing), RepeatMode.Reverse), label = "pulse")
    Box(modifier.size(28.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(22.dp).graphicsLayer {
            rotationY = if (mode == OrbMode.ALERT) 0f else angle
            cameraDistance = 8 * density
            val scale = if (mode == OrbMode.ALERT) 1f + 0.14f * pulse else 1f
            scaleX = scale; scaleY = scale
        }) {
            val path = sparklePath(size)
            val brush: Brush = if (mode == OrbMode.ALERT) Brush.linearGradient(listOf(AppTheme.safety, AppTheme.safety)) else AppTheme.gradient
            drawPath(path, brush, style = Stroke(width = 1.8.dp.toPx(), join = StrokeJoin.Round))
        }
    }
}

/** Line glyphs for the dock, drawn in the text colour; no icon fonts. */
fun DrawScope.videoGlyph(on: Boolean, color: Color) {
    val w = size.width; val h = size.height; val stroke = Stroke(1.6.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
    drawRoundRect(color, Offset(w * 0.12f, h * 0.3f), Size(w * 0.52f, h * 0.4f), androidx.compose.ui.geometry.CornerRadius(3.dp.toPx()), style = stroke)
    drawPath(Path().apply { moveTo(w * 0.66f, h * 0.44f); lineTo(w * 0.88f, h * 0.32f); lineTo(w * 0.88f, h * 0.68f); lineTo(w * 0.66f, h * 0.56f) }, color, style = stroke)
    if (!on) drawLine(color, Offset(w * 0.12f, h * 0.15f), Offset(w * 0.88f, h * 0.85f), 1.6.dp.toPx(), StrokeCap.Round)
}

fun DrawScope.lookAgainGlyph(color: Color) {
    val stroke = Stroke(1.6.dp.toPx(), cap = StrokeCap.Round)
    val r = size.minDimension * 0.32f; val c = center
    drawArc(color, 40f, 290f, false, Offset(c.x - r, c.y - r), Size(r * 2, r * 2), style = stroke)
    val end = 40f * PI.toFloat() / 180f
    val tip = Offset(c.x + r * cos(end), c.y + r * sin(end))
    drawLine(color, tip, Offset(tip.x + 5.dp.toPx(), tip.y - 1.dp.toPx()), 1.6.dp.toPx(), StrokeCap.Round)
    drawLine(color, tip, Offset(tip.x + 1.dp.toPx(), tip.y + 5.dp.toPx()), 1.6.dp.toPx(), StrokeCap.Round)
}

fun DrawScope.gearGlyph(color: Color) {
    val c = center; val inner = size.minDimension * 0.18f; val outer = size.minDimension * 0.3f
    drawCircle(color, inner, c, style = Stroke(1.6.dp.toPx()))
    for (i in 0 until 8) {
        val a = i * PI.toFloat() / 4
        drawLine(color, Offset(c.x + outer * cos(a), c.y + outer * sin(a)), Offset(c.x + (outer + 3.dp.toPx()) * cos(a), c.y + (outer + 3.dp.toPx()) * sin(a)),
            2.4.dp.toPx(), StrokeCap.Round)
    }
    drawCircle(color, outer, c, style = Stroke(1.4.dp.toPx()))
}

fun DrawScope.chevronGlyph(pointsLeft: Boolean, color: Color) {
    val w = size.width; val h = size.height; val dx = w * 0.18f; val dy = h * 0.08f
    val x0 = if (pointsLeft) w / 2 + dx / 2 else w / 2 - dx / 2; val x1 = if (pointsLeft) w / 2 - dx / 2 else w / 2 + dx / 2
    drawPath(Path().apply { moveTo(x0, h / 2 - dy); lineTo(x1, h / 2); lineTo(x0, h / 2 + dy) }, color,
        style = Stroke(1.8.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
}
