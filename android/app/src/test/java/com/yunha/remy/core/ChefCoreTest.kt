package com.yunha.remy.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of ChefCoreTests.swift (session and contract tests).

private val plan = RecipePlan(
    dish = "Cold pasta salad",
    ingredients = listOf(Ingredient("pasta", "fusilli", "200 g"), Ingredient("cucumber", "cucumber", "1"),
        Ingredient("salt", "salt", "to taste")),
    steps = listOf(
        RecipeStep(id = "dice", title = "Dice the cucumber", instruction = "Cut into bite-size cubes.",
            doneWhen = "cucumber in fingertip-size cubes", wrongSize = "long spears", tool = "chef's knife"),
        RecipeStep(id = "taste", kind = RecipeStep.Kind.ASK, title = "Salt preference", instruction = "Ask how salty.",
            question = "How salty do you like it?", saves = "salt"),
        RecipeStep(id = "dress", title = "Make the dressing", instruction = "Oil, lemon and one addition of salt.", needs = listOf("taste"),
            doneWhen = "oil, lemon and salt in the bowl", guardItem = "salt"),
        RecipeStep(id = "toss", title = "Toss", instruction = "Mix everything.", needs = listOf("dice", "dress"), doneWhen = "mixed"),
    ))

/** A session that has planned, reviewed ingredients and is sitting on the guarded dressing step. */
private fun atDressing(): CookingSession {
    val session = CookingSession(); session.start(plan); session.beginCooking()
    session.nextStep(); session.answer("lightly salted", heard = null, origin = EvidenceOrigin.USER)
    return session
}

private fun roundTrip(session: CookingSession): CookingSession = CookingSession.fromJson(session.toJson())!!

class ChefCoreTest {
    @Test fun testPlanValidationCatchesBrokenGraphs() {
        assertEquals(emptyList<String>(), plan.problems)
        val forward = RecipePlan("x", plan.ingredients, listOf(
            RecipeStep(id = "a", title = "A", instruction = "", needs = listOf("b"), doneWhen = "d"),
            RecipeStep(id = "b", title = "B", instruction = "", doneWhen = "d")))
        assertTrue(forward.problems.any { it.contains("not an earlier step") })
        val askWithoutQuestion = RecipePlan("x", plan.ingredients, listOf(
            RecipeStep(id = "a", kind = RecipeStep.Kind.ASK, title = "A", instruction = ""),
            RecipeStep(id = "b", title = "B", instruction = "", doneWhen = "d")))
        assertFalse(askWithoutQuestion.problems.isEmpty())
        val repaired = RecipePlan.decode(forward.toJson())
        assertEquals("a forward reference is dropped, not a re-plan", emptyList<String>(), repaired.steps[0].needs)
        val saltWithoutAsk = RecipePlan("x", plan.ingredients, listOf(
            RecipeStep(id = "a", title = "Mash", instruction = "Mash it.", doneWhen = "d"),
            RecipeStep(id = "b", title = "Add salt", instruction = "Salt it.", doneWhen = "d"))).normalized
        assertEquals(emptyList<String>(), saltWithoutAsk.problems)
        assertEquals("the missing salt question is inserted", listOf("a", "ask_salt", "b"), saltWithoutAsk.steps.map { it.id })
        assertEquals("salt", saltWithoutAsk.steps[2].guardItem)
        assertEquals(plan.normalized, RecipePlan.decode("```json\n${plan.toJson()}\n```"))
    }

