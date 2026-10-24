import Foundation

public struct Point2: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
    public func distance(to other: Point2) -> Double { hypot(x - other.x, y - other.y) }
}

public struct GuardZone: Codable, Equatable, Sendable {
    public var center: Point2
    public var radius: Double
    public init(center: Point2, radius: Double = 0.12) { self.center = center; self.radius = radius }
    public var isValid: Bool { center.isValid && radius.isFinite && (0.03...0.35).contains(radius) }
    public func contains(_ point: Point2) -> Bool { point.distance(to: center) <= radius }
}

public struct Ingredient: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let amount: String
    public init(id: String, name: String, amount: String) { self.id = id; self.name = name; self.amount = amount }
}

/// One node of a Gemma-planned recipe graph. `needs` lists earlier step ids that must be done first.
/// Unused text fields are empty strings so the model always emits the same shape.
public struct RecipeStep: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case `do`, ask }
    public let id: String
    public let kind: Kind
    public let title: String
    public let instruction: String
    public let needs: [String]
    public let doneWhen: String
    public let wrongSize: String
    public let tool: String
    /// An irreversible single addition, e.g. "salt". Once added, reaching for it again arms the fast-loop warning.
    public let guardItem: String
    /// Ask steps: the question for the cook and the preference key the answer is saved under.
    public let question: String
    public let saves: String
    /// Said the moment a do step starts, before anything irreversible can happen ("colander in the sink first").
    public let warning: String
    public init(id: String, kind: Kind = .do, title: String, instruction: String, needs: [String] = [],
                doneWhen: String = "", wrongSize: String = "", tool: String = "", guardItem: String = "",
                question: String = "", saves: String = "", warning: String = "") {
        self.id = id; self.kind = kind; self.title = title; self.instruction = instruction; self.needs = needs
        self.doneWhen = doneWhen; self.wrongSize = wrongSize; self.tool = tool; self.guardItem = guardItem
        self.question = question; self.saves = saves; self.warning = warning
    }
    public var isGuarded: Bool { kind == .do && !guardItem.isEmpty }
    /// A pot, pan or stove step: the app marks the hot object so a hand reaching it is warned at once.
    public var involvesHeat: Bool { warning == RecipePlan.heatWarning }

    /// `warning` is added by the app, not the model. Gemma leaves out fields that do not apply to a step
    /// (writing them as "" cost about a quarter of the plan's output tokens), so only the core fields are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title); instruction = try c.decode(String.self, forKey: .instruction)
        needs = try c.decodeIfPresent([String].self, forKey: .needs) ?? []
        func optional(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        doneWhen = try optional(.doneWhen); wrongSize = try optional(.wrongSize); tool = try optional(.tool)
        guardItem = try optional(.guardItem); question = try optional(.question); saves = try optional(.saves)
        warning = try c.decodeIfPresent(String.self, forKey: .warning) ?? ""
    }
}

/// The whole recipe, planned once by Gemma from the dish name and then held by the app, not the model.
public struct RecipePlan: Codable, Equatable, Sendable {
    public static let maxSteps = 12
    public let dish: String
    public let ingredients: [Ingredient]
    public let steps: [RecipeStep]
    public init(dish: String, ingredients: [Ingredient], steps: [RecipeStep]) {
        self.dish = dish; self.ingredients = ingredients; self.steps = steps
    }
    /// Empty when the graph is usable. Steps must already be in an order where every `needs` points backwards.
    public var problems: [String] {
        var found: [String] = []
        if dish.isEmpty || dish.count > 80 { found.append("dish name must be 1-80 characters") }
        if !(1...20).contains(ingredients.count) { found.append("list 1-20 ingredients") }
        if Set(ingredients.map(\.id)).count != ingredients.count { found.append("ingredient ids must be unique") }
        if ingredients.contains(where: { $0.id.isEmpty || $0.name.isEmpty }) { found.append("every ingredient needs an id and name") }
        if !(2...Self.maxSteps).contains(steps.count) { found.append("use 2-\(Self.maxSteps) steps") }
        var seen = Set<String>()
        for step in steps {
            if step.id.isEmpty || seen.contains(step.id) { found.append("step id '\(step.id)' is empty or repeated") }
            if step.title.isEmpty { found.append("step \(step.id) needs a title") }
            for need in step.needs where !seen.contains(need) {
                found.append("step \(step.id) needs '\(need)', which is not an earlier step")
            }
            switch step.kind {
            case .do where step.doneWhen.isEmpty: found.append("step \(step.id) needs doneWhen")
            case .ask where step.question.isEmpty || step.saves.isEmpty: found.append("ask step \(step.id) needs question and saves")
            default: break
            }
            seen.insert(step.id)
        }
        // Only structural breaks are rejected (a re-plan costs ~20 s live). Content issues such as a salt step
        // without a preference question are repaired in `normalized` instead.
        return found
    }

