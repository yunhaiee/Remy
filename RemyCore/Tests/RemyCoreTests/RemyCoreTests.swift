import XCTest
@testable import RemyCore

private let plan = RecipePlan(
    dish: "Cold pasta salad",
    ingredients: [.init(id: "pasta", name: "fusilli", amount: "200 g"), .init(id: "cucumber", name: "cucumber", amount: "1"),
                  .init(id: "salt", name: "salt", amount: "to taste")],
    steps: [
        .init(id: "dice", title: "Dice the cucumber", instruction: "Cut into bite-size cubes.",
              doneWhen: "cucumber in fingertip-size cubes", wrongSize: "long spears", tool: "chef's knife"),
        .init(id: "taste", kind: .ask, title: "Salt preference", instruction: "Ask how salty.",
              question: "How salty do you like it?", saves: "salt"),
        .init(id: "dress", title: "Make the dressing", instruction: "Oil, lemon and one addition of salt.", needs: ["taste"],
              doneWhen: "oil, lemon and salt in the bowl", guardItem: "salt"),
        .init(id: "toss", title: "Toss", instruction: "Mix everything.", needs: ["dice", "dress"], doneWhen: "mixed")
    ])

/// A session that has planned, reviewed ingredients and is sitting on the guarded dressing step.
private func atDressing() -> CookingSession {
    var session = CookingSession(); session.start(plan); session.beginCooking()
    session.nextStep(); session.answer("lightly salted", heard: nil, origin: .user)
    return session
}

