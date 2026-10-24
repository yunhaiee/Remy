import Foundation

/// Presentation policy for a generic COCO detector, not ingredient recognition. COCO has no
/// cucumber, onion, tomato, or lemon class; those can be forced into a visually similar class.
/// Keep generic produce locations useful without presenting that guess as an ingredient name.
public enum FastObjectPresentation {
    private static let produce: Set<String> = ["banana", "apple", "orange", "broccoli", "carrot"]
    private static let preparedFood: Set<String> = ["sandwich", "hot dog", "pizza", "donut", "cake"]

    public static func displayLabel(_ detectorLabel: String) -> String {
        let normalized = detectorLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if produce.contains(normalized) { return "Produce" }
        if preparedFood.contains(normalized) { return "Food" }
        return detectorLabel
    }

    /// This is a conservative fast-path policy, not a confidence guarantee for other categories.
    /// Ingredient-specific food searches need semantic verification or the cook's confirmation.
    public static func isSpecificIdentityReliable(_ detectorLabel: String) -> Bool {
        let normalized = detectorLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && !["produce", "food"].contains(normalized) &&
            !produce.contains(normalized) && !preparedFood.contains(normalized)
    }

    public static func displayBox(_ box: ItemBox) -> ItemBox {
        ItemBox(label: displayLabel(box.label), x: box.x, y: box.y, width: box.width, height: box.height)
    }
}
