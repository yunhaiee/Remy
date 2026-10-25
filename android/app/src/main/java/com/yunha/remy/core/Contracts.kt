package com.yunha.remy.core

import java.util.UUID
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

// Kotlin port of ChefCore/Contracts.swift. Point2 lives in HazardWatch.kt. Codable structs get explicit
// org.json encode/decode with Swift JSONDecoder strictness: required keys must be present with the right type,
// optional keys may be missing or null.

data class GuardZone(val center: Point2, val radius: Double = 0.12) {
    val isValid: Boolean get() = center.isValid && radius.isFinite() && radius in 0.03..0.35
    fun contains(point: Point2): Boolean = point.distance(center) <= radius

    fun toJsonObject(): JSONObject =
        JSONObject().put("center", JSONObject().put("x", center.x).put("y", center.y)).put("radius", radius)

    companion object {
        fun fromJsonObject(o: JSONObject): GuardZone {
            val c = Json.obj(o, "center")
            return GuardZone(Point2(Json.num(c, "x"), Json.num(c, "y")), Json.num(o, "radius"))
        }
    }
}

data class Ingredient(val id: String, val name: String, val amount: String) {
    fun toJsonObject(): JSONObject = JSONObject().put("id", id).put("name", name).put("amount", amount)

    companion object {
        fun fromJsonObject(o: JSONObject): Ingredient = Ingredient(Json.str(o, "id"), Json.str(o, "name"), Json.str(o, "amount"))
    }
}

/**
 * One node of a Gemma-planned recipe graph. `needs` lists earlier step ids that must be done first.
 * Unused text fields are empty strings so the model always emits the same shape.
 */
data class RecipeStep(
    val id: String,
    val kind: Kind = Kind.DO,
    val title: String,
    val instruction: String,
    val needs: List<String> = emptyList(),
    val doneWhen: String = "",
    val wrongSize: String = "",
    val tool: String = "",
    /** An irreversible single addition, e.g. "salt". Once added, reaching for it again arms the fast-loop warning. */
    val guardItem: String = "",
    /** Ask steps: the question for the cook and the preference key the answer is saved under. */
    val question: String = "",
    val saves: String = "",
    /** Said the moment a do step starts, before anything irreversible can happen ("colander in the sink first"). */
    val warning: String = "",
) {
    enum class Kind(val raw: String) {
        DO("do"), ASK("ask");
        companion object { fun of(raw: String): Kind = entries.firstOrNull { it.raw == raw } ?: throw JSONException("unknown kind $raw") }
    }

    val isGuarded: Boolean get() = kind == Kind.DO && guardItem.isNotEmpty()
    /** A pot, pan or stove step: the app marks the hot object so a hand reaching it is warned at once. */
    val involvesHeat: Boolean get() = warning == RecipePlan.HEAT_WARNING

    fun toJsonObject(): JSONObject = JSONObject().put("id", id).put("kind", kind.raw).put("title", title)
        .put("instruction", instruction).put("needs", Json.array(needs)).put("doneWhen", doneWhen).put("wrongSize", wrongSize)
        .put("tool", tool).put("guardItem", guardItem).put("question", question).put("saves", saves).put("warning", warning)

    companion object {
        /**
         * `warning` is added by the app, not the model. Gemma leaves out fields that do not apply to a step
         * (writing them as "" cost about a quarter of the plan's output tokens), so only the core fields are required.
         */
        fun fromJsonObject(o: JSONObject): RecipeStep = RecipeStep(
            id = Json.str(o, "id"), kind = Kind.of(Json.str(o, "kind")), title = Json.str(o, "title"),
            instruction = Json.str(o, "instruction"), needs = Json.optStrings(o, "needs") ?: emptyList(),
            doneWhen = Json.optStr(o, "doneWhen"), wrongSize = Json.optStr(o, "wrongSize"), tool = Json.optStr(o, "tool"),
            guardItem = Json.optStr(o, "guardItem"), question = Json.optStr(o, "question"), saves = Json.optStr(o, "saves"),
            warning = Json.optStr(o, "warning"))
    }
}

/** The whole recipe, planned once by Gemma from the dish name and then held by the app, not the model. */
data class RecipePlan(val dish: String, val ingredients: List<Ingredient>, val steps: List<RecipeStep>) {

