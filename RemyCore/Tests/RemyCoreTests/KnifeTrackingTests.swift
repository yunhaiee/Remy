import XCTest
@testable import RemyCore

final class KnifeTrackingTests: XCTestCase {
    private func knife(_ x: Double = 0.2, _ y: Double = 0.4, w: Double = 0.3, h: Double = 0.04) -> ItemBox {
        .init(label:"knife",x:x,y:y,width:w,height:h)
    }
    func testKnifeLabelAndGeometryValidation() {
        XCTAssertTrue(KnifeAssociation.isKnife("chef's knife"))
        XCTAssertTrue(KnifeAssociation.isKnife("knives"))
        for label in ["fork","spoon","knifeholder","knife_edge_prediction"] { XCTAssertFalse(KnifeAssociation.isKnife(label)) }
        XCTAssertTrue(KnifeAssociation.valid(knife()))
        XCTAssertFalse(KnifeAssociation.valid(knife(-0.1)))
        XCTAssertFalse(KnifeAssociation.valid(knife(.nan)))
        XCTAssertFalse(KnifeAssociation.valid(knife(w:0)))
        XCTAssertFalse(KnifeAssociation.valid(knife(0,0,w:1,h:1)))
    }
    func testStrongCandidateCanSeedImmediatelyButWeakNeedsThreeFreshConsistentFrames() {
        var gate = KnifeCandidateGate()
        XCTAssertTrue(gate.accepts(.init(box:knife(),score:0.6),time:1))
        gate.reset()
        XCTAssertFalse(gate.accepts(.init(box:knife(),score:0.3),time:2))
        XCTAssertFalse(gate.accepts(.init(box:knife(0.21),score:0.3),time:2.1))
        XCTAssertTrue(gate.accepts(.init(box:knife(0.22),score:0.3),time:2.2))
    }
    func testWeakCandidateCannotAccumulateAcrossGapsOtherTargetsOrRepeatedFrames() {
        var gate = KnifeCandidateGate()
        XCTAssertFalse(gate.accepts(.init(box:knife(),score:0.3),time:1))
        XCTAssertFalse(gate.accepts(.init(box:knife(),score:0.3),time:1))
        XCTAssertFalse(gate.accepts(.init(box:knife(),score:0.3),time:1.1))
        XCTAssertFalse(gate.accepts(.init(box:knife(),score:0.3),time:2))
        XCTAssertFalse(gate.accepts(.init(box:knife(0.7),score:0.3),time:2.1))
        XCTAssertFalse(gate.accepts(.init(box:knife(0.7),score:0.1),time:2.2))
        XCTAssertFalse(gate.accepts(.init(box:knife(0.7),score:0.3),time:2.3))
    }
    func testReDetectionKeepsCurrentIdentityRatherThanSwitchingToHigherScoringFarKnife() {
        let current = knife()
        let matching = KnifeCandidate(box:knife(0.21),score:0.6)
        let other = KnifeCandidate(box:knife(0.7,0.1,w:0.2,h:0.03),score:0.99)
        XCTAssertEqual(KnifeAssociation.select([other,matching],previous:current)?.box,matching.box)
        XCTAssertNil(KnifeAssociation.select([other],previous:current))
        XCTAssertEqual(KnifeAssociation.select([other,matching],previous:nil)?.box,other.box)
    }
    func testRotationAndModerateMotionCanMatchButExplodingBoxesCannot() {
        XCTAssertTrue(KnifeAssociation.matches(knife(0.3,0.3,w:0.04,h:0.3),knife()))
        XCTAssertTrue(KnifeAssociation.matches(knife(0.24),knife()))
        XCTAssertFalse(KnifeAssociation.matches(knife(0,0,w:0.9,h:0.9),knife()))
        XCTAssertFalse(KnifeAssociation.matches(knife(0.7,0.8,w:0.2,h:0.03),knife()))
    }
}
