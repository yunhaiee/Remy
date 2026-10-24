import XCTest
@testable import RemyCore

final class IngredientConfirmationTests: XCTestCase {
    private let ingredients: [Ingredient] = [
        .init(id: "pasta", name: "Pasta", amount: "200 g"),
        .init(id: "salt", name: "Salt", amount: "to taste"),
        .init(id: "lemon", name: "Lemon", amount: "1"),
        .init(id: "red_onion", name: "Red onion", amount: "1"),
        .init(id: "cucumber", name: "Cucumber", amount: "1"),
        .init(id: "tomato", name: "Tomato", amount: "2")
    ]
    func testExactAffirmationsUseCurrentNamesOrIDs() {
        for (text, id) in [("I have pasta.", "pasta"), ("Got cucumber!", "cucumber"),
                           ("I HAVE red-onion", "red_onion"), ("got RED_ONION", "red_onion")] {
            let result = IngredientConfirmation.parse(text, ingredients: ingredients)
            XCTAssertEqual(result?.ingredientID, id, text)
            XCTAssertEqual(result?.status, .seen, text)
        }
    }
    func testExactMissingStatementsNormalizeContractionsAndPunctuation() {
        for (text, id) in [("I don't have salt", "salt"), ("I don’t have lemon.", "lemon"),
                           ("I do not have pasta", "pasta"), ("I dont have tomato", "tomato"),
                           ("No cucumber", "cucumber"), ("Red onion is missing.", "red_onion")] {
            let result = IngredientConfirmation.parse(text, ingredients: ingredients)
            XCTAssertEqual(result?.ingredientID, id, text)
            XCTAssertEqual(result?.status, .missing, text)
        }
    }
    func testQuestionsInstructionsAndMixedIntentStayWithTheChef() {
        for text in ["Do I have salt?", "I have salt?", "I have salt but not lemon", "No salt please",
                     "I have pasta and tomato", "I have pasta, can we start", "If I have pasta",
                     "No problem with salt", "I don't have salt so use soy sauce", "Onion is missing, add it",
                     "Please check if tomato is missing", "Chef, I have pasta", "I have two tomato",
                     "I have", "No", "Got", ""] {
            XCTAssertNil(IngredientConfirmation.parse(text, ingredients: ingredients), text)
        }
    }
    func testNamesAreExactAndAmbiguousAliasesAreRejected() {
        XCTAssertNil(IngredientConfirmation.parse("I have onion", ingredients: ingredients), "no substring red-onion match")
        XCTAssertNil(IngredientConfirmation.parse("I have tomatoes", ingredients: ingredients), "no plural inference")
        XCTAssertNil(IngredientConfirmation.parse("I have pasta salad", ingredients: ingredients), "dish is not ingredient")
        let ambiguous = ingredients + [.init(id: "sea_salt", name: "Salt", amount: "")]
        XCTAssertNil(IngredientConfirmation.parse("I have salt", ingredients: ambiguous))
        let idNameCollision = ingredients + [.init(id: "lemon_juice", name: "Pasta", amount: "")]
        XCTAssertNil(IngredientConfirmation.parse("Got pasta", ingredients: idNameCollision))
        XCTAssertNil(IngredientConfirmation.parse("I have lemon", ingredients: []))
    }
    func testConfirmationPreservesCookAuthorityWhenInstructionsArrive() {
        var session = CookingSession()
        let draft = IngredientDraft(dish: "Salad", ingredients: ingredients)
        XCTAssertTrue(session.startIngredients(draft))
        let id = session.id
        let result = IngredientConfirmation.parse("I have cucumber", ingredients: ingredients)!
        session.setPantry(result.ingredientID, result.status)
        let complete = RecipePlan(dish: "Salad", ingredients: ingredients, steps: [
            .init(id: "prep", title: "Prepare", instruction: "Prepare the ingredients.", doneWhen: "Ingredients ready"),
            .init(id: "mix", title: "Mix", instruction: "Mix the salad.", needs: ["prep"], doneWhen: "Combined")
        ])
        XCTAssertTrue(session.applyInstructions(complete, expectedSessionID: id, expectedIngredients: ingredients))
        XCTAssertEqual(session.pantry["cucumber"]?.status, .seen)
        XCTAssertEqual(session.pantry["cucumber"]?.origin, .user)
    }
}