    /** Empty when the graph is usable. Steps must already be in an order where every `needs` points backwards. */
    val problems: List<String> get() {
        val found = mutableListOf<String>()
        if (dish.isEmpty() || dish.length > 80) found.add("dish name must be 1-80 characters")
        if (ingredients.size !in 1..20) found.add("list 1-20 ingredients")
        if (ingredients.map { it.id }.toSet().size != ingredients.size) found.add("ingredient ids must be unique")
        if (ingredients.any { it.id.isEmpty() || it.name.isEmpty() }) found.add("every ingredient needs an id and name")
        if (steps.size !in 2..MAX_STEPS) found.add("use 2-$MAX_STEPS steps")
        val seen = mutableSetOf<String>()
        for (step in steps) {
            if (step.id.isEmpty() || step.id in seen) found.add("step id '${step.id}' is empty or repeated")
            if (step.title.isEmpty()) found.add("step ${step.id} needs a title")
            for (need in step.needs) if (need !in seen) found.add("step ${step.id} needs '$need', which is not an earlier step")
            when {
                step.kind == RecipeStep.Kind.DO && step.doneWhen.isEmpty() -> found.add("step ${step.id} needs doneWhen")
                step.kind == RecipeStep.Kind.ASK && (step.question.isEmpty() || step.saves.isEmpty()) ->
                    found.add("ask step ${step.id} needs question and saves")
            }
            seen.add(step.id)
        }
        // Only structural breaks are rejected (a re-plan costs ~20 s live). Content issues such as a salt step
        // without a preference question are repaired in `normalized` instead.
        return found
    }

    /**
     * Makes the graph consistent where a rule is mechanical; small models often fill every field or forget one.
     * - Fields that do not belong to a step's kind are cleared; ids used as names get spaces.
     * - A do step that uses a preference answer becomes the guarded step for it: the addition happens once
     *   there, so the fast loop can warn on a second reach.
     */
    val normalized: RecipePlan get() {
        // Steps never refer to ingredient ids, so a repeated id is renamed instead of costing a full re-plan.
        val seenIDs = mutableMapOf<String, Int>()
        val uniqueIngredients = ingredients.map { item ->
            val count = (seenIDs[item.id] ?: 0) + 1
            seenIDs[item.id] = count
            Ingredient(if (count == 1) item.id else "${item.id}_$count", item.name.replace("_", " "), item.amount)
        }
        // A seasoning a step adds once (or an ask step saves) belongs on the ingredient list, even when the plan
        // forgot it there; the ingredient check and the screen then include it.
        val listed = uniqueIngredients.map { it.name.lowercase() }.toSet()
        val seasonings = steps.flatMap { listOf(it.guardItem, if (it.kind == RecipeStep.Kind.ASK) it.saves else "") }
            .map { it.replace("_", " ").lowercase() }
            .filter { it.isNotEmpty() && it !in listed && it in listOf("salt", "pepper", "sugar") }
        val completeIngredients = uniqueIngredients + seasonings.distinct().map { Ingredient(it.replace(" ", "_"), it, "to taste") }
        // The core promise: a one-way seasoning is asked about first, then guarded. If the plan forgot the
        // question, it is inserted before the first step that adds the salt; an ask step is linked to the later
        // step that mentions what it saves.
        val steps = this.steps.toMutableList()
        val hasSalt = completeIngredients.any { it.name.lowercase().contains("salt") }
        if (hasSalt && steps.none { it.kind == RecipeStep.Kind.ASK && it.saves.contains("salt") }) {
            val target = steps.indexOfFirst { it.kind == RecipeStep.Kind.DO && "${it.title} ${it.instruction}".lowercase().contains("salt") }
            if (target >= 0) {
                val id = if (steps.any { it.id == "ask_salt" }) "ask_salt_2" else "ask_salt"
                val salted = steps[target]
                steps[target] = salted.copy(needs = salted.needs + id, warning = "")
                steps.add(target, RecipeStep(id = id, kind = RecipeStep.Kind.ASK, title = "Salt preference",
                    instruction = "Ask how salty the cook likes it.", question = "How salty do you like it?", saves = "salt"))
            }
        }
        for ((index, ask) in steps.toList().withIndex()) {
            if (!(ask.kind == RecipeStep.Kind.ASK && ask.saves.isNotEmpty() && steps.none { it.needs.contains(ask.id) })) continue
            val word = ask.saves.replace("_", " ").lowercase()
            val target = steps.indices.firstOrNull {
                it > index && steps[it].kind == RecipeStep.Kind.DO && "${steps[it].title} ${steps[it].instruction}".lowercase().contains(word)
            }
            if (target != null) steps[target] = steps[target].copy(needs = steps[target].needs + ask.id, warning = "")
        }
        val asks = LinkedHashMap<String, RecipeStep>()
        for (step in steps) if (step.kind == RecipeStep.Kind.ASK && step.id !in asks) asks[step.id] = step
        // needs may only name earlier steps; Gemma sometimes lists ingredients there ("mash_avocado needs avocado"),
        // which says nothing about order, so those entries are dropped instead of rejecting the whole plan.
        val earlier = mutableMapOf<String, Int>()
        steps.forEachIndexed { index, step -> if (step.id !in earlier) earlier[step.id] = index }
        return RecipePlan(dish, completeIngredients, steps.mapIndexed { index, original ->
            val step = RecipeStep(id = original.id, kind = original.kind, title = original.title, instruction = original.instruction,
                needs = original.needs.filter { need -> earlier[need]?.let { it < index } ?: false },
                doneWhen = original.doneWhen, wrongSize = original.wrongSize, tool = original.tool,
                guardItem = original.guardItem, question = original.question, saves = original.saves)
            if (step.kind != RecipeStep.Kind.DO) {
                return@mapIndexed RecipeStep(id = step.id, kind = RecipeStep.Kind.ASK, title = step.title, instruction = step.instruction,
                    needs = step.needs, question = step.question, saves = step.saves)
            }
            var guardItem = step.guardItem.replace("_", " ")
            var instruction = step.instruction
            // Prefer the answer the step text mentions, then salt, the classic one-way addition.
            val used = step.needs.mapNotNull { asks[it]?.saves?.replace("_", " ") }.filter { it.isNotEmpty() }
            val text = "${step.title} ${step.instruction}".lowercase()
            if (guardItem.isEmpty()) {
                val item = used.firstOrNull { text.contains(it) } ?: used.firstOrNull { it.contains("salt") } ?: used.firstOrNull()
                if (item != null) {
                    guardItem = item
                    if (!instruction.lowercase().contains(guardItem)) instruction += " Add the $guardItem once, to taste."
                }
            }
            RecipeStep(id = step.id, kind = RecipeStep.Kind.DO, title = step.title, instruction = instruction, needs = step.needs,
                // A missing doneWhen would cost a whole re-plan (~20 s); the instruction is a usable target.
                doneWhen = if (step.doneWhen.isEmpty()) step.instruction else step.doneWhen,
                wrongSize = step.wrongSize, tool = step.tool, guardItem = guardItem,
                warning = warning(step, guardItem))
        })
    }