    @Test fun testNormalizingGuardsTheStepThatUsesAnAnswer() {
        val loose = RecipePlan("x", listOf(Ingredient("chili_flakes", "chili_flakes", "")), listOf(
            RecipeStep(id = "ask", kind = RecipeStep.Kind.ASK, title = "Salt", instruction = "", doneWhen = "stray", question = "How salty?", saves = "salt"),
            RecipeStep(id = "herbs", title = "Herbs", instruction = "Sprinkle oregano.", needs = listOf("ask"), doneWhen = "d", question = "stray")))
        val plan = loose.normalized
        assertEquals("", plan.steps[0].doneWhen); assertEquals("", plan.steps[1].question)
        assertEquals("salt", plan.steps[1].guardItem)
        assertEquals("Sprinkle oregano. Add the salt once, to taste.", plan.steps[1].instruction)
        assertEquals("chili flakes", plan.ingredients[0].name)
        val repeated = RecipePlan("x", listOf(Ingredient("cheese", "mozzarella", ""), Ingredient("cheese", "parmesan", "")), loose.steps).normalized
        assertEquals("salt is asked about, so it is listed", listOf("cheese", "cheese_2", "salt"), repeated.ingredients.map { it.id })
        val fromModel = """{"dish":"x","ingredients":[{"id":"salt","name":"salt","amount":""}],"steps":[{"id":"ask","kind":"ask","title":"Salt","instruction":"","needs":[],"doneWhen":"","wrongSize":"","tool":"","guardItem":"","question":"How salty?","saves":"salt"},{"id":"add","kind":"do","title":"Add salt","instruction":"Salt it.","needs":["ask"],"doneWhen":"d","wrongSize":"","tool":"","guardItem":"","question":"","saves":""}]}"""
        assertEquals("model JSON has no warning key", "Taste first. The salt can't come back out.", RecipePlan.decode(fromModel).steps[1].warning)
        assertEquals("Taste first. The salt can't come back out.", plan.steps[1].warning)
        val drain = RecipePlan("x", loose.ingredients, listOf(
            RecipeStep(id = "d", title = "Drain the pasta", instruction = "Tip it out.", doneWhen = "d", warning = "Have fun!"))).normalized
        assertEquals("rules replace model text", "Put the colander in the sink before you pour.", drain.steps[0].warning)
        val two = RecipePlan("x", loose.ingredients, listOf(
            RecipeStep(id = "chili", kind = RecipeStep.Kind.ASK, title = "Chili", instruction = "", question = "How spicy?", saves = "chili_flame"),
            RecipeStep(id = "salt", kind = RecipeStep.Kind.ASK, title = "Salt", instruction = "", question = "How salty?", saves = "salt"),
            RecipeStep(id = "herbs", title = "Herbs", instruction = "Sprinkle oregano.", needs = listOf("chili", "salt"), doneWhen = "d"))).normalized
        assertEquals("salt", two.steps[2].guardItem)
    }

    @Test fun testFlowGoesDishThenIngredientsThenCooking() {
        val session = CookingSession()
        assertEquals(CookingSession.Phase.NEEDS_DISH, session.phase)
        session.start(plan); assertEquals(CookingSession.Phase.INGREDIENTS, session.phase)
        session.beginCooking(); assertEquals(CookingSession.Phase.COOKING, session.phase); assertEquals("dice", session.step?.id)
    }

    @Test fun testAnswerSavesPreferenceAndAdvances() {
        val session = CookingSession(); session.start(plan); session.beginCooking(); session.nextStep()
        assertEquals(RecipeStep.Kind.ASK, session.step?.kind)
        session.nextStep()
        assertEquals("an ask step only finishes with an answer", "taste", session.step?.id)
        session.answer("not too salty", heard = "um not too salty please", origin = EvidenceOrigin.CAMERA)
        assertEquals("not too salty", session.preferences["salt"])
        assertEquals("dress", session.step?.id); assertTrue(session.done.contains("taste"))
    }

    @Test fun testUnmetNeedsListsSkippedDependencies() {
        val session = CookingSession(); session.start(plan); session.beginCooking()
        session.selectStep(3)
        assertEquals(setOf("dice", "dress"), session.unmetNeeds.map { it.id }.toSet())
    }

