package com.yunha.remy.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of PresentedIngredientTests.swift.
class PresentedIngredientTest {
    private val ingredients = IngredientDraft.preset("pasta salad")!!.ingredients + Ingredient("salt", "salt", "to taste")

    @Test fun testPresentationIsAnImageRequestWithAnOptionalHint() {
        assertEquals("onion", IngredientPresentationCue.parse("Here's the onion", ingredients)?.ingredientID)
        assertEquals("cucumber", IngredientPresentationCue.parse("Chef, here is my cucumber!", ingredients)?.ingredientID)
        assertNotNull(IngredientPresentationCue.parse("Here’s the first ingredient", ingredients))
        assertNotNull(IngredientPresentationCue.parse("Here's the banana", ingredients))
        assertNotNull(IngredientPresentationCue.parse("What is this", ingredients))
        assertNull(IngredientPresentationCue.parse("I have onion and cucumber", ingredients))
        assertNull(IngredientPresentationCue.parse("This is not the onion", ingredients))
    }

    @Test fun testOnionNeedsVisualAgreementAndCannotBecomeAppleOrOrange() {
        val onion = IngredientVisualIdentity("red onion", 0.94, "Purple papery outer layers and a dried root tuft", listOf(100.0, 100.0, 900.0, 900.0))
        val agreed = IngredientVisualVerification(true, "onion", 0.9, "Visible layered papery skin and root end")
        assertEquals("onion", onion.confirmedIngredient(ingredients, agreed)?.id)
        val apple = IngredientVisualVerification(true, "apple", 0.95, "Smooth shiny skin and a fruit stem")
        assertNull(onion.confirmedIngredient(ingredients, apple))
        assertFalse(IngredientVisualIdentity.sameFood("onion", "orange"))
        assertFalse(IngredientVisualIdentity.sameFood("cucumber", "banana"))
    }

    @Test fun testUnknownUnboxedLowConfidenceAndUnlabelledPowderCannotConfirm() {
        val box = listOf(100.0, 100.0, 900.0, 900.0)
        val verify = IngredientVisualVerification(true, "salt", 0.98, "Fine white powder in a bowl")
        val salt = IngredientVisualIdentity("salt", 0.98, "Fine white powder in a bowl", box)
        assertNull(salt.confirmedIngredient(ingredients, verify))
        for (identity in listOf(
            IngredientVisualIdentity("unknown", 0.98, "A round food is held up", box),
            IngredientVisualIdentity("onion", 0.5, "Papery outer layers", box),
            IngredientVisualIdentity("onion", 0.98, "Papery outer layers", emptyList()),
            IngredientVisualIdentity("onion", 0.98, "It could be an onion", box),
        )) assertFalse(identity.isSupported)
    }

    @Test fun testSpecificPastaShapesMatchPastaWithoutAliasingOtherFoods() {
        for (shape in listOf("rotini", "fusilli", "penne", "spaghetti")) assertTrue(IngredientVisualIdentity.sameFood(shape, "pasta"))
        assertFalse(IngredientVisualIdentity.sameFood("rice", "pasta"))
    }

    @Test fun testOutOfListIdentityStillNeedsUnambiguousCorroboration() {
        val apple = IngredientVisualIdentity("apple", 0.95, "Glossy red skin and stem", listOf(100.0, 100.0, 900.0, 900.0))
        assertTrue(apple.isCorroborated(IngredientVisualVerification(true, "apple", 0.95, "Smooth skin and fruit stem")))
        assertNull(apple.confirmedIngredient(ingredients, IngredientVisualVerification(true, "apple", 0.95, "Smooth skin and fruit stem")))
        assertFalse(apple.isCorroborated(IngredientVisualVerification(true, "apple", 0.95, "It could be an apple")))
    }

    @Test fun testPackageLabelsRejectRecipeSentencesAndPepper() {
        assertEquals("pasta", PackageIngredientLabel.food("ROTINI"))
        assertEquals("salt", PackageIngredientLabel.food("Sea Salt"))
        for (text in listOf("salt-free", "unsalted", "add salt", "salt and pepper", "pepper", "1 tsp salt")) assertNull(PackageIngredientLabel.food(text))
        assertTrue(IngredientVisualIdentity.sameFood("rotini box", "pasta"))
        assertTrue(IngredientVisualIdentity.sameFood("salt shaker", "salt"))
        assertFalse(IngredientVisualIdentity.sameFood("pepper grinder", "salt"))
    }

