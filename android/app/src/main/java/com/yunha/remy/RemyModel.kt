package com.yunha.remy

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.yunha.remy.agent.AgentEvent
import com.yunha.remy.agent.AgentPhase
import com.yunha.remy.agent.ChefAgent
import com.yunha.remy.agent.GemmaRunner
import com.yunha.remy.agent.StepGate
import com.yunha.remy.agent.ToolCall
import com.yunha.remy.core.ChefObservation
import com.yunha.remy.core.ChefPrompt
import com.yunha.remy.core.ChefWakeGate
import com.yunha.remy.core.CookingReadinessReply
import com.yunha.remy.core.CookingSession
import com.yunha.remy.core.EvidenceOrigin
import com.yunha.remy.core.GemmaTask
import com.yunha.remy.core.HeardAnswer
import com.yunha.remy.core.IngredientCheck
import com.yunha.remy.core.IngredientConfirmation
import com.yunha.remy.core.IngredientDraft
import com.yunha.remy.core.IngredientPresentationCue
import com.yunha.remy.core.IngredientVisualIdentity
import com.yunha.remy.core.IngredientVisualVerification
import com.yunha.remy.core.ItemBox
import com.yunha.remy.core.JSONOutputContract
import com.yunha.remy.core.PantryStatus
import com.yunha.remy.core.RecipeInstructions
import com.yunha.remy.core.RecipePlan
import com.yunha.remy.core.RecipeStep
import com.yunha.remy.core.VoiceCommand
import com.yunha.remy.ui.AgentActivity.Kind
import com.yunha.remy.ui.RemyState
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * AppModel.swift's recipe, voice and agent flow on Android: dish → ingredient draft → checklist → instructions →
 * step by step, the hands-free wake gate, Gemma hearing answers to its questions, and the 16-tool agent.
 * Runs on the main thread; Gemma calls go through one serialized GemmaRunner on Dispatchers.IO.
 */
class RemyModel(private val context: Context, val state: RemyState, private val scope: CoroutineScope, private val host: Host) {
    /** What the camera side of the app provides (MainActivity). */
    interface Host {
        fun latestJpeg(): ByteArray?
        fun startCamera()
        /** Box the named hot items and watch them with the reflex loop. True when something was boxed. */
        suspend fun markHot(items: List<String>, jpeg: ByteArray): Boolean
        fun showBoxes(boxes: List<ItemBox>, seconds: Double)
        fun knifeBox(box: ItemBox?)
    }

    var session: CookingSession = restore(); private set
    private var runner: GemmaRunner? = null
    private var agent: ChefAgent? = null
    private val wakeGate = ChefWakeGate()
    val speaker = Speaker(context) { speaking -> state.speaking = speaking; listener.setMuted(speaking) }
    val listener = VoiceListener(context, object : VoiceListener.Events {
        override fun onWords(text: String, ms: Double) { scope.launch { handleWords(text, ms, "Android on-device speech") } }
        override fun onAudio(wav: ByteArray, seconds: Double) { scope.launch { handleAudio(wav, seconds) } }
        override fun onListenerState(on: Boolean, hearing: Boolean) { state.listenerOn = on; state.hearing = hearing }
        override fun onListenerNote(note: String) { state.speechPath = note }
    })
    private var startWhenRecipeReady = false
    private var readyPromptSession: String? = null
    private var preparing = false
    private var lastReview = 0L
    private var lastConcern = "" to 0L
    private val sessionFile = File(context.filesDir, "session.json")

    // ---- Lifecycle ---------------------------------------------------------------------------------------------

    fun attach(lm: TensorLmLoader.LoadedLm): GemmaRunner {
        val r = GemmaRunner(lm); runner = r; agent = ChefAgent(r)
        state.isLoaded = true
        state.chefLineIdle()
        state.status = when (session.phase) {
            CookingSession.Phase.NEEDS_DISH -> "Say Remy or Hey Remy."
            CookingSession.Phase.INGREDIENTS -> "Show me an ingredient. Open Session to correct the checklist."
            CookingSession.Phase.COOKING -> "Listening. Ask a question or tell me when you’re done."
        }
        changed(save = false)
        if (state.handsFree) listener.start()
        if (session.instructionsPending) schedulePreparation()
        // "Watch the board automatically": a quiet glance every 10 s while a do-step is on screen.
        scope.launch {
            while (true) {
                delay(2000)
                if (state.automaticChecks && session.phase == CookingSession.Phase.COOKING && session.step?.kind == RecipeStep.Kind.DO &&
                    !session.isComplete && !state.isBusy && SystemClock.elapsedRealtime() - lastReview > 10_000) reviewBoard(spoken = false)
            }
        }
        return r
    }

    private fun RemyState.chefLineIdle() {
        line = when (session.phase) {
            CookingSession.Phase.NEEDS_DISH -> "Tell me what we're making."
            CookingSession.Phase.INGREDIENTS -> "Show me your ingredients."
            CookingSession.Phase.COOKING -> session.step?.let { if (it.kind == RecipeStep.Kind.ASK) it.question else it.instruction } ?: "Ready when you are."
        }
    }

    fun setHandsFree(on: Boolean) {
        state.handsFree = on
        if (on && state.isLoaded) listener.start() else if (!on) listener.stop()
        syncPrimary()
    }

    fun setSpoken(on: Boolean) { state.spokenResponses = on; speaker.enabled = on; if (!on) speaker.stop() }

    private fun say(line: String) { state.line = line; if (state.spokenResponses) speaker.say(line) }

    /** Session changed: persist, refresh the screen, keep the microphone mode right for ask steps. */
    private fun changed(save: Boolean = true) {
        if (save) runCatching { sessionFile.writeText(session.toJson()) }.onFailure { Log.e(TAG, "REMY_SESSION save failed", it) }
        state.sessionVersion++
        val asking = session.phase == CookingSession.Phase.COOKING && session.step?.kind == RecipeStep.Kind.ASK && !session.isComplete
        listener.captureNextAnswerAsAudio(asking)
        syncPrimary()
    }

