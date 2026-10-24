import XCTest
@testable import RemyCore

final class FastObjectPresentationTests: XCTestCase {
    func testGenericFoodGuessesCannotBecomeSpecificIngredientIdentity() {
        for label in ["banana", "apple", "orange", "broccoli", "carrot", " BANANA "] {
            XCTAssertEqual(FastObjectPresentation.displayLabel(label), "Produce")
            XCTAssertFalse(FastObjectPresentation.isSpecificIdentityReliable(label))
        }
        for label in ["sandwich", "hot dog", "pizza", "donut", "cake"] {
            XCTAssertEqual(FastObjectPresentation.displayLabel(label), "Food")
            XCTAssertFalse(FastObjectPresentation.isSpecificIdentityReliable(label))
        }
        for label in ["  ", "Produce", "Food"] {
            XCTAssertFalse(FastObjectPresentation.isSpecificIdentityReliable(label))
        }
    }
    func testPresentationNeverFabricatesARecipeIngredientOrChangesGeometry() {
        let bananaGuess = ItemBox(label: "banana", x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let display = FastObjectPresentation.displayBox(bananaGuess)
        XCTAssertEqual(display.label, "Produce")
        XCTAssertNotEqual(display.label, "cucumber")
        XCTAssertEqual(display.x, bananaGuess.x); XCTAssertEqual(display.y, bananaGuess.y)
        XCTAssertEqual(display.width, bananaGuess.width); XCTAssertEqual(display.height, bananaGuess.height)
        XCTAssertEqual(bananaGuess.label, "banana", "raw evidence remains unchanged")
    }
    func testNonFoodLabelsRetainTheirGenericDetectorCategory() {
        for label in ["knife", "bowl", "cup", "microwave"] {
            XCTAssertEqual(FastObjectPresentation.displayLabel(label), label)
            XCTAssertTrue(FastObjectPresentation.isSpecificIdentityReliable(label))
        }
    }
}
