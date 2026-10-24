import Foundation

public struct KnifeCandidate: Sendable {
    public let box: ItemBox
    public let score: Double
    public init(box: ItemBox, score: Double) { self.box = box; self.score = score }
}

/// Geometry and semantic gates for one persistent knife target. Does not infer blade edges.
public enum KnifeAssociation {
    public static func isKnife(_ label: String) -> Bool {
        label.lowercased().range(of: #"\b(?:knife|knives)\b"#, options: .regularExpression) != nil
    }
    public static func valid(_ box: ItemBox) -> Bool {
        isKnife(box.label) && [box.x,box.y,box.width,box.height].allSatisfy(\.isFinite) &&
            box.x >= 0 && box.y >= 0 && box.width > 0 && box.height > 0 &&
            box.x + box.width <= 1 && box.y + box.height <= 1 &&
            box.width * box.height > 0.00002 && box.width * box.height < 0.85
    }
    public static func iou(_ a: ItemBox, _ b: ItemBox) -> Double {
        let area = max(0,min(a.x+a.width,b.x+b.width)-max(a.x,b.x)) * max(0,min(a.y+a.height,b.y+b.height)-max(a.y,b.y))
        let union = a.width*a.height+b.width*b.height-area
        return union > 0 ? area/union : 0
    }
    public static func matches(_ candidate: ItemBox, _ previous: ItemBox) -> Bool {
        guard valid(candidate), valid(previous) else { return false }
        let ratio = candidate.width*candidate.height/(previous.width*previous.height)
        guard (0.15...6).contains(ratio) else { return false }
        let distance = hypot(candidate.center.x-previous.center.x,candidate.center.y-previous.center.y)
        return iou(candidate,previous) >= 0.05 || distance <= max(0.12,hypot(previous.width,previous.height)*0.65)
    }
    public static func select(_ candidates: [KnifeCandidate], previous: ItemBox?) -> KnifeCandidate? {
        let valid = candidates.filter { Self.valid($0.box) && $0.score.isFinite && (0.25...1).contains($0.score) }
        if let previous {
            return valid.filter { matches($0.box,previous) }.min { a,b in
                func cost(_ c: KnifeCandidate) -> Double {
                    hypot(c.box.center.x-previous.center.x,c.box.center.y-previous.center.y) + (1-iou(c.box,previous))*0.2 - c.score*0.02
                }
                return cost(a)<cost(b)
            }
        }
        return valid.max { a,b in a.score == b.score ? a.box.width*a.box.height < b.box.width*b.box.height : a.score < b.score }
    }
}

/// A weak classifier hit must agree across three fresh detections; a strong hit can seed immediately.
public struct KnifeCandidateGate: Sendable {
    private var previous: ItemBox?
    private var lastTime: Double?
    private var consecutive = 0
    public init() {}
    public mutating func reset() { previous = nil; lastTime = nil; consecutive = 0 }
    public mutating func accepts(_ candidate: KnifeCandidate, time: Double) -> Bool {
        guard KnifeAssociation.valid(candidate.box), candidate.score.isFinite, (0.25...1).contains(candidate.score), time.isFinite else { reset(); return false }
        guard lastTime.map({time > $0}) ?? true else { return false }
        if let lastTime, time-lastTime <= 0.35, let previous, KnifeAssociation.matches(candidate.box,previous) { consecutive += 1 }
        else { consecutive = 1 }
        previous = candidate.box; lastTime = time
        return candidate.score >= 0.5 || consecutive >= 3
    }
}
