import XCTest
@testable import RemyCore

final class HazardWatchTests: XCTestCase {
    private let pot = HazardZone(label: "pot", x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    private func hand(_ x: Double, _ y: Double, id: String = "right", reliable: Bool = true) -> HazardWatch.Hand {
        .init(id: id, points: (0..<21).map { index in
            .init(x + Double(index % 4) * 0.005, y + Double(index / 4) * 0.005)
        }, isReliable: reliable)
    }
    private func check(_ watch: inout HazardWatch, hands: [HazardWatch.Hand], at time: Double) -> HazardZone? {
        watch.check(hands: hands, zones: [pot], time: time, now: time)
    }

    func testWholeHandWarnsOnceAndRearmsOnlyAfterItLeaves() {
        var watch = HazardWatch()
        XCTAssertNil(check(&watch, hands: [hand(0.1, 0.1)], at: 0))
        XCTAssertEqual(check(&watch, hands: [hand(0.45, 0.45)], at: 1)?.label, "pot")
        XCTAssertNil(check(&watch, hands: [hand(0.45, 0.45)], at: 2), "still inside: quiet")
        XCTAssertNil(check(&watch, hands: [hand(0.45, 0.45)], at: 6), "cooldown alone must not re-arm")
        XCTAssertNil(check(&watch, hands: [hand(0.1, 0.1)], at: 7))
        XCTAssertNil(check(&watch, hands: [hand(0.45, 0.45)], at: 7.5), "back too soon to re-arm")
        XCTAssertNil(check(&watch, hands: [hand(0.1, 0.1)], at: 8))
        XCTAssertEqual(check(&watch, hands: [hand(0.45, 0.45)], at: 9.2)?.label, "pot")
    }

    func testFingertipsInsideButWristOutsideDoesNotWarn() {
        var watch = HazardWatch()
        var points = hand(0.45, 0.45).points
        points[0] = .init(0.39, 0.5)
        XCTAssertNil(check(&watch, hands: [.init(id: "right", points: points)], at: 1))
        // Every landmark is required, not merely a palm/tip majority.
        for index in 1..<21 {
            var partial = hand(0.45, 0.45).points
            partial[index] = .init(0.601, 0.5)
            var separateWatch = HazardWatch()
            XCTAssertNil(check(&separateWatch, hands: [.init(id: "right", points: partial)], at: 1), "landmark \(index)")
        }
    }

    func testApproachAndNearbyHandDoNotWarnBeforeWholeHandEnters() {
        var watch = HazardWatch()
        XCTAssertNil(check(&watch, hands: [hand(0.12, 0.5)], at: 0))
        XCTAssertNil(check(&watch, hands: [hand(0.22, 0.5)], at: 0.1), "projection into the pot must not trigger")
        XCTAssertNil(check(&watch, hands: [hand(0.32, 0.5)], at: 0.2), "old 10% outside margin must not trigger")
        XCTAssertEqual(check(&watch, hands: [hand(0.45, 0.45)], at: 0.3)?.label, "pot")
    }

    func testMissingInvalidUnreliableAndDuplicateHandsCannotTrigger() {
        let good = hand(0.45, 0.45)
        var invalid = good.points
        invalid[0] = .init(.nan, 0.5)
        let cases: [[HazardWatch.Hand]] = [
            [.init(id: "right", points: Array(good.points.dropFirst()))],
            [.init(id: "right", points: good.points + [.init(0.5, 0.5)])],
            [.init(id: "right", points: invalid)],
            [hand(0.45, 0.45, id: "unknown")],
            [hand(0.45, 0.45, reliable: false)],
            [good, good]
        ]
        for hands in cases {
            var watch = HazardWatch()
            XCTAssertNil(check(&watch, hands: hands, at: 1))
        }
        var watch = HazardWatch()
        XCTAssertEqual(check(&watch, hands: [hand(0.1, 0.1, id: "left"), good], at: 1)?.label, "pot", "one complete hand suffices")
    }

    func testStaleFutureAndOutOfOrderFramesCannotTrigger() {
        let inside = hand(0.45, 0.45)
        var watch = HazardWatch()
        XCTAssertNil(watch.check(hands: [inside], zones: [pot], time: 1, now: 1.31), "stale")
        XCTAssertNil(watch.check(hands: [inside], zones: [pot], time: 2, now: 1), "future")
        XCTAssertNil(watch.check(hands: [inside], zones: [pot], time: .nan, now: 1), "invalid clock")
        XCTAssertNil(check(&watch, hands: [hand(0.1, 0.1)], at: 3))
        XCTAssertNil(watch.check(hands: [inside], zones: [pot], time: 3, now: 3.01), "repeated frame")
        XCTAssertNil(watch.check(hands: [inside], zones: [pot], time: 2.99, now: 3.01), "out of order")
        XCTAssertEqual(watch.check(hands: [inside], zones: [pot], time: 3.1, now: 3.2)?.label, "pot")
    }

    func testPartialContactAndStaleGapDoNotRearm() {
        var watch = HazardWatch()
        XCTAssertEqual(check(&watch, hands: [hand(0.45, 0.45)], at: 1)?.label, "pot")
        var partial = hand(0.45, 0.45).points
        partial[0] = .init(0.2, 0.2)
        XCTAssertNil(check(&watch, hands: [.init(id: "right", points: partial)], at: 4))
        XCTAssertNil(check(&watch, hands: [hand(0.45, 0.45)], at: 5), "contact never cleared")
        XCTAssertNil(check(&watch, hands: [], at: 6))
        XCTAssertNil(watch.check(hands: [], zones: [pot], time: 6.1, now: 8), "stale empty frame is not evidence of clear time")
        XCTAssertNil(check(&watch, hands: [hand(0.45, 0.45)], at: 8.1))
        watch.reset()
        XCTAssertNil(check(&watch, hands: [hand(0.45, 0.45)], at: 8.2), "reset keeps the recent-alert protection")
    }

    func testNoOrInvalidZonesCannotTrigger() {
        var watch = HazardWatch()
        XCTAssertNil(watch.check(hands: [hand(0.45, 0.45)], zones: [], time: 1, now: 1))
        for bad in [HazardZone(label: "pan", x: .nan, y: 0.4, width: 0.2, height: 0.2),
                    HazardZone(label: "pan", x: 0.4, y: 0.4, width: 0, height: 0.2),
                    HazardZone(label: "pan", x: -0.1, y: 0.4, width: 1, height: 0.2)] {
            var separateWatch = HazardWatch()
            XCTAssertNil(separateWatch.check(hands: [hand(0.45, 0.45)], zones: [bad], time: 1, now: 1))
        }
    }

    func testOnlyHeatWordsBecomeHotZones() {
        for name in ["pot", "frying pan", "electric cooker", "kettle", "stove burner", "boiling water", "hot plate"] {
            XCTAssertTrue(HazardZone.looksHot(name), name)
        }
        for name in ["knife", "cutting board", "bowl", "tomato", "chef's knife", "scissors"] {
            XCTAssertFalse(HazardZone.looksHot(name), name)
        }
    }
    func testTwoNamesForOneObjectOverlap() {
        let pan = HazardZone(label: "pan", x: 0.41, y: 0.4, width: 0.2, height: 0.21)
        let kettle = HazardZone(label: "kettle", x: 0.0, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertTrue(pot.overlaps(pan))
        XCTAssertFalse(pot.overlaps(kettle))
    }
    func testCookerProximityWarnsOutsideBoxAndRequiresClearanceToRearm() {
        var watch = HazardWatch(); watch.proximityMargin = 0.07; watch.cooldown = 6
        XCTAssertNil(check(&watch, hands: [hand(0.1, 0.5)], at: 0))
        XCTAssertEqual(check(&watch, hands: [hand(0.35, 0.45)], at: 1)?.label, "pot")
        XCTAssertNil(check(&watch, hands: [hand(0.35, 0.45)], at: 9), "remaining nearby must not repeat")
        XCTAssertNil(check(&watch, hands: [hand(0.1, 0.5)], at: 10))
        XCTAssertEqual(check(&watch, hands: [hand(0.35, 0.45)], at: 11.2)?.label, "pot")
    }
    func testCookerProximityRejectsStaleIncompleteUnknownAndFarHands() {
        var watch = HazardWatch(); watch.proximityMargin = 0.07
        let near = hand(0.35, 0.45)
        XCTAssertNil(watch.check(hands: [near], zones: [pot], time: 1, now: 1.4))
        XCTAssertNil(check(&watch, hands: [.init(id: "right", points: Array(near.points.dropLast()))], at: 2))
        XCTAssertNil(check(&watch, hands: [hand(0.35, 0.45, id: "unknown")], at: 3))
        XCTAssertNil(check(&watch, hands: [hand(0.1, 0.5)], at: 4))
        XCTAssertEqual(check(&watch, hands: [near], at: 5)?.label, "pot")
    }

    func testCookerTargetsRestoreVesselAliasesWithoutInventingOrDuplicatingBoxes() {
        XCTAssertTrue(CookerSafetyTargets.queries.contains("pot"))
        XCTAssertTrue(CookerSafetyTargets.zones(from: []).isEmpty)
        let boxes = [ItemBox(label: "pot", x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                     ItemBox(label: "electric cooker", x: 0.41, y: 0.4, width: 0.2, height: 0.2),
                     ItemBox(label: "onion", x: 0.1, y: 0.1, width: 0.1, height: 0.1),
                     ItemBox(label: "kettle", x: -0.1, y: 0.1, width: 0.2, height: 0.2)]
        let zones = CookerSafetyTargets.zones(from: boxes)
        XCTAssertEqual(zones.count, 1)
        XCTAssertEqual(zones.first?.label, "pot", "Preserve the visible vessel label; do not rename every object electric cooker")
        XCTAssertEqual(zones.first?.x, 0.4)
    }

    func testCupAliasRequiresAnActualValidBoxAndDoesNotTreatAllCupsAsHot() {
        XCTAssertTrue(CookerSafetyTargets.queries.contains("cup"))
        let cup = ItemBox(label: "coffee cup", x: 0.2, y: 0.3, width: 0.2, height: 0.3)
        XCTAssertEqual(CookerSafetyTargets.zones(from: [cup]).first?.label, "coffee cup")
        XCTAssertFalse(HazardZone.looksHot("cup"), "Cup proxy is scoped to the requested cooking demo")
        for label in ["cupboard", "potato", "tomato"] {
            XCTAssertTrue(CookerSafetyTargets.zones(from: [.init(label: label, x: 0.2, y: 0.2, width: 0.2, height: 0.2)]).isEmpty)
        }
    }
    func testCookerPowerReportsAcceptStatementsAndRejectQuestionsNegationAndIntentions() {
        for words in ["I turned the kettle off", "I've switched off the kettle", "the kettle is off", "I turned it off", "the kettle's off", "it's off", "the cooker is switched off"] {
            XCTAssertEqual(CookerPowerCommand.parse(words), .off, words)
        }
        for words in ["I turned it back on", "I turned the kettle on", "the kettle is back on", "I've just switched on the cooker"] {
            XCTAssertEqual(CookerPowerCommand.parse(words), .on, words)
        }
        for words in ["Is the kettle off?", "I haven't turned it off", "I didn't turn it on", "Should I turn it off", "I will turn it off", "turn it off", "the cup is on the table", "I turned the kettle off and back on", "not off"] {
            XCTAssertNil(CookerPowerCommand.parse(words), words)
        }
    }

    func testBowlIsARequestedSafetyProxy() {
        XCTAssertTrue(CookerSafetyTargets.queries.contains("bowl"))
        XCTAssertEqual(CookerSafetyTargets.zones(from: [.init(label: "bowl", x: 0.2, y: 0.2, width: 0.3, height: 0.3)]).first?.label, "bowl")
        XCTAssertFalse(HazardZone.looksHot("bowl"), "Scoped proxy, not a heat measurement")
    }
    func testAnyPartRequiresHalfSecondOfContinuousOverlap() {
        var watch = HazardWatch(); watch.anyPartOverlap = true; watch.minimumContactDuration = 0.5
        let tip = HazardWatch.Hand(id: "right", points: [.init(0.5, 0.5)])
        XCTAssertNil(check(&watch, hands: [tip], at: 1))
        XCTAssertNil(check(&watch, hands: [tip], at: 1.2))
        XCTAssertNil(check(&watch, hands: [tip], at: 1.49))
        XCTAssertEqual(check(&watch, hands: [tip], at: 1.51)?.label, "pot")
        XCTAssertNil(check(&watch, hands: [tip], at: 3), "staying inside must not repeat")
    }
    func testDwellResetsOnExitTrackingLossAndFrameGaps() {
        let tip = HazardWatch.Hand(id: "right", points: [.init(0.5, 0.5)])
        for loss in ["exit", "zones", "stale", "gap", "other hand"] {
            var watch = HazardWatch(); watch.anyPartOverlap = true; watch.minimumContactDuration = 0.5
            XCTAssertNil(check(&watch, hands: [tip], at: 1))
            XCTAssertNil(check(&watch, hands: [tip], at: 1.2))
            switch loss {
            case "exit": XCTAssertNil(check(&watch, hands: [], at: 1.3))
            case "zones": XCTAssertNil(watch.check(hands: [tip], zones: [], time: 1.3, now: 1.3))
            case "stale": XCTAssertNil(watch.check(hands: [tip], zones: [pot], time: 1.3, now: 2))
            case "other hand": XCTAssertNil(check(&watch, hands: [.init(id: "left", points: tip.points)], at: 1.3))
            default: break
            }
            XCTAssertNil(check(&watch, hands: [tip], at: 1.6), loss)
        }
    }
    func testSkeletalSegmentCrossingCountsButNearbyOutsideDoesNot() {
        var points = Array(repeating: Point2(0.1, 0.5), count: 21)
        points[1] = .init(0.9, 0.5)
        XCTAssertTrue(pot.intersectsHand(points))
        XCTAssertFalse(pot.intersectsHand([.init(0.39, 0.5)]), "No outside proximity margin in overlap mode")
        XCTAssertFalse(pot.intersectsHand([.init(.nan, 0.5)]))
    }

    func testVisibleFingertipCanDwellWhenOtherLandmarksAreOffscreen() {
        var watch = HazardWatch(); watch.anyPartOverlap = true; watch.minimumContactDuration = 0.5
        let partial = HazardWatch.Hand(id: "right", points: [.init(-0.1, 0.5), .init(0.5, 0.5)])
        XCTAssertNil(check(&watch, hands: [partial], at: 1))
        XCTAssertNil(check(&watch, hands: [partial], at: 1.2))
        XCTAssertNil(check(&watch, hands: [partial], at: 1.4))
        XCTAssertEqual(check(&watch, hands: [partial], at: 1.51)?.label, "pot")
    }

    func testHeldAlarmStartsAtOneSecondStaysActiveAndResetsImmediatelyOnExit() {
        var watch = HazardWatch(); watch.anyPartOverlap = true
        watch.minimumContactDuration = 1; watch.holdsAlertUntilExit = true
        let hand = HazardWatch.Hand(id: "right", points: [.init(0.5, 0.5)])
        for time in [0.0,0.2,0.4,0.6,0.8,0.99] { XCTAssertNil(check(&watch, hands: [hand], at: time)) }
        XCTAssertTrue(watch.hasContact)
        XCTAssertEqual(check(&watch, hands: [hand], at: 1)?.label, "pot")
        XCTAssertEqual(check(&watch, hands: [hand], at: 1.1)?.label, "pot", "active on every frame, not a timed toast")
        XCTAssertEqual(check(&watch, hands: [hand], at: 1.3)?.label, "pot")
        XCTAssertNil(check(&watch, hands: [], at: 1.4), "leave: immediately clear")
        XCTAssertFalse(watch.hasContact)
        for time in [1.41,1.6,1.8,2.0,2.2,2.4] { XCTAssertNil(check(&watch, hands: [hand], at: time)) }
        XCTAssertEqual(check(&watch, hands: [hand], at: 2.42)?.label, "pot", "no six-second cooldown or one-second clearance required")
    }
    func testHeldAlarmClearsOnLostGeometryStaleFramesAndReset() {
        let hand = HazardWatch.Hand(id: "right", points: [.init(0.5, 0.5)])
        for loss in ["geometry", "stale", "reset"] {
            var watch = HazardWatch(); watch.anyPartOverlap = true
            watch.minimumContactDuration = 1; watch.holdsAlertUntilExit = true
            for time in [0.0,0.2,0.4,0.6,0.8] { XCTAssertNil(check(&watch, hands: [hand], at: time)) }
            XCTAssertNotNil(check(&watch, hands: [hand], at: 1))
            switch loss {
            case "geometry": XCTAssertNil(watch.check(hands: [hand], zones: [], time: 1.1, now: 1.1))
            case "stale": XCTAssertNil(watch.check(hands: [hand], zones: [pot], time: 1.1, now: 1.5))
            default: watch.reset()
            }
            XCTAssertFalse(watch.hasContact)
            XCTAssertNil(check(&watch, hands: [hand], at: 1.2), loss)
        }
    }

}
