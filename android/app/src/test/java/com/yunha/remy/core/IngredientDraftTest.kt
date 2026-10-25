package com.yunha.remy.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of IngredientDraftTests.swift.
class IngredientDraftTest {
    private val draft: IngredientDraft get() = IngredientDraft.preset("Pasta salad")!!
    private fun instructions(draft: IngredientDraft): RecipePlan = RecipePlan(draft.dish, draft.ingredients, listOf(
        RecipeStep(id = "prepare", title = "Prepare ingredients", instruction = "Prepare the listed vegetables.", doneWhen = "vegetables chopped"),
        RecipeStep(id = "mix", title = "Mix salad", instruction = "Mix the pasta and vegetables.", needs = listOf("prepare"), doneWhen = "salad combined"),
    ))
    private fun roundTrip(session: CookingSession): CookingSession = CookingSession.fromJson(session.toJson())!!

    @Test fun testRequestedPastaSaladPresetContainsExactlyFiveIngredientsWithoutSalt() {
        val preset = IngredientDraft.preset("Let's make COLD PASTA SALAD!")
        assertEquals(listOf("pasta", "lemon", "onion", "cucumber", "tomato"), preset?.ingredients?.map { it.name })
        assertEquals(listOf("pasta", "lemon", "onion", "cucumber", "tomato"), preset?.ingredients?.map { it.id })
        assertEquals(emptyList<String>(), preset?.problems)
        assertNull(IngredientDraft.preset("Guacamole"))
        assertNull(IngredientDraft.preset("Salad"))
    }

    @Test fun testDraftNormalizesDisplayNamesBeforeFreezingTheIngredientContract() {
        val parsed = IngredientDraft.decode("""{"dish":" Toast ","ingredients":[{"id":"olive_oil","name":" olive_oil ","amount":" 1 tsp "}]}""")
        assertEquals("Toast", parsed.dish)
        assertEquals(listOf(Ingredient("olive_oil", "olive oil", "1 tsp")), parsed.ingredients)
    }

    @Test fun testPresetAcceptsOnlyPlainRequestsAndPreservesExplicitModifiersForTheModel() {
        for (request in listOf("pasta salad", "Cold pasta salad", "Let's make COLD PASTA SALAD!",
                "Let’s cook a pasta salad", "Please make me a pasta salad", "I want a pasta salad",
                "Can we make pasta salad, please?", "A recipe for pasta salad")) {
            assertNotNull(request, IngredientDraft.preset(request))
        }
        for (request in listOf("pasta salad without tomato", "pasta salad with chicken", "tomato-free pasta salad",
                "pasta salad, I'm allergic to onion", "I have a lemon allergy; make pasta salad",
                "gluten free pasta salad", "pasta salad for four", "pasta salad or soup",
                "Do not make pasta salad", "Don't make pasta salad", "not pasta salad")) {
            assertNull(request, IngredientDraft.preset(request))
        }
    }

    @Test fun testIngredientOnlyDraftCanBeReviewedButCannotStartCooking() {
        val session = CookingSession()
        assertTrue(session.startIngredients(draft))
        assertEquals(CookingSession.Phase.INGREDIENTS, session.phase)
        assertEquals(draft.ingredients, session.plan?.ingredients)
        assertEquals(emptyList<RecipeStep>(), session.plan?.steps)
        assertTrue(session.instructionsPending)
        assertFalse(session.instructionsReady)
        session.setPantry("pasta", PantryStatus.SEEN)
        session.beginCooking()
        assertEquals(CookingSession.Phase.INGREDIENTS, session.phase)
        assertFalse(session.ingredientsReviewed)
        assertNull(session.step)
    }

    @Test fun testCompletingInstructionsPreservesPantryReviewAcrossRevisionChanges() {
        val session = CookingSession(); session.startIngredients(draft)
        val sessionID = session.id
        session.setPantry("pasta", PantryStatus.SEEN)
        session.setPantry("onion", PantryStatus.MISSING)
        session.markUnavailable("onion")
        val revision = session.revision
        assertTrue(session.applyInstructions(instructions(draft), sessionID, draft.ingredients))
        assertEquals(CookingSession.PantryItem(PantryStatus.SEEN, EvidenceOrigin.USER), session.pantry["pasta"])
        assertEquals(CookingSession.PantryItem(PantryStatus.MISSING, EvidenceOrigin.USER), session.pantry["onion"])
        assertTrue(session.isUnavailable("onion"))
        assertTrue(session.revision > revision)
        assertTrue(session.instructionsReady)
        assertFalse(session.instructionsPending)
        assertEquals("preparing instructions must not start cooking automatically", CookingSession.Phase.INGREDIENTS, session.phase)
        session.beginCooking()
        assertEquals(CookingSession.Phase.COOKING, session.phase)
    }