    private fun restore(): CookingSession {
        val text = runCatching { File(context.filesDir, "session.json").readText() }.getOrNull() ?: return CookingSession()
        val restored = CookingSession.fromJson(text)?.takeIf { it.plan != null } ?: return CookingSession()
        // RemyModel.restoreSession on iPhone: the preset never keeps salt, legacy and two-step demos move to the current preset.
        val preset = IngredientDraft.preset(restored.plan?.dish ?: "") != null && restored.removeForReplanning("salt")
        val legacy = restored.refreshLegacyPastaInstructions(); val demo = restored.refreshPastaDemoSteps()
        restored.restoredAfterLaunch()
        if (preset || legacy || demo) runCatching { File(context.filesDir, "session.json").writeText(restored.toJson()) }
        Log.i(TAG, "REMY_SESSION restored ${restored.plan?.dish} phase ${restored.phase} step ${restored.currentStep + 1}")
        return restored
    }

    val readyToCook: Boolean get() = session.phase == CookingSession.Phase.INGREDIENTS && session.ingredientsCollected

    /** PrimaryAction's title and enabled state, from ContentView.swift. */
    fun syncPrimary() {
        val phase = session.phase
        val asking = phase == CookingSession.Phase.COOKING && session.step?.kind == RecipeStep.Kind.ASK
        state.primaryTitle = when {
            !state.isLoaded -> if (state.isLoading) "Loading Gemma…" else "Set up Remy"
            phase == CookingSession.Phase.INGREDIENTS -> if (readyToCook) "Start cooking" else "Check ingredients"
            phase == CookingSession.Phase.COOKING && session.isComplete -> "All done"
            phase == CookingSession.Phase.NEEDS_DISH -> "Plan ingredients"
            !state.videoOn -> "Open camera"
            asking && state.handsFree -> "Just say your answer"
            asking -> if (state.recording) "Done talking" else "Answer out loud"
            session.isLastStep -> "Finish"
            else -> "Next step"
        }
        state.primaryEnabled = !(state.isLoading || session.isComplete ||
            ((phase == CookingSession.Phase.NEEDS_DISH || asking) && state.isBusy && !state.recording))
        state.planningDish = session.plan?.dish ?: state.planningDish
    }

    fun primary() {
        val phase = session.phase
        val asking = phase == CookingSession.Phase.COOKING && session.step?.kind == RecipeStep.Kind.ASK
        when {
            !state.isLoaded -> state.settingsOpen = true
            phase == CookingSession.Phase.INGREDIENTS -> if (readyToCook) beginCooking() else scope.launch { checkIngredients() }
            phase == CookingSession.Phase.NEEDS_DISH ->
                // The dish comes from the voice or the Session composer; with nothing typed, open the composer.
                if (state.dishRequest.isBlank()) state.sessionOpen = true else scope.launch { planDish() }
            !state.videoOn -> host.startCamera()
            asking && state.handsFree -> {}
            asking -> state.sessionOpen = true
            else -> nextStep()
        }
    }

    // ---- Gemma tasks -------------------------------------------------------------------------------------------

    private suspend fun run(task: GemmaTask, prompt: String, jpeg: ByteArray? = null, wav: ByteArray? = null, constrained: Boolean = true): GemmaRunner.Result {
        val r = runner ?: error("Gemma is not loaded")
        val system = task.system + if (constrained && task.schema.isNotEmpty()) JSONOutputContract.instruction(task.schema) else ""
        val result = when {
            wav != null -> r.audio(system, prompt, wav, task.maxTokens)
            jpeg != null -> r.vision(system, prompt, jpeg, task.maxTokens)
            else -> r.text(system, prompt, task.maxTokens)
        }
        state.gemmaCalls++
        if (jpeg != null) state.visionChecks++
        if (wav != null) state.audioCalls++
        record(result)
        return result
    }

    private fun record(result: GemmaRunner.Result) {
        state.rawResponse = result.text
        state.gemmaSeconds = result.ms / 1000.0
        state.callMs.add(result.ms); while (state.callMs.size > 20) state.callMs.removeAt(0)
        result.prefillTps?.let { state.prefillTps = it }; result.decodeTps?.let { state.decodeTps = it }; result.ttft?.let { state.ttft = it }
    }

    // ---- Recipe flow -------------------------------------------------------------------------------------------

    suspend fun planDish() {
        val dish = state.dishRequest.trim()
        if (!state.isLoaded || state.isBusy || dish.isEmpty()) return
        state.isBusy = true; state.planning = true; state.planningDish = dish; state.planIngredients = emptyList(); state.planSteps = emptyList()
        syncPrimary()
        val entry = state.activity.begin(Kind.PLAN, "Ingredients for $dish")
        state.status = "Choosing your ingredients…"
        state.line = "I'll get the ingredients ready first."
        var draft: IngredientDraft? = null
        try {
            val preset = if (state.demoPreset) IngredientDraft.preset(dish) else null
            if (preset != null) {
                draft = preset
                state.activity.finish(entry, "Your saved five-ingredient pasta salad list")
            } else {
                val prompt = ChefPrompt.ingredientDraft(dish)
                val first = withContext(Dispatchers.IO) { run(ChefPrompt.ingredientDraftTask, prompt) }
                draft = runCatching { IngredientDraft.decode(first.text) }.getOrNull()
                var ms = first.ms
                if (draft == null) {
                    val correction = "\nYour reply was rejected. Return complete JSON with only dish and ingredients, each with a unique id, name and amount. Keep it short."
                    val second = withContext(Dispatchers.IO) { run(ChefPrompt.ingredientDraftTask, prompt + correction) }
                    ms += second.ms
                    draft = IngredientDraft.decode(second.text)
                }
                state.activity.finish(entry, "${draft.ingredients.size} ingredients", ms.toDouble())
                Log.i(TAG, "REMY_PLAN ingredients ${ms} ms ${draft.ingredients.map { it.name }}")
            }
        } catch (e: Throwable) {
            state.activity.finish(entry, e.message ?: "failed", failed = true)
            state.status = "Could not prepare the ingredients. Try again."
            Log.e(TAG, "REMY_PLAN failed", e)
        }
        state.planning = false
        val d = draft
        if (d == null || !session.startIngredients(d)) { state.isBusy = false; syncPrimary(); return }
        startWhenRecipeReady = false; readyPromptSession = null
        agent?.resetHistory()
        state.planIngredients = d.ingredients.map { it.name }
        say("${d.dish}: ${list(d.ingredients.map { it.name })}. Show me one at a time.")
        state.status = "Show me an ingredient. Open Session to correct the checklist."
        state.isBusy = false
        changed()
        if (!state.videoOn) host.startCamera()
        schedulePreparation()
    }

