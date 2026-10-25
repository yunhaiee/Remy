package com.yunha.remy.core

/**
 * Who a transcribed utterance is for, and the few bare commands that skip the model.
 * Everything said to the chef goes to Gemma (ChefAgent), which understands it in context and acts through tools.
 * Keyword rules inside sentences made the chef obtuse ("I still see vinegar in the ingredients list, can you change
 * that?" ran an ingredient check), so the only shortcuts left are whole utterances like "next" or "go back", where
 * skipping a model call saves time and cannot be misread.
 * For the chef = starts with "Remy", or a reply within 10 s of the chef speaking.
 */
data class VoiceCommand(val intent: Intent, val value: String) {
    enum class Intent { START_COOKING, NEXT, PREVIOUS, REPEAT, WAKE, AGENT, IGNORE }

    companion object {
        /** `secondsSinceChefSpoke`: a reply soon after the chef talked counts as addressed without "Remy". */
        fun parse(transcript: String, phase: CookingSession.Phase, secondsSinceChefSpoke: Double): VoiceCommand {
            val text = transcript.lowercase()
                .replace(Regex("[^a-z0-9' ]"), " ")
                .split(" ").filter { it.isNotEmpty() }.joinToString(" ")
            if (!(startsWithWakeWord(text) || secondsSinceChefSpoke <= 10) || text.isEmpty()) return VoiceCommand(Intent.IGNORE, "")
            val body = text.replace(Regex("^(hey )?(remy)\\b"), "").trim { it == ' ' || it == '\t' }
            // "Remy…" and a pause: the end-of-speech cut it off. The chef answers "Yes?" so the rest counts as addressed.
            if (body.isEmpty()) return VoiceCommand(Intent.WAKE, "")
            val command = body.replace(Regex("\\b(please|now|then|okay|ok)\\b"), "")
                .split(" ").filter { it.isNotEmpty() }.joinToString(" ")
            val cooking = phase == CookingSession.Phase.COOKING
            val ingredients = phase == CookingSession.Phase.INGREDIENTS
            return when {
                cooking && command in listOf("next", "next step", "done", "i'm done", "what's next", "whats next") ->
                    VoiceCommand(Intent.NEXT, "")
                cooking && command in listOf("go back", "back", "previous step") -> VoiceCommand(Intent.PREVIOUS, "")
                cooking && command in listOf("repeat", "repeat that", "say that again", "again") -> VoiceCommand(Intent.REPEAT, "")
                ingredients && command in listOf("start cooking", "let's cook", "let's start", "let's start cooking",
                    "next", "next step", "let's go", "let's go to the next step") -> VoiceCommand(Intent.START_COOKING, "")
                else -> VoiceCommand(Intent.AGENT, body)
            }
        }

        /** "Remy, …", "Hey Remy …": the cook is talking to the chef. */
        fun startsWithWakeWord(transcript: String): Boolean = ChefWakeGate.hasPrefix(transcript)
    }
}