    @Test fun testIngredientCheckIsStaleSafeAndCookOverrides() {
        val session = CookingSession(); session.start(plan)
        val check = IngredientCheck.decode("""{"items":[{"id":"pasta","status":"seen"},{"id":"salt","status":"unsure"}],"line":"Is that salt?"}""", plan)
        session.setPantry("salt", PantryStatus.SEEN)
        val revision = session.revision
        assertTrue(session.applyIngredientCheck(check, session.id, revision))
        assertEquals(PantryStatus.SEEN, session.pantry["pasta"]?.status)
        assertEquals("the cook's word beats the camera", CookingSession.PantryItem(PantryStatus.SEEN, EvidenceOrigin.USER), session.pantry["salt"])
        assertFalse(session.applyIngredientCheck(check, session.id, revision))
        assertThrows(Exception::class.java) { IngredientCheck.decode("""{"items":[{"id":"saffron","status":"seen"}],"line":"x"}""", plan) }
    }

    @Test fun testStaleModelReplyCannotArmGuardAfterUserMovesToAnotherStep() {
        val session = atDressing()
        val revision = session.revision
        session.nextStep()
        assertFalse(session.apply(ChefObservation(confidence = 0.99, saltAdded = true, evidence = "pour", line = "Stop"), session.id, revision, 2.0, 3))
        assertFalse(session.salted)
    }

    @Test fun testSaltRequiresGuardedStepStrongConfidenceAndSequence() {
        val observation = ChefObservation(confidence = 0.95, saltAdded = true, evidence = "salt enters bowl", line = "Salt remembered")
        var session = CookingSession(); session.start(plan); session.beginCooking()
        assertTrue(session.apply(observation, session.id, session.revision, 1.0, 3))
        assertFalse("unguarded step", session.salted)
        session = atDressing()
        assertTrue(session.apply(observation, session.id, session.revision, 1.0, 1))
        assertFalse(session.salted)
        assertTrue(session.apply(observation, session.id, session.revision, 1.0, 3))
        assertTrue(session.salted); assertEquals(EvidenceOrigin.CAMERA, session.saltOrigin)
        session.markZone(GuardZone(Point2(0.7, 0.5)))
        assertTrue(session.guardArmed)
        session.nextStep(); assertFalse(session.guardArmed)
    }

    @Test fun testCameraMoveDisarmsAndManualConfirmationHasHonestProvenance() {
        val session = atDressing()
        session.markZone(GuardZone(Point2(0.5, 0.5))); session.confirmSalt()
        assertTrue(session.guardArmed); assertEquals(EvidenceOrigin.USER, session.saltOrigin)
        session.invalidateZone(); assertFalse(session.guardArmed); assertTrue(session.salted)
    }

    @Test fun testSourceSwitchOrPauseRejectsPendingObservationWithoutMarkedZone() {
        val session = atDressing()
        val revision = session.revision
        session.invalidateZone()
        assertFalse(session.apply(ChefObservation(confidence = 0.99, saltAdded = true, evidence = "previous camera", line = "Salt added"), session.id, revision, 1.0, 3))
        assertFalse(session.salted)
    }

    @Test fun testReplyFromAnEarlierSessionCannotMutateNewPlan() {
        val session = CookingSession(); session.start(plan); session.beginCooking()
        val oldID = session.id
        session.start(plan); session.beginCooking()
        val events = session.events.size
        assertFalse(session.apply(ChefObservation(confidence = 0.99, evidence = "old image", line = "done"), oldID, session.revision, 1.0, 3))
        assertEquals(events, session.events.size)
    }

    @Test fun testInvalidOrExpiredObservationIsRejected() {
        assertThrows(Exception::class.java) { ChefObservation.decode("{\"confidence\":2}") }
        val session = CookingSession(); session.start(plan); session.beginCooking()
        val r = session.revision
        assertFalse(session.apply(ChefObservation(confidence = Double.NaN, evidence = "x", line = "x"), session.id, r, 1.0, 3))
        assertFalse(session.apply(ChefObservation(confidence = 0.99, evidence = "x", line = "x"), session.id, r, 13.0, 3))
        assertFalse(session.apply(ChefObservation(confidence = 0.99, evidence = "x", line = "x"), session.id, r, -1.0, 3))
    }