    /** The longer instructions call waits until the ingredients are in, or cooking is asked for (iPhone order). */
    private fun schedulePreparation() {
        if (preparing || !session.instructionsPending) return
        preparing = true
        val id = session.id
        scope.launch {
            try {
                while (session.id == id && session.instructionsPending) {
                    if ((session.ingredientsCollected || startWhenRecipeReady) && !state.isBusy) { retryInstructions(); break }
                    delay(200)
                }
            } finally { preparing = false }
        }
    }

    suspend fun retryInstructions() {
        val initial = session.plan ?: return
        if (!state.isLoaded || state.isBusy || !session.instructionsPending) return
        val sessionID = session.id
        val initialDraft = IngredientDraft(initial.dish, initial.ingredients)
        initialDraft.presetInstructions?.let { preset ->
            if (session.applyInstructions(preset, sessionID, initial.ingredients)) {
                state.activity.log(Kind.PLAN, "Pasta salad instructions ready", "Validated app recipe preset · ${preset.steps.size} steps; no model generation")
                changed()
                if (startWhenRecipeReady) beginCooking()
            }
            return
        }
        state.isBusy = true; syncPrimary()
        val entry = state.activity.begin(Kind.PLAN, "Preparing ${initial.dish} instructions")
        try {
            val maxSteps = if (state.shortRecipes) 5 else RecipePlan.MAX_STEPS
            val draft = IngredientDraft(initial.dish, initial.ingredients)
            val task = ChefPrompt.instructionsTask(maxSteps)
            val prompt = ChefPrompt.instructions(draft, maxSteps)
            val first = withContext(Dispatchers.IO) { run(task, prompt) }
            var ms = first.ms
            val plan = runCatching { RecipeInstructions.decode(first.text, draft) }.getOrElse { error ->
                val correction = """

                Your previous instructions were rejected: ${error.message ?: "the JSON syntax or field types were invalid"}.
                Rewrite the whole JSON object from scratch, following the complete example's structure.
                Every ask AND do step needs id, kind, title, instruction, needs, doneWhen.
                All text values must be quoted strings, never null; ask doneWhen is "".
                needs is [] or earlier step ids only. Use at most $maxSteps short steps total and group vegetable prep.
                Keep the supplied ingredients unchanged. Close every quote, array and object. Output only valid JSON.
                """.trimIndent()
                val second = withContext(Dispatchers.IO) { run(task, prompt + "\n" + correction) }
                ms += second.ms
                RecipeInstructions.decode(second.text, draft)
            }
            if (session.id == sessionID && session.applyInstructions(plan, sessionID, draft.ingredients)) {
                state.planSteps = plan.steps.map { (if (it.kind == RecipeStep.Kind.ASK) "Ask · " else "") + it.title }
                state.activity.finish(entry, "${plan.steps.size} steps ready; ingredient checks preserved", ms.toDouble())
                Log.i(TAG, "REMY_PLAN instructions $ms ms ${plan.steps.size} steps")
                changed()
            } else state.activity.finish(entry, "Ingredients changed; preparing steps for the new list")
        } catch (e: Throwable) {
            state.activity.finish(entry, e.message ?: "failed", failed = true)
            state.status = "Keep showing your ingredients. Your checklist is saved."
            Log.e(TAG, "REMY_PLAN instructions failed", e)
        } finally { state.isBusy = false; syncPrimary() }
        if (startWhenRecipeReady && session.instructionsReady) beginCooking()
    }

    /** Ingredient check from the newest frame (ChefPrompt.ingredients): only listed recipe ids, anything else missing. */
    suspend fun checkIngredients(): String? {
        val plan = session.plan ?: return null
        if (!state.isLoaded || session.phase != CookingSession.Phase.INGREDIENTS || state.isBusy) return null
        if (!state.videoOn) { host.startCamera(); delay(1500) }
        val jpeg = host.latestJpeg() ?: run { say("I can't see the counter yet. Point the camera at it."); return "The camera has no picture yet." }
        state.isBusy = true; state.understanding = true; syncPrimary()
        state.line = "Thinking…"
        // The iPhone path first: name the one food held up, blind, then verify a closer crop.
        try {
            presented(jpeg, plan)?.let { return it }
        } catch (e: Throwable) { Log.e(TAG, "REMY_PRESENTED failed", e) }
        val entry = state.activity.begin(Kind.VISION, "Checking ingredients", "${plan.ingredients.size} on the list")
        val revision = session.revision; val id = session.id
        try {
            val task = ChefPrompt.ingredients(plan)
            val prompt = ChefPrompt.ingredients(session, 1)
            val first = withContext(Dispatchers.IO) { run(task, prompt, jpeg) }
            var ms = first.ms
            val check = runCatching { IngredientCheck.decode(first.text, plan) }.getOrElse {
                val ids = plan.ingredients.joinToString(", ") { it.id }
                val correction = "\nYour previous reply was rejected. Return only seen and unsure arrays. " +
                    "The ONLY allowed array values are these exact recipe IDs: $ids. " +
                    "Never put ingredient names, new IDs or aliases in either list. Use empty lists if no listed ingredient is clearly visible."
                val second = withContext(Dispatchers.IO) { run(task, prompt + correction, jpeg) }
                ms += second.ms
                IngredientCheck.decode(second.text, plan)
            }
            session.applyIngredientCheck(check, id, revision)
            val seen = check.items.filter { it.status == PantryStatus.SEEN }.mapNotNull { item -> plan.ingredients.firstOrNull { it.id == item.id }?.name }
            state.activity.finish(entry, "seen: ${seen.joinToString().ifEmpty { "nothing listed" }}", ms.toDouble())
            Log.i(TAG, "REMY_INGREDIENTS $ms ms seen $seen")
            changed()
            val left = plan.ingredients.filter { session.pantry[it.id]?.status != PantryStatus.SEEN }.map { it.name }
            val line = if (seen.isEmpty()) "I don't see anything from the list yet." else "I see ${list(seen)}." +
                if (left.isEmpty()) "" else " Still need ${list(left)}."
            say(line)
            offerCookingIfReady()
            return "The camera shows: ${seen.joinToString().ifEmpty { "none of the listed ingredients" }}. Still needed: ${left.joinToString().ifEmpty { "nothing" }}."
        } catch (e: Throwable) {
            state.activity.finish(entry, e.message ?: "failed", failed = true)
            Log.e(TAG, "REMY_INGREDIENTS failed", e)
            return null
        } finally { state.isBusy = false; state.understanding = false; syncPrimary() }
    }

