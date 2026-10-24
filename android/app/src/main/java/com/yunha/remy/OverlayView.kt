package com.yunha.remy

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.View
import androidx.core.content.res.ResourcesCompat
import com.yunha.remy.core.HazardZone
import com.yunha.remy.core.Point2

/**
 * Text-led overlay in the iPhone palette: hands in accent light, the hot zone dashed in warning orange with a
 * "Hot surface" tag, a floating pill with Remy's line and the Gemma time, replaced by "Reflex NN ms" during an alarm,
 * and one evidence line at the bottom. Coordinates are normalized to the analysed camera image.
 */
class OverlayView(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    var imageAspect = 4f / 3f
    var hands: List<List<Point2>> = emptyList()
    var zones: List<HazardZone> = emptyList()
    var line = "Starting the camera…"
    var gemmaSeconds: Double? = null
    var reflexMs: Double? = null
    var evidence = ""

    private val background = Color.parseColor("#121317")
    private val accentLight = Color.parseColor("#ACB7FF")
    private val warning = Color.parseColor("#FFA552")
    private val text = Color.parseColor("#F8F9FC")
    private val secondary = Color.parseColor("#B2BBC5")
    private val regular: Typeface = ResourcesCompat.getFont(context, R.font.google_sans_flex_regular) ?: Typeface.DEFAULT
    private val medium: Typeface = ResourcesCompat.getFont(context, R.font.google_sans_flex_medium) ?: Typeface.DEFAULT_BOLD
    private val density = resources.displayMetrics.density
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val label = Paint(Paint.ANTI_ALIAS_FLAG)

    /** The fitted rectangle of the analysed image inside this view (PreviewView FIT_CENTER). */
    private fun imageRect(): RectF {
        val viewAspect = width.toFloat() / height
        return if (viewAspect > imageAspect) {
            val w = height * imageAspect; RectF((width - w) / 2, 0f, (width + w) / 2, height.toFloat())
        } else {
            val h = width / imageAspect; RectF(0f, (height - h) / 2, width.toFloat(), (height + h) / 2)
        }
    }

    override fun onDraw(canvas: Canvas) {
        val rect = imageRect()
        fun px(p: Point2) = Pair(rect.left + p.x.toFloat() * rect.width(), rect.top + p.y.toFloat() * rect.height())
        val alerting = reflexMs != null

        for (zone in zones) {
            val (l, t) = px(Point2(zone.x, zone.y)); val (r, b) = px(Point2(zone.x + zone.width, zone.y + zone.height))
            val box = RectF(l, t, r, b)
            if (alerting) { fill.color = warning; fill.alpha = 56; canvas.drawRoundRect(box, 10 * density, 10 * density, fill) }
            stroke.color = warning; stroke.strokeWidth = (if (alerting) 4f else 2.5f) * density
            stroke.pathEffect = DashPathEffect(floatArrayOf(8 * density, 5 * density), 0f)
            canvas.drawRoundRect(box, 10 * density, 10 * density, stroke)
            stroke.pathEffect = null
            tag(canvas, "Hot surface", box.left, box.top, warning, background)
        }

        fill.color = accentLight; fill.alpha = 255
        for (hand in hands) for (p in hand) if (p.isValid) {
            val (x, y) = px(p); canvas.drawCircle(x, y, 3.5f * density, fill)
        }

        pill(canvas, alerting)

        if (evidence.isNotEmpty()) {
            label.typeface = regular; label.textSize = 12 * density; label.color = secondary
            canvas.drawText(evidence, 16 * density, height - 14 * density, label)
        }
    }

    private fun tag(canvas: Canvas, title: String, x: Float, top: Float, color: Int, textColor: Int) {
        label.typeface = medium; label.textSize = 13 * density
        val w = label.measureText(title) + 14 * density; val h = 13 * density + 10 * density
        val y = maxOf(0f, top - h - 8 * density)
        fill.color = color; fill.alpha = 255
        canvas.drawRoundRect(RectF(x, y, x + w, y + h), h / 2, h / 2, fill)
        label.color = textColor
        canvas.drawText(title, x + 7 * density, y + h - 7 * density, label)
    }

    private fun pill(canvas: Canvas, alerting: Boolean) {
        val right = when {
            reflexMs != null -> String.format("Reflex %.0f ms", reflexMs)
            gemmaSeconds != null -> String.format("%.1f s", gemmaSeconds)
            else -> ""
        }
        label.typeface = regular; label.textSize = 17 * density
        val lineWidth = label.measureText(line)
        label.typeface = medium; label.textSize = 12 * density
        val rightWidth = if (right.isEmpty()) 0f else label.measureText(right) + 14 * density
        val w = minOf(width - 32 * density, lineWidth + rightWidth + 44 * density); val h = 46 * density
        val box = RectF((width - w) / 2, 12 * density, (width + w) / 2, 12 * density + h)
        fill.color = Color.parseColor("#18191D"); fill.alpha = 230
        canvas.drawRoundRect(box, h / 2, h / 2, fill)
        if (alerting) {
            stroke.color = warning; stroke.strokeWidth = 1.5f * density
            canvas.drawRoundRect(box, h / 2, h / 2, stroke)
        }
        label.typeface = regular; label.textSize = 17 * density; label.color = text
        canvas.drawText(line, box.left + 22 * density, box.centerY() + 6 * density, label)
        if (right.isNotEmpty()) {
            label.typeface = medium; label.textSize = 12 * density
            label.color = if (alerting) warning else secondary
            canvas.drawText(right, box.right - 22 * density - label.measureText(right), box.centerY() + 4 * density, label)
        }
    }
}