    @Test fun testChangedIngredientListRejectsOldInstructionsAndAllowsNewestList() {
        val session = CookingSession(); session.startIngredients(draft)
        val sessionID = session.id
        assertTrue(session.substitute("onion", "shallot"))
        assertFalse(session.applyInstructions(instructions(draft), sessionID, draft.ingredients))
        assertTrue(session.instructionsPending)
        assertEquals("shallot", session.plan?.ingredients?.firstOrNull { it.id == "onion" }?.name)
        val newest = IngredientDraft(session.plan!!.dish, session.plan!!.ingredients)
        assertTrue(session.applyInstructions(instructions(newest), sessionID, newest.ingredients))
    }

    @Test fun testInstructionsFromAnEarlierSessionOrDuplicateCompletionAreRejected() {
        val session = CookingSession(); session.startIngredients(draft)
        val earlier = session.id
        session.startIngredients(draft)
        assertFalse(session.applyInstructions(instructions(draft), earlier, draft.ingredients))
        assertTrue(session.applyInstructions(instructions(draft), session.id, draft.ingredients))
        assertFalse(session.applyInstructions(instructions(draft), session.id, draft.ingredients))
    }

    @Test fun testPersistedDraftStillRequiresInstructions() {
        val session = CookingSession(); session.startIngredients(draft); session.setPantry("lemon", PantryStatus.SEEN)
        val restored = roundTrip(session)
        restored.restoredAfterLaunch()
        assertTrue(restored.instructionsPending)
        assertEquals(CookingSession.PantryItem(PantryStatus.SEEN, EvidenceOrigin.USER), restored.pantry["lemon"])
        restored.beginCooking()
        assertEquals(CookingSession.Phase.INGREDIENTS, restored.phase)
    }

    @Test fun testInvalidDraftCannotReplaceTheCurrentSession() {
        val invalid = IngredientDraft("", listOf(Ingredient("x", "", "")))
        val session = CookingSession(); session.startIngredients(draft)
        val id = session.id
        assertFalse(session.startIngredients(invalid))
        assertEquals(id, session.id)
        assertThrows(Exception::class.java) { IngredientDraft.decode("""{"dish":"Salad","ingredients":[{"id":"x","name":"onion","amount":"1"},{"id":"x","name":"cucumber","amount":"1"}]}""") }
        assertThrows(Exception::class.java) { IngredientDraft.decode("""{"dish":"Salad","ingredients":[{"id":"onion","name":"onion","amount":"1"},{"id":"onion_two","name":"Onion","amount":"1"}]}""") }
    }

    @Test fun testStepsOnlyReplyPreservesIngredientContractAndRejectsNewSeasoning() {
        val output = RecipeInstructions(instructions(draft).steps)
        val complete = RecipeInstructions.decode(output.toJson(), draft)
        assertEquals(draft.ingredients, complete.ingredients)
        assertEquals(draft.dish, complete.dish)
        assertEquals(emptyList<String>(), complete.problems)
        val extra = RecipeInstructions(listOf(
            RecipeStep(id = "prepare", title = "Prepare", instruction = "Prepare vegetables.", doneWhen = "chopped"),
            RecipeStep(id = "pepper", title = "Add pepper", instruction = "Add pepper once.", doneWhen = "seasoned", guardItem = "pepper"),
        ))
        assertThrows(Exception::class.java) { RecipeInstructions.decode(extra.toJson(), draft) }
        assertThrows(Exception::class.java) { RecipeInstructions.decode("""{"steps":[]}""", draft) }
        assertThrows(Exception::class.java) { RecipeInstructions.decode("""{"ingredients":[],"steps":[]}""", draft) }
    }

