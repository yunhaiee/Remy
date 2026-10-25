package com.yunha.remy.core

import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * The app's memory of the cook. Gemma never holds state between calls; every call is built from this.
 * The salt names below refer to the current step's `guardItem`, whatever the plan says it is.
 *
 * Kotlin port of CookingSession.swift. The Swift type is a value struct with `mutating` methods; this is a
 * mutable class, so use [copy] when a snapshot is needed. Persist with [toJson] / [fromJson].
 */
class CookingSession {
    enum class Phase { NEEDS_DISH, INGREDIENTS, COOKING }
    data class PantryItem(val status: PantryStatus, val origin: EvidenceOrigin)

    var id: String = UUID.randomUUID().toString(); private set
    var revision = 0; private set
    var plan: RecipePlan? = null; private set
    var currentStep = 0; private set
    var done: Set<String> = emptySet(); private set
    var preferences: Map<String, String> = emptyMap(); private set
    var pantry: Map<String, PantryItem> = emptyMap(); private set
    var ingredientsReviewed = false; private set
    /** Guarded additions already made, keyed by step id. */
    var added: Map<String, EvidenceOrigin> = emptyMap(); private set
    /** What the cook said they do not have, across swaps, so the chef never suggests it again. */
    private var missingItems: List<String>? = null
    val unavailable: List<String> get() = missingItems ?: emptyList()
    var zone: GuardZone? = null; private set
    var cookerPowerOn: Boolean? = null; private set
    var suggestedCompletion = false; private set
    var events: List<SessionEvent> = emptyList(); private set

    /** Swift `self = CookingSession()`. */
    private fun resetAll() {
        id = UUID.randomUUID().toString(); revision = 0; plan = null; currentStep = 0; done = emptySet()
        preferences = emptyMap(); pantry = emptyMap(); ingredientsReviewed = false; added = emptyMap()
        missingItems = null; zone = null; cookerPowerOn = null; suggestedCompletion = false; events = emptyList()
    }

    fun isUnavailable(name: String): Boolean {
        val key = name.lowercase().trimSpaces()
        return unavailable.any { it == key || sameFood(it, key) }
    }

    fun markUnavailable(name: String) {
        val key = name.lowercase().trimSpaces()
        if (key.isEmpty() || isUnavailable(key)) return
        missingItems = unavailable + key; revision += 1
    }

    /** An ingredient-only draft deliberately has no executable steps. */
    val instructionsReady: Boolean get() = plan?.problems?.isEmpty() ?: false
    val instructionsPending: Boolean get() = plan != null && !instructionsReady
    val ingredientsCollected: Boolean get() {
        val plan = plan ?: return false
        if (plan.ingredients.isEmpty()) return false
        return plan.ingredients.all { pantry[it.id]?.status == PantryStatus.SEEN }
    }
    val isComplete: Boolean get() {
        val plan = plan ?: return false
        if (plan.steps.isEmpty()) return false
        return plan.steps.all { it.id in done }
    }
    /** This requested cooking demo is armed by the cook confirming step 1, not by temperature sensing. */
    val usesCookerSafetySequence: Boolean get() {
        val plan = plan ?: return false
        val preset = IngredientDraft.preset(plan.dish)?.presetInstructions ?: return false
        return plan == preset
    }
    /**
     * Heat caution persists from confirmation of the first step through completion of the whole dish.
     * Reporting power off does not establish that a tracked vessel has cooled.
     */
    val cookerSafetyArmed: Boolean get() {
        if (phase != Phase.COOKING || isComplete) return false
        val first = plan?.steps?.firstOrNull() ?: return false
        return first.id in done
    }

    fun reportCookerPower(on: Boolean) {
        if (!usesCookerSafetySequence || phase != Phase.COOKING) return
        cookerPowerOn = on; revision += 1
        record(if (on) "Cook reported the cooker switched on." else "Cook reported the cooker switched off; heat-caution monitoring stays active until the dish is complete.", EvidenceOrigin.USER)
    }

