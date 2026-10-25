package com.yunha.remy.agent

import android.os.SystemClock
import android.util.Log
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.OpenApiTool
import com.google.ai.edge.litertlm.ToolProvider
import com.google.ai.edge.litertlm.tool
import org.json.JSONArray
import org.json.JSONObject
import com.google.ai.edge.litertlm.ToolCall as LmToolCall

/** What the parent maps from CookingSession.phase. */
enum class AgentPhase { NEEDS_DISH, INGREDIENTS, COOKING }

/**
 * The finer COOKING cases the iPhone gates tools on (ChefAgent.tools): the dish is complete, the current step
 * asks the cook something, or the current step is a guarded seasoning step not yet recorded (!session.salted).
 * Ignored outside COOKING.
 */
enum class StepGate { NORMAL, COMPLETE, ASK, GUARDED_UNSALTED }

/** One tool call from Gemma, arguments already trimmed (nil/null/none become ""). */
data class ToolCall(val name: String, val args: Map<String, Any?>) {
    fun arg(key: String): String = args[key]?.toString() ?: ""
}

/** One line for the live drawer: a Gemma turn or a tool call, with its time. */
data class AgentEvent(val kind: Kind, val title: String, val detail: String, val ms: Long?, val failed: Boolean = false) {
    enum class Kind { GEMMA, TOOL }
}

data class ToolResult(val call: ToolCall, val result: String, val ms: Long, val rejected: Boolean)

data class AgentReply(
    /** The line to show (the follow-up's words when there was one, else the first reply). May be empty. */
    val speech: String,
    /** Whether [speech] still needs saying: false when it was already passed to onEarlySpeech, or when an
     *  action announces itself (next step, "Got it, mild") and would cut it off, as on iPhone. */
    val shouldSpeak: Boolean,
    /** Calls from the first turn (after nudges), then the follow-up's one level of calls. */
    val calls: List<ToolCall>,
    val followUpCalls: List<ToolCall>,
    val results: List<ToolResult>,
    /** Gemma time only (all turns), and wall time for the whole respond(). */
    val gemmaMs: Long,
    val totalMs: Long,
)

/**
 * Gemma as a conversational chef (port of the iPhone ChefAgent + AppModel.converse): it answers in its own words
 * and acts through tools (Gemma 4 function calling, automatic tool calling off). It sees the recipe state, the
 * last few turns, and only the tools that make sense right now (fewer tools keep a 2B model accurate). The app,
 * not the model, carries out each call; results go back as a tool message and Gemma says what they mean.
 */
class ChefAgent(private val runner: GemmaRunner) {
    data class Turn(val cook: String, val chef: String)

    private val history = ArrayDeque<Turn>()

    fun resetHistory() = history.clear()