    @Test fun testSaltContainerRequiresVisualContentsOrLabel() {
        val box = listOf(100.0, 100.0, 900.0, 900.0)
        val verify = IngredientVisualVerification(true, "salt shaker", 0.95, "Clear shaker containing white crystals")
        val salt = IngredientVisualIdentity("salt shaker", 0.95, "Clear bottle with white crystals", box)
        assertEquals("salt", salt.confirmedIngredient(ingredients, verify)?.id)
        val opaque = IngredientVisualIdentity("salt shaker", 0.95, "Opaque white shaker with holes", box)
        assertNull(opaque.confirmedIngredient(ingredients, IngredientVisualVerification(true, "salt shaker", 0.95, "Opaque shaker with holes")))
    }

    @Test fun testMalformedAndOutOfBoundsVisualRepliesAreRejected() {
        assertThrows(Exception::class.java) { IngredientVisualIdentity.decode("""{"name":"onion","confidence":1.4,"evidence":"papery skin","box_2d":[0,0,1000,1000]}""") }
        assertThrows(Exception::class.java) { IngredientVisualIdentity.decode("""{"name":"onion","confidence":0.9,"evidence":"papery skin","box_2d":[0,0,1100,1000]}""") }
    }
}

// Port of IngredientConfirmationTests.swift.
class IngredientConfirmationTest {
    private val ingredients = listOf(
        Ingredient("pasta", "Pasta", "200 g"), Ingredient("salt", "Salt", "to taste"), Ingredient("lemon", "Lemon", "1"),
        Ingredient("red_onion", "Red onion", "1"), Ingredient("cucumber", "Cucumber", "1"), Ingredient("tomato", "Tomato", "2"),
    )

    @Test fun testExactAffirmationsUseCurrentNamesOrIDs() {
        for ((text, id) in listOf("I have pasta." to "pasta", "Got cucumber!" to "cucumber", "I HAVE red-onion" to "red_onion", "got RED_ONION" to "red_onion")) {
            val result = IngredientConfirmation.parse(text, ingredients)
            assertEquals(text, id, result?.ingredientID)
            assertEquals(text, PantryStatus.SEEN, result?.status)
        }
    }

    @Test fun testExactMissingStatementsNormalizeContractionsAndPunctuation() {
        for ((text, id) in listOf("I don't have salt" to "salt", "I don’t have lemon." to "lemon", "I do not have pasta" to "pasta",
                "I dont have tomato" to "tomato", "No cucumber" to "cucumber", "Red onion is missing." to "red_onion")) {
            val result = IngredientConfirmation.parse(text, ingredients)
            assertEquals(text, id, result?.ingredientID)
            assertEquals(text, PantryStatus.MISSING, result?.status)
        }
    }

    @Test fun testQuestionsInstructionsAndMixedIntentStayWithTheChef() {
        for (text in listOf("Do I have salt?", "I have salt?", "I have salt but not lemon", "No salt please",
                "I have pasta and tomato", "I have pasta, can we start", "If I have pasta",
                "No problem with salt", "I don't have salt so use soy sauce", "Onion is missing, add it",
                "Please check if tomato is missing", "Chef, I have pasta", "I have two tomato",
                "I have", "No", "Got", "")) {
            assertNull(text, IngredientConfirmation.parse(text, ingredients))
        }
    }

    @Test fun testNamesAreExactAndAmbiguousAliasesAreRejected() {
        assertNull("no substring red-onion match", IngredientConfirmation.parse("I have onion", ingredients))
        assertNull("no plural inference", IngredientConfirmation.parse("I have tomatoes", ingredients))
        assertNull("dish is not ingredient", IngredientConfirmation.parse("I have pasta salad", ingredients))
        assertNull(IngredientConfirmation.parse("I have salt", ingredients + Ingredient("sea_salt", "Salt", "")))
        assertNull(IngredientConfirmation.parse("Got pasta", ingredients + Ingredient("lemon_juice", "Pasta", "")))
        assertNull(IngredientConfirmation.parse("I have lemon", emptyList()))
    }