    /**
     * Retire only the old app-authored preset. Preserve checked ingredients, but never transfer
     * completion of the old draining step into confirmation that the new cooker has been switched on.
     */
    fun refreshLegacyPastaInstructions(): Boolean {
        val plan = plan ?: return false
        val preset = IngredientDraft.preset(plan.dish)?.presetInstructions ?: return false
        if (plan.ingredients != preset.ingredients || plan.steps.map { it.id } != listOf("cook_pasta", "prepare", "combine") ||
            plan.steps.firstOrNull()?.instruction != "Cook pasta in plain water according to its package directions, then drain and let it cool.") return false
        this.plan = preset; done = emptySet(); currentStep = 0; ingredientsReviewed = false; cookerPowerOn = null
        added = emptyMap(); zone = null; suggestedCompletion = false; revision += 1
        return true
    }

    /** Remove only the app-authored third step; earlier work and ingredient confirmations survive. */
    fun removeRetiredPastaFinalStep(): Boolean {
        val plan = plan ?: return false
        val preset = IngredientDraft.preset(plan.dish)?.presetInstructions ?: return false
        if (plan.ingredients != preset.ingredients || plan.steps.size != 3 || plan.steps.take(2) != preset.steps ||
            plan.steps[2].id !in listOf("combine", "portion_salad")) return false
        this.plan = preset
        val retained = preset.steps.map { it.id }.toSet()
        done = done.intersect(retained); added = added.filterKeys { it in retained }
        currentStep = minOf(currentStep, preset.steps.size - 1)
        zone = null; suggestedCompletion = false; revision += 1
        return true
    }

    val phase: Phase get() = if (plan == null) Phase.NEEDS_DISH else if (ingredientsReviewed && instructionsReady) Phase.COOKING else Phase.INGREDIENTS
    val step: RecipeStep? get() = plan?.steps?.getOrNull(currentStep)
    val isLastStep: Boolean get() = plan?.let { currentStep >= it.steps.size - 1 } ?: true
    val salted: Boolean get() = step?.let { added[it.id] != null } ?: false
    val saltOrigin: EvidenceOrigin? get() = step?.let { added[it.id] }
    val guardArmed: Boolean get() = phase == Phase.COOKING && step?.isGuarded == true && salted && zone != null
    /** Earlier steps this one depends on that the cook has not finished. */
    val unmetNeeds: List<RecipeStep> get() {
        val plan = plan ?: return emptyList()
        val step = step ?: return emptyList()
        return plan.steps.filter { it.id in step.needs && it.id !in done }
    }

    fun record(message: String, origin: EvidenceOrigin) {
        val next = events + SessionEvent(message, origin)
        events = if (next.size > 150) next.drop(next.size - 150) else next
    }

    fun start(plan: RecipePlan) {
        if (plan.problems.isNotEmpty()) return
        resetAll()
        this.plan = plan
        record("Gemma planned ${plan.dish}: ${plan.ingredients.size} ingredients, ${plan.steps.size} steps.", EvidenceOrigin.SYSTEM)
    }

    /** Publish the first stage immediately. Pantry controls work while instructions are prepared. */
    fun startIngredients(draft: IngredientDraft): Boolean {
        if (draft.problems.isNotEmpty()) return false
        resetAll()
        plan = RecipePlan(draft.dish, draft.ingredients, emptyList())
        record("Ingredients ready for ${draft.dish}; instructions are being prepared.", EvidenceOrigin.SYSTEM)
        return true
    }

    /**
     * Replace only the empty instruction list. Pantry review increments revision, so revision alone
     * is intentionally not a stale-result check: a user's confirmations must survive this response.
     * Ingredient additions/removals/swaps do invalidate the request and require a new second stage.
     */
    fun applyInstructions(complete: RecipePlan, expectedSessionID: String, expectedIngredients: List<Ingredient>): Boolean {
        val current = plan
        if (id != expectedSessionID || !instructionsPending || phase != Phase.INGREDIENTS || current == null ||
            current.ingredients != expectedIngredients || complete.dish != current.dish ||
            complete.ingredients != expectedIngredients || complete.problems.isNotEmpty()) return false
        plan = complete
        revision += 1
        record("Gemma prepared ${complete.steps.size} instructions; ingredient review was preserved.", EvidenceOrigin.SYSTEM)
        return true
    }