    /**
     * One cook utterance end to end. [context] is the session part of the system prompt (see [context] builder).
     * [execute] runs one validated call and returns what Gemma should hear back, or "" for nothing to report
     * (the iPhone's nil). It runs while the runner is free, so it may itself use the GemmaRunner (look, find,
     * plan). Unknown, not-offered or incomplete calls are not executed; an error string goes back to Gemma.
     * [onEarlySpeech] is called with the first reply before tools run when it should be said right away.
     * Throws when the first Gemma turn fails and no tool call can be recovered from the error.
     */
    suspend fun respond(
        utterance: String,
        phase: AgentPhase,
        context: String,
        execute: suspend (ToolCall) -> String,
        log: (AgentEvent) -> Unit,
        gate: StepGate = StepGate.NORMAL,
        onEarlySpeech: ((String) -> Unit)? = null,
    ): AgentReply {
        val began = SystemClock.elapsedRealtime()
        val specs = tools(phase, gate)
        val providers = specs.map { it.provider }
        val names = specs.map { it.name }
        val system = system(context)
        val past = messages()

        // First turn, with the iPhone's two nudges.
        val prompt = Message.user(utterance)
        var gemmaMs = 0L
        var reply: Message
        try {
            val first = converseRecovering(system, past, providers, prompt, 96)
            reply = first.reply; gemmaMs += first.result.ms
            log(AgentEvent(AgentEvent.Kind.GEMMA, "Chef is thinking", describeReply(reply, first.result, specs.size), first.result.ms))
        } catch (e: Exception) {
            log(AgentEvent(AgentEvent.Kind.GEMMA, "Chef is thinking", "failed: ${e.message}", null, failed = true))
            throw e
        }
        val exchange = mutableListOf(prompt, reply)
        val said = GemmaRunner.textOf(reply)
        // A 2B model sometimes describes an action instead of calling the tool. Give that back once.
        if (reply.toolCalls.isEmpty() && promisesAction(said, names)) {
            val nudge = Message.user("You said you would do that but did not call a tool. Call the right tool now.")
            val retry = runCatching { converseRecovering(system, past + exchange, providers, nudge, 64) }.getOrNull()
            if (retry != null) {
                gemmaMs += retry.result.ms
                log(AgentEvent(AgentEvent.Kind.GEMMA, "Nudge: call the tool", describeReply(retry.reply, retry.result, specs.size), retry.result.ms))
                if (retry.reply.toolCalls.isNotEmpty()) { reply = retry.reply; exchange += listOf(nudge, retry.reply) }
            }
        }
        // Nothing said and nothing done would leave the cook in silence: ask once more for a spoken answer.
        if (reply.toolCalls.isEmpty() && spoken(said, names).isEmpty()) {
            val nudge = Message.user("Answer the cook out loud in one or two sentences, or call a tool.")
            val retry = runCatching { converseRecovering(system, past + exchange, providers, nudge, 72) }.getOrNull()
            if (retry != null) {
                gemmaMs += retry.result.ms
                log(AgentEvent(AgentEvent.Kind.GEMMA, "Nudge: answer out loud", describeReply(retry.reply, retry.result, specs.size), retry.result.ms))
                reply = retry.reply; exchange += listOf(nudge, retry.reply)
            }
        }
        val calls = reply.toolCalls.map(::normalize)
        val firstSpeech = spoken(GemmaRunner.textOf(reply), names)
        Log.i(TAG, "REMY_AGENT ${gemmaMs}ms \"$utterance\" -> \"$firstSpeech\" ${calls.joinToString(" ") { "${it.name}${it.args}" }}")

        val announces = calls.any { it.name in ANNOUNCING }
        var spokeEarly = false
        if (firstSpeech.isNotEmpty() && !announces && onEarlySpeech != null) { onEarlySpeech(firstSpeech); spokeEarly = true }

        // The app carries out each call, after Gemma is free again.
        val results = mutableListOf<ToolResult>()
        for (call in calls) results += run(call, names, execute, log)
        val reported = results.filter { it.result.isNotEmpty() }

        var speech = firstSpeech
        var shouldSpeak = firstSpeech.isNotEmpty() && !announces && !spokeEarly
        val followCalls = mutableListOf<ToolCall>()
        // Gemma speaks about the results when it has not said anything yet, or when a result is news (what the
        // camera saw, or a rejected call it should fix); a plain confirmation after it already spoke needs no turn.
        if (reported.isNotEmpty() &&
            (firstSpeech.isEmpty() || reported.any { it.rejected || it.call.name in NEWS })
        ) {
            val toolMessage = Message.tool(Contents.of(reported.map { Content.ToolResponse(it.call.name, it.result) }))
            var follow: GemmaRunner.Turn? = null
            var followSaid = ""
            try {
                follow = converseRecovering(system, past + exchange, providers, toolMessage, 72)
                gemmaMs += follow.result.ms
                followSaid = GemmaRunner.textOf(follow.reply)
                // "All ingredients are here. Let's start cooking." without the call: ask once to act.
                if (follow.reply.toolCalls.isEmpty() && promisesAction(followSaid, names)) {
                    val nudge = Message.user("You said you would do that but did not call a tool. Call the right tool now.")
                    val retry = runCatching {
                        converseRecovering(system, past + exchange + listOf(toolMessage, follow.reply), providers, nudge, 48)
                    }.getOrNull()
                    if (retry != null) {
                        gemmaMs += retry.result.ms
                        if (retry.reply.toolCalls.isNotEmpty()) follow = GemmaRunner.Turn(retry.reply, follow.result)
                    }
                }
                log(AgentEvent(AgentEvent.Kind.GEMMA, "Chef reads the results",
                    describeReply(follow.reply, follow.result, specs.size, spoken(followSaid, names)), follow.result.ms))
            } catch (e: Exception) {
                log(AgentEvent(AgentEvent.Kind.GEMMA, "Chef reads the results", "failed: ${e.message}", null, failed = true))
            }
            followCalls += follow?.reply?.toolCalls.orEmpty().map(::normalize)
            // Never silent after doing something: an empty follow-up still gets a short spoken confirmation.
            val followSpeech = spoken(followSaid, names)
            val line = followSpeech.ifEmpty { if (firstSpeech.isEmpty()) remembered("", calls) else "" }
            if (line.isNotEmpty()) { speech = line; shouldSpeak = true }
            // One level of acting on what it learned (a hot pot it just saw); no further follow-up.
            for (call in followCalls) results += run(call, names, execute, log)
        }

        history.addLast(Turn(utterance, remembered(speech, calls)))
        while (history.size > 6) history.removeFirst()
        return AgentReply(speech, shouldSpeak, calls, followCalls, results, gemmaMs, SystemClock.elapsedRealtime() - began)
    }

