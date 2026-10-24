import XCTest
@testable import RemyCore
final class ChefWakeGateTests: XCTestCase {
    func testEitherWakePhraseAuthorizesAnIngredientRequest() {
        for text in ["here's the onion", "yes chef", "okay chef", "I said hey chef", "hey chefbot"] {
            var gate = ChefWakeGate()
            XCTAssertNil(gate.accept(text, now: 1), text)
        }
        var gate = ChefWakeGate()
        XCTAssertEqual(gate.accept("Hey Chef, here's the onion", now: 1), "here's the onion")
        XCTAssertNil(gate.accept("here is cucumber", now: 2))
        XCTAssertEqual(gate.accept("Chef, here's the cucumber", now: 3), "here's the cucumber")
        XCTAssertEqual(gate.accept("Hey Remy, here's the lemon", now: 4), "here's the lemon")
        XCTAssertEqual(gate.accept("Remi, here's the tomato", now: 5), "here's the tomato")
        // "Ready" is the reply to "Ready to cook?", never a wake word, however speech spells it.
        for text in ["ready", "Ready, here's the onion", "remedy the sauce"] { XCTAssertNil(gate.accept(text, now: 6), text) }
    }
    func testWakeAloneAllowsOnlyOneTimelyContinuation() {
        var gate = ChefWakeGate()
        XCTAssertEqual(gate.accept("Hey Chef!", now: 1), "")
        XCTAssertEqual(gate.accept("here's the first ingredient", now: 3), "here's the first ingredient")
        XCTAssertNil(gate.accept("here's another ingredient", now: 4))
        XCTAssertEqual(gate.accept("hey chef", now: 5), "")
        XCTAssertNil(gate.accept("here's the onion", now: 14))
    }
    func testCookingConversationRemainsOpenUntilExplicitlyClosedByTheCaller() {
        var gate = ChefWakeGate()
        XCTAssertEqual(gate.accept("What should I do next?", now: 100, conversationOpen: true), "What should I do next?")
        XCTAssertEqual(gate.accept("I'm done", now: 200, conversationOpen: true), "I'm done")
        XCTAssertNil(gate.accept("here's the onion", now: 201))
    }
    func testNaturalReadinessDoesNotTreatAQualifiedYesAsPermission() {
        for text in ["Yes!", "yep", "I'm ready", "sounds good", "let's go", "yes please"] {
            XCTAssertEqual(CookingReadinessReply.parse(text), .ready, text)
        }
        for text in ["no", "not yet", "hold on", "I'm not ready"] {
            XCTAssertEqual(CookingReadinessReply.parse(text), .wait, text)
        }
        for text in ["yes but wait", "I said yes earlier", "do you mean ready?", "what's next?"] {
            XCTAssertNil(CookingReadinessReply.parse(text), text)
        }
    }

    func testFiveIngredientsThroughCookingCompletion() {
        let draft = IngredientDraft.preset(for: "pasta salad")!
        var session = CookingSession()
        XCTAssertTrue(session.startIngredients(draft))
        XCTAssertFalse(session.ingredientsCollected)
        for ingredient in draft.ingredients { session.setPantry(ingredient.id, .seen) }
        XCTAssertTrue(session.ingredientsCollected)
        var gate = ChefWakeGate()
        let reply = gate.accept("yes", now: 100, conversationOpen: session.ingredientsCollected)
        XCTAssertEqual(CookingReadinessReply.parse(reply!), .ready)
        session.beginCooking()
        XCTAssertEqual(session.phase, .ingredients, "Never enter cooking with no executable instructions")
        let steps = [
            RecipeStep(id: "cook", title: "Cook pasta", instruction: "Boil pasta in water.", doneWhen: "pasta cooked"),
            RecipeStep(id: "chop", title: "Prepare vegetables", instruction: "Dice vegetables.", needs: ["cook"], doneWhen: "vegetables diced"),
            RecipeStep(id: "mix", title: "Mix salad", instruction: "Mix pasta, vegetables and lemon juice.", needs: ["chop"], doneWhen: "salad combined")
        ]
        XCTAssertTrue(session.applyInstructions(.init(dish: draft.dish, ingredients: draft.ingredients, steps: steps), expectedSessionID: session.id, expectedIngredients: draft.ingredients))
        session.beginCooking()
        XCTAssertEqual(session.phase, .cooking)
        XCTAssertEqual(gate.accept("How small should I cut these?", now: 200, conversationOpen: session.phase == .cooking), "How small should I cut these?")
        session.nextStep(); XCTAssertEqual(session.currentStep, 1)
        session.selectStep(0); XCTAssertEqual(session.currentStep, 0)
        session.nextStep(); session.nextStep()
        XCTAssertFalse(session.isComplete)
        session.nextStep(); XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.done.count, 3)
    }

}
