package com.yunha.remy

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Hands-free microphone (HandsFreeListener.swift on iPhone). Two ways in:
 *  - Words: Android's on-device SpeechRecognizer (en-US, prefer offline), restarted after every result, so the wake
 *    gate sees each utterance as text. Nothing leaves the phone.
 *  - Audio: a 16 kHz mono recorder with the iPhone's energy endpointing (adaptive noise floor, 0.45 s end silence,
 *    10 s cap, 0.3 s pre-roll). Used when Remy has just asked a question, so Gemma hears the answer itself, and as
 *    the whole path when on-device recognition is unavailable (Gemma transcribes each utterance).
 * While Remy speaks, the microphone is ignored so it never answers itself.
 */
class VoiceListener(private val context: Context, private val events: Events) {
    interface Events {
        fun onWords(text: String, ms: Double)
        fun onAudio(wav: ByteArray, seconds: Double)
        fun onListenerState(on: Boolean, hearing: Boolean)
        fun onListenerNote(note: String)
    }

    enum class Mode { WORDS, AUDIO }

    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    @Volatile var isOn = false; private set
    @Volatile private var mutedNow = false
    @Volatile private var mode = Mode.WORDS
    private var recordThread: Thread? = null
    private var heardAt = 0L
    val onDevice: Boolean by lazy { SpeechRecognizer.isOnDeviceRecognitionAvailable(context) }

    /** What the Evidence sheet says about the speech path. */
    val path: String get() = if (onDevice) "Android on-device SpeechRecognizer, en-US; Gemma hears answers to its questions"
        else "On-device recognition unavailable: Gemma transcribes 16 kHz audio"

    fun start() {
        if (isOn) return
        isOn = true
        mode = if (onDevice) Mode.WORDS else Mode.AUDIO
        Log.i(TAG, "REMY_MIC start ${mode.name.lowercase()} (on-device recognizer: $onDevice)")
        events.onListenerNote(path)
        resume()
    }

    fun stop() {
        isOn = false
        main.removeCallbacksAndMessages(null)
        recognizer?.cancel(); recognizer?.destroy(); recognizer = null
        recordThread?.interrupt(); recordThread = null
        events.onListenerState(false, false)
    }

    /** The next utterance goes to Gemma as audio (an ask step), then the listener returns to words. */
    fun captureNextAnswerAsAudio(on: Boolean) {
        val wanted = if (on || !onDevice) Mode.AUDIO else Mode.WORDS
        if (wanted == mode) return
        mode = wanted
        if (!isOn) return
        recognizer?.cancel(); recordThread?.interrupt(); recordThread = null
        main.postDelayed({ resume() }, 150)
    }

    /** Remy is speaking (or stopped): mute the microphone, then pick up again shortly after. */
    fun setMuted(value: Boolean) {
        mutedNow = value
        if (!isOn) return
        if (value) { recognizer?.cancel(); events.onListenerState(true, false) }
        else main.postDelayed({ if (!mutedNow) resume() }, 350)
    }

    private fun resume() {
        if (!isOn || mutedNow) return
        events.onListenerState(true, false)
        if (mode == Mode.WORDS) listenForWords() else if (recordThread == null) recordUtterance()
    }