    @Test fun testConfirmationPreservesCookAuthorityWhenInstructionsArrive() {
        val session = CookingSession()
        assertTrue(session.startIngredients(IngredientDraft("Salad", ingredients)))
        val id = session.id
        val result = IngredientConfirmation.parse("I have cucumber", ingredients)!!
        session.setPantry(result.ingredientID, result.status)
        val complete = RecipePlan("Salad", ingredients, listOf(
            RecipeStep(id = "prep", title = "Prepare", instruction = "Prepare the ingredients.", doneWhen = "Ingredients ready"),
            RecipeStep(id = "mix", title = "Mix", instruction = "Mix the salad.", needs = listOf("prep"), doneWhen = "Combined"),
        ))
        assertTrue(session.applyInstructions(complete, id, ingredients))
        assertEquals(PantryStatus.SEEN, session.pantry["cucumber"]?.status)
        assertEquals(EvidenceOrigin.USER, session.pantry["cucumber"]?.origin)
    }
}

// Port of GestureHoldWatchTests.swift.
class GestureHoldWatchTest {
    @Test fun testThumbsUpRequiresAFullSecondAndCannotSkipStepsWhileHeld() {
        val watch = GestureHoldWatch()
        for (i in 0 until 10) { val t = 1 + i / 10.0; assertNull(watch.update("Thumb_Up", "right", t, t)) }
        assertEquals("Thumb_Up", watch.update("Thumb_Up", "right", 2.0, 2.0))
        for (i in 1..50) { val t = 2 + i / 10.0; assertNull(watch.update("Thumb_Up", "right", t, t)) }
        assertNull(watch.update(null, null, 7.1, 7.1))
        for (i in 0 until 10) { val t = 8 + i / 10.0; assertNull(watch.update("Thumb_Up", "right", t, t)) }
        assertEquals("Thumb_Up", watch.update("Thumb_Up", "right", 9.0, 9.0))
    }

    @Test fun testLossOrIdentityChangeRestartsTheHold() {
        val watch = GestureHoldWatch()
        for (i in 0..8) { val t = 1 + i / 10.0; assertNull(watch.update("Thumb_Up", "left", t, t)) }
        assertNull(watch.update("Thumb_Up", "right", 1.9, 1.9))
        assertNull("a gap is not a continuous hold", watch.update("Thumb_Up", "right", 2.8, 2.8))
        assertNull(watch.update("Thumb_Up", "right", 2.9, 2.9))
        assertNull(watch.update(null, null, 3.0, 3.0))
        assertNull(watch.update("Thumb_Up", "right", 3.1, 3.1))
    }

    @Test fun testStaleUnknownAndNonMonotonicFramesCannotAdvance() {
        val watch = GestureHoldWatch()
        assertNull(watch.update("Thumb_Up", "left", 1.0, 2.0))
        assertNull(watch.update("Thumb_Up", "unknown", 2.0, 2.0))
        assertNull(watch.update("Thumb_Up", "left", 2.1, 2.1))
        assertNull(watch.update("Thumb_Up", "left", 2.1, 2.1))
        assertNull(watch.update("Thumb_Up", "left", 2.2, 2.2))
    }
}

// Port of GuidancePillArbiterTests.swift.
class GuidancePillArbiterTest {
    private val idle = GuidancePillArbiter.Entry(GuidancePillArbiter.Source.IDLE, "Cooking step")
    private fun e(source: GuidancePillArbiter.Source, text: String) = GuidancePillArbiter.Entry(source, text)
    private val knifeS = GuidancePillArbiter.Source.KNIFE
    private val safety = GuidancePillArbiter.Source.SAFETY
    private val chef = GuidancePillArbiter.Source.CHEF
    private val coachingS = GuidancePillArbiter.Source.COACHING
    private val curl = GuidancePillArbiter.Source.CURL