    /**
     * ChefBrain.presentedIngredient: identify the single food presented closest to the camera without the cook's
     * words, then inspect a tighter crop; only a corroborated identity that is on the list marks it ready.
     * Returns the tool result, or null when nothing single was presented (the whole-list check runs instead).
     */
    private suspend fun presented(jpeg: ByteArray, plan: RecipePlan): String? {
        val entry = state.activity.begin(Kind.VISION, "What is being shown?", "blind identity, then a closer crop")
        val first = withContext(Dispatchers.IO) { run(ChefPrompt.presentedIngredient,
            "Identify the single food being held up or presented closest to the camera. Give its visible distinguishing features, actual name and box. If no clear single ingredient is presented, return unknown and an empty box.", jpeg) }
        val identity = runCatching { IngredientVisualIdentity.decode(JSONOutputContract.clean(first.text)) }.getOrNull()
        val box = identity?.box
        if (identity == null || !identity.isSupported || box == null) {
            Log.i(TAG, "REMY_PRESENTED ${first.ms} ms no single ingredient \"${first.text.take(80)}\"")
            state.activity.finish(entry, "no single ingredient presented", first.ms.toDouble()); return null
        }
        state.presentedBox = ItemBox(identity.name, box.x, box.y, box.width, box.height); state.boxCount++
        val crop = withContext(Dispatchers.Default) { crop(jpeg, box) }
        if (crop == null) { state.activity.finish(entry, "${identity.name} · crop too small", first.ms.toDouble()); return null }
        val second = withContext(Dispatchers.IO) { run(ChefPrompt.verifyPresentedIngredient,
            "Inspect this closer crop. An earlier visual pass suggested ${identity.name}. Independently decide if that identity is supported. Name what is ACTUALLY visible; reject the suggestion if a look-alike or unclear. Do not infer from what a cook says.", crop) }
        val verification = runCatching { IngredientVisualVerification.decode(JSONOutputContract.clean(second.text)) }.getOrNull()
        val ms = (first.ms + second.ms).toDouble()
        val match = verification?.let { identity.confirmedIngredient(plan.ingredients, it) }
        Log.i(TAG, "REMY_PRESENTED ${first.ms}+${second.ms} ms ${identity.name} verified=${verification?.matches} → ${match?.name}")
        scope.launch { delay(4000); state.presentedBox = null }
        if (match == null) {
            state.activity.finish(entry, "${identity.name} · " + if (verification?.matches == true) "not on the list" else "not confirmed", ms)
            val line = if (verification?.matches == true) "That looks like ${identity.name}, which isn't on the list." else "I'm not sure what that is. Hold it a little closer."
            say(line); changed(save = false)
            return "The camera shows ${identity.name}" + if (verification?.matches == true) ", which is not on the list." else ", not confirmed."
        }
        session.setPantry(match.id, PantryStatus.SEEN)
        state.activity.finish(entry, "${match.name} · verified on a closer crop", ms)
        changed()
        val left = plan.ingredients.filter { session.pantry[it.id]?.status != PantryStatus.SEEN }.map { it.name }
        say("Got it, ${match.name}." + if (left.isEmpty()) "" else " Next, ${left.first()}.")
        offerCookingIfReady()
        return "Marked ${match.name} as ready. " + if (left.isEmpty()) "Every ingredient is ready." else "Still needed: ${left.joinToString()}."
    }

    private fun crop(jpeg: ByteArray, box: ItemBox): ByteArray? {
        val bitmap = android.graphics.BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return null
        val w = bitmap.width; val h = bitmap.height
        val left = ((box.x - 0.035) * w).toInt().coerceIn(0, w); val top = ((box.y - 0.035) * h).toInt().coerceIn(0, h)
        val right = ((box.x + box.width + 0.035) * w).toInt().coerceIn(0, w); val bottom = ((box.y + box.height + 0.035) * h).toInt().coerceIn(0, h)
        if (right - left < 16 || bottom - top < 16) return null
        val out = java.io.ByteArrayOutputStream()
        android.graphics.Bitmap.createBitmap(bitmap, left, top, right - left, bottom - top).compress(android.graphics.Bitmap.CompressFormat.JPEG, 94, out)
        return out.toByteArray()
    }

    fun cyclePantry(id: String) {
        Log.i(TAG, "REMY_PANTRY tap $id")
        session.setPantry(id, if (session.pantry[id]?.status == PantryStatus.SEEN) PantryStatus.MISSING else PantryStatus.SEEN)
        if (!session.ingredientsCollected) readyPromptSession = null
        changed(); offerCookingIfReady()
    }

    private fun offerCookingIfReady() {
        if (!readyToCook || readyPromptSession == session.id || startWhenRecipeReady) return
        readyPromptSession = session.id
        say("That's all ${session.plan?.ingredients?.size ?: 0} ingredients. Ready to cook?")
        state.status = "Say yes when you're ready."
        schedulePreparation()
    }

    fun beginCooking() {
        if (!session.instructionsReady) {
            startWhenRecipeReady = true
            say("Let's cook. One moment.")
            schedulePreparation()
            return
        }
        startWhenRecipeReady = false; readyPromptSession = null
        session.beginCooking()
        if (!state.videoOn) host.startCamera()
        if (state.handsFree) state.automaticChecks = true
        changed()
        announceStep()
    }