    private fun listenForWords() {
        val r = recognizer ?: SpeechRecognizer.createOnDeviceSpeechRecognizer(context).also { recognizer = it }
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() { heardAt = SystemClock.elapsedRealtime(); events.onListenerState(true, true) }
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() { events.onListenerState(true, false) }
            override fun onError(error: Int) {
                events.onListenerState(isOn, false)
                // No match and speech timeout are the normal "nobody spoke" outcomes; listen again.
                if (error != SpeechRecognizer.ERROR_NO_MATCH && error != SpeechRecognizer.ERROR_SPEECH_TIMEOUT) Log.w(TAG, "REMY_MIC recognizer error $error")
                val wait = when (error) {
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> 5000L
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_CLIENT -> 800L
                    else -> 250L
                }
                if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY || error == SpeechRecognizer.ERROR_CLIENT) { recognizer?.destroy(); recognizer = null }
                main.postDelayed({ if (mode == Mode.WORDS) resume() }, wait)
            }
            override fun onResults(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                val ms = if (heardAt > 0) (SystemClock.elapsedRealtime() - heardAt).toDouble() else 0.0
                events.onListenerState(isOn, false)
                if (text.isNotBlank()) events.onWords(text, ms)
                main.postDelayed({ if (mode == Mode.WORDS) resume() }, 150)
            }
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 700L)
        }
        runCatching { r.startListening(intent) }.onFailure { Log.e(TAG, "REMY_MIC start failed", it); main.postDelayed({ resume() }, 1000) }
    }

    /** One utterance with the iPhone's energy endpointing, delivered as a 16 kHz mono 16-bit WAV. */
    @SuppressLint("MissingPermission")
    private fun recordUtterance() {
        val thread = Thread {
            val rate = 16_000
            val chunk = rate / 20 // 50 ms
            val minBuffer = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val record = runCatching {
                AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, max(minBuffer, chunk * 8))
            }.getOrNull()
            if (record == null || record.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "REMY_MIC recorder unavailable"); record?.release(); recordThread = null; return@Thread
            }
            val onsetRatio = 3.2f; val minimumLevel = 0.012f; val endSilence = 0.45; val maxSeconds = 10.0; val minSeconds = 0.2
            val prerollChunks = 6
            var noiseFloor = 0.005f
            val preroll = ArrayDeque<ShortArray>()
            val utterance = mutableListOf<ShortArray>()
            var speaking = false; var quiet = 0.0; var loud = 0
            val buffer = ShortArray(chunk)
            record.startRecording()
            try {
                while (!Thread.currentThread().isInterrupted && isOn) {
                    val n = record.read(buffer, 0, chunk)
                    if (n <= 0) continue
                    if (mutedNow) { preroll.clear(); utterance.clear(); speaking = false; continue }
                    val piece = buffer.copyOf(n)
                    var sum = 0.0
                    for (s in piece) { val v = s / 32768.0; sum += v * v }
                    val level = sqrt(sum / n).toFloat()
                    val threshold = max(noiseFloor * onsetRatio, minimumLevel)
                    if (!speaking) {
                        preroll.addLast(piece); while (preroll.size > prerollChunks) preroll.removeFirst()
                        if (level > threshold) { loud++ } else { loud = 0; noiseFloor = noiseFloor * 0.95f + level * 0.05f }
                        if (loud >= 2) {
                            speaking = true; quiet = 0.0; utterance.clear(); utterance.addAll(preroll); preroll.clear()
                            main.post { events.onListenerState(true, true) }
                        }
                    } else {
                        utterance.add(piece)
                        quiet = if (level > threshold) 0.0 else quiet + 0.05
                        val seconds = utterance.sumOf { it.size } / rate.toDouble()
                        if (quiet >= endSilence || seconds >= maxSeconds) {
                            speaking = false; loud = 0
                            main.post { events.onListenerState(true, false) }
                            if (seconds - quiet >= minSeconds) {
                                val wav = wav(utterance, rate)
                                utterance.clear()
                                main.post { events.onAudio(wav, seconds) }
                                if (mode == Mode.WORDS) break
                            } else utterance.clear()
                        }
                    }
                }
            } finally {
                runCatching { record.stop() }; record.release()
                if (recordThread === Thread.currentThread()) recordThread = null
                main.post { if (isOn && mode == Mode.WORDS) resume() }
            }
        }
        recordThread = thread
        thread.start()
    }

    companion object {
        private const val TAG = "Remy"

        fun wav(chunks: List<ShortArray>, rate: Int): ByteArray {
            val samples = chunks.sumOf { it.size }
            val out = ByteArrayOutputStream(44 + samples * 2)
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray()).putInt(36 + samples * 2).put("WAVE".toByteArray())
            header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
            header.put("data".toByteArray()).putInt(samples * 2)
            out.write(header.array())
            val body = ByteBuffer.allocate(samples * 2).order(ByteOrder.LITTLE_ENDIAN)
            for (c in chunks) for (s in c) body.putShort(s)
            out.write(body.array())
            return out.toByteArray()
        }
    }
}
