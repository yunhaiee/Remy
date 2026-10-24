package com.yunha.remy.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunha.remy.R

/** The iPhone app's AppTheme, token for token (GlassControlDock.swift). No Material: nothing shows through. */
object AppTheme {
    val background = Color(0xFF121317)
    val text = Color(0xFFF8F9FC)
    val secondary = Color(0xFFB2BBC5)
    val surface = Color(0xFF18191D)
    val surfaceHigh = Color(0xFF212226)
    val outline = Color(0xFFE6EAF0).copy(alpha = 0.12f)
    val outlineStrong = Color(0xFFE6EAF0).copy(alpha = 0.24f)
    val accent = Color(0xFF2E96FF)
    val accentLight = Color(0xFFACB7FF)
    val warning = Color(0xFFFFA552)
    /** Hot-surface tag, border, pill and orb alert: our warning orange, as on iPhone. */
    val safety = warning
    /** Text on a safety-coloured tag: dark on orange for contrast. */
    val onSafety = background
    val gradient = Brush.linearGradient(0f to Color(0xFF3B6BFF), 0.6f to Color(0xFF2E96FF), 1f to Color(0xFFACB7FF))
}

/** Google Sans Flex, bundled; the platform falls back to sans-serif for missing glyphs. */
val GoogleSansFlex = FontFamily(
    Font(R.font.google_sans_flex_regular, FontWeight.Normal),
    Font(R.font.google_sans_flex_medium, FontWeight.Medium),
    Font(R.font.google_sans_flex_bold, FontWeight.Bold),
)

fun appText(size: TextUnit, weight: FontWeight = FontWeight.Normal, color: Color = AppTheme.text, tracking: TextUnit = TextUnit.Unspecified) =
    TextStyle(fontFamily = GoogleSansFlex, fontSize = size, fontWeight = weight, color = color, letterSpacing = tracking)

/** Plain text in the app font; no Material Text, so no theme defaults leak in. */
@Composable
fun AppText(text: String, style: TextStyle, modifier: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE) {
    BasicText(text, modifier, style = style, maxLines = maxLines, overflow = TextOverflow.Ellipsis)
}

/** Eyebrow: 11 sp Medium, uppercase, 1.2 sp tracking, accent light. */
@Composable
fun Eyebrow(text: String, color: Color = AppTheme.accentLight, modifier: Modifier = Modifier) {
    AppText(text.uppercase(), appText(11.sp, FontWeight.Medium, color, 1.2.sp), modifier, maxLines = 1)
}

/** "Glass" without blur: surface at 72% with a 1 dp outline. Text-led, no elevation shadows. */
fun Modifier.glass(shape: Shape, stroke: Color = AppTheme.outline): Modifier =
    this.background(AppTheme.surface.copy(alpha = 0.72f), shape).border(1.dp, stroke, shape)