    fun announceStep(prefix: String = "") {
        val step = session.step ?: return
        if (session.phase != CookingSession.Phase.COOKING) return
        if (step.kind == RecipeStep.Kind.ASK) say(if (prefix.isEmpty()) step.question else "$prefix ${step.question}")
        else {
            val line = (if (prefix.isEmpty()) "" else "$prefix ") + "Step ${session.currentStep + 1} of ${session.plan?.steps?.size ?: 0}. ${step.instruction}"
            state.line = line
            if (state.spokenResponses) speaker.say((if (step.warning.isEmpty()) "" else "${step.warning} ") + line)
        }
        changed(save = false)
    }

    fun nextStep() {
        if (!session.isComplete) session.nextStep()
        host.showBoxes(emptyList(), 0.0)
        changed()
        if (session.isComplete) {
            state.automaticChecks = false
            say(if (session.usesCookerSafetySequence) "Cutting complete. That's the end of the demo." else "Your ${session.plan?.dish?.lowercase() ?: "dish"} is ready. Enjoy!")
            state.status = "Finished."
        } else announceStep()
    }

    fun selectStep(index: Int) { session.selectStep(index); host.showBoxes(emptyList(), 0.0); changed(); announceStep() }

    fun answerTyped(text: String) {
        val value = text.trim(); if (value.isEmpty()) return
        session.answer(value, null, EvidenceOrigin.USER); changed()
        announceStep("Got it, $value.")
    }

    fun confirmSalt() { session.confirmSalt(); changed(); state.line = "Remembered. Taste before adding more." }

    fun reset() {
        session = CookingSession(); state.dishRequest = ""; startWhenRecipeReady = false; readyPromptSession = null
        agent?.resetHistory(); speaker.stop(); state.automaticChecks = false
        state.planIngredients = emptyList(); state.planSteps = emptyList()
        changed()
        state.line = "Fresh start. What are we making?"
    }

    // ---- Voice -------------------------------------------------------------------------------------------------

    /** handleUtterance in AppModel.swift: the wake gate first; unaddressed speech is dropped before anything else. */
    suspend fun handleWords(heard: String, ms: Double, source: String) {
        val conversationOpen = session.phase == CookingSession.Phase.COOKING || readyToCook || startWhenRecipeReady
        val addressed = wakeGate.accept(heard, SystemClock.elapsedRealtime() / 1000.0, conversationOpen) ?: run {
            Log.i(TAG, "REMY_HEARD ignored (no wake word) \"$heard\""); return
        }
        state.lastHeard = heard
        if (addressed.isEmpty()) { state.line = "Listening…"; return }
        if (readyToCook || startWhenRecipeReady) {
            CookingReadinessReply.parse(addressed)?.let { decision ->
                if (decision == CookingReadinessReply.Decision.READY) beginCooking()
                else { startWhenRecipeReady = false; say("Take your time. Tell me when you're ready.") }
                return
            }
        }
        if (session.phase == CookingSession.Phase.COOKING && session.suggestedCompletion && session.step?.kind == RecipeStep.Kind.DO &&
            CookingReadinessReply.parse(addressed) == CookingReadinessReply.Decision.READY) { nextStep(); return }
        val plan = session.plan
        if (session.phase == CookingSession.Phase.INGREDIENTS && plan != null && IngredientPresentationCue.parse(addressed, plan.ingredients) != null) {
            state.activity.log(Kind.HEARD, "\u201c$heard\u201d", "$source → ingredient shown", ms)
            checkIngredients(); return
        }
        if (session.phase == CookingSession.Phase.INGREDIENTS && plan != null && !heard.contains("?")) {
            IngredientConfirmation.parse(addressed, plan.ingredients)?.let { c ->
                state.activity.log(Kind.HEARD, "\u201c$heard\u201d", "$source → ${c.status.raw}", ms)
                if (c.status == PantryStatus.SEEN) { checkIngredients(); return }
                session.setPantry(c.ingredientID, c.status); changed()
                say("Marked ${plan.ingredients.firstOrNull { it.id == c.ingredientID }?.name ?: c.ingredientID} as missing.")
                return
            }
        }
        val command = VoiceCommand.parse("Hey Remy $addressed", session.phase, 60.0)
        session.record("Heard \"$heard\" → ${command.intent.name.lowercase()}", EvidenceOrigin.USER)
        Log.i(TAG, String.format("REMY_HEARD %s %.0f ms \"%s\" → %s", source, ms, heard, command.intent.name.lowercase()))
        state.activity.log(Kind.HEARD, "“$heard”", "$source → ${command.intent.name.lowercase()}", ms)
        when (command.intent) {
            VoiceCommand.Intent.IGNORE -> state.status = "Not for me: \"$heard\""
            VoiceCommand.Intent.WAKE -> say("Yes?")
            VoiceCommand.Intent.START_COOKING -> beginCooking()
            VoiceCommand.Intent.NEXT -> if (session.step?.kind == RecipeStep.Kind.ASK) announceStep() else nextStep()
            VoiceCommand.Intent.PREVIOUS -> selectStep(maxOf(0, session.currentStep - 1))
            VoiceCommand.Intent.REPEAT -> announceStep()
            VoiceCommand.Intent.AGENT -> {
                if (state.isBusy) speaker.say("One moment.", priority = false)
                for (i in 0 until 60) { if (!state.isBusy) break; delay(250) }
                if (state.isBusy) return
                converse(heard)
            }
        }
    }

    /** An utterance as audio: Gemma hears the answer to its question, or (no on-device recognizer) transcribes it. */
    private suspend fun handleAudio(wav: ByteArray, seconds: Double) {
        if (runner == null) return
        val asking = session.phase == CookingSession.Phase.COOKING && session.step?.kind == RecipeStep.Kind.ASK
        if (asking && hearAnswer(wav)) return
        // Not an answer (or no question): Gemma transcribes, and the words go through the same wake gate.
        if (state.isBusy) return
        state.isBusy = true; state.understanding = true
        try {
            val started = SystemClock.elapsedRealtime()
            val result = withContext(Dispatchers.IO) { run(ChefPrompt.transcribe, ChefPrompt.transcribeHint(session), wav = wav, constrained = false) }
            val text = result.text.trim().trim('"', '\'')
            Log.i(TAG, "REMY_TRANSCRIBE ${result.ms} ms \"$text\"")
            state.isBusy = false; state.understanding = false
            if (text.isNotEmpty()) handleWords(text, (SystemClock.elapsedRealtime() - started).toDouble(), "Gemma transcription")
        } catch (e: Throwable) { Log.e(TAG, "REMY_TRANSCRIBE failed", e) } finally { state.isBusy = false; state.understanding = false }
    }