    fun applyIngredientCheck(check: IngredientCheck, expectedSessionID: String, expectedRevision: Int): Boolean {
        if (expectedSessionID != id || expectedRevision != revision || phase != Phase.INGREDIENTS) return false
        // Camera evidence adds up: an item once seen stays seen when the next frame shows something else (the cook
        // holds items up one by one); unsure can become seen. The cook's word always wins.
        fun rank(status: PantryStatus) = if (status == PantryStatus.SEEN) 2 else if (status == PantryStatus.UNSURE) 1 else 0
        val next = pantry.toMutableMap()
        for (item in check.items) {
            if (next[item.id]?.origin == EvidenceOrigin.USER) continue
            val old = next[item.id]
            if (old != null && rank(old.status) > rank(item.status)) continue
            next[item.id] = PantryItem(item.status, EvidenceOrigin.CAMERA)
        }
        pantry = next
        revision += 1
        val seen = check.items.count { it.status == PantryStatus.SEEN }
        record("Gemma checked the counter: $seen of ${plan?.ingredients?.size ?: 0} ingredients seen.", EvidenceOrigin.CAMERA)
        return true
    }

    /** The cook's word overrides the camera, e.g. "yes, that white powder is salt". */
    fun setPantry(ingredientID: String, status: PantryStatus) {
        val item = plan?.ingredients?.firstOrNull { it.id == ingredientID } ?: return
        pantry = pantry + (ingredientID to PantryItem(status, EvidenceOrigin.USER))
        revision += 1
        record("Cook marked ${item.name} as ${status.raw}.", EvidenceOrigin.USER)
    }

    /** The recipe ingredient a spoken name refers to ("vinegar" finds "red wine vinegar"). */
    fun ingredient(named: String): Ingredient? {
        val key = named.lowercase().trimSpaces()
        val plan = plan
        if (key.isEmpty() || plan == null) return null
        return plan.ingredients.firstOrNull { it.name.lowercase() == key || it.id == key }
            ?: plan.ingredients.firstOrNull { key.contains(it.name.lowercase()) || it.name.lowercase().contains(key) }
            ?: plan.ingredients.firstOrNull { sameFood(it.name.lowercase(), key) }
    }

    /**
     * Swap an ingredient in the recipe itself: the list and every step that mentions it change, so the screen,
     * the camera check and later answers all use the new one. It starts unchecked.
     */
    fun substitute(name: String, with: String): Boolean {
        val new = with.trimSpaces()
        val plan = plan ?: return false
        val old = ingredient(name) ?: return false
        if (new.isEmpty() || new.lowercase() == old.name.lowercase()) return false
        // Replacing it with something already in the recipe ("use what I have") just means going without it.
        if (plan.ingredients.any { it.id != old.id && it.name.lowercase() == new.lowercase() }) return remove(old.name)
        fun swap(text: String) = text.replace(old.name, new, ignoreCase = true)
        val ingredients = plan.ingredients.map { if (it.id == old.id) Ingredient(old.id, new, old.amount) else it }
        val steps = plan.steps.map { step ->
            RecipeStep(id = step.id, kind = step.kind, title = swap(step.title), instruction = swap(step.instruction), needs = step.needs,
                doneWhen = swap(step.doneWhen), wrongSize = swap(step.wrongSize), tool = step.tool,
                guardItem = if (step.guardItem.lowercase() == old.name.lowercase()) new else step.guardItem,
                question = swap(step.question), saves = step.saves, warning = swap(step.warning))
        }
        this.plan = RecipePlan(plan.dish, ingredients, steps)
        pantry = pantry - old.id; revision += 1; markUnavailable(old.name)
        record("Using $new instead of ${old.name}.", EvidenceOrigin.USER)
        return true
    }

    /** Add an ingredient the plan forgot ("add lime"). It starts unchecked. */
    fun add(name: String, amount: String): Boolean {
        val new = name.trimSpaces()
        val plan = plan ?: return false
        if (new.isEmpty() || ingredient(new)?.name?.lowercase() == new.lowercase()) return false
        var id = new.lowercase().replace(Regex("[^a-z0-9]+"), "_")
        while (plan.ingredients.any { it.id == id }) id += "_2"
        this.plan = RecipePlan(plan.dish, plan.ingredients + Ingredient(id, new, amount), plan.steps)
        revision += 1
        record("Added $new to the ingredients.", EvidenceOrigin.USER)
        return true
    }