    /// Makes the graph consistent where a rule is mechanical; small models often fill every field or forget one.
    /// - Fields that do not belong to a step's kind are cleared; ids used as names get spaces.
    /// - A do step that uses a preference answer becomes the guarded step for it: the addition happens once
    ///   there, so the fast loop can warn on a second reach.
    public var normalized: RecipePlan {
        // Steps never refer to ingredient ids, so a repeated id is renamed instead of costing a full re-plan.
        var seenIDs: [String: Int] = [:]
        let uniqueIngredients = ingredients.map { item -> Ingredient in
            let count = seenIDs[item.id, default: 0] + 1
            seenIDs[item.id] = count
            return Ingredient(id: count == 1 ? item.id : "\(item.id)_\(count)",
                              name: item.name.replacingOccurrences(of: "_", with: " "), amount: item.amount)
        }
        // A seasoning a step adds once (or an ask step saves) belongs on the ingredient list, even when the plan
        // forgot it there; the ingredient check and the screen then include it.
        let listed = Set(uniqueIngredients.map { $0.name.lowercased() })
        let seasonings = steps.flatMap { [$0.guardItem, $0.kind == .ask ? $0.saves : ""] }
            .map { $0.replacingOccurrences(of: "_", with: " ").lowercased() }
            .filter { !$0.isEmpty && !listed.contains($0) && ["salt", "pepper", "sugar"].contains($0) }
        let completeIngredients = uniqueIngredients + Array(NSOrderedSet(array: seasonings)).compactMap { $0 as? String }.map {
            Ingredient(id: $0.replacingOccurrences(of: " ", with: "_"), name: $0, amount: "to taste")
        }
        // The core promise: a one-way seasoning is asked about first, then guarded. If the plan forgot the
        // question, it is inserted before the first step that adds the salt; an ask step is linked to the later
        // step that mentions what it saves.
        var steps = steps
        let hasSalt = completeIngredients.contains { $0.name.lowercased().contains("salt") }
        if hasSalt, !steps.contains(where: { $0.kind == .ask && $0.saves.contains("salt") }),
           let target = steps.firstIndex(where: { $0.kind == .do && "\($0.title) \($0.instruction)".lowercased().contains("salt") }) {
            let id = steps.contains { $0.id == "ask_salt" } ? "ask_salt_2" : "ask_salt"
            let salted = steps[target]
            steps[target] = RecipeStep(id: salted.id, kind: salted.kind, title: salted.title, instruction: salted.instruction,
                                       needs: salted.needs + [id], doneWhen: salted.doneWhen, wrongSize: salted.wrongSize,
                                       tool: salted.tool, guardItem: salted.guardItem, question: salted.question, saves: salted.saves)
            steps.insert(RecipeStep(id: id, kind: .ask, title: "Salt preference", instruction: "Ask how salty the cook likes it.",
                                    question: "How salty do you like it?", saves: "salt"), at: target)
        }
        for (index, ask) in steps.enumerated() where ask.kind == .ask && !ask.saves.isEmpty
            && !steps.contains(where: { $0.needs.contains(ask.id) }) {
            let word = ask.saves.replacingOccurrences(of: "_", with: " ").lowercased()
            if let target = steps.indices.first(where: { $0 > index && steps[$0].kind == .do
                && "\(steps[$0].title) \(steps[$0].instruction)".lowercased().contains(word) }) {
                let step = steps[target]
                steps[target] = RecipeStep(id: step.id, kind: step.kind, title: step.title, instruction: step.instruction,
                                           needs: step.needs + [ask.id], doneWhen: step.doneWhen, wrongSize: step.wrongSize,
                                           tool: step.tool, guardItem: step.guardItem, question: step.question, saves: step.saves)
            }
        }
        let asks = Dictionary(steps.filter { $0.kind == .ask }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // needs may only name earlier steps; Gemma sometimes lists ingredients there ("mash_avocado needs avocado"),
        // which says nothing about order, so those entries are dropped instead of rejecting the whole plan.
        let earlier = Dictionary(steps.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return RecipePlan(dish: dish, ingredients: completeIngredients, steps: steps.enumerated().map { index, original in
            let step = RecipeStep(id: original.id, kind: original.kind, title: original.title, instruction: original.instruction,
                                  needs: original.needs.filter { earlier[$0].map { $0 < index } ?? false },
                                  doneWhen: original.doneWhen, wrongSize: original.wrongSize, tool: original.tool,
                                  guardItem: original.guardItem, question: original.question, saves: original.saves)
            guard step.kind == .do else {
                return RecipeStep(id: step.id, kind: .ask, title: step.title, instruction: step.instruction, needs: step.needs,
                                  question: step.question, saves: step.saves)
            }
            var guardItem = step.guardItem.replacingOccurrences(of: "_", with: " "), instruction = step.instruction
            // Prefer the answer the step text mentions, then salt, the classic one-way addition.
            let used = step.needs.compactMap { asks[$0]?.saves.replacingOccurrences(of: "_", with: " ") }.filter { !$0.isEmpty }
            let text = "\(step.title) \(step.instruction)".lowercased()
            if guardItem.isEmpty, let item = used.first(where: { text.contains($0) }) ?? used.first(where: { $0.contains("salt") }) ?? used.first {
                guardItem = item
                if !instruction.lowercased().contains(guardItem) { instruction += " Add the \(guardItem) once, to taste." }
            }
            return RecipeStep(id: step.id, kind: .do, title: step.title, instruction: instruction, needs: step.needs,
                              // A missing doneWhen would cost a whole re-plan (~20 s); the instruction is a usable target.
                              doneWhen: step.doneWhen.isEmpty ? step.instruction : step.doneWhen,
                              wrongSize: step.wrongSize, tool: step.tool, guardItem: guardItem,
                              warning: Self.warning(for: step, guardItem: guardItem))
        })
    }
    /// Warnings come from rules, not the model: a 2B model warns about everything, and these are the
    /// moments that cannot be undone. Spoken as the step starts, before the mistake can happen.
    public static let heatWarning = "Turn the pan handle inward and keep your hands clear of the heat."
    static func warning(for step: RecipeStep, guardItem: String) -> String {
        let text = "\(step.title) \(step.instruction)".lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil } }
        if has("drain", "strain", "pour off") { return "Put the colander in the sink before you pour." }
        if !guardItem.isEmpty { return "Taste first. The \(guardItem) can't come back out." }
        if has("fry", "sear", "sauté", "saute", "pan", "hot oil", "skillet", "griddle", "boil", "boiling", "stove", "toast") {
            return heatWarning
        }
        if has("discard", "throw away", "throw out") { return "Check what you're throwing out before it goes in the bin." }
        return ""
    }