    @Test fun testRemovingSaltPreservesPantryButInvalidatesOldInstructions() {
        val old = RecipePlan("Pasta salad", draft.ingredients + Ingredient("salt", "salt", "to taste"), listOf(
            RecipeStep(id = "prepare", title = "Prepare vegetables", instruction = "Dice the vegetables.", doneWhen = "vegetables diced"),
            RecipeStep(id = "mix", title = "Mix salad", instruction = "Mix pasta, vegetables and salt.", needs = listOf("prepare"), doneWhen = "salad mixed"),
        ))
        val session = CookingSession()
        session.start(old)
        session.setPantry("onion", PantryStatus.SEEN)
        session.setPantry("salt", PantryStatus.SEEN)
        assertTrue(session.removeForReplanning("salt"))
        assertEquals(draft.ingredients.map { it.id }, session.plan?.ingredients?.map { it.id })
        assertEquals(PantryStatus.SEEN, session.pantry["onion"]?.status)
        assertNull(session.pantry["salt"])
        assertTrue(session.plan?.steps?.isEmpty() == true)
        assertTrue(session.isUnavailable("salt"))
        assertFalse(session.removeForReplanning("salt"))
    }

    @Test fun testInstructionsCannotAddUnlistedSaltThroughProse() {
        val text = """{"steps":[{"id":"prepare","kind":"do","title":"Prepare vegetables","instruction":"Dice vegetables.","needs":[],"doneWhen":"vegetables diced"},{"id":"mix","kind":"do","title":"Mix salad","instruction":"Mix pasta and vegetables with salt.","needs":["prepare"],"doneWhen":"salad mixed"}]}"""
        assertThrows(Exception::class.java) { RecipeInstructions.decode(text, draft) }
        RecipeInstructions.decode(text.replace(" with salt", ""), draft)
    }

    @Test fun testMalformedDeviceInstructionRepliesAreRejectedWithoutRepair() {
        // Regression for the physical model reply: a broken quote and an ask without core fields.
        val malformed = """{"steps":[{"id":"ask_salt","kind":"ask","question":"How salty?","saves":"salt","doneWhen:null}]}"""
        val missingCoreFields = """{"steps":[{"id":"ask_salt","kind":"ask","needs":[],"doneWhen":"","question":"How salty?","saves":"salt"},{"id":"season","kind":"do","title":"Add salt","instruction":"Add salt once.","needs":["ask_salt"],"doneWhen":"salt added","guardItem":"salt"}]}"""
        assertThrows(Exception::class.java) { RecipeInstructions.decode(malformed, draft) }
        assertThrows(Exception::class.java) { RecipeInstructions.decode(missingCoreFields, draft) }
    }

    @Test fun testFixedRecipeHasTwoValidSaltFreeInstructions() {
        val plan = draft.presetInstructions!!
        assertEquals(emptyList<String>(), plan.problems)
        assertEquals(draft.ingredients, plan.ingredients)
        assertEquals(2, plan.steps.size)
        assertEquals(listOf("cook_pasta", "prepare"), plan.steps.map { it.id })
        assertFalse(plan.steps.any { it.kind == RecipeStep.Kind.ASK || it.isGuarded })
        assertFalse(plan.steps.any { (it.instruction + it.title).lowercase().contains("salt") })
        val modified = IngredientDraft(draft.dish, draft.ingredients.dropLast(1))
        assertNull("Never replace an edited recipe with the preset", modified.presetInstructions)
    }

    @Test fun testCookerSafetyIsArmedOnlyAfterStepOneUntilTheWholeDishFinishes() {
        val session = CookingSession(); session.start(draft.presetInstructions!!)
        assertTrue(session.usesCookerSafetySequence)
        assertFalse(session.cookerSafetyArmed)
        session.beginCooking()
        assertFalse(session.cookerSafetyArmed)
        session.nextStep()
        assertTrue(session.cookerSafetyArmed)
        val restored = roundTrip(session)
        assertTrue(restored.cookerSafetyArmed)
        session.nextStep()
        assertFalse(session.cookerSafetyArmed)
        session.selectStep(1)
        assertFalse("going back after finishing does not re-arm the cooker", session.cookerSafetyArmed)
        val other = CookingSession(); other.start(instructions(draft)); other.beginCooking(); other.nextStep()
        assertTrue("generated plans also stay monitored after their first step", other.cookerSafetyArmed)
    }

