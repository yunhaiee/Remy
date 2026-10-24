import Foundation

/// Something hot on the counter (a pot, a pan, an electric cooker) as a box in the camera picture, in the same
/// normalized space as the hand landmarks. Gemma finds it once; the fast loop then checks every hand frame against
/// it, with no model call.
public struct HazardZone: Codable, Equatable, Sendable {
    public let label: String
    public let x: Double, y: Double, width: Double, height: Double
    public init(label: String, x: Double, y: Double, width: Double, height: Double) {
        self.label = label; self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ box: ItemBox, label: String? = nil) {
        self.init(label: label ?? box.label, x: box.x, y: box.y, width: box.width, height: box.height)
    }
    public var center: Point2 { Point2(x + width / 2, y + height / 2) }

    /// Whether a name Gemma gave for "something hot" is heat at all. A 2B model also lists knives and boards when
    /// asked what could hurt; a knife is handled on purpose while cutting and must not sound the heat alarm.
    public static func looksHot(_ name: String) -> Bool {
        let lower = name.lowercased()
        let heat = ["pot", "pan", "kettle", "cooker", "skillet", "wok", "stove", "burner", "oven", "toaster", "grill",
                    "griddle", "steam", "boil", "fryer", "hot plate", "hotplate", "electric", "heater", "teapot",
                    "microwave", "flame", "fire", "element"]
        return heat.contains { lower.contains($0) } && !lower.contains("knife") && !lower.contains("blade")
    }
    /// Two names for one object ("pot" and "pan" on the same box) must not become two zones that alarm twice.
    public func overlaps(_ other: HazardZone, threshold: Double = 0.6) -> Bool {
        let w = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let h = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        let intersection = w * h
        let union = width * height + other.width * other.height - intersection
        return union > 0 && intersection / union >= threshold
    }
    /// Inside the box, or within `margin` of it (a hand about to touch counts).
    public func contains(_ point: Point2, margin: Double) -> Bool {
        point.x >= x - margin && point.x <= x + width + margin && point.y >= y - margin && point.y <= y + height + margin
    }
    /// Landmark and skeletal-segment intersection in normalized image coordinates.
    public func intersectsHand(_ points: [Point2]) -> Bool {
        if points.contains(where: { $0.isValid && contains($0, margin: 0) }) { return true }
        guard points.count == 21, points.allSatisfy(\.isValid) else { return false }
        let edges = [(0,1),(1,2),(2,3),(3,4),(0,5),(5,6),(6,7),(7,8),(5,9),(9,10),(10,11),(11,12),
                     (9,13),(13,14),(14,15),(15,16),(13,17),(17,18),(18,19),(19,20),(17,0)]
        return edges.contains { a, b in
            let start = points[a], end = points[b]
            var lower = 0.0, upper = 1.0
            let dx = end.x - start.x, dy = end.y - start.y
            for (p, q) in [(-dx, start.x-x),(dx,x+width-start.x),(-dy,start.y-y),(dy,y+height-start.y)] {
                if abs(p) < 1e-12 { if q < 0 { return false }; continue }
                let ratio = q/p
                if p < 0 { lower = max(lower, ratio) } else { upper = min(upper, ratio) }
                if lower > upper { return false }
            }
            return true
        }
    }

}

/// Requires a reliable, current hand. Default mode requires all 21 landmarks inside;
/// overlap mode accepts visible valid landmarks or skeletal segments, with configurable dwell.
/// The separately configured proximity mode accepts a landmark in an expanded image-space box.
/// After an alert, observed proximity/contact prevents rearming until the hand has stayed clear.
public struct HazardWatch: Sendable {
    public struct Hand: Sendable {
        public let id: String
        /// All MediaPipe landmarks, ordered 0...20, including the wrist at index 0.
        public let points: [Point2]
        public let isReliable: Bool
        public init(id: String, points: [Point2], isReliable: Bool = true) {
            self.id = id; self.points = points; self.isReliable = isReliable
        }
    }

    /// Maximum capture-to-check age; old frames must not sound a current warning.
    /// Optional image-space buffer. Zero preserves the whole-hand rule for other recipes.
    /// A positive buffer warns when any landmark of a complete reliable hand approaches the box.
    public var proximityMargin: Double = 0
    public var anyPartOverlap = false
    public var minimumContactDuration: TimeInterval = 0
    /// Level-triggered mode: return the active zone on every overlapping frame after dwell,
    /// clearing and restarting the timer on exit, with no cooldown or clearance delay.
    public var holdsAlertUntilExit = false
    public var hasContact: Bool { !contactSince.isEmpty }
    private var contactSince: [String: TimeInterval] = [:]
    public var maximumFrameAge: TimeInterval = 0.3
    /// Shortest gap between two alarms for one zone.
    public var cooldown: TimeInterval = 2
    /// How long a hand must stay completely clear before the zone can alarm again.
    public var rearmAfter: TimeInterval = 1.0
    private var lastAlert: [String: TimeInterval] = [:]
    private var clearSince: [String: TimeInterval] = [:]
    private var lastSampleTime: TimeInterval?
    public init() {}

    public mutating func reset() { clearSince = [:]; contactSince = [:]; lastSampleTime = nil }