    /** Cook without an ingredient: it leaves the list (steps keep their text; the chef says to skip it). */
    fun remove(name: String): Boolean {
        val plan = plan ?: return false
        val old = ingredient(name) ?: return false
        this.plan = RecipePlan(plan.dish, plan.ingredients.filter { it.id != old.id }, plan.steps)
        pantry = pantry - old.id; revision += 1; markUnavailable(old.name)
        record("Cooking without ${old.name}.", EvidenceOrigin.USER)
        return true
    }

    /** Keep checked ingredients while discarding instructions that still use a removed food. */
    fun removeForReplanning(name: String): Boolean {
        val old = ingredient(name) ?: return false
        if (!remove(name)) return false
        val plan = plan ?: return false
        this.plan = RecipePlan(plan.dish, plan.ingredients, emptyList())
        preferences = preferences - old.id
        currentStep = 0; done = emptySet(); added = emptyMap(); ingredientsReviewed = false
        zone = null; suggestedCompletion = false; revision += 1
        return true
    }

    fun beginCooking() {
        if (phase != Phase.INGREDIENTS || !instructionsReady) return
        ingredientsReviewed = true; currentStep = 0; revision += 1
        record("Cook started cooking.", EvidenceOrigin.USER)
    }

    fun selectStep(index: Int) {
        val plan = plan ?: return
        if (index !in plan.steps.indices || index == currentStep) return
        currentStep = index; suggestedCompletion = false; zone = null; revision += 1
        record("Cook selected step ${index + 1}: ${plan.steps[index].title}", EvidenceOrigin.USER)
    }

    /** The cook confirms the current step and moves on. Ask steps finish through `answer` instead. */
    fun nextStep() {
        val step = step ?: return
        if (step.kind != RecipeStep.Kind.DO) return
        done = done + step.id
        if (usesCookerSafetySequence && step.id == "cook_pasta") cookerPowerOn = true
        if (isLastStep) { revision += 1; record("Cook finished ${plan?.dish ?: "the dish"}.", EvidenceOrigin.USER); return }
        selectStep(currentStep + 1)
    }

    fun answer(value: String, heard: String?, origin: EvidenceOrigin) {
        val value = value.trim()
        val step = step ?: return
        if (step.kind != RecipeStep.Kind.ASK || value.isEmpty() || value.length > 80) return
        preferences = preferences + (step.saves to value)
        done = done + step.id; revision += 1
        record("${step.saves}: $value${heard?.let { " (heard: \"$it\")" } ?: ""}", origin)
        if (!isLastStep) selectStep(currentStep + 1)
    }

    fun markZone(zone: GuardZone) {
        val step = step ?: return
        if (!zone.isValid || !step.isGuarded) return
        this.zone = zone; revision += 1
        record("Cook marked the ${step.guardItem} location. Re-mark after moving it.", EvidenceOrigin.USER)
    }

    fun invalidateZone() {
        // A source switch or pause also invalidates pending observations when no zone exists.
        revision += 1
        suggestedCompletion = false
        if (zone == null) return
        zone = null
        record("Camera moved or scene interrupted. Guarded item location needs setup again.", EvidenceOrigin.SYSTEM)
    }

    fun confirmSalt() {
        val step = step ?: return
        if (!step.isGuarded || phase != Phase.COOKING || salted) return
        added = added + (step.id to EvidenceOrigin.USER); revision += 1
        record("Cook confirmed adding ${step.guardItem}.", EvidenceOrigin.USER)
    }

    fun allowMoreSalt() {
        val step = step ?: return
        if (!step.isGuarded) return
        added = added - step.id; revision += 1
        record("Cook chose to add more ${step.guardItem} after tasting.", EvidenceOrigin.USER)
    }

    /** A request can only update the state it actually observed. A single frame cannot establish a pour. `frameAge` in seconds. */
    fun apply(observation: ChefObservation, expectedSessionID: String, expectedRevision: Int, frameAge: Double, frameCount: Int): Boolean {
        val step = step
        if (expectedSessionID != id || expectedRevision != revision || !frameAge.isFinite() || frameAge !in 0.0..12.0 ||
            !observation.isValid || phase != Phase.COOKING || step == null || step.kind != RecipeStep.Kind.DO) return false
        record(observation.evidence, EvidenceOrigin.CAMERA)
        suggestedCompletion = observation.stepComplete && observation.confidence >= 0.85
        if (step.isGuarded && observation.saltAdded && observation.confidence >= 0.9 && frameCount >= 2 && !salted) {
            added = added + (step.id to EvidenceOrigin.CAMERA); revision += 1
            record("Gemma observed ${step.guardItem} being added in the image sequence.", EvidenceOrigin.CAMERA)
        }
        return true
    }

