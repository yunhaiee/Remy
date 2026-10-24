import XCTest
@testable import RemyCore

final class IngredientDraftTests: XCTestCase {
    private var draft: IngredientDraft { IngredientDraft.preset(for: "Pasta salad")! }
    private func instructions(for draft: IngredientDraft) -> RecipePlan {
        RecipePlan(dish: draft.dish, ingredients: draft.ingredients, steps: [
            .init(id: "prepare", title: "Prepare ingredients", instruction: "Prepare the listed vegetables.", doneWhen: "vegetables chopped"),
            .init(id: "mix", title: "Mix salad", instruction: "Mix the pasta and vegetables.", needs: ["prepare"], doneWhen: "salad combined")
        ])
    }

    func testRequestedPastaSaladPresetContainsExactlyFiveIngredientsWithoutSalt() {
        let preset = IngredientDraft.preset(for: "Let's make COLD PASTA SALAD!")
        XCTAssertEqual(preset?.ingredients.map(\.name), ["pasta", "lemon", "onion", "cucumber", "tomato"])
        XCTAssertEqual(preset?.ingredients.map(\.id), ["pasta", "lemon", "onion", "cucumber", "tomato"])
        XCTAssertEqual(preset?.problems, [])
        XCTAssertNil(IngredientDraft.preset(for: "Guacamole"))
        XCTAssertNil(IngredientDraft.preset(for: "Salad"))
    }