    /** ChefBrain.hear: native audio input, the answer extracted; false when it was not an answer. */
    private suspend fun hearAnswer(wav: ByteArray): Boolean {
        val question = session.step?.question?.takeIf { it.isNotEmpty() } ?: return false
        state.isBusy = true; state.understanding = true
        val entry = state.activity.begin(Kind.GEMMA, "Gemma hears the answer (audio)", "“$question”")
        try {
            var answer: HeardAnswer? = null; var ms = 0L
            for (attempt in 0 until 2) {
                val result = withContext(Dispatchers.IO) { run(ChefPrompt.answer, ChefPrompt.answer(question), wav = wav) }
                ms += result.ms
                answer = runCatching { HeardAnswer.decode(result.text) }.getOrNull()
                if (answer != null) break
            }
            val a = answer ?: run { state.activity.finish(entry, "reply unreadable", ms.toDouble(), failed = true); return false }
            Log.i(TAG, "REMY_HEAR $ms ms heard \"${a.heard}\" → ${a.value}")
            state.activity.finish(entry, "“${a.heard}” → ${a.value}", ms.toDouble())
            state.lastHeard = a.heard
            if (a.value.lowercase() == "unclear") return false
            session.answer(a.value, a.heard, EvidenceOrigin.USER)
            state.isBusy = false
            changed()
            announceStep("Got it, ${a.value}." + if (a.line.isEmpty()) "" else " ${a.line}")
            return true
        } catch (e: Throwable) {
            state.activity.finish(entry, e.message ?: "failed", failed = true)
            Log.e(TAG, "REMY_HEAR failed", e); return false
        } finally { state.isBusy = false; state.understanding = false }
    }

    // ---- Agent -------------------------------------------------------------------------------------------------

    private fun agentPhase() = when (session.phase) {
        CookingSession.Phase.NEEDS_DISH -> AgentPhase.NEEDS_DISH
        CookingSession.Phase.INGREDIENTS -> AgentPhase.INGREDIENTS
        CookingSession.Phase.COOKING -> AgentPhase.COOKING
    }

    private fun gate(): StepGate {
        val step = session.step
        return when {
            session.phase != CookingSession.Phase.COOKING -> StepGate.NORMAL
            session.isComplete -> StepGate.COMPLETE
            step?.kind == RecipeStep.Kind.ASK -> StepGate.ASK
            step?.isGuarded == true && !session.salted -> StepGate.GUARDED_UNSALTED
            else -> StepGate.NORMAL
        }
    }

    private fun agentContext(): String {
        val plan = session.plan
        val step = session.step
        return ChefAgent.context(
            phase = agentPhase(), dish = plan?.dish,
            ingredients = plan?.ingredients?.map { ChefAgent.Companion.Ingredient(it.name, it.amount, session.pantry[it.id]?.status?.raw ?: "unchecked") } ?: emptyList(),
            ingredientsCollected = session.ingredientsCollected, stepIndex = session.currentStep, stepCount = plan?.steps?.size ?: 0,
            stepTitle = step?.title, stepInstruction = step?.instruction ?: "",
            stepQuestion = step?.takeIf { it.kind == RecipeStep.Kind.ASK }?.question, isComplete = session.isComplete,
            guardItem = step?.takeIf { it.isGuarded && !session.salted }?.guardItem, unavailable = session.unavailable, preferences = session.preferences)
    }

    suspend fun converse(heard: String) {
        val agent = agent ?: return
        state.isBusy = true; state.understanding = true; syncPrimary()
        val turn = state.activity.begin(Kind.GEMMA, "Remy is thinking", "${ChefAgent.tools(agentPhase(), gate()).size} tools offered")
        try {
            val reply = agent.respond(heard, agentPhase(), agentContext(), execute = { call -> execute(call, heard) },
                log = { event -> logAgent(event) }, gate = gate(), onEarlySpeech = { line -> say(line) })
            state.activity.finish(turn, (if (reply.speech.isEmpty()) "" else "“${reply.speech}”") +
                (if (reply.calls.isEmpty()) "" else " · calls ${reply.calls.joinToString { it.name }}"), reply.totalMs.toDouble())
            Log.i(TAG, "REMY_AGENT ${reply.totalMs} ms \"$heard\" → \"${reply.speech}\" ${reply.calls.map { it.name + it.args }}")
            state.gemmaCalls++
            if (reply.shouldSpeak && reply.speech.isNotEmpty()) say(reply.speech) else if (reply.speech.isNotEmpty()) state.line = reply.speech
        } catch (e: Throwable) {
            state.activity.finish(turn, "reply unreadable; answering plainly instead", failed = true)
            Log.e(TAG, "REMY_AGENT failed", e)
            runCatching {
                val result = withContext(Dispatchers.IO) { run(ChefPrompt.answerQuestion, ChefPrompt.question(heard, session), constrained = false) }
                if (result.text.isNotBlank()) say(result.text.trim())
            }
        } finally { state.isBusy = false; state.understanding = false; syncPrimary() }
        offerCookingIfReady()
    }

    private fun logAgent(event: AgentEvent) {
        if (event.kind == AgentEvent.Kind.TOOL) {
            state.toolCalls++
            state.activity.log(Kind.TOOL, event.title, event.detail, event.ms?.toDouble())
            Log.i(TAG, "REMY_TOOL ${event.title} ${event.ms} ms ${event.detail}")
        } else state.activity.log(Kind.GEMMA, event.title, event.detail, event.ms?.toDouble())
    }