    @Test fun testKnifeThenHotSurfacePreemptCompetingModelRepliesAndHints() {
        val policy = GuidancePillArbiter()
        val hot = e(safety, "Hot Surface")
        val knife = e(knifeS, "Knife")
        policy.update(listOf(idle, knife, e(chef, "New reply"), e(coachingS, "Error or coaching"), e(curl, "Index"), hot), 1.0)
        assertEquals(knife, policy.current)
        policy.update(listOf(idle, e(chef, "Another reply"), e(curl, "Middle"), hot), 1.1)
        assertEquals("instructions and heat cannot shorten the knife notice", knife, policy.current)
        policy.update(listOf(idle, hot, e(chef, "Another reply")), 2.0)
        assertEquals("heat is next after the one-second knife notice", hot, policy.current)
        policy.update(listOf(idle, hot, knife, e(chef, "Another reply")), 2.2)
        assertEquals("a fresh knife entry immediately preempts heat", knife, policy.current)
        policy.update(listOf(idle, e(chef, "Response")), 3.2)
        assertEquals(chef, policy.current?.source)
    }

    @Test fun testBriefKnifeEventOverridesInstructionsForOneSecond() {
        val policy = GuidancePillArbiter()
        val knife = e(knifeS, "Left hand is near the knife")
        policy.update(listOf(idle, knife, e(curl, "Index")), 1.0)
        policy.update(listOf(idle, knife, e(curl, "Middle")), 1.1)
        assertEquals(knife, policy.current)
        policy.update(listOf(idle, e(chef, "Step instructions"), e(curl, "Middle")), 1.2)
        assertEquals("brief loss of overlap cannot flash the instructions back", knife, policy.current)
        policy.update(listOf(idle, e(chef, "Different instructions")), 1.99)
        assertEquals(knife, policy.current)
        policy.update(listOf(idle, e(chef, "Step instructions")), 2.0)
        assertEquals("Step instructions", policy.current?.text)
    }

    @Test fun testJitteringHintNamesCannotReplaceAStableCueEachFrame() {
        val policy = GuidancePillArbiter()
        val index = e(curl, "Index")
        policy.update(listOf(idle, index), 1.0); policy.update(listOf(idle, index), 1.4)
        assertEquals(index, policy.current)
        for (i in 0 until 6) {
            policy.update(listOf(idle, e(curl, if (i % 2 == 0) "Middle" else "Pinky")), 1.5 + i * 0.1)
            assertEquals(index, policy.current)
        }
        val middle = e(curl, "Middle")
        policy.update(listOf(idle, middle), 2.2); policy.update(listOf(idle, middle), 2.6)
        assertEquals(middle, policy.current)
        policy.update(listOf(idle), 2.7); assertEquals(idle, policy.current)
    }

    @Test fun testChefPreemptsCurlAndGenericCoachingCannotPreemptSafety() {
        val policy = GuidancePillArbiter()
        val coaching = e(coachingS, "Coaching cue")
        policy.update(listOf(idle, coaching), 1.0); policy.update(listOf(idle, coaching), 1.4)
        assertEquals(coaching, policy.current)
        val hot = e(safety, "Hot Surface")
        policy.update(listOf(idle, coaching, hot), 1.5); assertEquals(hot, policy.current)
        val answer = e(chef, "Your answer")
        policy.update(listOf(idle, answer, e(curl, "Index")), 1.6); assertEquals(answer, policy.current)
    }

    @Test fun testContinuousKnifeContactDoesNotExtendOrReplayTheOneSecondNotice() {
        val policy = GuidancePillArbiter()
        val knife = e(knifeS, "Left hand is near the knife")
        policy.update(listOf(idle, knife), 1.0)
        policy.update(listOf(idle, knife), 1.9); assertEquals(knife, policy.current)
        policy.update(listOf(idle, knife), 2.0); assertEquals(idle, policy.current)
        policy.update(listOf(idle, knife), 5.0); assertEquals(idle, policy.current)
        policy.update(listOf(idle), 5.1)
        policy.update(listOf(idle, knife), 6.1); assertEquals(knife, policy.current)
    }

    @Test fun testResetCancelsAnOldKnifeNoticeWhenCameraOrSessionChanges() {
        val policy = GuidancePillArbiter()
        policy.update(listOf(idle, e(knifeS, "Knife")), 1.0)
        policy.reset()
        policy.update(listOf(idle), 1.1)
        assertEquals(idle, policy.current)
    }
}
