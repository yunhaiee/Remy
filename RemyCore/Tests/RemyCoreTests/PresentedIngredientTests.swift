import XCTest
@testable import RemyCore

final class PresentedIngredientTests: XCTestCase {
    let ingredients = IngredientDraft.preset(for: "pasta salad")!.ingredients + [Ingredient(id: "salt", name: "salt", amount: "to taste")]
    func testPresentationIsAnImageRequestWithAnOptionalHint() {
        XCTAssertEqual(IngredientPresentationCue.parse("Here's the onion", ingredients: ingredients)?.ingredientID, "onion")
        XCTAssertEqual(IngredientPresentationCue.parse("Chef, here is my cucumber!", ingredients: ingredients)?.ingredientID, "cucumber")
        XCTAssertNotNil(IngredientPresentationCue.parse("Here’s the first ingredient", ingredients: ingredients))
        XCTAssertNotNil(IngredientPresentationCue.parse("Here's the banana", ingredients: ingredients))
        XCTAssertNotNil(IngredientPresentationCue.parse("What is this", ingredients: ingredients))
        XCTAssertNil(IngredientPresentationCue.parse("I have onion and cucumber", ingredients: ingredients))
        XCTAssertNil(IngredientPresentationCue.parse("This is not the onion", ingredients: ingredients))
    }
    func testOnionNeedsVisualAgreementAndCannotBecomeAppleOrOrange() {
        let onion = IngredientVisualIdentity(name: "red onion", confidence: 0.94, evidence: "Purple papery outer layers and a dried root tuft", box_2d: [100, 100, 900, 900])
        let agreed = IngredientVisualVerification(matches: true, name: "onion", confidence: 0.9, evidence: "Visible layered papery skin and root end")
        XCTAssertEqual(onion.confirmedIngredient(in: ingredients, verification: agreed)?.id, "onion")
        let apple = IngredientVisualVerification(matches: true, name: "apple", confidence: 0.95, evidence: "Smooth shiny skin and a fruit stem")
        XCTAssertNil(onion.confirmedIngredient(in: ingredients, verification: apple))
        XCTAssertFalse(IngredientVisualIdentity.sameFood("onion", "orange"))
        XCTAssertFalse(IngredientVisualIdentity.sameFood("cucumber", "banana"))
    }
    func testUnknownUnboxedLowConfidenceAndUnlabelledPowderCannotConfirm() {
        let verify = IngredientVisualVerification(matches: true, name: "salt", confidence: 0.98, evidence: "Fine white powder in a bowl")
        let salt = IngredientVisualIdentity(name: "salt", confidence: 0.98, evidence: "Fine white powder in a bowl", box_2d: [100, 100, 900, 900])
        XCTAssertNil(salt.confirmedIngredient(in: ingredients, verification: verify))
        for identity in [
            IngredientVisualIdentity(name: "unknown", confidence: 0.98, evidence: "A round food is held up", box_2d: [100,100,900,900]),
            IngredientVisualIdentity(name: "onion", confidence: 0.5, evidence: "Papery outer layers", box_2d: [100,100,900,900]),
            IngredientVisualIdentity(name: "onion", confidence: 0.98, evidence: "Papery outer layers", box_2d: []),
            IngredientVisualIdentity(name: "onion", confidence: 0.98, evidence: "It could be an onion", box_2d: [100,100,900,900])
        ] { XCTAssertFalse(identity.isSupported) }
    }
    func testSpecificPastaShapesMatchPastaWithoutAliasingOtherFoods() {
        for shape in ["rotini", "fusilli", "penne", "spaghetti"] {
            XCTAssertTrue(IngredientVisualIdentity.sameFood(shape, "pasta"))
        }
        XCTAssertFalse(IngredientVisualIdentity.sameFood("rice", "pasta"))
    }
    func testOutOfListIdentityStillNeedsUnambiguousCorroboration() {
        let apple = IngredientVisualIdentity(name: "apple", confidence: 0.95, evidence: "Glossy red skin and stem", box_2d: [100,100,900,900])
        XCTAssertTrue(apple.isCorroborated(by: .init(matches: true, name: "apple", confidence: 0.95, evidence: "Smooth skin and fruit stem")))
        XCTAssertNil(apple.confirmedIngredient(in: ingredients, verification: .init(matches: true, name: "apple", confidence: 0.95, evidence: "Smooth skin and fruit stem")))
        XCTAssertFalse(apple.isCorroborated(by: .init(matches: true, name: "apple", confidence: 0.95, evidence: "It could be an apple")))
    }
    func testPackageLabelsRejectRecipeSentencesAndPepper() {
        XCTAssertEqual(PackageIngredientLabel.food("ROTINI"), "pasta")
        XCTAssertEqual(PackageIngredientLabel.food("Sea Salt"), "salt")
        for text in ["salt-free", "unsalted", "add salt", "salt and pepper", "pepper", "1 tsp salt"] {
            XCTAssertNil(PackageIngredientLabel.food(text))
        }
        XCTAssertTrue(IngredientVisualIdentity.sameFood("rotini box", "pasta"))
        XCTAssertTrue(IngredientVisualIdentity.sameFood("salt shaker", "salt"))
        XCTAssertFalse(IngredientVisualIdentity.sameFood("pepper grinder", "salt"))
    }
    func testSaltContainerRequiresVisualContentsOrLabel() {
        let verify = IngredientVisualVerification(matches: true, name: "salt shaker", confidence: 0.95, evidence: "Clear shaker containing white crystals")
        let salt = IngredientVisualIdentity(name: "salt shaker", confidence: 0.95, evidence: "Clear bottle with white crystals", box_2d: [100,100,900,900])
        XCTAssertEqual(salt.confirmedIngredient(in: ingredients, verification: verify)?.id, "salt")
        let opaque = IngredientVisualIdentity(name: "salt shaker", confidence: 0.95, evidence: "Opaque white shaker with holes", box_2d: [100,100,900,900])
        XCTAssertNil(opaque.confirmedIngredient(in: ingredients, verification: .init(matches: true, name: "salt shaker", confidence: 0.95, evidence: "Opaque shaker with holes")))
    }
    func testMalformedAndOutOfBoundsVisualRepliesAreRejected() {
        XCTAssertThrowsError(try IngredientVisualIdentity.decode(#"{"name":"onion","confidence":1.4,"evidence":"papery skin","box_2d":[0,0,1000,1000]}"#))
        XCTAssertThrowsError(try IngredientVisualIdentity.decode(#"{"name":"onion","confidence":0.9,"evidence":"papery skin","box_2d":[0,0,1100,1000]}"#))
    }
}