    public static func decode(_ text: String) throws -> RecipePlan {
        let plan = try JSONDecoder().decode(Self.self, from: try modelJSON(text)).normalized
        guard plan.problems.isEmpty else { throw CoreError.invalidPlan(plan.problems) }
        return plan
    }
}

public enum PantryStatus: String, Codable, Sendable { case seen, missing, unsure }

/// Gemma's look at the counter before cooking. Look-alikes such as salt and sugar should come back unsure.
public struct IngredientCheck: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let status: PantryStatus
        public init(id: String, status: PantryStatus) { self.id = id; self.status = status }
    }
    public let items: [Item]
    public let line: String
    public init(items: [Item], line: String) { self.items = items; self.line = line }
    /// Reads the compact reply ({"seen":[ids],"unsure":[ids]}: anything not listed is missing, so Gemma writes a
    /// few ids instead of a status for every ingredient) or the older per-item form.
    public static func decode(_ text: String, plan: RecipePlan) throws -> IngredientCheck {
        let json = try modelJSON(text)
        let known = Set(plan.ingredients.map(\.id))
        struct Compact: Decodable { let seen: [String]; let unsure: [String]? }
        if let compact = try? JSONDecoder().decode(Compact.self, from: json) {
            guard (compact.seen + (compact.unsure ?? [])).allSatisfy(known.contains) else { throw CoreError.invalidObservation }
            let items = plan.ingredients.map { item in
                Item(id: item.id, status: compact.seen.contains(item.id) ? .seen : (compact.unsure ?? []).contains(item.id) ? .unsure : .missing)
            }
            return IngredientCheck(items: items, line: "")
        }
        let check = try JSONDecoder().decode(Self.self, from: json)
        guard check.items.allSatisfy({ known.contains($0.id) }) else { throw CoreError.invalidObservation }
        return check
    }
}

