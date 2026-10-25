package com.yunha.remy.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of PlanPreviewTests.swift.
class PlanPreviewTest {
    private val step = """{"id":"boil","kind":"do","title":"Boil the {pasta}","instruction":"Salted \"water\".","needs":[],"doneWhen":"d","wrongSize":"","tool":"pot","guardItem":"","question":"","saves":""}"""

    @Test fun testShowsDishThenIngredientsThenClosedStepsOnly() {
        var text = """{"dish":"Lasagna","ingredients":[{"id":"pasta","name":"lasagna sheets","amount":"12"},{"id":"beef","na"""
        var preview = PlanPreview.streamed(text)
        assertEquals("Lasagna", preview.dish)
        assertEquals("a half-written ingredient is not shown", listOf("pasta"), preview.ingredients.map { it.id })
        assertTrue(preview.steps.isEmpty())
        text += """me":"ground beef","amount":"500 g"}],"steps":[""" + step + """,{"id":"bake","kind":"do","title":"Ba"""
        preview = PlanPreview.streamed(text)
        assertEquals(2, preview.ingredients.size)
        assertEquals("braces and quotes inside strings are not structure", listOf("Boil the {pasta}"), preview.steps.map { it.title })
    }

    @Test fun testEmptyOrUnrelatedTextShowsNothing() {
        assertEquals(PlanPreview.streamed("{"), PlanPreview.streamed(""))
        assertNull(PlanPreview.streamed("{").dish)
    }
}

// Port of VoiceCommandTests.swift.
class VoiceCommandTest {
    private fun parse(text: String, phase: CookingSession.Phase = CookingSession.Phase.COOKING, recent: Boolean = false): VoiceCommand =
        VoiceCommand.parse(text, phase, if (recent) 3.0 else 60.0)

    @Test fun testOnlySpeechForTheRemyCounts() {
        assertEquals(VoiceCommand.Intent.IGNORE, parse("Did you see the game last night? It was crazy.").intent)
        assertEquals("the wake word must come first", VoiceCommand.Intent.IGNORE, parse("Totally darling, it's crazy. Remy.", CookingSession.Phase.NEEDS_DISH).intent)
        assertEquals(VoiceCommand(VoiceCommand.Intent.AGENT, "not too salty please"), parse("Not too salty, please.", recent = true))
        assertEquals(VoiceCommand.Intent.WAKE, parse("Remy.", CookingSession.Phase.INGREDIENTS).intent)
        assertTrue(VoiceCommand.startsWithWakeWord("Hey Remy, it's burning"))
        assertEquals(VoiceCommand.Intent.IGNORE, parse("Chef, next step").intent)
        assertEquals(VoiceCommand.Intent.IGNORE, parse("Hey Chef, next step").intent)
        assertFalse(VoiceCommand.startsWithWakeWord("Remybot, next"))
    }

    @Test fun testBareCommandsSkipTheModel() {
        assertEquals(VoiceCommand.Intent.NEXT, parse("Remy, next step please.").intent)
        assertEquals(VoiceCommand.Intent.PREVIOUS, parse("Remy, go back").intent)
        assertEquals(VoiceCommand.Intent.REPEAT, parse("Remy, say that again").intent)
        assertEquals(VoiceCommand.Intent.START_COOKING, parse("Remy, let's start cooking", CookingSession.Phase.INGREDIENTS).intent)
        assertEquals("a sentence, not a bare command", VoiceCommand.Intent.AGENT, parse("Okay, done. What's next?", recent = true).intent)
    }

    @Test fun testSentencesGoToRemyWhole() {
        assertEquals(VoiceCommand(VoiceCommand.Intent.AGENT, "i still see red wine vinegar in the ingredients list can you change that"),
            parse("Remy, I still see red wine vinegar in the ingredients list. Can you change that?", CookingSession.Phase.INGREDIENTS))
        assertEquals(VoiceCommand.Intent.AGENT, parse("Remy, let's me call pasta salad today", CookingSession.Phase.NEEDS_DISH).intent)
        assertEquals(VoiceCommand.Intent.AGENT, parse("Remy, where's the salt?").intent)
        assertEquals(VoiceCommand.Intent.AGENT, parse("Remy, I'm done chopping, what's next?").intent)
    }
}

// Port of ChefWakeGateTests.swift.
class ChefWakeGateTest {
    @Test fun testEitherWakePhraseAuthorizesAnIngredientRequest() {
        for (text in listOf("here's the onion", "yes remy", "okay remy", "I said hey remy", "hey remybot", "chef", "hey chef", "chief", "shef")) {
            val gate = ChefWakeGate()
            assertNull(text, gate.accept(text, 1.0))
        }
        val gate = ChefWakeGate()
        assertEquals("here's the onion", gate.accept("Hey Remy, here's the onion", 1.0))
        assertNull(gate.accept("here is cucumber", 2.0))
        assertEquals("here's the cucumber", gate.accept("Remy, here's the cucumber", 3.0))
    }

