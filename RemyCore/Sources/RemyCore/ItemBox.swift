import Foundation

/// Where Gemma found an item in a camera snapshot, as fractions of the image (top-left origin), the same space as
/// the hand landmarks. Gemma 4 answers "What's the bounding box for the X" with box_2d [ymin, xmin, ymax, xmax] on a
/// 0-1000 grid, as a JSON list (sometimes in a ```json fence) or a single object.
public struct ItemBox: Codable, Equatable, Sendable {
    public let label: String
    public let x: Double, y: Double, width: Double, height: Double
    public init(label: String, x: Double, y: Double, width: Double, height: Double) {
        self.label = label; self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: Point2 { .init(x + width / 2, y + height / 2) }

    /// Boxes in the reply; [] when Gemma found nothing ("I did not find any bounding box detections").
    /// A box covering nearly the whole image is dropped: that is Gemma not knowing, not a location.
    public static func parse(_ text: String) -> [ItemBox] {
        guard let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let end = text.lastIndex(where: { $0 == "]" || $0 == "}" }), start < end else { return [] }
        let json = Data(text[start...end].utf8)
        struct Raw: Decodable { let box_2d: [Double]; let label: String? }
        let raws = (try? JSONDecoder().decode([Raw].self, from: json)) ?? (try? JSONDecoder().decode(Raw.self, from: json)).map { [$0] } ?? []
        return raws.compactMap { raw in
            guard raw.box_2d.count == 4 else { return nil }
            let v = raw.box_2d.map { min(max($0, 0), 1000) / 1000 }
            let (top, left, bottom, right) = (v[0], v[1], v[2], v[3])
            guard bottom > top, right > left, (bottom - top) * (right - left) < 0.9 else { return nil }
            let label = (raw.label ?? "").replacingOccurrences(of: #"^the "#, with: "", options: [.regularExpression, .caseInsensitive])
            return ItemBox(label: label, x: left, y: top, width: right - left, height: bottom - top)
        }
    }
}