    func testDraftNormalizesDisplayNamesBeforeFreezingTheIngredientContract() throws {
        let parsed = try IngredientDraft.decode(#"{"dish":" Toast ","ingredients":[{"id":"olive_oil","name":" olive_oil ","amount":" 1 tsp "}]}"#)
        XCTAssertEqual(parsed.dish, "Toast")
        XCTAssertEqual(parsed.ingredients, [.init(id: "olive_oil", name: "olive oil", amount: "1 tsp")])
    }

    func testPresetAcceptsOnlyPlainRequestsAndPreservesExplicitModifiersForTheModel() {
        for request in ["pasta salad", "Cold pasta salad", "Let's make COLD PASTA SALAD!",
                        "Let’s cook a pasta salad", "Please make me a pasta salad", "I want a pasta salad",
                        "Can we make pasta salad, please?", "A recipe for pasta salad"] {
            XCTAssertNotNil(IngredientDraft.preset(for: request), request)
        }
        for request in ["pasta salad without tomato", "pasta salad with chicken", "tomato-free pasta salad",
                        "pasta salad, I'm allergic to onion", "I have a lemon allergy; make pasta salad",
                        "gluten free pasta salad", "pasta salad for four", "pasta salad or soup",
                        "Do not make pasta salad", "Don't make pasta salad", "not pasta salad"] {
            XCTAssertNil(IngredientDraft.preset(for: request), request)
        }
    }

    func testIngredientOnlyDraftCanBeReviewedButCannotStartCooking() {
        var session = CookingSession()
        XCTAssertTrue(session.startIngredients(draft))
        XCTAssertEqual(session.phase, .ingredients)
        XCTAssertEqual(session.plan?.ingredients, draft.ingredients)
        XCTAssertEqual(session.plan?.steps, [])
        XCTAssertTrue(session.instructionsPending)
        XCTAssertFalse(session.instructionsReady)
        session.setPantry("pasta", .seen)
        session.beginCooking()
        XCTAssertEqual(session.phase, .ingredients)
        XCTAssertFalse(session.ingredientsReviewed)
        XCTAssertNil(session.step)
    }

    func testCompletingInstructionsPreservesPantryReviewAcrossRevisionChanges() {
        var session = CookingSession(); session.startIngredients(draft)
        let sessionID = session.id
        session.setPantry("pasta", .seen)
        session.setPantry("onion", .missing)
        session.markUnavailable("onion")
        let revision = session.revision
        XCTAssertTrue(session.applyInstructions(instructions(for: draft), expectedSessionID: sessionID,
                                                expectedIngredients: draft.ingredients))
        XCTAssertEqual(session.pantry["pasta"], .init(status: .seen, origin: .user))
        XCTAssertEqual(session.pantry["onion"], .init(status: .missing, origin: .user))
        XCTAssertTrue(session.isUnavailable("onion"))
        XCTAssertGreaterThan(session.revision, revision)
        XCTAssertTrue(session.instructionsReady)
        XCTAssertFalse(session.instructionsPending)
        XCTAssertEqual(session.phase, .ingredients, "preparing instructions must not start cooking automatically")
        session.beginCooking()
        XCTAssertEqual(session.phase, .cooking)
    }

    func testChangedIngredientListRejectsOldInstructionsAndAllowsNewestList() {
        var session = CookingSession(); session.startIngredients(draft)
        let sessionID = session.id
        XCTAssertTrue(session.substitute("onion", with: "shallot"))
        XCTAssertFalse(session.applyInstructions(instructions(for: draft), expectedSessionID: sessionID,
                                                 expectedIngredients: draft.ingredients))
        XCTAssertTrue(session.instructionsPending)
        XCTAssertEqual(session.plan?.ingredients.first { $0.id == "onion" }?.name, "shallot")
        let newest = IngredientDraft(dish: session.plan!.dish, ingredients: session.plan!.ingredients)
        XCTAssertTrue(session.applyInstructions(instructions(for: newest), expectedSessionID: sessionID,
                                                expectedIngredients: newest.ingredients))
    }

    func testInstructionsFromAnEarlierSessionOrDuplicateCompletionAreRejected() {
        var session = CookingSession(); session.startIngredients(draft)
        let earlier = session.id
        session.startIngredients(draft)
        XCTAssertFalse(session.applyInstructions(instructions(for: draft), expectedSessionID: earlier,
                                                 expectedIngredients: draft.ingredients))
        XCTAssertTrue(session.applyInstructions(instructions(for: draft), expectedSessionID: session.id,
                                                expectedIngredients: draft.ingredients))
        XCTAssertFalse(session.applyInstructions(instructions(for: draft), expectedSessionID: session.id,
                                                 expectedIngredients: draft.ingredients))
    }

    func testPersistedDraftStillRequiresInstructions() throws {
        var session = CookingSession(); session.startIngredients(draft); session.setPantry("lemon", .seen)
        var restored = try JSONDecoder().decode(CookingSession.self, from: JSONEncoder().encode(session))
        restored.restoredAfterLaunch()
        XCTAssertTrue(restored.instructionsPending)
        XCTAssertEqual(restored.pantry["lemon"], .init(status: .seen, origin: .user))
        restored.beginCooking()
        XCTAssertEqual(restored.phase, .ingredients)
    }

    func testInvalidDraftCannotReplaceTheCurrentSession() throws {
        let invalid = IngredientDraft(dish: "", ingredients: [.init(id: "x", name: "", amount: "")])
        var session = CookingSession(); session.startIngredients(draft)
        let id = session.id
        XCTAssertFalse(session.startIngredients(invalid))
        XCTAssertEqual(session.id, id)
        XCTAssertThrowsError(try IngredientDraft.decode(#"{"dish":"Salad","ingredients":[{"id":"x","name":"onion","amount":"1"},{"id":"x","name":"cucumber","amount":"1"}]}"#))
        XCTAssertThrowsError(try IngredientDraft.decode(#"{"dish":"Salad","ingredients":[{"id":"onion","name":"onion","amount":"1"},{"id":"onion_two","name":"Onion","amount":"1"}]}"#))
    }

    func testStepsOnlyReplyPreservesIngredientContractAndRejectsNewSeasoning() throws {
        let output = RecipeInstructions(steps: instructions(for: draft).steps)
        let text = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        let complete = try RecipeInstructions.decode(text, for: draft)
        XCTAssertEqual(complete.ingredients, draft.ingredients)
        XCTAssertEqual(complete.dish, draft.dish)
        XCTAssertEqual(complete.problems, [])
        let extra = RecipeInstructions(steps: [
            .init(id: "prepare", title: "Prepare", instruction: "Prepare vegetables.", doneWhen: "chopped"),
            .init(id: "pepper", title: "Add pepper", instruction: "Add pepper once.", doneWhen: "seasoned", guardItem: "pepper")
        ])
        XCTAssertThrowsError(try RecipeInstructions.decode(String(decoding: JSONEncoder().encode(extra), as: UTF8.self), for: draft))
        XCTAssertThrowsError(try RecipeInstructions.decode(#"{"steps":[]}"#, for: draft))
        XCTAssertThrowsError(try RecipeInstructions.decode(#"{"ingredients":[],"steps":[]}"#, for: draft))
    }

    func testRemovingSaltPreservesPantryButInvalidatesOldInstructions() {
        let old = RecipePlan(dish: "Pasta salad", ingredients: draft.ingredients + [.init(id: "salt", name: "salt", amount: "to taste")], steps: [
            .init(id: "prepare", title: "Prepare vegetables", instruction: "Dice the vegetables.", doneWhen: "vegetables diced"),
            .init(id: "mix", title: "Mix salad", instruction: "Mix pasta, vegetables and salt.", needs: ["prepare"], doneWhen: "salad mixed")
        ])
        var session = CookingSession()
        session.start(old)
        session.setPantry("onion", .seen)
        session.setPantry("salt", .seen)
        XCTAssertTrue(session.removeForReplanning("salt"))
        XCTAssertEqual(session.plan?.ingredients.map(\.id), draft.ingredients.map(\.id))
        XCTAssertEqual(session.pantry["onion"]?.status, .seen)
        XCTAssertNil(session.pantry["salt"])
        XCTAssertTrue(session.plan?.steps.isEmpty == true)
        XCTAssertTrue(session.isUnavailable("salt"))
        XCTAssertFalse(session.removeForReplanning("salt"))
    }
    func testInstructionsCannotAddUnlistedSaltThroughProse() {
        let text = #"{"steps":[{"id":"prepare","kind":"do","title":"Prepare vegetables","instruction":"Dice vegetables.","needs":[],"doneWhen":"vegetables diced"},{"id":"mix","kind":"do","title":"Mix salad","instruction":"Mix pasta and vegetables with salt.","needs":["prepare"],"doneWhen":"salad mixed"}]}"#
        XCTAssertThrowsError(try RecipeInstructions.decode(text, for: draft))
        XCTAssertNoThrow(try RecipeInstructions.decode(text.replacingOccurrences(of: " with salt", with: ""), for: draft))
    }

    func testMalformedDeviceInstructionRepliesAreRejectedWithoutRepair() {
        // Regression for the physical model reply: a broken quote and an ask without core fields.
        let malformed = #"{"steps":[{"id":"ask_salt","kind":"ask","question":"How salty?","saves":"salt","doneWhen:null}]}"#
        let missingCoreFields = #"{"steps":[{"id":"ask_salt","kind":"ask","needs":[],"doneWhen":"","question":"How salty?","saves":"salt"},{"id":"season","kind":"do","title":"Add salt","instruction":"Add salt once.","needs":["ask_salt"],"doneWhen":"salt added","guardItem":"salt"}]}"#
        XCTAssertThrowsError(try RecipeInstructions.decode(malformed, for: draft))
        XCTAssertThrowsError(try RecipeInstructions.decode(missingCoreFields, for: draft))
    }
    func testFixedRecipeHasThreeValidSaltFreeInstructions() {
        let plan = draft.presetInstructions!
        XCTAssertEqual(plan.problems, [])
        XCTAssertEqual(plan.ingredients, draft.ingredients)
        XCTAssertEqual(plan.steps.count, 3)
        XCTAssertEqual(plan.steps.map(\.id), ["cook_pasta", "prepare", "combine"])
        XCTAssertFalse(plan.steps.contains { $0.kind == .ask || $0.isGuarded })
        XCTAssertFalse(plan.steps.contains { ($0.instruction + $0.title).lowercased().contains("salt") })
        let modified = IngredientDraft(dish: draft.dish, ingredients: Array(draft.ingredients.dropLast()))
        XCTAssertNil(modified.presetInstructions, "Never replace an edited recipe with the preset")
    }

    func testCookerSafetyIsArmedOnlyAfterStepOneUntilStepThreeFinishes() throws {
        var session = CookingSession(); session.start(draft.presetInstructions!)
        XCTAssertTrue(session.usesCookerSafetySequence)
        XCTAssertFalse(session.cookerSafetyArmed)
        session.beginCooking()
        XCTAssertFalse(session.cookerSafetyArmed)
        session.nextStep()
        XCTAssertTrue(session.cookerSafetyArmed)
        session.nextStep()
        XCTAssertTrue(session.cookerSafetyArmed)
        let restored = try JSONDecoder().decode(CookingSession.self, from: JSONEncoder().encode(session))
        XCTAssertTrue(restored.cookerSafetyArmed)
        session.nextStep()
        XCTAssertFalse(session.cookerSafetyArmed)
        session.selectStep(1)
        XCTAssertFalse(session.cookerSafetyArmed, "going back after finishing does not re-arm the cooker")
        var other = CookingSession(); other.start(instructions(for: draft)); other.beginCooking(); other.nextStep()
        XCTAssertFalse(other.cookerSafetyArmed)
    }
    func testLegacyPresetMigrationNeverArmsFromOldCompletion() {
        let updated = draft.presetInstructions!
        let old = RecipePlan(dish: updated.dish, ingredients: updated.ingredients, steps: [
            RecipeStep(id: "cook_pasta", title: "Cook and cool pasta",
                instruction: "Cook pasta in plain water according to its package directions, then drain and let it cool.",
                doneWhen: "pasta cooked, drained and cooled", tool: "pot")
        ] + Array(updated.steps.dropFirst()))
        var session = CookingSession(); session.start(old)
        for ingredient in old.ingredients { session.setPantry(ingredient.id, .seen) }
        session.beginCooking(); session.nextStep()
        XCTAssertTrue(session.refreshLegacyPastaInstructions())
        XCTAssertEqual(session.plan, updated)
        XCTAssertTrue(session.ingredientsCollected)
        XCTAssertEqual(session.done, [])
        XCTAssertEqual(session.phase, .ingredients)
        XCTAssertFalse(session.cookerSafetyArmed)
        XCTAssertFalse(session.refreshLegacyPastaInstructions())
    }

    func testCookerPowerOffPersistsAndOnResumesWithoutMovingSteps() throws {
        var session = CookingSession(); session.start(draft.presetInstructions!); session.beginCooking(); session.nextStep()
        XCTAssertTrue(session.cookerSafetyArmed)
        let step = session.currentStep
        session.reportCookerPower(on: false)
        XCTAssertFalse(session.cookerSafetyArmed)
        session = try JSONDecoder().decode(CookingSession.self, from: JSONEncoder().encode(session))
        XCTAssertFalse(session.cookerSafetyArmed)
        session.nextStep()
        XCTAssertFalse(session.cookerSafetyArmed, "advancing from step 2 to 3 must not undo power off")
        session.reportCookerPower(on: true)
        XCTAssertTrue(session.cookerSafetyArmed)
        XCTAssertEqual(session.currentStep, step + 1)
        session.nextStep()
        XCTAssertFalse(session.cookerSafetyArmed, "recipe completion still ends the demo window")
    }

}