    @Test fun testWakeAloneAllowsOnlyOneTimelyContinuation() {
        val gate = ChefWakeGate()
        assertEquals("", gate.accept("Hey Remy!", 1.0))
        assertEquals("here's the first ingredient", gate.accept("here's the first ingredient", 3.0))
        assertNull(gate.accept("here's another ingredient", 4.0))
        assertEquals("", gate.accept("hey remy", 5.0))
        assertNull(gate.accept("here's the onion", 14.0))
    }

    @Test fun testCookingConversationRemainsOpenUntilExplicitlyClosedByTheCaller() {
        val gate = ChefWakeGate()
        assertEquals("What should I do next?", gate.accept("What should I do next?", 100.0, conversationOpen = true))
        assertEquals("I'm done", gate.accept("I'm done", 200.0, conversationOpen = true))
        assertNull(gate.accept("here's the onion", 201.0))
    }

    @Test fun testNaturalReadinessDoesNotTreatAQualifiedYesAsPermission() {
        for (text in listOf("Yes!", "yep", "I'm ready", "sounds good", "let's go", "yes please")) {
            assertEquals(text, CookingReadinessReply.Decision.READY, CookingReadinessReply.parse(text))
        }
        for (text in listOf("no", "not yet", "hold on", "I'm not ready")) {
            assertEquals(text, CookingReadinessReply.Decision.WAIT, CookingReadinessReply.parse(text))
        }
        for (text in listOf("yes but wait", "I said yes earlier", "do you mean ready?", "what's next?")) {
            assertNull(text, CookingReadinessReply.parse(text))
        }
    }

    @Test fun testFiveIngredientsThroughCookingCompletion() {
        val draft = IngredientDraft.preset("pasta salad")!!
        val session = CookingSession()
        assertTrue(session.startIngredients(draft))
        assertFalse(session.ingredientsCollected)
        for (ingredient in draft.ingredients) session.setPantry(ingredient.id, PantryStatus.SEEN)
        assertTrue(session.ingredientsCollected)
        val gate = ChefWakeGate()
        val reply = gate.accept("yes", 100.0, conversationOpen = session.ingredientsCollected)
        assertEquals(CookingReadinessReply.Decision.READY, CookingReadinessReply.parse(reply!!))
        session.beginCooking()
        assertEquals("Never enter cooking with no executable instructions", CookingSession.Phase.INGREDIENTS, session.phase)
        val steps = listOf(
            RecipeStep(id = "cook", title = "Cook pasta", instruction = "Boil pasta in water.", doneWhen = "pasta cooked"),
            RecipeStep(id = "chop", title = "Prepare vegetables", instruction = "Dice vegetables.", needs = listOf("cook"), doneWhen = "vegetables diced"),
            RecipeStep(id = "mix", title = "Mix salad", instruction = "Mix pasta, vegetables and lemon juice.", needs = listOf("chop"), doneWhen = "salad combined"),
        )
        assertTrue(session.applyInstructions(RecipePlan(draft.dish, draft.ingredients, steps), session.id, draft.ingredients))
        session.beginCooking()
        assertEquals(CookingSession.Phase.COOKING, session.phase)
        assertEquals("How small should I cut these?", gate.accept("How small should I cut these?", 200.0, conversationOpen = session.phase == CookingSession.Phase.COOKING))
        session.nextStep(); assertEquals(1, session.currentStep)
        session.selectStep(0); assertEquals(0, session.currentStep)
        session.nextStep(); session.nextStep()
        assertFalse(session.isComplete)
        session.nextStep(); assertTrue(session.isComplete)
        assertEquals(3, session.done.size)
    }
}

// Android-only checks for the prompt and output-contract ports.
class PromptContractTest {
    @Test fun testInstructionGivesADataExampleWithSortedKeys() {
        val text = JSONOutputContract.instruction(ChefPrompt.board.schema)
        assertTrue(text.endsWith("""{"concern":"none","confidence":0.5,"evidence":"value","line":"value","saltAdded":false,"stepComplete":false}"""))
        assertEquals("\nReturn one JSON object with the requested fields, without markdown.", JSONOutputContract.instruction(""))
    }

    @Test fun testCleanRemovesOnlyWrappers() {
        assertEquals("""{"a":1}""", JSONOutputContract.clean("```json\n{\"a\":1}\n```"))
        assertEquals("""{"a":1}""", JSONOutputContract.clean("Sure: {\"a\":1} done"))
        assertEquals("{\"a\":1} {\"b\":2}", JSONOutputContract.clean("{\"a\":1} {\"b\":2}"))
    }

    @Test fun testInstructionsTaskKeepsOnlyTheStepSchema() {
        val task = ChefPrompt.instructionsTask(4)
        assertTrue(task.schema.startsWith("""{"additionalProperties":false,"properties":{"steps":{"items":"""))
        assertTrue(task.system.contains("at most 4, including questions"))
        assertTrue(ChefPrompt.planTask(12).system.startsWith(ChefPrompt.persona + "\nPlan a recipe"))
    }
}
