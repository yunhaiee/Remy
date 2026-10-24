import Foundation

/// The app's memory of the cook. Gemma never holds state between calls; every call is built from this.
/// The salt names below refer to the current step's `guardItem`, whatever the plan says it is.
public struct CookingSession: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case needsDish, ingredients, cooking }
    public struct PantryItem: Codable, Equatable, Sendable {
        public var status: PantryStatus
        public var origin: EvidenceOrigin
    }

    public private(set) var id = UUID()
    public private(set) var revision = 0
    public private(set) var plan: RecipePlan?
    public private(set) var currentStep = 0
    public private(set) var done: Set<String> = []
    public private(set) var preferences: [String: String] = [:]
    public private(set) var pantry: [String: PantryItem] = [:]
    public private(set) var ingredientsReviewed = false
    /// Guarded additions already made, keyed by step id.
    public private(set) var added: [String: EvidenceOrigin] = [:]
    /// What the cook said they do not have, across swaps, so the chef never suggests it again. Optional storage
    /// keeps sessions saved before this field readable.
    private var missingItems: [String]?
    public var unavailable: [String] { missingItems ?? [] }
    public func isUnavailable(_ name: String) -> Bool {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        return unavailable.contains { $0 == key || Self.sameFood($0, key) }
    }
    public mutating func markUnavailable(_ name: String) {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !isUnavailable(key) else { return }
        missingItems = unavailable + [key]; revision += 1
    }
    /// "white vinegar" and "white wine vinegar": every word of the shorter name is in the longer one.
    public static func sameFood(_ a: String, _ b: String) -> Bool {
        let wa = Set(a.split(separator: " ")), wb = Set(b.split(separator: " "))
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        return wa.isSubset(of: wb) || wb.isSubset(of: wa)
    }
    public private(set) var zone: GuardZone?
    public private(set) var cookerPowerOn: Bool?
    public private(set) var suggestedCompletion = false
    public private(set) var events: [SessionEvent] = []

    public init() {}

    /// An ingredient-only draft deliberately has no executable steps.
    public var instructionsReady: Bool { plan.map { $0.problems.isEmpty } ?? false }
    public var instructionsPending: Bool { plan != nil && !instructionsReady }
    public var ingredientsCollected: Bool {
        guard let plan, !plan.ingredients.isEmpty else { return false }
        return plan.ingredients.allSatisfy { pantry[$0.id]?.status == .seen }
    }
    public var isComplete: Bool {
        guard let plan, !plan.steps.isEmpty else { return false }
        return plan.steps.allSatisfy { done.contains($0.id) }
    }
    /// This requested three-step demo is armed by the cook confirming step 1, not by temperature sensing.
    public var usesCookerSafetySequence: Bool {
        guard let plan, let preset = IngredientDraft.preset(for: plan.dish)?.presetInstructions else { return false }
        return plan == preset
    }
    public var cookerSafetyArmed: Bool {
        usesCookerSafetySequence && phase == .cooking && !isComplete &&
            (cookerPowerOn ?? (done.contains("cook_pasta") && !done.contains("combine")))
    }
    public mutating func reportCookerPower(on: Bool) {
        guard usesCookerSafetySequence, phase == .cooking else { return }
        cookerPowerOn = on; revision += 1
        record(on ? "Cook reported the cooker switched on." : "Cook reported the cooker switched off; heat-caution monitoring paused.", origin: .user)
    }
    /// Retire only the old app-authored preset. Preserve checked ingredients, but never transfer
    /// completion of the old draining step into confirmation that the new cooker has been switched on.
    @discardableResult public mutating func refreshLegacyPastaInstructions() -> Bool {
        guard let plan, let preset = IngredientDraft.preset(for: plan.dish)?.presetInstructions,
              plan.ingredients == preset.ingredients,
              plan.steps.map(\.id) == ["cook_pasta", "prepare", "combine"],
              plan.steps.first?.instruction == "Cook pasta in plain water according to its package directions, then drain and let it cool." else { return false }
        self.plan = preset; done = []; currentStep = 0; ingredientsReviewed = false; cookerPowerOn = nil
        added = [:]; zone = nil; suggestedCompletion = false; revision += 1
        return true
    }
    public var phase: Phase { plan == nil ? .needsDish : ingredientsReviewed && instructionsReady ? .cooking : .ingredients }
    public var step: RecipeStep? { plan.flatMap { $0.steps.indices.contains(currentStep) ? $0.steps[currentStep] : nil } }
    public var isLastStep: Bool { plan.map { currentStep >= $0.steps.count - 1 } ?? true }
    public var salted: Bool { step.map { added[$0.id] != nil } ?? false }
    public var saltOrigin: EvidenceOrigin? { step.flatMap { added[$0.id] } }
    public var guardArmed: Bool { phase == .cooking && step?.isGuarded == true && salted && zone != nil }
    /// Earlier steps this one depends on that the cook has not finished.
    public var unmetNeeds: [RecipeStep] {
        guard let plan, let step else { return [] }
        return plan.steps.filter { step.needs.contains($0.id) && !done.contains($0.id) }
    }

    public mutating func record(_ message: String, origin: EvidenceOrigin) {
        events.append(.init(message, origin: origin))
        if events.count > 150 { events.removeFirst(events.count - 150) }
    }

    public mutating func start(_ plan: RecipePlan) {
        guard plan.problems.isEmpty else { return }
        self = CookingSession()
        self.plan = plan
        record("Gemma planned \(plan.dish): \(plan.ingredients.count) ingredients, \(plan.steps.count) steps.", origin: .system)
    }

    /// Publish the first stage immediately. Pantry controls work while instructions are prepared.
    @discardableResult public mutating func startIngredients(_ draft: IngredientDraft) -> Bool {
        guard draft.problems.isEmpty else { return false }
        self = CookingSession()
        plan = RecipePlan(dish: draft.dish, ingredients: draft.ingredients, steps: [])
        record("Ingredients ready for \(draft.dish); instructions are being prepared.", origin: .system)
        return true
    }

    /// Replace only the empty instruction list. Pantry review increments revision, so revision alone
    /// is intentionally not a stale-result check: a user's confirmations must survive this response.
    /// Ingredient additions/removals/swaps do invalidate the request and require a new second stage.
    @discardableResult public mutating func applyInstructions(_ complete: RecipePlan, expectedSessionID: UUID,
                                                              expectedIngredients: [Ingredient]) -> Bool {
        guard id == expectedSessionID, instructionsPending, phase == .ingredients,
              let current = plan, current.ingredients == expectedIngredients,
              complete.dish == current.dish, complete.ingredients == expectedIngredients,
              complete.problems.isEmpty else { return false }
        plan = complete
        revision += 1
        record("Gemma prepared \(complete.steps.count) instructions; ingredient review was preserved.", origin: .system)
        return true
    }

    public mutating func applyIngredientCheck(_ check: IngredientCheck, expectedSessionID: UUID, expectedRevision: Int) -> Bool {
        guard expectedSessionID == id, expectedRevision == revision, phase == .ingredients else { return false }
        // Camera evidence adds up: an item once seen stays seen when the next frame shows something else (the cook
        // holds items up one by one); unsure can become seen. The cook's word always wins.
        func rank(_ status: PantryStatus) -> Int { status == .seen ? 2 : status == .unsure ? 1 : 0 }
        for item in check.items where pantry[item.id]?.origin != .user {
            if let old = pantry[item.id], rank(old.status) > rank(item.status) { continue }
            pantry[item.id] = .init(status: item.status, origin: .camera)
        }
        revision += 1
        let seen = check.items.filter { $0.status == .seen }.count
        record("Gemma checked the counter: \(seen) of \(plan?.ingredients.count ?? 0) ingredients seen.", origin: .camera)
        return true
    }

    /// The cook's word overrides the camera, e.g. "yes, that white powder is salt".
    public mutating func setPantry(_ ingredientID: String, _ status: PantryStatus) {
        guard let item = plan?.ingredients.first(where: { $0.id == ingredientID }) else { return }
        pantry[ingredientID] = .init(status: status, origin: .user)
        revision += 1
        record("Cook marked \(item.name) as \(status.rawValue).", origin: .user)
    }

    /// The recipe ingredient a spoken name refers to ("vinegar" finds "red wine vinegar").
    public func ingredient(named name: String) -> Ingredient? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, let plan else { return nil }
        return plan.ingredients.first { $0.name.lowercased() == key || $0.id == key }
            ?? plan.ingredients.first { key.contains($0.name.lowercased()) || $0.name.lowercased().contains(key) }
            ?? plan.ingredients.first { Self.sameFood($0.name.lowercased(), key) }
    }

    /// Swap an ingredient in the recipe itself: the list and every step that mentions it change, so the screen,
    /// the camera check and later answers all use the new one. It starts unchecked.
    @discardableResult public mutating func substitute(_ name: String, with replacement: String) -> Bool {
        let new = replacement.trimmingCharacters(in: .whitespaces)
        guard let plan, let old = ingredient(named: name), !new.isEmpty, new.lowercased() != old.name.lowercased() else { return false }
        // Replacing it with something already in the recipe ("use what I have") just means going without it.
        if plan.ingredients.contains(where: { $0.id != old.id && $0.name.lowercased() == new.lowercased() }) { return remove(old.name) }
        func swap(_ text: String) -> String {
            text.replacingOccurrences(of: old.name, with: new, options: .caseInsensitive)
        }
        let ingredients = plan.ingredients.map { $0.id == old.id ? Ingredient(id: old.id, name: new, amount: old.amount) : $0 }
        let steps = plan.steps.map { step in
            RecipeStep(id: step.id, kind: step.kind, title: swap(step.title), instruction: swap(step.instruction), needs: step.needs,
                       doneWhen: swap(step.doneWhen), wrongSize: swap(step.wrongSize), tool: step.tool,
                       guardItem: step.guardItem.lowercased() == old.name.lowercased() ? new : step.guardItem,
                       question: swap(step.question), saves: step.saves, warning: swap(step.warning))
        }
        self.plan = RecipePlan(dish: plan.dish, ingredients: ingredients, steps: steps)
        pantry[old.id] = nil; revision += 1; markUnavailable(old.name)
        record("Using \(new) instead of \(old.name).", origin: .user)
        return true
    }

    /// Add an ingredient the plan forgot ("add lime"). It starts unchecked.
    @discardableResult public mutating func add(_ name: String, amount: String) -> Bool {
        let new = name.trimmingCharacters(in: .whitespaces)
        guard let plan, !new.isEmpty, ingredient(named: new)?.name.lowercased() != new.lowercased() else { return false }
        var id = new.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
        while plan.ingredients.contains(where: { $0.id == id }) { id += "_2" }
        self.plan = RecipePlan(dish: plan.dish, ingredients: plan.ingredients + [Ingredient(id: id, name: new, amount: amount)], steps: plan.steps)
        revision += 1
        record("Added \(new) to the ingredients.", origin: .user)
        return true
    }

    /// Cook without an ingredient: it leaves the list (steps keep their text; the chef says to skip it).
    @discardableResult public mutating func remove(_ name: String) -> Bool {
        guard let plan, let old = ingredient(named: name) else { return false }
        self.plan = RecipePlan(dish: plan.dish, ingredients: plan.ingredients.filter { $0.id != old.id }, steps: plan.steps)
        pantry[old.id] = nil; revision += 1; markUnavailable(old.name)
        record("Cooking without \(old.name).", origin: .user)
        return true
    }

    /// Keep checked ingredients while discarding instructions that still use a removed food.
    @discardableResult public mutating func removeForReplanning(_ name: String) -> Bool {
        guard let old = ingredient(named: name), remove(name), let plan else { return false }
        self.plan = RecipePlan(dish: plan.dish, ingredients: plan.ingredients, steps: [])
        preferences[old.id] = nil
        currentStep = 0; done = []; added = [:]; ingredientsReviewed = false
        zone = nil; suggestedCompletion = false; revision += 1
        return true
    }

    public mutating func beginCooking() {
        guard phase == .ingredients, instructionsReady else { return }
        ingredientsReviewed = true; currentStep = 0; revision += 1
        record("Cook started cooking.", origin: .user)
    }

    public mutating func selectStep(_ index: Int) {
        guard let plan, plan.steps.indices.contains(index), index != currentStep else { return }
        currentStep = index; suggestedCompletion = false; zone = nil; revision += 1
        record("Cook selected step \(index + 1): \(plan.steps[index].title)", origin: .user)
    }

    /// The cook confirms the current step and moves on. Ask steps finish through `answer` instead.
    public mutating func nextStep() {
        guard let step, step.kind == .do else { return }
        done.insert(step.id)
        if usesCookerSafetySequence && step.id == "cook_pasta" { cookerPowerOn = true }
        if isLastStep { revision += 1; record("Cook finished \(plan?.dish ?? "the dish").", origin: .user); return }
        selectStep(currentStep + 1)
    }

    public mutating func answer(_ value: String, heard: String?, origin: EvidenceOrigin) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let step, step.kind == .ask, !value.isEmpty, value.count <= 80 else { return }
        preferences[step.saves] = value
        done.insert(step.id); revision += 1
        record("\(step.saves): \(value)\(heard.map { " (heard: \"\($0)\")" } ?? "")", origin: origin)
        if !isLastStep { selectStep(currentStep + 1) }
    }

    public mutating func markZone(_ zone: GuardZone) {
        guard zone.isValid, let step, step.isGuarded else { return }
        self.zone = zone; revision += 1
        record("Cook marked the \(step.guardItem) location. Re-mark after moving it.", origin: .user)
    }

    public mutating func invalidateZone() {
        // A source switch or pause also invalidates pending observations when no zone exists.
        revision += 1
        suggestedCompletion = false
        guard zone != nil else { return }
        zone = nil
        record("Camera moved or scene interrupted. Guarded item location needs setup again.", origin: .system)
    }

    public mutating func confirmSalt() {
        guard let step, step.isGuarded, phase == .cooking, !salted else { return }
        added[step.id] = .user; revision += 1
        record("Cook confirmed adding \(step.guardItem).", origin: .user)
    }

    public mutating func allowMoreSalt() {
        guard let step, step.isGuarded else { return }
        added[step.id] = nil; revision += 1
        record("Cook chose to add more \(step.guardItem) after tasting.", origin: .user)
    }

    /// A request can only update the state it actually observed. A single frame cannot establish a pour.
    @discardableResult public mutating func apply(_ observation: ChefObservation, expectedSessionID: UUID, expectedRevision: Int,
                                                frameAge: TimeInterval, frameCount: Int) -> Bool {
        guard expectedSessionID == id, expectedRevision == revision, frameAge.isFinite, (0...12).contains(frameAge),
              observation.isValid, phase == .cooking, let step, step.kind == .do else { return false }
        record(observation.evidence, origin: .camera)
        suggestedCompletion = observation.stepComplete && observation.confidence >= 0.85
        if step.isGuarded && observation.saltAdded && observation.confidence >= 0.9 && frameCount >= 2 && !salted {
            added[step.id] = .camera; revision += 1
            record("Gemma observed \(step.guardItem) being added in the image sequence.", origin: .camera)
        }
        return true
    }

    /// After a relaunch the camera has almost certainly moved, so a saved location is never trusted.
    public mutating func restoredAfterLaunch() {
        zone = nil; suggestedCompletion = false; revision += 1
        record("Session restored after the app restarted.", origin: .system)
    }
}
