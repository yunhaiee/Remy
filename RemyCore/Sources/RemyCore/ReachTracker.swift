import Foundation

/// Predicts an image-plane approach, not a physical collision. Call separately for each tracked hand.
public struct ReachTracker: Sendable {
    private var previous: Point2?
    private var previousTime: TimeInterval?
    private var lastAlert: TimeInterval = -.infinity
    public init() {}
    public mutating func reset() { previous = nil; previousTime = nil }
    public mutating func update(point: Point2?, time: TimeInterval, zone: GuardZone?, armed: Bool) -> Bool {
        guard time.isFinite, let point, point.isValid else { reset(); return false }
        defer { previous = point; previousTime = time }
        guard armed, let zone, zone.isValid, let previous, let previousTime else { return false }
        let dt = time - previousTime
        guard (0.015...0.3).contains(dt), time - lastAlert > 3 else { return false }
        let speed = point.distance(to: previous) / dt
        guard speed >= 0.08, speed <= 3,
              point.distance(to: zone.center) < previous.distance(to: zone.center) else { return false }
        let projected = Point2(point.x + (point.x - previous.x) / dt * 0.25,
                               point.y + (point.y - previous.y) / dt * 0.25)
        // Distance from the zone to the complete predicted path avoids skipping over a small zone.
        let dx = projected.x - point.x, dy = projected.y - point.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return false }
        let t = max(0, min(1, ((zone.center.x - point.x) * dx + (zone.center.y - point.y) * dy) / length2))
        let nearest = Point2(point.x + t * dx, point.y + t * dy)
        guard zone.contains(nearest) else { return false }
        lastAlert = time; return true
    }
}
