package com.yunha.remy

import android.content.Context
import android.os.VibrationEffect
import android.os.Vibrator
import android.speech.tts.TextToSpeech
import android.util.Log
import com.yunha.remy.core.HazardZone
import com.yunha.remy.ui.AgentActivity
import com.yunha.remy.ui.RemyState
import java.util.Locale

/** What a reflex does once per entry: pill to alert, a haptic composition, one spoken line, a drawer row. */
class ReflexAlarm(private val context: Context, private val state: RemyState) {
    private var tts: TextToSpeech? = null
    private var ttsReady = false

    /** On-device text to speech; nothing is sent anywhere. */
    fun prepare() {
        tts = TextToSpeech(context) { status -> ttsReady = status == TextToSpeech.SUCCESS; tts?.language = Locale.US }
    }

    fun fire(zone: HazardZone, latency: Double) {
        state.reflexMs = latency; state.lastReflexMs = latency
        state.line = "Hot: ${zone.label}. Hands back."
        state.activity.log(AgentActivity.Kind.REFLEX, "Hand reached the hot ${zone.label}", "alarm from the fast loop, no model call", latency)
        Log.i("Remy", String.format("REMY_REFLEX hot %s %.0f ms after the frame", zone.label, latency))
        context.getSystemService(Vibrator::class.java)?.let { vibrator ->
            val primitives = intArrayOf(VibrationEffect.Composition.PRIMITIVE_THUD, VibrationEffect.Composition.PRIMITIVE_CLICK)
            if (vibrator.areAllPrimitivesSupported(*primitives)) {
                vibrator.vibrate(VibrationEffect.startComposition()
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_THUD, 1f)
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, 1f, 80)
                    .addPrimitive(VibrationEffect.Composition.PRIMITIVE_THUD, 1f, 80).compose())
            } else vibrator.vibrate(VibrationEffect.createOneShot(300, VibrationEffect.DEFAULT_AMPLITUDE))
        }
        if (state.spokenResponses && ttsReady) tts?.speak("Careful, the ${zone.label} is hot. Hands back.", TextToSpeech.QUEUE_FLUSH, null, "reflex")
    }

    /** Leaving the zone ends the alert and cuts the spoken line short. */
    fun clear() { state.reflexMs = null; tts?.stop() }

    fun shutdown() { tts?.shutdown() }
}
