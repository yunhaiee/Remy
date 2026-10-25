package com.yunha.remy

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

/** Remy's spoken lines (AudioCoach.swift): on-device text to speech, the newest priority line replaces the last. */
class Speaker(context: Context, private val onSpeaking: (Boolean) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private var ready = false
    private var next = 0
    var enabled = true
    private val tts: TextToSpeech = TextToSpeech(context) { status ->
        ready = status == TextToSpeech.SUCCESS
        if (ready) tts.language = Locale.US
    }

    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) { main.post { onSpeaking(true) } }
            override fun onDone(utteranceId: String?) { main.post { if (!tts.isSpeaking) onSpeaking(false) } }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) { main.post { onSpeaking(false) } }
            override fun onStop(utteranceId: String?, interrupted: Boolean) { main.post { onSpeaking(false) } }
        })
    }

    fun say(line: String, priority: Boolean = true) {
        if (!enabled || !ready || line.isBlank()) return
        tts.speak(line, if (priority) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD, null, "remy-${next++}")
    }

    fun stop() { tts.stop(); onSpeaking(false) }
    fun shutdown() = tts.shutdown()
}