    /** Carry out one validated tool call (AppModel.execute). Returns what Gemma should hear back, "" for nothing. */
    private suspend fun execute(call: ToolCall, heard: String): String {
        fun arg(key: String): String = call.arg(key).trim().let { if (it.lowercase() in setOf("nil", "null", "none")) "" else it }
        // The runner lock is released while a tool runs; tools that use Gemma wait for isBusy to clear.
        val wasBusy = state.isBusy
        state.isBusy = false
        try {
            return when (call.name) {
                "plan_recipe" -> if (arg("dish").isEmpty()) "" else { state.dishRequest = arg("dish"); planDish(); "" }
                "check_ingredients" -> checkIngredients() ?: ""
                "substitute_ingredient" -> {
                    val same = arg("substitute").equals(arg("ingredient"), ignoreCase = true)
                    if (session.isUnavailable(arg("substitute")) || same) {
                        session.markUnavailable(arg("ingredient")); changed()
                        "The cook does not have ${arg("substitute")} either. Suggest a different substitute, or remove the ingredient."
                    } else if (session.substitute(arg("ingredient"), arg("substitute"))) { changed(); "Recipe updated: ${arg("substitute")} replaces ${arg("ingredient")} in the list and the steps." }
                    else "${arg("ingredient")} is not in this recipe."
                }
                "have_ingredient" -> {
                    val item = session.ingredient(arg("ingredient")) ?: return "${arg("ingredient")} is not in this recipe."
                    session.setPantry(item.id, PantryStatus.SEEN); changed()
                    val left = session.plan?.ingredients?.filter { session.pantry[it.id]?.status != PantryStatus.SEEN }?.map { it.name } ?: emptyList()
                    "Marked ${item.name} as ready. " + if (left.isEmpty()) "Every ingredient is ready." else "Still needed: ${left.joinToString()}."
                }
                "add_ingredient" -> if (session.add(arg("ingredient"), arg("amount"))) { changed(); "Recipe updated: added ${arg("ingredient")}." } else "${arg("ingredient")} is already in the recipe."
                "remove_ingredient" -> if (session.remove(arg("ingredient"))) { changed(); "Recipe updated: cooking without ${arg("ingredient")}." } else "${arg("ingredient")} is not in this recipe."
                "start_cooking" -> { val ready = session.instructionsReady; beginCooking(); if (ready) "" else "The cook asked to start. Keep checking ingredients until the first cooking step is announced." }
                "next_step" -> { if (session.step?.kind == RecipeStep.Kind.ASK) announceStep() else nextStep(); "" }
                "previous_step" -> { selectStep(maxOf(0, session.currentStep - 1)); "" }
                "repeat_step" -> { announceStep(); "" }
                "check_step" -> { reviewBoard(spoken = true); "" }
                "look" -> look(arg("question").ifEmpty { heard }) ?: ""
                "find" -> if (arg("item").isEmpty()) "" else { find(arg("item")); "" }
                "save_preference" -> if (arg("value").isEmpty()) "" else { session.answer(arg("value"), heard, EvidenceOrigin.USER); changed(); announceStep("Got it, ${arg("value")}."); "" }
                "mark_added" -> { confirmSalt(); say(state.line); "" }
                "hot_object" -> if (arg("item").isEmpty()) "" else {
                    val jpeg = host.latestJpeg()
                    val marked = jpeg != null && host.markHot(listOf(arg("item")), jpeg)
                    if (marked) "Marked the ${arg("item")}; the cook is warned if the whole tracked hand enters its marked area." else "Could not find the ${arg("item")} in the camera picture."
                }
                else -> { Log.w(TAG, "REMY_AGENT ignored tool ${call.name}"); "" }
            }
        } finally { state.isBusy = wasBusy }
    }

    /** AppModel.reviewBoard: a one-frame glance (or the full check on a guarded step), applied to the session. */
    suspend fun reviewBoard(spoken: Boolean) {
        if (!state.isLoaded || state.isBusy || session.phase != CookingSession.Phase.COOKING || session.step?.kind != RecipeStep.Kind.DO) return
        val jpeg = host.latestJpeg() ?: return
        lastReview = SystemClock.elapsedRealtime()
        val guarded = session.step?.isGuarded == true
        val revision = session.revision; val id = session.id
        state.isBusy = true; syncPrimary()
        state.status = "Gemma is checking the board…"
        val entry = state.activity.begin(Kind.VISION, if (spoken) "Checking the step" else "Glance at the board")
        try {
            val task = if (guarded) ChefPrompt.board else ChefPrompt.glance
            val prompt = ChefPrompt.make(session, 1, 0.0)
            val result = withContext(Dispatchers.IO) { run(task, prompt, jpeg) }
            val observation = runCatching { if (guarded) ChefObservation.decode(result.text) else glance(result.text) }.getOrNull()
                ?: run { state.activity.finish(entry, "reply unreadable", result.ms.toDouble(), failed = true); return }
            state.activity.finish(entry, "${observation.concern} · ${observation.line}", result.ms.toDouble())
            Log.i(TAG, "REMY_BOARD ${result.ms} ms ${observation.concern} complete=${observation.stepComplete} \"${observation.line}\"")
            if (!session.apply(observation, id, revision, 0.5, 1)) { state.status = "Scene changed during the check. Discarded old result."; return }
            changed()
            state.status = if (observation.confidence < 0.7) "Gemma is uncertain. Check the evidence." else "Board checked locally."
            val now = SystemClock.elapsedRealtime()
            val mistake = observation.concern in setOf("size", "knife")
            val repeated = observation.concern == lastConcern.first && now - lastConcern.second < 30_000
            if ((spoken || (mistake && !repeated)) && observation.confidence >= 0.7 && state.reflexMs == null) {
                say(observation.line)
                if (mistake) lastConcern = observation.concern to now
            }
        } catch (e: Throwable) {
            state.activity.finish(entry, e.message ?: "failed", failed = true)
        } finally { state.isBusy = false; syncPrimary() }
    }

    /** ChefBrain.glanceObservation: a glance has no evidence sentence; 0.85 lets stepComplete surface only as a suggestion. */
    private fun glance(text: String): ChefObservation {
        val o = JSONObject(JSONOutputContract.clean(text))
        val concern = o.getString("concern").trim().lowercase()
        val line = o.getString("line").trim()
        require(concern in setOf("none", "size", "knife", "visibility", "uncertain")) { "concern is outside the allowed list" }
        require(line.isNotEmpty() && line.length <= 240) { "line is empty or too long" }
        val observation = ChefObservation(confidence = 0.85, stepComplete = o.getBoolean("stepComplete"), concern = concern,
            evidence = "Quick glance: ${if (concern == "none") "looks right" else concern}", line = line)
        require(observation.isValid) { "invalid observation" }
        return observation
    }

