import XCTest
@testable import RemyCore

final class ItemBoxTests: XCTestCase {
    func testParsesGemmaBoxes() {
        let reply = "```json\n[\n  {\"box_2d\": [454, 192, 706, 333], \"label\": \"the cucumber\"}\n]\n```"
        let box = ItemBox.parse(reply).first
        XCTAssertEqual(box?.label, "cucumber")
        XCTAssertEqual(box?.x ?? 0, 0.192, accuracy: 0.001)
        XCTAssertEqual(box?.y ?? 0, 0.454, accuracy: 0.001)
        XCTAssertEqual(box?.width ?? 0, 0.141, accuracy: 0.001)
        XCTAssertEqual(box?.height ?? 0, 0.252, accuracy: 0.001)
    }
    func testSeveralSingleAndNone() {
        XCTAssertEqual(ItemBox.parse(#"[{"box_2d":[1,2,3,4],"label":"a"},{"box_2d":[10,20,30,40]}]"#).count, 2)
        XCTAssertEqual(ItemBox.parse(#"{"box_2d":[100,100,500,500],"label":"knife"}"#).first?.label, "knife")
        XCTAssertEqual(ItemBox.parse("I did not find any bounding box detections for avocado."), [])
        XCTAssertEqual(ItemBox.parse(#"[{"box_2d":[0,0,1000,1000],"label":"the bowl"}]"#), [], "whole image means unknown")
    }
}