    fun toJsonObject(): JSONObject = JSONObject().put("dish", dish)
        .put("ingredients", JSONArray().apply { ingredients.forEach { put(it.toJsonObject()) } })
        .put("steps", JSONArray().apply { steps.forEach { put(it.toJsonObject()) } })

    fun toJson(): String = toJsonObject().toString()

    companion object {
        const val MAX_STEPS = 12
        /**
         * Warnings come from rules, not the model: a 2B model warns about everything, and these are the
         * moments that cannot be undone. Spoken as the step starts, before the mistake can happen.
         */
        const val HEAT_WARNING = "Turn the pan handle inward and keep your hands clear of the heat."

        internal fun warning(step: RecipeStep, guardItem: String): String {
            val text = "${step.title} ${step.instruction}".lowercase()
            fun has(vararg words: String): Boolean = words.any { Regex("\\b$it\\b").containsMatchIn(text) }
            if (has("drain", "strain", "pour off")) return "Put the colander in the sink before you pour."
            if (guardItem.isNotEmpty()) return "Taste first. The $guardItem can't come back out."
            if (has("fry", "sear", "sauté", "saute", "pan", "hot oil", "skillet", "griddle", "boil", "boiling", "stove", "toast")) {
                return HEAT_WARNING
            }
            if (has("discard", "throw away", "throw out")) return "Check what you're throwing out before it goes in the bin."
            return ""
        }

        fun fromJsonObject(o: JSONObject): RecipePlan = RecipePlan(Json.str(o, "dish"),
            Json.objects(o, "ingredients").map(Ingredient::fromJsonObject), Json.objects(o, "steps").map(RecipeStep::fromJsonObject))

        /** Throws CoreError.InvalidPlan or a JSONException. */
        fun decode(text: String): RecipePlan {
            val plan = fromJsonObject(Json.parseObject(modelJSON(text))).normalized
            if (plan.problems.isNotEmpty()) throw CoreError.InvalidPlan(plan.problems)
            return plan
        }
    }
}

enum class PantryStatus(val raw: String) {
    SEEN("seen"), MISSING("missing"), UNSURE("unsure");
    companion object { fun of(raw: String): PantryStatus = entries.firstOrNull { it.raw == raw } ?: throw JSONException("unknown status $raw") }
}

