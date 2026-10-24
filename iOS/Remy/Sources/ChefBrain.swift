import Foundation
import UIKit
import Vision
import RemyCore

/// A Gemma reply that ran but could not be used. Keeps the raw text so the Evidence screen and receipts can show it.
struct GemmaReplyError: LocalizedError {
    let task: String
    let result: InferenceResult
    let underlying: Error
    var errorDescription: String? {
        let reason: String
        switch underlying {
        case CoreError.invalidPlan(let problems): reason = problems.prefix(2).joined(separator: "; ")
        case is DecodingError: reason = result.text.isEmpty ? "the reply was empty" : "the reply was cut off or not valid JSON"
        default: reason = underlying.localizedDescription
        }
        return "Gemma's \(task) could not be used: \(reason). Tap Evidence to see the reply."
    }
}

/// Gemma task wrappers shared by the app and RemyEval: run, decode, validate. No UI or state changes here.
/// Every task gets one retry when the reply cannot be decoded; the plan retry also lists what was wrong.
enum ChefBrain {
    struct PresentedIngredientResult {
        let identity: IngredientVisualIdentity
        let verification: IngredientVisualVerification?
        let result: InferenceResult
        func ingredient(in ingredients: [Ingredient]) -> Ingredient? {
            verification.flatMap { identity.confirmedIngredient(in: ingredients, verification: $0) }
        }
    }

    /// First identify without the cook's claimed name, then inspect a tighter crop. COCO labels
    /// and the spoken hint are deliberately absent from both visual prompts.
    static func presentedIngredient(frame: Data, runner: GemmaRunner) async throws -> PresentedIngredientResult {
        async let labels = Task.detached(priority: .userInitiated) { packageLabels(frame) }.value
        let first = try await runner.run(ChefPrompt.presentedIngredient, prompt:
            "Identify the single food being held up or presented closest to the camera. Give its visible distinguishing features, actual name and box. If no clear single ingredient is presented, return unknown and an empty box.", images: [frame])
        let identity: IngredientVisualIdentity
        do { identity = try IngredientVisualIdentity.decode(JSONOutputContract.clean(first.text)) }
        catch { throw GemmaReplyError(task: "ingredient recognition", result: first, underlying: error) }
        guard identity.isSupported, let box = identity.box, let crop = cropIngredient(frame, box: box) else {
            return .init(identity: identity, verification: nil, result: first)
        }
        // A readable product label inside the visually identified package supplies independent
        // corroboration without a second generative call. Recipe text outside the food box cannot qualify.
        if let label = await labels.first(where: { label in
            IngredientVisualIdentity.sameFood(identity.name, label.name) && label.confidence >= 0.8
                && label.x >= box.x && label.x <= box.x + box.width
                && label.y >= box.y && label.y <= box.y + box.height
        }) {
            let verification = IngredientVisualVerification(matches: true, name: label.name,
                confidence: label.confidence, evidence: "Readable printed package label: \(label.name)")
            return .init(identity: identity, verification: verification,
                result: InferenceResult(text: first.text, elapsedMS: first.elapsedMS, imageCount: 1,
                    speed: "visual identity + independent on-device package OCR"))
        }
        let second = try await runner.run(ChefPrompt.verifyPresentedIngredient, prompt:
            "Inspect this closer crop. An earlier visual pass suggested \(identity.name). Independently decide if that identity is supported. Name what is ACTUALLY visible; reject the suggestion if a look-alike or unclear. Do not infer from what a cook says.", images: [crop])
        let verification: IngredientVisualVerification
        do { verification = try IngredientVisualVerification.decode(JSONOutputContract.clean(second.text)) }
        catch { throw GemmaReplyError(task: "ingredient verification", result: second, underlying: error) }
        return .init(identity: identity, verification: verification,
            result: InferenceResult(text: second.text, elapsedMS: first.elapsedMS + second.elapsedMS, imageCount: 2,
                speed: "blind identity + closer visual verification"))
    }

    private struct PackageLabel: Sendable {
        let name: String
        let confidence: Double
        let x: Double
        let y: Double
    }
    private static func packageLabels(_ data: Data) -> [PackageLabel] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.015
        guard (try? VNImageRequestHandler(data: data, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  let food = PackageIngredientLabel.food(candidate.string) else { return nil }
            return PackageLabel(name: food, confidence: Double(candidate.confidence),
                x: observation.boundingBox.midX, y: 1 - observation.boundingBox.midY)
        }
    }

