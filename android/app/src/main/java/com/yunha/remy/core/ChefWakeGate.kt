package com.yunha.remy.core

/**
 * A wake-only utterance authorizes one continuation for eight seconds. Cooking mode may explicitly open
 * conversation. Tentative transcripts may prefetch but cannot authorize actions.
 */
class ChefWakeGate {
    private var continuationUntil = Double.NEGATIVE_INFINITY

    /** The addressed words (without the wake word), or null when the utterance is not for Remy. */
    fun accept(text: String, now: Double, conversationOpen: Boolean = false): String? {
        val value = text.trim()
        if (hasPrefix(value)) {
            val body = value.replace(STRIP, "")
            continuationUntil = if (body.isEmpty()) now + 8 else Double.NEGATIVE_INFINITY
            return body
        }
        if (value.isEmpty() || !(conversationOpen || now <= continuationUntil)) return null
        continuationUntil = Double.NEGATIVE_INFINITY
        return value
    }

    companion object {
        /** "Remy" as Android's on-device recognizer writes it; "ready" is never a wake word. */
        const val WAKE = "(?:remy|remi|rémy|rémi|remmy)"
        private val PREFIX = Regex("^\\W*(?:(?:hey|hi)[ ,]+)?$WAKE(?![a-z])")
        private val STRIP = Regex("(?i)^\\W*(?:(?:hey|hi)[ ,]+)?$WAKE(?![a-z])[\\s,.!?]*")

        fun hasPrefix(text: String): Boolean = PREFIX.containsMatchIn(text.lowercase())
    }
}

/** Only whole affirmative/negative replies are shortcuts. Questions and qualifications go to Gemma. */
object CookingReadinessReply {
    enum class Decision { READY, WAIT }

    private val READY = setOf("yes", "yeah", "yep", "yup", "sure", "okay", "ok", "ready", "i'm ready", "i am ready", "yes i'm ready",
        "yes i am ready", "let's go", "lets go", "let's cook", "let's do it", "sounds good", "absolutely", "go ahead", "yes please",
        "yes let's cook", "yeah let's do it")
    private val WAIT = setOf("no", "nope", "not yet", "wait", "hold on", "one moment", "give me a second", "i'm not ready",
        "i am not ready", "not right now")

    fun parse(text: String): Decision? {
        val body = text.lowercase().replace("’", "'")
            .replace(Regex("[^a-z0-9' ]"), " ")
            .split(" ").filter { it.isNotEmpty() }.joinToString(" ")
        if (body in READY) return Decision.READY
        if (body in WAIT) return Decision.WAIT
        return null
    }
}