/** Gemma's look at the counter before cooking. Look-alikes such as salt and sugar should come back unsure. */
data class IngredientCheck(val items: List<Item>, val line: String) {
    data class Item(val id: String, val status: PantryStatus)

    companion object {
        /**
         * Reads the compact reply ({"seen":[ids],"unsure":[ids]}: anything not listed is missing, so Gemma writes a
         * few ids instead of a status for every ingredient) or the older per-item form.
         */
        fun decode(text: String, plan: RecipePlan): IngredientCheck {
            val json = Json.parseObject(modelJSON(text))
            val known = plan.ingredients.map { it.id }.toSet()
            val compact: Pair<List<String>, List<String>>? = try {
                Json.strings(json, "seen") to (Json.optStrings(json, "unsure") ?: emptyList())
            } catch (_: JSONException) { null }
            if (compact != null) {
                val (seen, unsure) = compact
                if (!(seen + unsure).all { it in known }) throw CoreError.InvalidObservation()
                val items = plan.ingredients.map { item ->
                    Item(item.id, if (item.id in seen) PantryStatus.SEEN else if (item.id in unsure) PantryStatus.UNSURE else PantryStatus.MISSING)
                }
                return IngredientCheck(items, "")
            }
            val check = IngredientCheck(Json.objects(json, "items").map { Item(Json.str(it, "id"), PantryStatus.of(Json.str(it, "status"))) },
                Json.str(json, "line"))
            if (!check.items.all { it.id in known }) throw CoreError.InvalidObservation()
            return check
        }
    }
}

/** What Gemma heard in a spoken answer. `value` is the short normalized answer saved as a preference. */
data class HeardAnswer(val heard: String, val value: String, val line: String) {
    companion object {
        fun decode(text: String): HeardAnswer {
            val o = Json.parseObject(modelJSON(text))
            val answer = HeardAnswer(Json.str(o, "heard"), Json.str(o, "value"), Json.str(o, "line"))
            if (answer.value.isEmpty() || answer.value.length > 80 || answer.line.isEmpty()) throw CoreError.InvalidObservation()
            return answer
        }
    }
}

private val NEWLINE_CHARS = charArrayOf('\n', '\u000B', '\u000C', '\r', '\u0085', ' ', ' ')

/** Swift `components(separatedBy: .newlines)`: every newline character separates, so "\r\n" yields an empty part. */
internal fun splitNewlines(text: String): List<String> = text.split(*NEWLINE_CHARS)

/** Accepts bare JSON or a single fenced block, which models sometimes add even under a schema. */
internal fun modelJSON(text: String): String {
    val cleaned = text.trim()
    if (!cleaned.startsWith("```")) return cleaned
    val lines = splitNewlines(cleaned)
    if (lines.size < 3 || lines.last() != "```") throw CoreError.InvalidObservation()
    return lines.drop(1).dropLast(1).joinToString("\n")
}

data class ChefObservation(
    val confidence: Double,
    val saltAdded: Boolean = false,
    val stepComplete: Boolean = false,
    val concern: String = "none",
    val evidence: String,
    val line: String,
) {
    val isValid: Boolean get() = confidence.isFinite() && confidence in 0.0..1.0 &&
        concern in listOf("none", "size", "knife", "visibility", "uncertain") &&
        evidence.isNotEmpty() && evidence.length <= 500 && line.isNotEmpty() && line.length <= 240

    companion object {
        fun decode(text: String): ChefObservation {
            val o = Json.parseObject(modelJSON(text))
            val result = ChefObservation(Json.num(o, "confidence"), Json.bool(o, "saltAdded"), Json.bool(o, "stepComplete"),
                Json.str(o, "concern"), Json.str(o, "evidence"), Json.str(o, "line"))
            if (!result.isValid) throw CoreError.InvalidObservation()
            return result
        }
    }
}

sealed class CoreError(message: String) : Exception(message) {
    class InvalidObservation : CoreError("Gemma's reply did not match the expected format.")
    class InvalidPlan(val problems: List<String>) :
        CoreError("Gemma's recipe plan was not usable: ${problems.take(3).joinToString("; ")}.")
}

enum class EvidenceOrigin(val raw: String) {
    CAMERA("camera"), USER("user"), SYSTEM("system");
    companion object { fun of(raw: String): EvidenceOrigin = entries.firstOrNull { it.raw == raw } ?: throw JSONException("unknown origin $raw") }
}

