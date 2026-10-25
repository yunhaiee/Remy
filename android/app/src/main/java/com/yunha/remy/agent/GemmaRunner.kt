package com.yunha.remy.agent

import android.os.SystemClock
import android.util.Log
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ThinkingConfig
import com.google.ai.edge.litertlm.ToolProvider
import com.yunha.remy.TensorLmLoader
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * One Gemma engine, one request at a time (port of the iPhone GemmaRunner actor). Every call opens a fresh
 * Conversation, sends one message, reads LiteRT-LM's benchmark numbers and closes it, so nothing leaks between
 * calls and the engine never holds two sessions. Sampler settings per call kind are the iPhone's:
 * one-shot text/vision/audio decode greedily (topK 1, topP 0.9, temperature 0.1, seed 7); the chef's tool turns
 * ([converse]) are slightly random (topK 40, topP 0.95, temperature 0.3, seed 7). Thinking is off everywhere.
 *
 * Do not call the runner from inside another runner call (for example from a tool executor while a turn is in
 * flight): the Mutex is not reentrant. ChefAgent releases it before running tools.
 */
class GemmaRunner(val lm: TensorLmLoader.LoadedLm) {
    data class Result(
        val text: String,
        val ms: Long,
        val prefillTokens: Int? = null,
        val decodeTokens: Int? = null,
        val prefillTps: Double? = null,
        val decodeTps: Double? = null,
        /** Time to first token, seconds. */
        val ttft: Double? = null,
    ) {
        /** "prefill 772 tok @ 2878 tok/s · decode 12 tok @ 21.3 tok/s · first token 0.31 s", as on iPhone's Evidence. */
        val speed: String?
            get() = if (prefillTps == null) null else String.format(
                "prefill %d tok @ %.0f tok/s · decode %d tok @ %.1f tok/s · first token %.2f s",
                prefillTokens ?: 0, prefillTps, decodeTokens ?: 0, decodeTps ?: 0.0, ttft ?: 0.0,
            )
    }

    /** A tool turn: the model's full reply (text and/or tool calls) plus its timing. */
    data class Turn(val reply: Message, val result: Result)

    private val mutex = Mutex()

    /** Run other work on the same engine (the hazard scan) without overlapping a request. */
    suspend fun <T> exclusive(block: suspend () -> T): T = mutex.withLock { block() }

    /** True while a request is running. */
    val isBusy: Boolean get() = mutex.isLocked

    /** LiteRT-LM's measured speed for the last call, for an Evidence/drawer line. */
    @Volatile var lastSpeed: String? = null
        private set

    /** Free text. temperature <= 0.1 decodes greedily (iPhone generate); higher uses the chat sampler. */
    suspend fun text(system: String?, prompt: String, maxTokens: Int, temperature: Double = 0.1): Result =
        generate(system, maxTokens, sampler(temperature), Contents.of(Content.Text(prompt)))

    /** One photo. Gemma 4's documented order: images before the text. */
    suspend fun vision(system: String?, prompt: String, jpeg: ByteArray, maxTokens: Int): Result =
        generate(system, maxTokens, GREEDY, Contents.of(Content.ImageBytes(jpeg), Content.Text(prompt)))

    /**
     * The cook speaking: a 16 kHz mono WAV file (what the iPhone sends as .audioData). Raw 16-bit little-endian
     * PCM is wrapped in a WAV header first. Gemma 4's documented order: text before audio.
     */
    suspend fun audio(system: String?, prompt: String, pcm16kMono: ByteArray, maxTokens: Int = 96): Result {
        val wav = if (isWav(pcm16kMono)) pcm16kMono else wavFromPcm16(pcm16kMono)
        return generate(system, maxTokens, GREEDY, Contents.of(Content.Text(prompt), Content.AudioBytes(wav)))
    }