/// What Gemma heard in a spoken answer. `value` is the short normalized answer saved as a preference.
public struct HeardAnswer: Codable, Equatable, Sendable {
    public let heard: String
    public let value: String
    public let line: String
    public init(heard: String, value: String, line: String) { self.heard = heard; self.value = value; self.line = line }
    public static func decode(_ text: String) throws -> HeardAnswer {
        let answer = try JSONDecoder().decode(Self.self, from: try modelJSON(text))
        guard !answer.value.isEmpty, answer.value.count <= 80, !answer.line.isEmpty else { throw CoreError.invalidObservation }
        return answer
    }
}

/// Accepts bare JSON or a single fenced block, which models sometimes add even under a schema.
func modelJSON(_ text: String) throws -> Data {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.hasPrefix("```") else { return Data(cleaned.utf8) }
    let lines = cleaned.components(separatedBy: .newlines)
    guard lines.count >= 3, lines.last == "```" else { throw CoreError.invalidObservation }
    return Data(lines.dropFirst().dropLast().joined(separator: "\n").utf8)
}

public struct ChefObservation: Codable, Equatable, Sendable {
    public var confidence: Double
    public var saltAdded: Bool
    public var stepComplete: Bool
    public var concern: String
    public var evidence: String
    public var line: String
    public init(confidence: Double, saltAdded: Bool = false, stepComplete: Bool = false,
                concern: String = "none", evidence: String, line: String) {
        self.confidence = confidence; self.saltAdded = saltAdded; self.stepComplete = stepComplete
        self.concern = concern; self.evidence = evidence; self.line = line
    }
    public var isValid: Bool {
        confidence.isFinite && (0...1).contains(confidence) &&
        ["none", "size", "knife", "visibility", "uncertain"].contains(concern) &&
        !evidence.isEmpty && evidence.count <= 500 && !line.isEmpty && line.count <= 240
    }
    public static func decode(_ text: String) throws -> ChefObservation {
        let result = try JSONDecoder().decode(Self.self, from: try modelJSON(text))
        guard result.isValid else { throw CoreError.invalidObservation }
        return result
    }
}

public enum CoreError: LocalizedError {
    case invalidObservation, invalidPlan([String])
    public var errorDescription: String? {
        switch self {
        case .invalidObservation: return "Gemma's reply did not match the expected format."
        case .invalidPlan(let problems): return "Gemma's recipe plan was not usable: \(problems.prefix(3).joined(separator: "; "))."
        }
    }
}
public enum EvidenceOrigin: String, Codable, Sendable { case camera, user, system }
public struct SessionEvent: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let origin: EvidenceOrigin
    public let message: String
    public init(_ message: String, origin: EvidenceOrigin) {
        id = UUID(); timestamp = Date(); self.message = message; self.origin = origin
    }
}
