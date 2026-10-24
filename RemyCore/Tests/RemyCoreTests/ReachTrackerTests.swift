import XCTest
@testable import RemyCore

final class ReachTrackerTests: XCTestCase {
    func testReachTriggersBeforeEntryButNotBeforeSaltingOrMovingAway() {
        let zone = GuardZone(center: .init(0.7, 0.5), radius: 0.1)
        var reach = ReachTracker()
        XCTAssertFalse(reach.update(point: .init(0.3, 0.5), time: 1, zone: zone, armed: true))
        XCTAssertTrue(reach.update(point: .init(0.4, 0.5), time: 1.1, zone: zone, armed: true))
        XCTAssertFalse(reach.update(point: .init(0.5, 0.5), time: 1.2, zone: zone, armed: true))
        var unarmed = ReachTracker()
        _ = unarmed.update(point: .init(0.3, 0.5), time: 1, zone: zone, armed: false)
        XCTAssertFalse(unarmed.update(point: .init(0.4, 0.5), time: 1.1, zone: zone, armed: false))
        var away = ReachTracker()
        _ = away.update(point: .init(0.4, 0.5), time: 1, zone: zone, armed: true)
        XCTAssertFalse(away.update(point: .init(0.3, 0.5), time: 1.1, zone: zone, armed: true))
    }
    func testLostOrStaleHandCannotCreateFalseVelocity() {
        var reach = ReachTracker(); let zone = GuardZone(center: .init(0.7, 0.5))
        _ = reach.update(point: .init(0.3, 0.5), time: 1, zone: zone, armed: true)
        XCTAssertFalse(reach.update(point: nil, time: 1.1, zone: zone, armed: true))
        XCTAssertFalse(reach.update(point: .init(0.5, 0.5), time: 1.2, zone: zone, armed: true))
        XCTAssertFalse(reach.update(point: .init(0.6, 0.5), time: 4, zone: zone, armed: true))
    }
}