    /** Validate against the offered schema, then execute and log with its time. */
    private suspend fun run(call: ToolCall, offered: List<String>, execute: suspend (ToolCall) -> String,
                            log: (AgentEvent) -> Unit): ToolResult {
        val spec = ALL[call.name]
        val error = when {
            spec == null -> "Error: there is no tool named ${call.name}. Use one of: ${offered.joinToString(", ")}."
            call.name !in offered -> "Error: ${call.name} is not available right now. Use one of: ${offered.joinToString(", ")}."
            else -> spec.params.filter { call.arg(it.name).isEmpty() }.map { it.name }.takeIf { it.isNotEmpty() }
                ?.let { "Error: ${call.name} needs ${it.joinToString(" and ")}. Call it again with ${if (it.size == 1) "that argument" else "those arguments"}." }
        }
        val started = SystemClock.elapsedRealtime()
        val result = if (error != null) error else runCatching { execute(call) }.getOrElse { "Error: ${it.message ?: "the tool failed"}." }
        val ms = SystemClock.elapsedRealtime() - started
        log(AgentEvent(AgentEvent.Kind.TOOL, describe(call), result.ifEmpty { "done" }, ms, failed = error != null || result.startsWith("Error:")))
        Log.i(TAG, "REMY_TOOL ${ms}ms ${describe(call)} -> ${result.ifEmpty { "done" }}")
        return ToolResult(call, result, ms, rejected = error != null)
    }

    /**
     * The model chose a tool but wrote its arguments loosely (call:save_preference{value:mild}); LiteRT-LM's parser
     * rejects that. The intended call is in the error text, so recover it instead of losing it.
     */
    private suspend fun converseRecovering(system: String, history: List<Message>, tools: List<ToolProvider>,
                                           prompt: Message, maxTokens: Int): GemmaRunner.Turn =
        try {
            runner.converse(system, history, tools, prompt, maxTokens)
        } catch (e: Exception) {
            val calls = recoveredCalls(e.toString())
            if (calls.isEmpty()) throw e
            Log.w(TAG, "REMY_AGENT recovered ${calls.map { it.name }} from: ${e.message}")
            GemmaRunner.Turn(Message.model(Contents.of(emptyList<Content>()), calls, emptyMap()), GemmaRunner.Result("", 0))
        }

