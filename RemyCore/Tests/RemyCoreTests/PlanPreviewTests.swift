import XCTest
@testable import RemyCore

final class PlanPreviewTests: XCTestCase {
    private let step = #"{"id":"boil","kind":"do","title":"Boil the {pasta}","instruction":"Salted \"water\".","needs":[],"doneWhen":"d","wrongSize":"","tool":"pot","guardItem":"","question":"","saves":""}"#

    func testShowsDishThenIngredientsThenClosedStepsOnly() {
        var text = #"{"dish":"Lasagna","ingredients":[{"id":"pasta","name":"lasagna sheets","amount":"12"},{"id":"beef","na"#
        var preview = PlanPreview(streamed: text)
        XCTAssertEqual(preview.dish, "Lasagna")
        XCTAssertEqual(preview.ingredients.map(\.id), ["pasta"], "a half-written ingredient is not shown")
        XCTAssertTrue(preview.steps.isEmpty)
        text += #"me":"ground beef","amount":"500 g"}],"steps":["# + step + #",{"id":"bake","kind":"do","title":"Ba"#
        preview = PlanPreview(streamed: text)
        XCTAssertEqual(preview.ingredients.count, 2)
        XCTAssertEqual(preview.steps.map(\.title), ["Boil the {pasta}"], "braces and quotes inside strings are not structure")
    }
    func testEmptyOrUnrelatedTextShowsNothing() {
        XCTAssertEqual(PlanPreview(streamed: ""), PlanPreview(streamed: "{"))
        XCTAssertNil(PlanPreview(streamed: "{").dish)
    }
}