    @Test fun testLegacyPresetMigrationNeverArmsFromOldCompletion() {
        val updated = draft.presetInstructions!!
        val old = RecipePlan(updated.dish, updated.ingredients, listOf(
            RecipeStep(id = "cook_pasta", title = "Cook and cool pasta",
                instruction = "Cook pasta in plain water according to its package directions, then drain and let it cool.",
                doneWhen = "pasta cooked, drained and cooled", tool = "pot"),
        ) + updated.steps.drop(1) + listOf(RecipeStep(id = "combine", title = "Mix salad", instruction = "Mix ingredients.", doneWhen = "mixed")))
        val session = CookingSession(); session.start(old)
        for (ingredient in old.ingredients) session.setPantry(ingredient.id, PantryStatus.SEEN)
        session.beginCooking(); session.nextStep()
        assertTrue(session.refreshLegacyPastaInstructions())
        assertEquals(updated, session.plan)
        assertTrue(session.ingredientsCollected)
        assertEquals(emptySet<String>(), session.done)
        assertEquals(CookingSession.Phase.INGREDIENTS, session.phase)
        assertFalse(session.cookerSafetyArmed)
        assertFalse(session.refreshLegacyPastaInstructions())
    }

    @Test fun testCookerPowerOffPersistsWithoutDisablingHotSurfaceWindow() {
        var session = CookingSession(); session.start(draft.presetInstructions!!); session.beginCooking(); session.nextStep()
        assertTrue(session.cookerSafetyArmed)
        val step = session.currentStep
        session.reportCookerPower(false)
        assertTrue(session.cookerSafetyArmed)
        session = roundTrip(session)
        assertTrue(session.cookerSafetyArmed)
        session.reportCookerPower(true)
        assertTrue(session.cookerSafetyArmed)
        assertEquals(step, session.currentStep)
        session.nextStep()
        assertFalse("recipe completion still ends the demo window", session.cookerSafetyArmed)
    }

    @Test fun testRetiredThirdStepIsRemovedWithoutReplayingFinishedCutting() {
        val preset = draft.presetInstructions!!
        for (id in listOf("combine", "portion_salad")) {
            val old = RecipePlan(preset.dish, preset.ingredients, preset.steps + listOf(
                RecipeStep(id = id, title = "Old final step", instruction = "Old final instruction.", needs = listOf("prepare"), doneWhen = "done")))
            var session = CookingSession(); session.start(old); session.setPantry("onion", PantryStatus.SEEN)
            session.beginCooking(); session.nextStep(); session.nextStep()
            assertEquals(2, session.currentStep)
            val obj = JSONObject(session.toJson())
            obj.put("portioning", JSONObject().put("phase", "awaitingPortions").put("counts", JSONObject()))
            session = CookingSession.fromJson(obj.toString())!!
            assertTrue(session.removeRetiredPastaFinalStep())
            assertEquals(preset, session.plan); assertEquals(1, session.currentStep)
            assertEquals(setOf("cook_pasta", "prepare"), session.done)
            assertEquals(PantryStatus.SEEN, session.pantry["onion"]?.status)
            assertTrue(session.isComplete); assertFalse(session.cookerSafetyArmed)
            val saved = JSONObject(session.toJson())
            assertFalse("retired runtime state is omitted on the next save", saved.has("portioning"))
            assertFalse(session.removeRetiredPastaFinalStep())
        }
    }

    @Test fun testThirdStepRemovalPreservesAnUnfinishedCuttingStep() {
        val preset = draft.presetInstructions!!
        val old = RecipePlan(preset.dish, preset.ingredients, preset.steps + listOf(
            RecipeStep(id = "portion_salad", title = "Build salad", instruction = "Count pinches.", doneWhen = "done")))
        val session = CookingSession(); session.start(old); session.beginCooking(); session.nextStep()
        assertTrue(session.removeRetiredPastaFinalStep())
        assertEquals(setOf("cook_pasta"), session.done); assertEquals(1, session.currentStep)
        assertFalse(session.isComplete); assertTrue(session.cookerSafetyArmed)
        session.nextStep(); assertTrue(session.isComplete)
    }

    @Test fun testThirdStepRemovalDoesNotTruncateGeneratedRecipes() {
        val session = CookingSession(); session.start(instructions(draft))
        assertFalse(session.removeRetiredPastaFinalStep())
        assertEquals(listOf("prepare", "mix"), session.plan?.steps?.map { it.id })
    }
}