    private fun messages(): List<Message> =
        history.toList().takeLast(4).flatMap { listOf(Message.user(it.cook), Message.model(it.chef)) }

    private fun describeReply(reply: Message, result: GemmaRunner.Result, offered: Int, speech: String? = null): String {
        val said = speech ?: GemmaRunner.textOf(reply).trim()
        val calls = reply.toolCalls.joinToString(", ") { it.name }
        val parts = mutableListOf<String>()
        if (said.isNotEmpty()) parts += "“$said”"
        if (calls.isNotEmpty()) parts += "calls $calls"
        if (parts.isEmpty()) parts += "no reply"
        parts += "$offered tools offered"
        result.speed?.let { parts += it }
        return parts.joinToString(" · ")
    }

    // ---- Tools ------------------------------------------------------------------------------------------------

    class Param(val name: String, val description: String)

    /** One tool: every parameter is a required string, as the iPhone's @ToolParam String fields. */
    class Spec(val name: String, val description: String, vararg val params: Param) {
        /** OpenAI-style function description, the shape LiteRT-LM's OpenApiTool parses. */
        val json: String = JSONObject()
            .put("name", name)
            .put("description", description)
            .put("parameters", JSONObject()
                .put("type", "object")
                .put("properties", JSONObject().apply {
                    params.forEach { put(it.name, JSONObject().put("type", "string").put("description", it.description)) }
                })
                .put("required", JSONArray(params.map { it.name })))
            .toString()

        // automaticToolCalling is off, so execute is never used; the app runs every call itself.
        val provider: ToolProvider by lazy {
            tool(object : OpenApiTool {
                override fun getToolDescriptionJsonString(): String = json
                override fun execute(paramsJsonString: String): String = ""
            })
        }
    }