    @Test fun testSavedSessionRestoresWithoutTrustingOldLocation() {
        val session = atDressing()
        session.markZone(GuardZone(Point2(0.5, 0.5))); session.confirmSalt()
        val restored = roundTrip(session)
        assertEquals(session.preferences, restored.preferences); assertEquals("dress", restored.step?.id)
        restored.restoredAfterLaunch()
        assertNull(restored.zone); assertFalse(restored.guardArmed); assertTrue(restored.salted)
    }

    @Test fun testStepsMayLeaveOutFieldsThatDoNotApply() {
        val text = """{"dish":"x","ingredients":[{"id":"salt","name":"salt","amount":""}],"steps":[{"id":"ask","kind":"ask","title":"Salt","instruction":"Ask.","needs":[],"question":"How salty?","saves":"salt"},{"id":"add","kind":"do","title":"Add salt","instruction":"Salt it.","needs":["ask"],"doneWhen":"salt in the bowl","guardItem":"salt"}]}"""
        val plan = RecipePlan.decode(text)
        assertEquals("", plan.steps[0].doneWhen)
        assertEquals("salt", plan.steps[1].guardItem)
        assertEquals("", plan.steps[1].tool)
        val noTarget = text.replace(""","doneWhen":"salt in the bowl"""", "")
        assertEquals("a missing target falls back to the instruction", "Salt it.", RecipePlan.decode(noTarget).steps[1].doneWhen)
    }

    @Test fun testSubstituteChangesTheRecipeItself() {
        val plan = RecipePlan.decode("""{"dish":"x","ingredients":[{"id":"vinegar","name":"red wine vinegar","amount":"2 tbsp"},{"id":"feta","name":"feta","amount":"1"}],"steps":[{"id":"dress","kind":"do","title":"Add red wine vinegar","instruction":"Whisk the Red Wine Vinegar with oil.","needs":[],"doneWhen":"dressing mixed"},{"id":"mix","kind":"do","title":"Mix","instruction":"Crumble the feta.","needs":["dress"],"doneWhen":"mixed"}]}""")
        val session = CookingSession(); session.start(plan)
        session.setPantry("vinegar", PantryStatus.MISSING)
        assertTrue(session.substitute("vinegar", "apple cider vinegar"))
        assertEquals("apple cider vinegar", session.plan?.ingredients?.first()?.name)
        assertEquals("ids stay, so the pantry and checks still line up", "vinegar", session.plan?.ingredients?.first()?.id)
        assertEquals("Add apple cider vinegar", session.plan?.steps?.first()?.title)
        assertEquals("Whisk the apple cider vinegar with oil.", session.plan?.steps?.first()?.instruction)
        assertNull("the new ingredient starts unchecked", session.pantry["vinegar"])
        assertTrue("already in the recipe: feta is just dropped", session.substitute("feta", "Apple cider vinegar"))
        assertEquals(listOf("vinegar"), session.plan?.ingredients?.map { it.id })
        assertFalse("not in the recipe", session.substitute("saffron", "turmeric"))
        assertTrue(session.add("lime", "1"))
        assertEquals("lime", session.plan?.ingredients?.last()?.id)
        assertFalse("already there", session.add("Lime", "2"))
    }

    @Test fun testNeedsThatNameIngredientsAreDropped() {
        val text = """{"dish":"Quesadilla","ingredients":[{"id":"cheese","name":"cheddar","amount":"1 cup"}],"steps":[{"id":"grate","kind":"do","title":"Grate the cheese","instruction":"Grate it.","needs":["cheese"],"doneWhen":"grated"},{"id":"cook","kind":"do","title":"Cook the quesadilla","instruction":"Cook it in a pan until golden.","needs":["grate","cheese"],"doneWhen":"golden"}]}"""
        val plan = RecipePlan.decode(text)
        assertEquals(emptyList<String>(), plan.steps[0].needs)
        assertEquals(listOf("grate"), plan.steps[1].needs)
        assertEquals("Turn the pan handle inward and keep your hands clear of the heat.", plan.steps[1].warning)
        assertEquals("word match: 'grate' is not a pan step", "", plan.steps[0].warning)
    }

    @Test fun testASeasoningTheStepsUseJoinsTheIngredientList() {
        val text = """{"dish":"Guac","ingredients":[{"id":"avocado","name":"avocado","amount":"2"}],"steps":[{"id":"mash","kind":"do","title":"Mash","instruction":"Mash the avocado.","needs":[],"doneWhen":"mashed"},{"id":"ask_salt","kind":"ask","title":"Salt","instruction":"Ask.","needs":[],"question":"How salty?","saves":"salt"},{"id":"season","kind":"do","title":"Add salt","instruction":"Add salt once.","needs":["mash","ask_salt"],"doneWhen":"salted","guardItem":"salt"}]}"""
        val plan = RecipePlan.decode(text)
        assertEquals(listOf("avocado", "salt"), plan.ingredients.map { it.name })
        assertEquals("to taste", plan.ingredients.last().amount)
    }

    @Test fun testWhatTheCookLacksIsRememberedAcrossSwaps() {
        val plan = RecipePlan.decode("""{"dish":"x","ingredients":[{"id":"vinegar","name":"red wine vinegar","amount":"1"}],"steps":[{"id":"a","kind":"do","title":"Dress","instruction":"Add the red wine vinegar.","needs":[],"doneWhen":"d"},{"id":"b","kind":"do","title":"Mix","instruction":"Mix.","needs":[],"doneWhen":"d"}]}""")
        val session = CookingSession(); session.start(plan)
        assertTrue(session.substitute("red wine vinegar", "white wine vinegar"))
        assertNotNull("close names match", session.ingredient("white vinegar"))
        assertTrue(session.substitute("white vinegar", "lemon juice"))
        assertTrue(session.isUnavailable("red wine vinegar"))
        assertTrue(session.isUnavailable("white vinegar"))
        assertEquals("lemon juice", session.plan?.ingredients?.first()?.name)
        val restored = roundTrip(session)
        assertEquals(listOf("red wine vinegar", "white wine vinegar"), restored.unavailable)
    }

    @Test fun testIngredientsShownOneByOneAddUp() {
        val session = CookingSession(); session.start(plan)
        val first = IngredientCheck.decode("""{"seen":["pasta"],"unsure":[]}""", plan)
        assertTrue(session.applyIngredientCheck(first, session.id, session.revision))
        val second = IngredientCheck.decode("""{"seen":["salt"],"unsure":[]}""", plan)
        assertTrue(session.applyIngredientCheck(second, session.id, session.revision))
        assertEquals("seen earlier, still seen", PantryStatus.SEEN, session.pantry["pasta"]?.status)
        assertEquals(PantryStatus.SEEN, session.pantry["salt"]?.status)
        assertThrows(Exception::class.java) { IngredientCheck.decode("""{"seen":["saffron"],"unsure":[]}""", plan) }
    }

    // Android-only: persistence round trip keeps everything the app reads back.
    @Test fun testSessionJsonRoundTripPreservesState() {
        val session = atDressing()
        session.markZone(GuardZone(Point2(0.5, 0.5))); session.confirmSalt(); session.markUnavailable("feta")
        val restored = roundTrip(session)
        assertEquals(session.id, restored.id); assertEquals(session.revision, restored.revision)
        assertEquals(session.plan, restored.plan); assertEquals(session.done, restored.done)
        assertEquals(session.pantry, restored.pantry); assertEquals(session.added, restored.added)
        assertEquals(session.zone, restored.zone); assertEquals(session.events, restored.events)
        assertEquals(session.unavailable, restored.unavailable); assertEquals(session.phase, restored.phase)
        assertNull(CookingSession.fromJson("not json"))
    }
}