    /// The approached/entered zone for a complete hand, if armed. `time` is the matching camera frame's
    /// monotonic capture timestamp and `now` is the current monotonic clock, in seconds.
    public mutating func check(hands: [Hand], zones: [HazardZone], time: TimeInterval,
                               now: TimeInterval) -> HazardZone? {
        guard time.isFinite, now.isFinite, maximumFrameAge.isFinite, maximumFrameAge >= 0,
              now >= time, now - time <= maximumFrameAge else {
            // A tracking gap is not evidence that the hand stayed clear during that gap.
            clearSince = [:]; contactSince = [:]
            return nil
        }
        guard lastSampleTime.map({ time > $0 }) ?? true else { return nil }
        if let previous = lastSampleTime, time - previous > maximumFrameAge { contactSince = [:] }
        lastSampleTime = time
        if zones.isEmpty { contactSince = [:] }
        let counts = Dictionary(grouping: hands, by: \.id).mapValues(\.count)
        let completeHands = hands.filter { hand in
            hand.isReliable && !hand.id.isEmpty && hand.id != "unknown" && counts[hand.id] == 1 &&
            (anyPartOverlap ? ((1...21).contains(hand.points.count) && hand.points.contains(where: \.isValid)) : (hand.points.count == 21 && hand.points.allSatisfy(\.isValid)))
        }
        let activePrefixes = zones.enumerated().map { "\($0.element.label)#\($0.offset)|" }
        contactSince = contactSince.filter { key, _ in activePrefixes.contains(where: key.hasPrefix) }
        var hit: HazardZone?
        for (zoneIndex, zone) in zones.enumerated() {
            guard zone.x.isFinite, zone.y.isFinite, zone.width.isFinite, zone.height.isFinite,
                  zone.x >= 0, zone.y >= 0, zone.width > 0, zone.height > 0,
                  zone.x + zone.width <= 1, zone.y + zone.height <= 1 else { continue }
            let margin = proximityMargin.isFinite ? min(0.15, max(0, proximityMargin)) : 0
            let contacting = completeHands.filter { hand in
                if anyPartOverlap { return zone.intersectsHand(hand.points) }
                return margin > 0 ? hand.points.contains { zone.contains($0, margin: margin) }
                    : hand.points.allSatisfy { zone.contains($0, margin: 0) }
            }
            let prefix = "\(zone.label)#\(zoneIndex)|"
            let keys = Set(contacting.map { prefix + $0.id })
            for key in Array(contactSince.keys) where key.hasPrefix(prefix) && !keys.contains(key) { contactSince[key] = nil }
            for key in keys where contactSince[key] == nil { contactSince[key] = time }
            let sustained = keys.contains { time - (contactSince[$0] ?? time) >= max(0, minimumContactDuration) }
            // Partial or uncertain hands cannot fire, but observed contact must not re-arm a
            // previously fired zone while that hand is still handling it.
            let touching = hands.contains { hand in
                (anyPartOverlap && hand.points.allSatisfy(\.isValid) && zone.intersectsHand(hand.points)) || hand.points.contains { $0.isValid && zone.contains($0, margin: margin) }
            }
            let clearFor = clearSince[zone.label].map { time - $0 }
            let armed = lastAlert[zone.label] == nil || (clearFor ?? 0) >= rearmAfter
            let rested = time - (lastAlert[zone.label] ?? -.infinity) >= cooldown
            if hit == nil && sustained && (holdsAlertUntilExit || (armed && rested)) {
                lastAlert[zone.label] = time
                hit = zone
            }
            if touching { clearSince[zone.label] = nil }
            else if clearSince[zone.label] == nil { clearSince[zone.label] = time }
        }
        return hit
    }
}

/// Alternate visible vessel names are not interchangeable semantic guarantees, but each can
/// supply a real heat-caution box after the cook confirms the cooker was switched on.
public enum CookerSafetyTargets {
    public static let queries = ["pot", "pan", "electric cooker", "kettle", "cup", "bowl"]
    public static func zones(from boxes: [ItemBox]) -> [HazardZone] {
        var zones: [HazardZone] = []
        for box in boxes {
            let name = box.label.lowercased()
            guard name.range(of: #"\b(pots?|pans?|cooker|kettle|cups?|mugs?|bowls?|hot ?plate|stove|burner)\b"#, options: .regularExpression) != nil,
                  box.x.isFinite, box.y.isFinite, box.width.isFinite, box.height.isFinite,
                  box.x >= 0, box.y >= 0, box.width > 0, box.height > 0,
                  box.x + box.width <= 1, box.y + box.height <= 1 else { continue }
            let zone = HazardZone(box)
            if !zones.contains(where: { $0.overlaps(zone) }) { zones.append(zone) }
        }
        return Array(zones.prefix(2))
    }
}

/// Explicit power reports only. Questions, negations and future intentions must not arm a warning.
public enum CookerPowerCommand: Equatable, Sendable {
    case on, off
    public static func parse(_ text: String) -> CookerPowerCommand? {
        guard !text.contains("?") else { return nil }
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'s", with: " is")
            .replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        let target = #"(?:the |my )?(?:kettle|cooker|stove|pot|cup|bowl|hot ?plate|burner|it)"#
        let report = #"(?:(?:i |i've |i have |we |we've |we have )?(?:just |already )?(?:turned|switched|powered) (?:"# + target + #" (?:back )?(on|off)|(on|off) "# + target + #")|"# + target + #" (?:is |was |has been |s )?(?:now |back )?(?:turned |switched |powered )?(on|off)(?: now| again)?)"#
        let pattern = "^(?:okay |ok |yes |and )?" + report + "(?: please| now| again| thanks)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) else { return nil }
        let states = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: words) else { return nil }
            return String(words[range])
        }
        guard let state = states.first else { return nil }
        return state == "on" ? .on : .off
    }
}