    companion object {
        private const val TAG = "REMY_AGENT"

        val PLAN_RECIPE = Spec("plan_recipe", "Plan a recipe and start it. Use for the dish the cook names, or one you pick when they ask you to choose.",
            Param("dish", "The dish, for example cold pasta salad"))
        val CHECK_INGREDIENTS = Spec("check_ingredients", "Look at the counter with the camera and check which ingredients are there.")
        val SUBSTITUTE_INGREDIENT = Spec("substitute_ingredient", "The cook does not have an ingredient: replace it with another in the list and the steps.",
            Param("ingredient", "The ingredient in the recipe, for example red wine vinegar"),
            Param("substitute", "What to use instead, for example apple cider vinegar"))
        val HAVE_INGREDIENT = Spec("have_ingredient", "The cook says they have an ingredient (\"that's the salt\", \"I've got the pasta\"): mark it as ready.",
            Param("ingredient", "The ingredient they have"))
        val ADD_INGREDIENT = Spec("add_ingredient", "Put an extra ingredient on the list, only when the cook asks you to add one.",
            Param("ingredient", "The ingredient"), Param("amount", "How much, for example 1 or to taste"))
        val REMOVE_INGREDIENT = Spec("remove_ingredient", "The cook wants to skip an ingredient: take it off the list.",
            Param("ingredient", "The ingredient to leave out"))
        val START_COOKING = Spec("start_cooking", "The cook is ready: start the first step.")
        val NEXT_STEP = Spec("next_step", "The cook says the current step is finished. Only then.")
        val PREVIOUS_STEP = Spec("previous_step", "Go back one step.")
        val REPEAT_STEP = Spec("repeat_step", "Say the current step again.")
        val CHECK_STEP = Spec("check_step", "Look at the cutting board with the camera and judge the current step.")
        val LOOK = Spec("look", "Answer a question about what the camera can see right now.",
            Param("question", "The cook's question"))
        val FIND = Spec("find", "Show where an item is on the counter by drawing a box around it.",
            Param("item", "The item; for a knife, the biggest knife or the smallest knife"))
        val SAVE_PREFERENCE = Spec("save_preference", "Save the cook's answer to the question you asked.",
            Param("value", "The answer in 1 to 4 words, for example mild"))
        val HOT_OBJECT = Spec("hot_object", "Mark a hot object on the counter (pot, pan, kettle, stove) so the cook is warned instantly when a hand gets close.",
            Param("item", "The hot object, for example pot"))
        val MARK_ADDED = Spec("mark_added", "The cook says they already added the seasoning for this step.")

        val ALL: Map<String, Spec> = listOf(
            PLAN_RECIPE, CHECK_INGREDIENTS, SUBSTITUTE_INGREDIENT, HAVE_INGREDIENT, ADD_INGREDIENT, REMOVE_INGREDIENT,
            START_COOKING, NEXT_STEP, PREVIOUS_STEP, REPEAT_STEP, CHECK_STEP, LOOK, FIND, SAVE_PREFERENCE, HOT_OBJECT, MARK_ADDED,
        ).associateBy { it.name }

        /** Actions that announce themselves; the first reply is shown but not spoken over them. */
        val ANNOUNCING = setOf("next_step", "previous_step", "repeat_step", "save_preference", "mark_added", "start_cooking")
        /** Results that are news (what the camera saw): Gemma always reads them back. */
        private val NEWS = setOf("check_ingredients", "look")

        /** Only the tools that make sense now, in the iPhone's order. */
        fun tools(phase: AgentPhase, gate: StepGate = StepGate.NORMAL): List<Spec> = when (phase) {
            AgentPhase.NEEDS_DISH -> listOf(PLAN_RECIPE, LOOK, FIND, HOT_OBJECT)
            AgentPhase.INGREDIENTS -> listOf(CHECK_INGREDIENTS, HAVE_INGREDIENT, SUBSTITUTE_INGREDIENT, REMOVE_INGREDIENT,
                ADD_INGREDIENT, START_COOKING, LOOK, FIND, HOT_OBJECT, PLAN_RECIPE)
            AgentPhase.COOKING -> when (gate) {
                StepGate.COMPLETE -> listOf(PLAN_RECIPE, LOOK, FIND, HOT_OBJECT)
                // The chef just asked the cook something: the camera tools do not fit, so the answer is the clear choice.
                StepGate.ASK -> listOf(SAVE_PREFERENCE, NEXT_STEP, PREVIOUS_STEP, REPEAT_STEP, SUBSTITUTE_INGREDIENT, REMOVE_INGREDIENT)
                // Until the seasoning is recorded, "I added it" must arm the reach warning rather than move on.
                StepGate.GUARDED_UNSALTED -> listOf(MARK_ADDED, PREVIOUS_STEP, REPEAT_STEP, CHECK_STEP, LOOK, FIND, HOT_OBJECT)
                StepGate.NORMAL -> listOf(NEXT_STEP, PREVIOUS_STEP, REPEAT_STEP, CHECK_STEP, LOOK, FIND,
                    SUBSTITUTE_INGREDIENT, REMOVE_INGREDIENT, HOT_OBJECT)
            }
        }

        val BASE_PROMPT: String = listOf(
            "You are Remy, a warm, quick cooking coach running on the cook's Pixel. You speak out loud, so answer in one or " +
                "two short sentences, under 30 words, with no lists or markdown. Use a tool when the cook wants something done; " +
                "otherwise just answer. Listen to what the cook actually asked and respond to that.",
            "- \"I don't have X\" means X is missing: suggest one substitute and call substitute_ingredient right away (the " +
                "recipe and the screen update), or remove_ingredient if they want to skip it. Only substitute something the " +
                "cook has or very likely has; \"with what I have\" or \"skip it\" means call remove_ingredient for each missing one. Never add_ingredient for this. " +
                "add_ingredient is only for something the recipe left out that the cook asks you to add.",
            "- Where something is, or which tool or knife to use: call find, so it is boxed on the screen. The camera finds",
            "knives by size, not by name, so for a knife always say \"the biggest knife\" (chopping, dicing, slicing) or \"the",
            "smallest knife\" (peeling, small or fine work). Other items by their name.",
            "- The cook says they have an ingredient, or confirms one you were unsure about: call have_ingredient.",
            "- When every ingredient is ready and the cook wants to go on, call start_cooking.",
            "- After a tool reports what the camera saw, tell the cook in your own words what is there and what is missing.",
            "- You cannot see by yourself. When asked what is visible right now, call look (or find for one item); never " +
                "answer from earlier turns.",
            "- Burns, cuts, smoke or a pot boiling over: give the safety step first.",
            "- Something hot on the counter (a pot, pan, kettle, stove), seen or mentioned: call hot_object with it, so " +
                "the cook is warned the moment a hand gets close. Asked whether anything is dangerous: call look first.",
            "- General cooking questions (heat, timing, technique, swaps): answer from your own knowledge, confidently.",
            "- Never invent steps the recipe does not have.",
        ).joinToString("\n")

        fun system(context: String): String = if (context.isBlank()) BASE_PROMPT else BASE_PROMPT + "\n" + context.trim()

        class Ingredient(val name: String, val amount: String, val status: String = "unchecked")

        /** The session lines the iPhone appends to the system prompt (ChefAgent.system), from plain values. */
        fun context(
            phase: AgentPhase,
            dish: String? = null,
            ingredients: List<Ingredient> = emptyList(),
            ingredientsCollected: Boolean = false,
            stepIndex: Int = 0,
            stepCount: Int = 0,
            stepTitle: String? = null,
            stepInstruction: String = "",
            stepQuestion: String? = null,
            isComplete: Boolean = false,
            guardItem: String? = null,
            unavailable: List<String> = emptyList(),
            preferences: Map<String, String> = emptyMap(),
        ): String {
            val lines = mutableListOf<String>()
            when (phase) {
                AgentPhase.NEEDS_DISH -> lines += "No dish yet. If the cook asks you to choose, pick one simple dish yourself and plan it."
                AgentPhase.INGREDIENTS, AgentPhase.COOKING -> if (dish != null) {
                    lines += "Dish: $dish. Ingredients: ${ingredients.joinToString(", ") { "${it.name} (${it.amount}, ${it.status})" }}."
                    if (phase == AgentPhase.INGREDIENTS) {
                        lines += "Now: checking ingredients before cooking."
                        if (ingredientsCollected) lines += "All ingredients are ready. You asked Ready to cook? An affirmative reply means call start_cooking. If the cook says wait, do not start."
                    } else if (stepTitle != null) {
                        lines += "Now: step ${stepIndex + 1} of $stepCount: $stepTitle. ${if (stepQuestion != null) "You asked: $stepQuestion" else stepInstruction}"
                        if (isComplete) lines += "The dish is complete. Congratulate the cook and answer follow-up questions; do not repeat the last instruction as unfinished."
                        if (stepQuestion != null) lines += "You just asked the cook: \"$stepQuestion\" Their next words are most likely the answer, even if short " +
                            "(\"a little\", \"medium\"): call save_preference with it."
                        if (guardItem != null) lines += "This step adds $guardItem once and it cannot come back out. If the cook says they already added it, call mark_added."
                    }
                }
            }
            if (unavailable.isNotEmpty()) lines += "The cook does not have: ${unavailable.joinToString(", ")}. Never suggest these."
            val prefs = preferences.toSortedMap().map { "${it.key}: ${it.value}" }
            if (prefs.isNotEmpty()) lines += "The cook said before: ${prefs.joinToString("; ")}."
            return lines.joinToString("\n")
        }

        // ---- Text helpers (ports of the iPhone's) -------------------------------------------------------------

        private val CALL_IN_ERROR = Regex("""call:([a-z_]+)\{([^}]*)\}""")

        /** Tool calls written as call:name{key:value,...} inside an error message. */
        fun recoveredCalls(text: String): List<LmToolCall> {
            val seen = HashSet<String>()
            return CALL_IN_ERROR.findAll(text).mapNotNull { match ->
                val name = match.groupValues[1]; val body = match.groupValues[2]
                if (!seen.add(name + body)) return@mapNotNull null
                val arguments = LinkedHashMap<String, Any>()
                for (pair in body.split(",")) {
                    val parts = pair.split(":", limit = 2).map { it.replace("<|\"|>", "").trim('"', '\'', ' ') }
                    if (parts.size == 2) arguments[parts[0]] = parts[1]
                }
                LmToolCall(name, arguments)
            }.toList()
        }

        private val PROMISE = Regex(
            """\b(i will|i'll|i can|let me|let's|lets|i am going to|i'm going to|i have|i've)\b.{0,30}\b(update|change|add|remove|swap|substitute|mark|check|find|look|save|move|start)""")

        fun promisesAction(text: String, toolNames: List<String>): Boolean {
            val lower = text.lowercase()
            // Only real tool names (snake_case, whole words); bare words like "look" or "find" are ordinary speech.
            if (toolNames.any { it.contains('_') && Regex("\\b${Regex.escape(it)}\\b").containsMatchIn(lower) }) return true
            return PROMISE.containsMatchIn(lower)
        }

        /** The reply without sentences that name a tool: those are the model talking about its plumbing. */
        fun spoken(text: String, toolNames: List<String>): String {
            val sentences = text.split('.', '!', '?').map { it.trim() }
            val nonEmpty = sentences.filter { it.isNotEmpty() }
            val kept = nonEmpty.filter { sentence ->
                val lower = sentence.lowercase()
                toolNames.none { name ->
                    val words = name.replace('_', ' ')
                    name.contains('_') && (lower.contains(name) || lower == words || lower.startsWith("$words "))
                }
            }
            if (kept.size == nonEmpty.size) return text.trim()
            return kept.joinToString(" ") { "$it." }
        }

        /** What the chef said in a turn, for the history; a turn with only tool calls becomes a short sentence. */
        fun remembered(speech: String, actions: List<ToolCall>): String {
            if (speech.isNotEmpty()) return speech
            val action = actions.firstOrNull() ?: return "Okay."
            return when (action.name) {
                "next_step" -> "On to the next step."
                "previous_step" -> "Back one step."
                "save_preference" -> "Got it, ${action.arg("value").ifEmpty { "noted" }}."
                "mark_added" -> "Noted, it's in."
                "find" -> "There it is."
                "look", "check_step", "check_ingredients" -> "Let me look."
                "plan_recipe" -> "Planning ${action.arg("dish").ifEmpty { "it" }} now."
                "start_cooking" -> "Let's start cooking."
                else -> "Done."
            }
        }

        /** "substitute_ingredient · feta → lemon": the drawer title for a call. */
        fun describe(call: ToolCall): String = when (call.name) {
            "substitute_ingredient" -> "${call.name} · ${call.arg("ingredient")} → ${call.arg("substitute")}"
            "remove_ingredient", "add_ingredient", "have_ingredient" -> "${call.name} · ${call.arg("ingredient")}"
            "find", "hot_object" -> "${call.name} · ${call.arg("item")}"
            "look" -> if (call.arg("question").isEmpty()) call.name else "${call.name} · ${call.arg("question")}"
            "plan_recipe" -> "${call.name} · ${call.arg("dish")}"
            "save_preference" -> "${call.name} · ${call.arg("value")}"
            else -> call.name
        }

        /** Trim string arguments; "nil", "null", "none" mean empty, as the iPhone's execute reads them. */
        private fun normalize(call: LmToolCall): ToolCall = ToolCall(call.name, call.arguments.mapValues { (_, value) ->
            val text = value?.toString()?.trim() ?: ""
            if (text.lowercase() in setOf("nil", "null", "none")) "" else text
        })
    }
}
