package com.yunha.remy.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunha.remy.R
import com.yunha.remy.RemyModel
import com.yunha.remy.core.DishAssessment
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.coroutines.launch

/**
 * FinishedDishSummaryView: a full-screen cover after "ready" on the last step. The frozen photo, Remy's rating from
 * Gemma's on-device review, and Retry / Retake / Screenshot / Next dish. Landscape layout: photo 30%, feedback beside it.
 */
@Composable
fun FinishedDishSummary(state: RemyState, model: RemyModel, actions: RemyActions) {
    val layer = rememberGraphicsLayer()
    val scope = rememberCoroutineScope()
    Box(Modifier.fillMaxSize().background(AppTheme.background).clickable(remember { MutableInteractionSource() }, null) {}) {
        Column(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            // The review content is recorded into a layer so Screenshot saves exactly this summary.
            Box(Modifier.weight(1f).fillMaxWidth().drawWithContent {
                layer.record { this@drawWithContent.drawContent() }
                drawLayer(layer)
            }.background(AppTheme.background)) {
                DishReviewContent(state.finishedDishPhoto, state.finishedDishName, state.dishAssessment)
            }
            if (state.dishReviewLoading) AppText("Examining the photo…", appText(13.sp, FontWeight.Medium))
            state.dishReviewError?.let { AppText(it, appText(12.sp, color = AppTheme.secondary)) }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (state.dishReviewError != null) BorderedButton("Retry review") { model.retryDishAssessment() }
                BorderedButton("Retake photo", enabled = !state.dishReviewLoading) { model.retakeFinishedDish() }
                Spacer(Modifier.weight(1f))
                BorderedButton("Screenshot", enabled = !state.dishReviewLoading && state.dishAssessment?.dishVisible == true) {
                    scope.launch {
                        val bitmap = runCatching { layer.toImageBitmap().asAndroidBitmap() }.getOrNull()
                        if (bitmap == null) state.dishSummaryMessage = "Couldn't create the summary image. Please try again."
                        else actions.saveDishSummary(bitmap.copy(android.graphics.Bitmap.Config.ARGB_8888, false))
                    }
                }
                Box(Modifier.heightIn(min = 36.dp).background(AppTheme.accent, RoundedCornerShape(10.dp))
                    .clickable(remember { MutableInteractionSource() }, null) { model.nextDish() }.padding(horizontal = 14.dp, vertical = 8.dp),
                    contentAlignment = Alignment.Center) { AppText("Next dish", appText(14.sp, FontWeight.Bold, Color.White)) }
            }
        }
        state.dishSummaryMessage?.let { message ->
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
                Column(Modifier.width(300.dp).background(AppTheme.surfaceHigh, RoundedCornerShape(14.dp)).padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    AppText("Dish summary", appText(17.sp, FontWeight.Medium))
                    AppText(message, appText(13.sp, color = AppTheme.secondary))
                    AppText("OK", appText(17.sp, FontWeight.Medium, AppTheme.accent),
                        Modifier.clickable(remember { MutableInteractionSource() }, null) { state.dishSummaryMessage = null }.padding(8.dp))
                }
            }
        }
    }
}

@Composable
private fun BorderedButton(title: String, enabled: Boolean = true, onTap: () -> Unit) {
    Box(Modifier.heightIn(min = 36.dp).alpha(if (enabled) 1f else 0.45f).background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(10.dp))
        .clickable(remember { MutableInteractionSource() }, null, enabled = enabled, onClick = onTap).padding(horizontal = 14.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center) { AppText(title, appText(14.sp, FontWeight.Bold, AppTheme.accent)) }
}

/** DishReviewContent(landscape: true). */
@Composable
private fun DishReviewContent(photo: android.graphics.Bitmap?, name: String, review: DishAssessment?) {
    Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.fillMaxWidth(0.30f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            AppText(name, appText(20.sp, FontWeight.Bold), maxLines = 2)
            if (photo != null) Image(photo.asImageBitmap(), name, Modifier.fillMaxWidth().weight(1f).clip(RoundedCornerShape(16.dp))
                .background(Color.White.copy(alpha = 0.035f)), contentScale = ContentScale.Fit)
        }
        Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Image(painterResource(R.drawable.remy_portrait), "Remy", Modifier.size(56.dp).clip(RoundedCornerShape(14.dp)), contentScale = ContentScale.Crop)
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    AppText("Remy's Rating", appText(19.sp, FontWeight.Bold))
                    if (review != null && review.dishVisible) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            for (index in 0 until 5) {
                                val fill = if (review.stars >= index + 0.75) 1f else if (review.stars >= index + 0.25) 0.5f else 0f
                                Star(fill)
                            }
                            AppText(String.format("%.1f / 5", review.stars), appText(17.sp, FontWeight.Bold, AppTheme.accentLight), Modifier.padding(start = 6.dp))
                        }
                    } else AppText(if (review == null) "Reviewing your dish" else "Dish not clearly visible", appText(13.sp, FontWeight.Medium, AppTheme.secondary))
                }
            }
            if (review != null) {
                AppText(review.summary, appText(13.sp, FontWeight.Medium))
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Section("Ingredient balance", review.ingredientBalance, Modifier.weight(1f))
                    Section("Cut consistency", review.cutConsistency, Modifier.weight(1f))
                }
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Section("Portion & presentation", review.portionPresentation, Modifier.weight(1f))
                    Section("Improve next time", review.improvements, Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun Section(title: String, text: String, modifier: Modifier) {
    Column(modifier.fillMaxHeight().background(Color.White.copy(alpha = 0.055f), RoundedCornerShape(12.dp)).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        AppText(title, appText(13.sp, FontWeight.Bold, AppTheme.accentLight))
        AppText(text, appText(13.sp))
    }
}

/** star.fill / star.leadinghalf.filled / star, in accent light, 17 pt. */
@Composable
private fun Star(fill: Float) {
    Canvas(Modifier.size(17.dp)) {
        val c = Offset(size.width / 2, size.height / 2); val outer = size.minDimension / 2; val inner = outer * 0.45f
        val path = Path().apply {
            for (i in 0 until 10) {
                val r = if (i % 2 == 0) outer else inner
                val a = Math.toRadians(-90.0 + i * 36.0)
                val p = Offset(c.x + r * cos(a).toFloat(), c.y + r * sin(a).toFloat())
                if (i == 0) moveTo(p.x, p.y) else lineTo(p.x, p.y)
            }
            close()
        }
        if (fill > 0f) clipRect(right = size.width * fill) { drawPath(path, AppTheme.accentLight) }
        drawPath(path, AppTheme.accentLight, style = Stroke(1.3.dp.toPx()))
    }
}