    // ---- Camera questions --------------------------------------------------------------------------------------

    /** ChefBrain.look: the answer from the newest frame, plus anything hot (which becomes a watched zone). */
    suspend fun look(question: String): String? {
        val jpeg = host.latestJpeg() ?: return "The camera has no picture yet."
        val entry = state.activity.begin(Kind.VISION, "Looking: $question")
        return try {
            val result = withContext(Dispatchers.IO) { run(ChefPrompt.look, ChefPrompt.look(question, session), jpeg) }
            val o = runCatching { JSONObject(JSONOutputContract.clean(result.text)) }.getOrNull()
            val answer = o?.optString("answer")?.trim() ?: result.text.trim()
            val hot = o?.optJSONArray("hot")?.let { a -> (0 until a.length()).map { a.optString(it) }.filter { it.isNotBlank() } } ?: emptyList()
            state.activity.finish(entry, answer + if (hot.isEmpty()) "" else " · hot: ${hot.joinToString()}", result.ms.toDouble())
            Log.i(TAG, "REMY_LOOK ${result.ms} ms \"$answer\" hot: $hot")
            if (hot.isNotEmpty() && state.safetyAlerts) host.markHot(hot, jpeg)
            if (answer.isEmpty()) null else "The camera shows: $answer"
        } catch (e: Throwable) { state.activity.finish(entry, e.message ?: "failed", failed = true); null }
    }

    /** "Where's the salt?" / "Which knife?": Gemma boxes it on the video (box_2d grounding). */
    suspend fun find(item: String) {
        val jpeg = host.latestJpeg() ?: run { say("I can't see the counter yet. Point the camera at it."); return }
        val query = boxQuery(item)
        val entry = state.activity.begin(Kind.VISION, "Finding $item", "locate with box_2d")
        try {
            val result = withContext(Dispatchers.IO) { run(ChefPrompt.locate(1), ChefPrompt.locate(listOf(query)), jpeg, constrained = false) }
            val box = ItemBox.parse(result.text).firstOrNull()
            state.activity.finish(entry, box?.let { String.format("boxed at %.2f, %.2f", it.x, it.y) } ?: "not found", result.ms.toDouble())
            Log.i(TAG, "REMY_FIND ${result.ms} ms \"$query\" → ${box != null}")
            if (box != null) {
                state.boxCount++
                if (item.lowercase().contains("knife") && state.knifeTracking) host.knifeBox(ItemBox("knife", box.x, box.y, box.width, box.height))
                else host.showBoxes(listOf(ItemBox(item, box.x, box.y, box.width, box.height)), 10.0)
                val tool = session.step?.tool ?: ""
                say(if (tool.isNotEmpty() && item.lowercase().contains("knife")) "Use this one for this step." else "There's the $item.")
            } else say("I can't find the $item. Hold it up to the camera.")
        } catch (e: Throwable) { state.activity.finish(entry, e.message ?: "failed", failed = true) }
    }

    suspend fun textTest() {
        val entry = state.activity.begin(Kind.GEMMA, "Local text test")
        state.isBusy = true
        try {
            val r = runner ?: return
            val result = withContext(Dispatchers.IO) { r.text(null, "Reply with exactly: Remy is ready.", 16) }
            state.gemmaCalls++; record(result)
            state.smokePassed = result.text.contains("ready", ignoreCase = true)
            state.activity.finish(entry, result.text.trim(), result.ms.toDouble())
        } catch (e: Throwable) { state.activity.finish(entry, e.message ?: "failed", failed = true) } finally { state.isBusy = false }
    }

    suspend fun describeCamera() {
        val jpeg = host.latestJpeg() ?: return
        val entry = state.activity.begin(Kind.VISION, "Describe the live camera image")
        state.isBusy = true
        try {
            val r = runner ?: return
            val result = withContext(Dispatchers.IO) { r.vision(null, "Describe this kitchen image in one short sentence.", jpeg, 48) }
            state.gemmaCalls++; state.visionChecks++; record(result)
            state.activity.finish(entry, result.text.trim(), result.ms.toDouble())
            say(result.text.trim())
        } catch (e: Throwable) { state.activity.finish(entry, e.message ?: "failed", failed = true) } finally { state.isBusy = false }
    }

    /** Gesture commands (AppModel.perform(gesture:)). */
    fun perform(gesture: String) {
        session.record("Gesture: $gesture", EvidenceOrigin.USER)
        Log.i(TAG, "REMY_GESTURE $gesture")
        val phase = session.phase
        when {
            gesture == "Open_Palm" -> { speaker.stop(); state.status = "Quiet."; state.activity.log(Kind.GESTURE, "Open palm", "chef goes quiet") }
            gesture == "Thumb_Up" && phase == CookingSession.Phase.INGREDIENTS -> { state.activity.log(Kind.GESTURE, "Thumbs up", "start cooking"); beginCooking() }
            gesture == "Thumb_Up" && phase == CookingSession.Phase.COOKING -> { state.activity.log(Kind.GESTURE, "Thumbs up", "next step"); nextStep() }
            gesture == "Thumb_Down" && phase == CookingSession.Phase.COOKING -> { state.activity.log(Kind.GESTURE, "Thumbs down", "back one step"); selectStep(maxOf(0, session.currentStep - 1)) }
            else -> state.activity.log(Kind.GESTURE, gesture.replace("_", " ").lowercase().replaceFirstChar { it.uppercase() }, "nothing to do right now")
        }
    }

    companion object {
        private const val TAG = "Remy"
        fun list(names: List<String>): String = when (names.size) {
            0 -> ""; 1 -> names[0]; 2 -> "${names[0]} and ${names[1]}"
            else -> names.dropLast(1).joinToString(", ") + " and " + names.last()
        }
        fun boxQuery(item: String): String {
            val name = item.lowercase()
            if (!name.contains("knife")) return item
            if (listOf("paring", "small", "little", "peeling", "utility").any { name.contains(it) }) return "the smallest knife"
            if (listOf("chef", "big", "large", "chopping", "santoku", "cook").any { name.contains(it) }) return "the biggest knife"
            return item
        }
    }
}