    /**
     * A conversational turn with tools (Gemma 4 function calling) and automatic tool calling off: the model may
     * answer, call tools, or both; the caller carries out the calls. [history] becomes the conversation's
     * initial messages (user/model/tool), [prompt] is the new message.
     */
    @OptIn(ExperimentalApi::class)
    suspend fun converse(
        system: String,
        history: List<Message>,
        tools: List<ToolProvider>,
        prompt: Message,
        maxTokens: Int,
    ): Turn = mutex.withLock {
        withContext(Dispatchers.IO) {
            val config = ConversationConfig(
                systemInstruction = Contents.of(system),
                initialMessages = history,
                tools = tools,
                samplerConfig = CHAT,
                automaticToolCalling = false,
                maxOutputToken = maxTokens,
                thinkingConfig = NO_THINKING,
            )
            val started = SystemClock.elapsedRealtime()
            lm.engine.createConversation(config).use { conversation ->
                val reply = conversation.sendMessage(prompt)
                Turn(reply, measure(conversation, textOf(reply), started))
            }
        }
    }

    @OptIn(ExperimentalApi::class)
    private suspend fun generate(system: String?, maxTokens: Int, sampler: SamplerConfig, contents: Contents): Result =
        mutex.withLock {
            withContext(Dispatchers.IO) {
                val config = ConversationConfig(
                    systemInstruction = system?.takeIf { it.isNotBlank() }?.let { Contents.of(it) },
                    samplerConfig = sampler,
                    automaticToolCalling = false,
                    maxOutputToken = maxTokens,
                    thinkingConfig = NO_THINKING,
                )
                val started = SystemClock.elapsedRealtime()
                lm.engine.createConversation(config).use { conversation ->
                    val reply = conversation.sendMessage(contents)
                    measure(conversation, textOf(reply), started)
                }
            }
        }

    @OptIn(ExperimentalApi::class)
    private fun measure(conversation: Conversation, text: String, started: Long): Result {
        val ms = SystemClock.elapsedRealtime() - started
        val info = runCatching { conversation.getBenchmarkInfo() }.getOrNull()
        val result = Result(
            text = text, ms = ms,
            prefillTokens = info?.lastPrefillTokenCount, decodeTokens = info?.lastDecodeTokenCount,
            prefillTps = info?.lastPrefillTokensPerSecond, decodeTps = info?.lastDecodeTokensPerSecond,
            ttft = info?.timeToFirstTokenInSecond,
        )
        lastSpeed = result.speed
        Log.i(TAG, "REMY_GEMMA ${ms}ms ${result.speed ?: "no benchmark"}")
        return result
    }

    companion object {
        private const val TAG = "REMY_GEMMA"
        private val GREEDY = SamplerConfig(1, 0.9, 0.1, 7)
        private val CHAT = SamplerConfig(40, 0.95, 0.3, 7)
        private val NO_THINKING = ThinkingConfig(false, 0)

        private fun sampler(temperature: Double): SamplerConfig =
            if (temperature <= 0.1) SamplerConfig(1, 0.9, temperature, 7) else SamplerConfig(40, 0.95, temperature, 7)

        /** The reply's text parts joined (the iPhone's Message.toString). */
        fun textOf(message: Message): String =
            message.contents.contents.filterIsInstance<Content.Text>().joinToString("") { it.text }

        private fun isWav(bytes: ByteArray): Boolean =
            bytes.size >= 12 && bytes[0] == 'R'.code.toByte() && bytes[1] == 'I'.code.toByte() &&
                bytes[2] == 'F'.code.toByte() && bytes[3] == 'F'.code.toByte() &&
                bytes[8] == 'W'.code.toByte() && bytes[9] == 'A'.code.toByte()

        /** A canonical 44-byte WAV header around 16-bit little-endian mono PCM. */
        fun wavFromPcm16(pcm: ByteArray, sampleRate: Int = 16_000): ByteArray {
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray())
            header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
                .putInt(sampleRate).putInt(sampleRate * 2).putShort(2).putShort(16)
            header.put("data".toByteArray()).putInt(pcm.size)
            return header.array() + pcm
        }
    }
}