final class RemyCoreTests: XCTestCase {
    func testPlanValidationCatchesBrokenGraphs() throws {
        XCTAssertEqual(plan.problems, [])
        let forward = RecipePlan(dish: "x", ingredients: plan.ingredients, steps: [
            .init(id: "a", title: "A", instruction: "", needs: ["b"], doneWhen: "d"), .init(id: "b", title: "B", instruction: "", doneWhen: "d")])
        XCTAssertTrue(forward.problems.contains { $0.contains("not an earlier step") })
        let askWithoutQuestion = RecipePlan(dish: "x", ingredients: plan.ingredients, steps: [
            .init(id: "a", kind: .ask, title: "A", instruction: ""), .init(id: "b", title: "B", instruction: "", doneWhen: "d")])
        XCTAssertFalse(askWithoutQuestion.problems.isEmpty)
        let repaired = try RecipePlan.decode(String(decoding: try JSONEncoder().encode(forward), as: UTF8.self))
        XCTAssertEqual(repaired.steps[0].needs, [], "a forward reference is dropped, not a re-plan")
        let saltWithoutAsk = RecipePlan(dish: "x", ingredients: plan.ingredients, steps: [
            .init(id: "a", title: "Mash", instruction: "Mash it.", doneWhen: "d"), .init(id: "b", title: "Add salt", instruction: "Salt it.", doneWhen: "d")]).normalized
        XCTAssertEqual(saltWithoutAsk.problems, [])
        XCTAssertEqual(saltWithoutAsk.steps.map(\.id), ["a", "ask_salt", "b"], "the missing salt question is inserted")
        XCTAssertEqual(saltWithoutAsk.steps[2].guardItem, "salt")
        XCTAssertEqual(try RecipePlan.decode("```json\n\(String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))\n```"), plan.normalized)
    }
    func testNormalizingGuardsTheStepThatUsesAnAnswer() {
        let loose = RecipePlan(dish: "x", ingredients: [.init(id: "chili_flakes", name: "chili_flakes", amount: "")], steps: [
            .init(id: "ask", kind: .ask, title: "Salt", instruction: "", doneWhen: "stray", question: "How salty?", saves: "salt"),
            .init(id: "herbs", title: "Herbs", instruction: "Sprinkle oregano.", needs: ["ask"], doneWhen: "d", question: "stray")])
        let plan = loose.normalized
        XCTAssertEqual(plan.steps[0].doneWhen, ""); XCTAssertEqual(plan.steps[1].question, "")
        XCTAssertEqual(plan.steps[1].guardItem, "salt")
        XCTAssertEqual(plan.steps[1].instruction, "Sprinkle oregano. Add the salt once, to taste.")
        XCTAssertEqual(plan.ingredients[0].name, "chili flakes")
        let repeated = RecipePlan(dish: "x", ingredients: [.init(id: "cheese", name: "mozzarella", amount: ""),
                                                           .init(id: "cheese", name: "parmesan", amount: "")], steps: loose.steps).normalized
        XCTAssertEqual(repeated.ingredients.map(\.id), ["cheese", "cheese_2", "salt"], "salt is asked about, so it is listed")
        let fromModel = #"{"dish":"x","ingredients":[{"id":"salt","name":"salt","amount":""}],"steps":[{"id":"ask","kind":"ask","title":"Salt","instruction":"","needs":[],"doneWhen":"","wrongSize":"","tool":"","guardItem":"","question":"How salty?","saves":"salt"},{"id":"add","kind":"do","title":"Add salt","instruction":"Salt it.","needs":["ask"],"doneWhen":"d","wrongSize":"","tool":"","guardItem":"","question":"","saves":""}]}"#
        XCTAssertEqual(try RecipePlan.decode(fromModel).steps[1].warning, "Taste first. The salt can't come back out.", "model JSON has no warning key")
        XCTAssertEqual(plan.steps[1].warning, "Taste first. The salt can't come back out.")
        let drain = RecipePlan(dish: "x", ingredients: loose.ingredients, steps: [
            .init(id: "d", title: "Drain the pasta", instruction: "Tip it out.", doneWhen: "d", warning: "Have fun!")]).normalized
        XCTAssertEqual(drain.steps[0].warning, "Put the colander in the sink before you pour.", "rules replace model text")
        let two = RecipePlan(dish: "x", ingredients: loose.ingredients, steps: [
            .init(id: "chili", kind: .ask, title: "Chili", instruction: "", question: "How spicy?", saves: "chili_flame"),
            .init(id: "salt", kind: .ask, title: "Salt", instruction: "", question: "How salty?", saves: "salt"),
            .init(id: "herbs", title: "Herbs", instruction: "Sprinkle oregano.", needs: ["chili", "salt"], doneWhen: "d")]).normalized
        XCTAssertEqual(two.steps[2].guardItem, "salt")
    }
    func testFlowGoesDishThenIngredientsThenCooking() {
        var session = CookingSession()
        XCTAssertEqual(session.phase, .needsDish)
        session.start(plan); XCTAssertEqual(session.phase, .ingredients)
        session.beginCooking(); XCTAssertEqual(session.phase, .cooking); XCTAssertEqual(session.step?.id, "dice")
    }
    func testAnswerSavesPreferenceAndAdvances() {
        var session = CookingSession(); session.start(plan); session.beginCooking(); session.nextStep()
        XCTAssertEqual(session.step?.kind, .ask)
        session.nextStep()
        XCTAssertEqual(session.step?.id, "taste", "an ask step only finishes with an answer")
        session.answer("not too salty", heard: "um not too salty please", origin: .camera)
        XCTAssertEqual(session.preferences["salt"], "not too salty")
        XCTAssertEqual(session.step?.id, "dress"); XCTAssertTrue(session.done.contains("taste"))
    }
    func testUnmetNeedsListsSkippedDependencies() {
        var session = CookingSession(); session.start(plan); session.beginCooking()
        session.selectStep(3)
        XCTAssertEqual(Set(session.unmetNeeds.map(\.id)), ["dice", "dress"])
    }
    func testIngredientCheckIsStaleSafeAndCookOverrides() throws {
        var session = CookingSession(); session.start(plan)
        let check = try IngredientCheck.decode(#"{"items":[{"id":"pasta","status":"seen"},{"id":"salt","status":"unsure"}],"line":"Is that salt?"}"#, plan: plan)
        session.setPantry("salt", .seen)
        let revision = session.revision
        XCTAssertTrue(session.applyIngredientCheck(check, expectedSessionID: session.id, expectedRevision: revision))
        XCTAssertEqual(session.pantry["pasta"]?.status, .seen)
        XCTAssertEqual(session.pantry["salt"], .init(status: .seen, origin: .user), "the cook's word beats the camera")
        XCTAssertFalse(session.applyIngredientCheck(check, expectedSessionID: session.id, expectedRevision: revision))
        XCTAssertThrowsError(try IngredientCheck.decode(#"{"items":[{"id":"saffron","status":"seen"}],"line":"x"}"#, plan: plan))
    }
    func testStaleModelReplyCannotArmGuardAfterUserMovesToAnotherStep() {
        var session = atDressing()
        let revision = session.revision
        session.nextStep()
        XCTAssertFalse(session.apply(.init(confidence: 0.99, saltAdded: true, evidence: "pour", line: "Stop"), expectedSessionID: session.id, expectedRevision: revision, frameAge: 2, frameCount: 3))
        XCTAssertFalse(session.salted)
    }
    func testSaltRequiresGuardedStepStrongConfidenceAndSequence() {
        let observation = ChefObservation(confidence: 0.95, saltAdded: true, evidence: "salt enters bowl", line: "Salt remembered")
        var session = CookingSession(); session.start(plan); session.beginCooking()
        XCTAssertTrue(session.apply(observation, expectedSessionID: session.id, expectedRevision: session.revision, frameAge: 1, frameCount: 3))
        XCTAssertFalse(session.salted, "unguarded step")
        session = atDressing()
        XCTAssertTrue(session.apply(observation, expectedSessionID: session.id, expectedRevision: session.revision, frameAge: 1, frameCount: 1))
        XCTAssertFalse(session.salted)
        XCTAssertTrue(session.apply(observation, expectedSessionID: session.id, expectedRevision: session.revision, frameAge: 1, frameCount: 3))
        XCTAssertTrue(session.salted); XCTAssertEqual(session.saltOrigin, .camera)
        session.markZone(.init(center: .init(0.7, 0.5)))
        XCTAssertTrue(session.guardArmed)
        session.nextStep(); XCTAssertFalse(session.guardArmed)
    }
    func testCameraMoveDisarmsAndManualConfirmationHasHonestProvenance() {
        var session = atDressing()
        session.markZone(.init(center: .init(0.5, 0.5))); session.confirmSalt()
        XCTAssertTrue(session.guardArmed); XCTAssertEqual(session.saltOrigin, .user)
        session.invalidateZone(); XCTAssertFalse(session.guardArmed); XCTAssertTrue(session.salted)
    }
    func testSourceSwitchOrPauseRejectsPendingObservationWithoutMarkedZone() {
        var session = atDressing()
        let revision = session.revision
        session.invalidateZone()
        XCTAssertFalse(session.apply(.init(confidence: 0.99, saltAdded: true, evidence: "previous camera", line: "Salt added"), expectedSessionID: session.id, expectedRevision: revision, frameAge: 1, frameCount: 3))
        XCTAssertFalse(session.salted)
    }
    func testReplyFromAnEarlierSessionCannotMutateNewPlan() {
        var session = CookingSession(); session.start(plan); session.beginCooking()
        let oldID = session.id
        session.start(plan); session.beginCooking()
        let events = session.events.count
        XCTAssertFalse(session.apply(.init(confidence: 0.99, evidence: "old image", line: "done"), expectedSessionID: oldID, expectedRevision: session.revision, frameAge: 1, frameCount: 3))
        XCTAssertEqual(session.events.count, events)
    }
    func testInvalidOrExpiredObservationIsRejected() throws {
        XCTAssertThrowsError(try ChefObservation.decode("{\"confidence\":2}"))
        var session = CookingSession(); session.start(plan); session.beginCooking()
        let r = session.revision
        XCTAssertFalse(session.apply(.init(confidence: .nan, evidence: "x", line: "x"), expectedSessionID: session.id, expectedRevision: r, frameAge: 1, frameCount: 3))
        XCTAssertFalse(session.apply(.init(confidence: 0.99, evidence: "x", line: "x"), expectedSessionID: session.id, expectedRevision: r, frameAge: 13, frameCount: 3))
        XCTAssertFalse(session.apply(.init(confidence: 0.99, evidence: "x", line: "x"), expectedSessionID: session.id, expectedRevision: r, frameAge: -1, frameCount: 3))
    }
    func testSavedSessionRestoresWithoutTrustingOldLocation() throws {
        var session = atDressing()
        session.markZone(.init(center: .init(0.5, 0.5))); session.confirmSalt()
        var restored = try JSONDecoder().decode(CookingSession.self, from: try JSONEncoder().encode(session))
        XCTAssertEqual(restored.preferences, session.preferences); XCTAssertEqual(restored.step?.id, "dress")
        restored.restoredAfterLaunch()
        XCTAssertNil(restored.zone); XCTAssertFalse(restored.guardArmed); XCTAssertTrue(restored.salted)
    }
    func testStepsMayLeaveOutFieldsThatDoNotApply() throws {
        let text = #"{"dish":"x","ingredients":[{"id":"salt","name":"salt","amount":""}],"steps":[{"id":"ask","kind":"ask","title":"Salt","instruction":"Ask.","needs":[],"question":"How salty?","saves":"salt"},{"id":"add","kind":"do","title":"Add salt","instruction":"Salt it.","needs":["ask"],"doneWhen":"salt in the bowl","guardItem":"salt"}]}"#
        let plan = try RecipePlan.decode(text)
        XCTAssertEqual(plan.steps[0].doneWhen, "")
        XCTAssertEqual(plan.steps[1].guardItem, "salt")
        XCTAssertEqual(plan.steps[1].tool, "")
        let noTarget = text.replacingOccurrences(of: #","doneWhen":"salt in the bowl""#, with: "")
        XCTAssertEqual(try RecipePlan.decode(noTarget).steps[1].doneWhen, "Salt it.", "a missing target falls back to the instruction")
    }
    func testSubstituteChangesTheRecipeItself() throws {
        let plan = try RecipePlan.decode(#"{"dish":"x","ingredients":[{"id":"vinegar","name":"red wine vinegar","amount":"2 tbsp"},{"id":"feta","name":"feta","amount":"1"}],"steps":[{"id":"dress","kind":"do","title":"Add red wine vinegar","instruction":"Whisk the Red Wine Vinegar with oil.","needs":[],"doneWhen":"dressing mixed"},{"id":"mix","kind":"do","title":"Mix","instruction":"Crumble the feta.","needs":["dress"],"doneWhen":"mixed"}]}"#)
        var session = CookingSession(); session.start(plan)
        session.setPantry("vinegar", .missing)
        XCTAssertTrue(session.substitute("vinegar", with: "apple cider vinegar"))
        XCTAssertEqual(session.plan?.ingredients.first?.name, "apple cider vinegar")
        XCTAssertEqual(session.plan?.ingredients.first?.id, "vinegar", "ids stay, so the pantry and checks still line up")
        XCTAssertEqual(session.plan?.steps.first?.title, "Add apple cider vinegar")
        XCTAssertEqual(session.plan?.steps.first?.instruction, "Whisk the apple cider vinegar with oil.")
        XCTAssertNil(session.pantry["vinegar"], "the new ingredient starts unchecked")
        XCTAssertTrue(session.substitute("feta", with: "Apple cider vinegar"), "already in the recipe: feta is just dropped")
        XCTAssertEqual(session.plan?.ingredients.map(\.id), ["vinegar"])
        XCTAssertFalse(session.substitute("saffron", with: "turmeric"), "not in the recipe")
        XCTAssertTrue(session.add("lime", amount: "1"))
        XCTAssertEqual(session.plan?.ingredients.last?.id, "lime")
        XCTAssertFalse(session.add("Lime", amount: "2"), "already there")
    }
    func testNeedsThatNameIngredientsAreDropped() throws {
        let text = #"{"dish":"Quesadilla","ingredients":[{"id":"cheese","name":"cheddar","amount":"1 cup"}],"steps":[{"id":"grate","kind":"do","title":"Grate the cheese","instruction":"Grate it.","needs":["cheese"],"doneWhen":"grated"},{"id":"cook","kind":"do","title":"Cook the quesadilla","instruction":"Cook it in a pan until golden.","needs":["grate","cheese"],"doneWhen":"golden"}]}"#
        let plan = try RecipePlan.decode(text)
        XCTAssertEqual(plan.steps[0].needs, [])
        XCTAssertEqual(plan.steps[1].needs, ["grate"])
        XCTAssertEqual(plan.steps[1].warning, "Turn the pan handle inward and keep your hands clear of the heat.")
        XCTAssertEqual(plan.steps[0].warning, "", "word match: 'grate' is not a pan step")
    }
    func testASeasoningTheStepsUseJoinsTheIngredientList() throws {
        let text = #"{"dish":"Guac","ingredients":[{"id":"avocado","name":"avocado","amount":"2"}],"steps":[{"id":"mash","kind":"do","title":"Mash","instruction":"Mash the avocado.","needs":[],"doneWhen":"mashed"},{"id":"ask_salt","kind":"ask","title":"Salt","instruction":"Ask.","needs":[],"question":"How salty?","saves":"salt"},{"id":"season","kind":"do","title":"Add salt","instruction":"Add salt once.","needs":["mash","ask_salt"],"doneWhen":"salted","guardItem":"salt"}]}"#
        let plan = try RecipePlan.decode(text)
        XCTAssertEqual(plan.ingredients.map(\.name), ["avocado", "salt"])
        XCTAssertEqual(plan.ingredients.last?.amount, "to taste")
    }
    func testWhatTheCookLacksIsRememberedAcrossSwaps() throws {
        let plan = try RecipePlan.decode(#"{"dish":"x","ingredients":[{"id":"vinegar","name":"red wine vinegar","amount":"1"}],"steps":[{"id":"a","kind":"do","title":"Dress","instruction":"Add the red wine vinegar.","needs":[],"doneWhen":"d"},{"id":"b","kind":"do","title":"Mix","instruction":"Mix.","needs":[],"doneWhen":"d"}]}"#)
        var session = CookingSession(); session.start(plan)
        XCTAssertTrue(session.substitute("red wine vinegar", with: "white wine vinegar"))
        XCTAssertNotNil(session.ingredient(named: "white vinegar"), "close names match")
        XCTAssertTrue(session.substitute("white vinegar", with: "lemon juice"))
        XCTAssertTrue(session.isUnavailable("red wine vinegar"))
        XCTAssertTrue(session.isUnavailable("white vinegar"))
        XCTAssertEqual(session.plan?.ingredients.first?.name, "lemon juice")
        let restored = try JSONDecoder().decode(CookingSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.unavailable, ["red wine vinegar", "white wine vinegar"])
    }
    func testIngredientsShownOneByOneAddUp() throws {
        var session = CookingSession(); session.start(plan)
        let first = try IngredientCheck.decode(#"{"seen":["pasta"],"unsure":[]}"#, plan: plan)
        XCTAssertTrue(session.applyIngredientCheck(first, expectedSessionID: session.id, expectedRevision: session.revision))
        let second = try IngredientCheck.decode(#"{"seen":["salt"],"unsure":[]}"#, plan: plan)
        XCTAssertTrue(session.applyIngredientCheck(second, expectedSessionID: session.id, expectedRevision: session.revision))
        XCTAssertEqual(session.pantry["pasta"]?.status, .seen, "seen earlier, still seen")
        XCTAssertEqual(session.pantry["salt"]?.status, .seen)
        XCTAssertThrowsError(try IngredientCheck.decode(#"{"seen":["saffron"],"unsure":[]}"#, plan: plan))
    }
}