/** `timestamp` is epoch milliseconds (Swift: Date). */
data class SessionEvent(val id: String, val timestamp: Long, val origin: EvidenceOrigin, val message: String) {
    constructor(message: String, origin: EvidenceOrigin) :
        this(UUID.randomUUID().toString(), System.currentTimeMillis(), origin, message)

    fun toJsonObject(): JSONObject =
        JSONObject().put("id", id).put("timestamp", timestamp).put("origin", origin.raw).put("message", message)

    companion object {
        fun fromJsonObject(o: JSONObject): SessionEvent =
            SessionEvent(Json.str(o, "id"), Json.num(o, "timestamp").toLong(), EvidenceOrigin.of(Json.str(o, "origin")), Json.str(o, "message"))
    }
}

/** Strict typed accessors over org.json, mirroring Swift Decodable behaviour. */
internal object Json {
    /** One complete top-level object or array and nothing after it (Swift JSONSerialization without fragments). */
    fun parse(text: String): Any {
        val tokener = JSONTokener(text)
        val value = tokener.nextValue()
        if (value !is JSONObject && value !is JSONArray) throw JSONException("not a JSON object or array")
        if (tokener.nextClean() != '\u0000') throw JSONException("trailing content after JSON")
        return value
    }

    fun parseObject(text: String): JSONObject = parse(text) as? JSONObject ?: throw JSONException("expected a JSON object")

    fun isJson(text: String): Boolean = try { parse(text); true } catch (_: Exception) { false }

    private fun present(o: JSONObject, key: String): Any? = o.opt(key).takeUnless { it == null || it == JSONObject.NULL }

    fun str(o: JSONObject, key: String): String = present(o, key) as? String ?: throw JSONException("missing string $key")
    fun optStr(o: JSONObject, key: String): String = when (val v = present(o, key)) {
        null -> ""; is String -> v; else -> throw JSONException("$key is not a string")
    }
    fun num(o: JSONObject, key: String): Double = when (val v = present(o, key)) {
        is Number -> v.toDouble(); else -> throw JSONException("missing number $key")
    }
    fun int(o: JSONObject, key: String): Int = num(o, key).toInt()
    fun bool(o: JSONObject, key: String): Boolean = present(o, key) as? Boolean ?: throw JSONException("missing bool $key")
    fun optBool(o: JSONObject, key: String): Boolean? = when (val v = present(o, key)) {
        null -> null; is Boolean -> v; else -> throw JSONException("$key is not a bool")
    }
    fun obj(o: JSONObject, key: String): JSONObject = present(o, key) as? JSONObject ?: throw JSONException("missing object $key")
    fun optObj(o: JSONObject, key: String): JSONObject? = when (val v = present(o, key)) {
        null -> null; is JSONObject -> v; else -> throw JSONException("$key is not an object")
    }
    fun arr(o: JSONObject, key: String): JSONArray = present(o, key) as? JSONArray ?: throw JSONException("missing array $key")
    fun objects(o: JSONObject, key: String): List<JSONObject> = arr(o, key).let { a ->
        (0 until a.length()).map { a.opt(it) as? JSONObject ?: throw JSONException("$key[$it] is not an object") }
    }
    fun strings(o: JSONObject, key: String): List<String> = arr(o, key).let { a ->
        (0 until a.length()).map { a.opt(it) as? String ?: throw JSONException("$key[$it] is not a string") }
    }
    fun optStrings(o: JSONObject, key: String): List<String>? = if (present(o, key) == null) null else strings(o, key)
    fun keys(o: JSONObject): Set<String> = o.keys().asSequence().toSet()
    fun array(values: Collection<String>): JSONArray = JSONArray().apply { values.forEach { put(it) } }

    /** Compact serialization with sorted keys, like JSONSerialization's `.sortedKeys`. */
    fun sorted(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted()
            .joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + sorted(value.opt(it)) }
        is Map<*, *> -> value.keys.map { it.toString() }.sorted()
            .joinToString(",", "{", "}") { k -> JSONObject.quote(k) + ":" + sorted(value[k]) }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { sorted(value.opt(it)) }
        is List<*> -> value.joinToString(",", "[", "]") { sorted(it) }
        is String -> JSONObject.quote(value)
        is Boolean -> value.toString()
        is Double -> if (value == Math.floor(value) && !value.isInfinite() && kotlin.math.abs(value) < 1e15) value.toLong().toString() else value.toString()
        is Float -> sorted(value.toDouble())
        is Number -> value.toString()
        else -> JSONObject.quote(value.toString())
    }
}