    private static func cropIngredient(_ data: Data, box: ItemBox) -> Data? {
        guard let image = UIImage(data: data), let cg = image.cgImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let rect = CGRect(x: box.x * Double(cg.width), y: box.y * Double(cg.height),
            width: box.width * Double(cg.width), height: box.height * Double(cg.height))
            .insetBy(dx: -Double(cg.width) * 0.035, dy: -Double(cg.height) * 0.035).intersection(bounds).integral
        guard rect.width >= 16, rect.height >= 16, let crop = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: crop).jpegData(compressionQuality: 0.94)
    }

    /// `onText` receives the plan as Gemma writes it (restarting on a retry) so the screen can fill in early.
    /// `speculative`: write the plan with speculative decoding (Settings switch). LiteRT-LM 0.18.1 cannot combine it
    /// with schema-constrained decoding (the output never stops), so that plan is free-form and parsed leniently.
    static func plan(dish: String, maxSteps: Int = RecipePlan.maxSteps, speculative: Bool = false, runner: GemmaRunner,
                     onText: (@Sendable (String) -> Void)? = nil) async throws -> (RecipePlan, InferenceResult) {
        var task = ChefPrompt.planTask(maxSteps: maxSteps)
        if speculative { task.maxTokens = 1400 }
        let first = try await runner.run(task, prompt: ChefPrompt.plan(dish: dish, maxSteps: maxSteps), constrained: !speculative,
                                         speculative: speculative, onText: onText)
        do { return (try RecipePlan.decode(first.text), first) } catch {
            let problems: [String]
            if case CoreError.invalidPlan(let found) = error { problems = found } else { problems = ["the JSON was incomplete; keep text fields short"] }
            // Retry the schema prompt; only a decoded, validated plan can be used.
            let second = try await runner.run(ChefPrompt.planTask(maxSteps: maxSteps), prompt: ChefPrompt.replan(dish: dish, maxSteps: maxSteps, problems: problems), onText: onText)
            let total = InferenceResult(text: second.text, elapsedMS: first.elapsedMS + second.elapsedMS, imageCount: 0,
                                        speed: "retried after \(Int(first.elapsedMS)) ms (\(problems.first ?? "")) · \(second.speed ?? "")")
            do { return (try RecipePlan.decode(second.text), total) } catch { throw GemmaReplyError(task: "recipe plan", result: total, underlying: error) }
        }
    }

    /// First stage for dishes without an explicit app preset. The caller publishes this list immediately.
    static func ingredientDraft(dish: String, runner: GemmaRunner) async throws -> (IngredientDraft, InferenceResult) {
        let prompt = ChefPrompt.ingredientDraft(dish: dish)
        let first = try await runner.run(ChefPrompt.ingredientDraftTask, prompt: prompt)
        do { return (try IngredientDraft.decode(first.text), first) }
        catch {
            let correction = "\nYour reply was rejected. Return complete JSON with only dish and ingredients, each with a unique id, name and amount. Keep it short."
            let second = try await runner.run(ChefPrompt.ingredientDraftTask, prompt: prompt + correction)
            let total = InferenceResult(text: second.text, elapsedMS: first.elapsedMS + second.elapsedMS, imageCount: 0,
                                        speed: "ingredient list retry · \(second.speed ?? "")")
            do { return (try IngredientDraft.decode(second.text), total) }
            catch { throw GemmaReplyError(task: "ingredient list", result: total, underlying: error) }
        }
    }

    /// The ingredient list is fixed input. Output contains only steps and cannot overwrite pantry review.
    static func instructions(draft: IngredientDraft, maxSteps: Int = RecipePlan.maxSteps,
                             runner: GemmaRunner) async throws -> (RecipePlan, InferenceResult) {
        guard draft.problems.isEmpty else { throw CoreError.invalidPlan(draft.problems) }
        let task = ChefPrompt.instructionsTask(maxSteps: maxSteps)
        let prompt = ChefPrompt.instructions(draft: draft, maxSteps: maxSteps)
        let first = try await runner.run(task, prompt: prompt)
        do { return (try RecipeInstructions.decode(first.text, for: draft), first) }
        catch {
            let detail: String
            if case CoreError.invalidPlan(let problems) = error { detail = problems.prefix(4).joined(separator: "; ") }
            else if case DecodingError.keyNotFound(let key, _) = error { detail = "a step omitted the required \(key.stringValue) field" }
            else { detail = "the JSON syntax or field types were invalid" }
            let correction = """

            Your previous instructions were rejected: \(detail).
            Rewrite the whole JSON object from scratch, following the complete example's structure.
            Every ask AND do step needs id, kind, title, instruction, needs, doneWhen.
            All text values must be quoted strings, never null; ask doneWhen is "".
            needs is [] or earlier step ids only. Use at most \(maxSteps) short steps total and group vegetable prep.
            Keep the supplied ingredients unchanged. Close every quote, array and object. Output only valid JSON.
            """
            let second = try await runner.run(task, prompt: prompt + correction)
            let total = InferenceResult(text: second.text, elapsedMS: first.elapsedMS + second.elapsedMS, imageCount: 0,
                                        speed: "instructions retry · \(second.speed ?? "")")
            do { return (try RecipeInstructions.decode(second.text, for: draft), total) }
            catch { throw GemmaReplyError(task: "instructions", result: total, underlying: error) }
        }
    }

    static func checkIngredients(session: CookingSession, frames: [Data], runner: GemmaRunner) async throws -> (IngredientCheck, InferenceResult) {
        guard let plan = session.plan else { throw RunnerError.noPlan }
        let task = ChefPrompt.ingredients(plan)
        let prompt = ChefPrompt.ingredients(session: session, frameCount: frames.count)
        let first = try await runner.run(task, prompt: prompt, images: frames)
        if let check = try? IngredientCheck.decode(first.text, plan: plan) { return (check, first) }
        let ids = plan.ingredients.map(\.id).joined(separator: ", ")
        let correction = "\nYour previous reply was rejected. Return only seen and unsure arrays. "
            + "The ONLY allowed array values are these exact recipe IDs: \(ids). "
            + "Never put ingredient names, new IDs or aliases in either list. Use empty lists if no listed ingredient is clearly visible."
        let second = try await runner.run(task, prompt: prompt + correction, images: frames)
        let total = InferenceResult(text: second.text, elapsedMS: first.elapsedMS + second.elapsedMS, imageCount: frames.count,
                                    speed: "ingredient format retry · \(second.speed ?? "")")
        do { return (try IngredientCheck.decode(second.text, plan: plan), total) }
        catch { throw GemmaReplyError(task: "ingredient check", result: total, underlying: error) }
    }

    static func hear(question: String, audio: Data, runner: GemmaRunner) async throws -> (HeardAnswer, InferenceResult) {
        try await decodeWithRetry(task: "voice answer") {
            try await runner.run(ChefPrompt.answer, prompt: ChefPrompt.answer(question: question), audio: audio)
        } decode: { try HeardAnswer.decode($0) }
    }

    /// What the microphone heard, as plain text ("" for no clear speech).
    static func transcribe(_ audio: Data, session: CookingSession, runner: GemmaRunner) async throws -> (String, InferenceResult) {
        let result = try await runner.run(ChefPrompt.transcribe, prompt: ChefPrompt.transcribeHint(session), audio: audio, constrained: false)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        return (text, result)
    }

    /// The answer, plus whatever Gemma sees that is hot (it becomes a watched hot zone).
    static func look(question: String, frame: Data, session: CookingSession, runner: GemmaRunner) async throws -> (String, [String], InferenceResult) {
        struct Look: Decodable { let answer: String; let hot: [String] }
        let result = try await runner.run(ChefPrompt.look, prompt: ChefPrompt.look(question, session: session), images: [frame])
        guard let look = try? JSONDecoder().decode(Look.self, from: Data(result.text.utf8)) else {
            return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), [], result)
        }
        return (look.answer.trimmingCharacters(in: .whitespacesAndNewlines), look.hot, result)
    }

    /// What a quick glance found hot ([] when none or unreadable).
    static func glanceHot(_ text: String) -> [String] {
        struct Hot: Decodable { let hot: [String]? }
        return (try? JSONDecoder().decode(Hot.self, from: Data(text.utf8)))?.hot ?? []
    }

    /// Short names of what Gemma thinks is or may be hot in the frame ([] when nothing or unreadable).
    static func hazards(frame: Data, runner: GemmaRunner) async throws -> ([String], InferenceResult) {
        struct Hot: Decodable { let hot: [String] }
        let result = try await runner.run(ChefPrompt.hazards, prompt: "What here is hot, or could burn someone?", images: [frame])
        let names = (try? JSONDecoder().decode(Hot.self, from: Data(result.text.utf8)))?.hot ?? []
        return (names.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, result)
    }

    /// Boxes for the named items in one frame; items Gemma cannot find are simply missing.
    static func locate(_ items: [String], frame: Data, runner: GemmaRunner) async throws -> ([ItemBox], InferenceResult) {
        let result = try await runner.run(ChefPrompt.locate(count: items.count), prompt: ChefPrompt.locate(items), images: [frame], constrained: false)
        return (ItemBox.parse(result.text), result)
    }

    static func answer(question: String, session: CookingSession, runner: GemmaRunner) async throws -> (String, InferenceResult) {
        let result = try await runner.run(ChefPrompt.answerQuestion, prompt: ChefPrompt.question(question, session: session), constrained: false)
        return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), result)
    }

    /// Decode before using a board reply. A format failure gets one corrective request, never an invented result.
    static func review(prompt: String, frames: [Data], guarded: Bool, runner: GemmaRunner) async throws -> (ChefObservation, InferenceResult) {
        let task = guarded ? ChefPrompt.board : ChefPrompt.glance
        func decode(_ text: String) throws -> ChefObservation {
            try guarded ? ChefObservation.decode(text) : glanceObservation(text)
        }
        let first = try await runner.run(task, prompt: prompt, images: frames)
        let failure: String
        do { return (try decode(first.text), first) }
        catch { failure = error.localizedDescription }
        let correction = "\nYour last reply failed validation: \(failure). Return one complete JSON data object only. "
            + "concern must be exactly one of none, size, knife, visibility, uncertain. "
            + "line must be a nonempty spoken sentence of 4–90 characters, under 12 words. "
            + "stepComplete must be a JSON boolean. "
            + (guarded ? "Include confidence, evidence and saltAdded with the requested types. " : "Include hot as an array. ")
            + "No prose, schema, or markdown."
        let second = try await runner.run(task, prompt: prompt + correction, images: frames)
        let result = InferenceResult(text: second.text, elapsedMS: first.elapsedMS + second.elapsedMS,
                                     imageCount: second.imageCount, speed: second.speed)
        do { return (try decode(second.text), result) }
        catch { throw GemmaReplyError(task: guarded ? "board check" : "live glance", result: result, underlying: error) }
    }

    /// A glance has no evidence sentence or confidence. 0.85 lets its stepComplete surface only as a suggestion
    /// the cook confirms; it never marks a guarded addition (glances are not used on guarded steps).
    static func glanceObservation(_ text: String) throws -> ChefObservation {
        struct Glance: Decodable { let concern: String; let stepComplete: Bool; let line: String }
        let glance = try JSONDecoder().decode(Glance.self, from: Data(text.utf8))
        let concern = glance.concern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let line = glance.line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["none", "size", "knife", "visibility", "uncertain"].contains(concern) else {
            throw GlanceValidationError.invalidConcern
        }
        guard !line.isEmpty, line.count <= 240 else { throw GlanceValidationError.invalidLine }
        let observation = ChefObservation(confidence: 0.85, stepComplete: glance.stepComplete, concern: concern,
                                          evidence: "Quick glance: \(concern == "none" ? "looks right" : concern)", line: line)
        guard observation.isValid else { throw CoreError.invalidObservation }
        return observation
    }

    private static func decodeWithRetry<T>(task: String, run: () async throws -> InferenceResult,
                                           decode: (String) throws -> T) async throws -> (T, InferenceResult) {
        let first = try await run()
        if let value = try? decode(first.text) { return (value, first) }
        let second = try await run()
        do { return (try decode(second.text), second) } catch { throw GemmaReplyError(task: task, result: second, underlying: error) }
    }
}

private enum GlanceValidationError: LocalizedError {
    case invalidConcern, invalidLine
    var errorDescription: String? {
        switch self {
        case .invalidConcern: return "concern is outside the allowed list"
        case .invalidLine: return "line is empty or too long"
        }
    }
}