    /** After a relaunch the camera has almost certainly moved, so a saved location is never trusted. */
    fun restoredAfterLaunch() {
        zone = null; suggestedCompletion = false; revision += 1
        record("Session restored after the app restarted.", EvidenceOrigin.SYSTEM)
    }

    // Persistence

    fun toJsonObject(): JSONObject = JSONObject().apply {
        put("id", id); put("revision", revision)
        plan?.let { put("plan", it.toJsonObject()) }
        put("currentStep", currentStep)
        put("done", Json.array(done))
        put("preferences", JSONObject().apply { preferences.forEach { (k, v) -> put(k, v) } })
        put("pantry", JSONObject().apply {
            pantry.forEach { (k, v) -> put(k, JSONObject().put("status", v.status.raw).put("origin", v.origin.raw)) }
        })
        put("ingredientsReviewed", ingredientsReviewed)
        put("added", JSONObject().apply { added.forEach { (k, v) -> put(k, v.raw) } })
        missingItems?.let { put("missingItems", Json.array(it)) }
        zone?.let { put("zone", it.toJsonObject()) }
        cookerPowerOn?.let { put("cookerPowerOn", it) }
        put("suggestedCompletion", suggestedCompletion)
        put("events", JSONArray().apply { events.forEach { put(it.toJsonObject()) } })
    }

    fun toJson(): String = toJsonObject().toString()

    /** An independent snapshot (Swift structs copy on assignment). */
    fun copy(): CookingSession = fromJson(toJson())!!

    companion object {
        /** "white vinegar" and "white wine vinegar": every word of the shorter name is in the longer one. */
        fun sameFood(a: String, b: String): Boolean {
            val wa = a.split(" ").filter { it.isNotEmpty() }.toSet()
            val wb = b.split(" ").filter { it.isNotEmpty() }.toSet()
            if (wa.isEmpty() || wb.isEmpty()) return false
            return wb.containsAll(wa) || wa.containsAll(wb)
        }

        /** Restores a saved session; unknown keys (retired runtime state) are ignored and dropped on the next save. */
        fun fromJson(s: String): CookingSession? = try {
            val o = Json.parseObject(s)
            CookingSession().apply {
                id = Json.str(o, "id")
                revision = Json.int(o, "revision")
                plan = Json.optObj(o, "plan")?.let(RecipePlan::fromJsonObject)
                currentStep = Json.int(o, "currentStep")
                done = (Json.optStrings(o, "done") ?: emptyList()).toSet()
                preferences = Json.optObj(o, "preferences")?.let { p -> Json.keys(p).associateWith { Json.str(p, it) } } ?: emptyMap()
                pantry = Json.optObj(o, "pantry")?.let { p ->
                    Json.keys(p).associateWith { k ->
                        val item = Json.obj(p, k)
                        PantryItem(PantryStatus.of(Json.str(item, "status")), EvidenceOrigin.of(Json.str(item, "origin")))
                    }
                } ?: emptyMap()
                ingredientsReviewed = Json.optBool(o, "ingredientsReviewed") ?: false
                added = Json.optObj(o, "added")?.let { a -> Json.keys(a).associateWith { EvidenceOrigin.of(Json.str(a, it)) } } ?: emptyMap()
                missingItems = Json.optStrings(o, "missingItems")
                zone = Json.optObj(o, "zone")?.let(GuardZone::fromJsonObject)
                cookerPowerOn = Json.optBool(o, "cookerPowerOn")
                suggestedCompletion = Json.optBool(o, "suggestedCompletion") ?: false
                events = if (o.has("events")) Json.objects(o, "events").map(SessionEvent::fromJsonObject) else emptyList()
            }
        } catch (_: Exception) { null }
    }
}

/** Swift `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not newlines. */
internal fun String.trimSpaces(): String = trim { it == ' ' || it == '\t' || (it.isWhitespace() && it != '\n' && it != '\r') }
