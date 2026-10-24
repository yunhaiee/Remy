import Foundation
import UIKit
import RemyCore
import LiteRTLM

/// Runs the real Gemma tasks on files in Documents/Eval, in the simulator or on a phone. No UI or app state.
/// - dish.txt: the dish to plan (default "cold pasta salad"). The plan is printed and saved to eval-plan.json.
///   plan.json (a saved eval-plan.json) skips planning.
/// - look_<question-words>.jpg: a spoken question about the photo ("look_do-you-see-red-onion.jpg").
/// - ingredients*.jpg: ingredient check against the plan.
/// - <keyword>_*.jpg: board check on the first plan step whose title or instruction contains the keyword.
/// - dish*.wav / other *.wav: spoken answer to "what do you want to make" / the plan's first ask step.
/// Results go to Documents/eval-results.json.
enum RemyEval {
    @available(iOS 26, *)
    private static var prepared: AppleSpeech??
    @available(iOS 26, *)
    private static func appleSpeech() async -> AppleSpeech? {
        if let prepared { return prepared }
        let speech = await AppleSpeech.prepare(); prepared = .some(speech); return speech
    }

    /// Isolated on-device compatibility probe; never consumes private sensor input.
    static func ingredientModelProbe() async {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fast = ProcessInfo.processInfo.arguments.contains("--fast-ingredient-probe")
        let file = folder.appendingPathComponent(fast ? "Models/gemma-4-E2B-it.litertlm" : "Models/gemma-4-E4B-it.litertlm")
        var report: [String: Any] = ["model": fast ? "Gemma 4 E2B" : "Gemma 4 E4B", "backendRequested": fast ? "Metal GPU + CPU vision" : "CPU + CPU vision",
            "processID": ProcessInfo.processInfo.processIdentifier, "completed": false]
        let runner = GemmaRunner()
        do {
            report["loadMS"] = try await runner.load(path: file.path, useGPU: fast)
            let image = await MainActor.run {
                UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320)).jpegData(withCompressionQuality: 0.9) { c in
                    UIColor.gray.setFill(); c.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
                }
            }
            let result = try await runner.run(prompt: "Describe only what is visible. Is there a recognizable food?", images: [image])
            report["response"] = result.text; report["elapsedMS"] = result.elapsedMS
            if ProcessInfo.processInfo.arguments.contains("--concurrent-ingredient-probe") {
                let chef = GemmaRunner()
                report["chefLoadMS"] = try await chef.load(path: folder.appendingPathComponent("Models/gemma-4-E2B-it.litertlm").path, useGPU: true)
                var pairs: [[String: Any]] = []
                for index in 0..<3 {
                    async let draft = ChefBrain.ingredientDraft(dish: "tomato cucumber salad", runner: chef)
                    async let vision = ChefBrain.presentedIngredient(frame: image, runner: runner)
                    let (ingredients, observation) = try await (draft, vision)
                    pairs.append(["cycle": index, "draftValid": ingredients.0.problems.isEmpty,
                        "visionName": observation.identity.name, "visionMS": observation.result.elapsedMS,
                        "grayImageConfirmed": observation.ingredient(in: ingredients.0.ingredients) != nil])
                }
                report["concurrentPairs"] = pairs
                report["nativeRuntimeHealthy"] = !runner.requiresRestart && !chef.requiresRestart
            }
            report["completed"] = true
        } catch { report["error"] = error.localizedDescription }
        report["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("ingredient-model-probe.json"), options: [.atomic, .completeFileProtection])
        }
    }

    static func run(modelPath: String) async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--vision-bench") || arguments.contains("--box-tokens") {
            print("REMY_EVAL Variable image-token benchmarks are disabled in this stability build. Every image uses 140 visual tokens; historical token sweeps require the earlier runtime path.")
            return
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Eval")
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let runner = GemmaRunner()
        // Prefill/decode speeds come from LiteRT-LM's benchmark info, an experimental API that must be opted into.
        // --mtp turns on speculative decoding (Gemma 4's multi-token-prediction drafter) to compare speed.
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        let speculative = ProcessInfo.processInfo.arguments.contains("--mtp")
        // --box-tokens N: image detail for box searches (70, 140, 280, 560).
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--box-tokens"),
           let n = Int(ProcessInfo.processInfo.arguments.dropFirst(i + 1).first ?? "") { ChefPrompt.boxVisualTokens = n }
        do {
            let loadMS = try await runner.load(path: modelPath, useGPU: true)
            print("REMY_EVAL backend \(await runner.backend), load \(Int(loadMS)) ms")
            // --mtp: the plan and the chef's turns use speculative decoding, as with the Settings switch.
            if ProcessInfo.processInfo.arguments.contains("--mtp") { await runner.setSpeculativeChat(true) }
        } catch {
            print("REMY_EVAL load failed: \(error.localizedDescription)"); return
        }
        var rows: [[String: Any]] = []
        func report(_ name: String, _ kind: String, _ result: InferenceResult?, _ error: Error?) {
            if let result {
                print("REMY_EVAL \(kind) \(name) \(Int(result.elapsedMS)) ms · \(result.text.count) chars · \(result.speed ?? "no speed info")\n\(result.text)")
                rows.append(["file": name, "kind": kind, "elapsedMS": result.elapsedMS, "response": result.text,
                             "error": error.map { $0.localizedDescription } ?? NSNull()])
            } else {
                print("REMY_EVAL \(kind) \(name) error: \(error?.localizedDescription ?? "unknown")")
                rows.append(["file": name, "kind": kind, "error": error?.localizedDescription ?? "unknown"])
            }
        }

        let dish = (try? String(contentsOf: folder.appendingPathComponent("dish.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "cold pasta salad"
        var plan: RecipePlan
        // plan.json (an earlier eval-plan.json) skips planning, so image and voice prompts can be tested quickly.
        // Raw Gemma output and app-saved plans both go through the app's normalization and checks.
        if let saved = try? String(contentsOf: folder.appendingPathComponent("plan.json"), encoding: .utf8),
           let decoded = try? RecipePlan.decode(saved) {
            plan = decoded
            print("REMY_EVAL using saved plan.json: \(decoded.dish)")
        } else { do {
            let started = ProcessInfo.processInfo.systemUptime
            // --short: the app's Short recipes setting (at most 5 steps).
            let maxSteps = ProcessInfo.processInfo.arguments.contains("--short") ? 5 : RecipePlan.maxSteps
            let (planned, result) = try await ChefBrain.plan(dish: dish, maxSteps: maxSteps, speculative: speculative, runner: runner) { text in
                guard text.hasSuffix("}") || text.hasSuffix("]") else { return }
                let preview = PlanPreview(streamed: text)
                print(String(format: "REMY_STREAM %.1f s · %d ingredients · %d steps",
                             ProcessInfo.processInfo.systemUptime - started, preview.ingredients.count, preview.steps.count))
            }
            plan = planned
            report(dish, "plan", result, nil)
            print(planned.steps.enumerated().map { "  \($0 + 1). [\($1.kind.rawValue)] \($1.title)\($1.isGuarded ? " · guard \($1.guardItem)" : "")\($1.kind == .ask ? " · \($1.question)" : "")" }.joined(separator: "\n"))
            if let data = try? JSONEncoder().encode(planned) { try? data.write(to: documents.appendingPathComponent("eval-plan.json")) }
            // --then-plain: plan again without speculative decoding on the same engine (switch turned off).
            if ProcessInfo.processInfo.arguments.contains("--then-plain") {
                let again = ProcessInfo.processInfo.systemUptime
                print("REMY_EVAL replanning without speculative decoding")
                do {
                    let (_, second) = try await ChefBrain.plan(dish: dish, maxSteps: maxSteps, speculative: false, runner: runner)
                    report(dish, "plan-plain-after", second, nil)
                    print(String(format: "REMY_EVAL plain plan after speculative: %.1f s", ProcessInfo.processInfo.systemUptime - again))
                } catch { report(dish, "plan-plain-after", nil, error) }
            }
        } catch {
            report(dish, "plan", (error as? GemmaReplyError)?.result, error); write(rows, to: documents); return
        } }

        // --plan-bench: the same plan prompt without schema enforcement, to separate constrained-decoding cost.
        if ProcessInfo.processInfo.arguments.contains("--plan-bench") {
            do { report(dish, "plan-unconstrained", try await runner.run(ChefPrompt.plan, prompt: ChefPrompt.plan(dish: dish), constrained: false), nil) }
            catch { report(dish, "plan-unconstrained", nil, error) }
        }

        var session = CookingSession()
        session.start(plan)

        // --vision-bench: what makes an image check slow — frame count, image tokens, or reply size.
        if ProcessInfo.processInfo.arguments.contains("--vision-bench"),
           let photo = files.first(where: { $0.pathExtension == "jpg" && !$0.lastPathComponent.hasPrefix("ingredients") }),
           let jpeg = try? Data(contentsOf: photo),
           let index = plan.steps.firstIndex(where: { !$0.wrongSize.isEmpty }) {
            var cooking = session
            cooking.beginCooking(); cooking.selectStep(index)
            var board = ChefPrompt.board, glance = ChefPrompt.glance
            let variants: [(String, GemmaTask, Int)] = [
                ("warm-up", board, 1), ("board 3 frames @280", board, 3), ("board 1 frame @280", board, 1),
                ("board 1 frame @140", { board.visualTokens = 140; return board }(), 1),
                ("board 1 frame @70", { board.visualTokens = 70; return board }(), 1),
                ("glance 1 frame @140", glance, 1),
                ("glance 1 frame @70", { glance.visualTokens = 70; return glance }(), 1)
            ]
            for (label, task, frames) in variants {
                do {
                    let result = try await runner.run(task, prompt: ChefPrompt.make(session: cooking, frameCount: frames, span: 0.8),
                                                      images: Array(repeating: jpeg, count: frames))
                    report("\(photo.lastPathComponent) · \(label)", "vision-bench", result, nil)
                } catch { report(label, "vision-bench", nil, error) }
            }
        }
        // --clone-bench: prompt reuse (conversation clone) vs fresh conversations for chef turns.
        if ProcessInfo.processInfo.arguments.contains("--clone-bench") {
            var turn = CookingSession(); turn.start(plan); turn.beginCooking()
            do {
                let lines = try await runner.cloneBench(system: ChefAgent.system(turn), tools: ChefAgent.tools(turn),
                                                        prompts: ["Chef, I'm done with this step", "Chef, where's the salt?", "Chef, how hot should the pan be?"])
                for line in lines { print("REMY_EVAL clone-bench \(line)") }
            } catch { print("REMY_EVAL clone-bench error: \(error)") }
        }

        // agent.txt: "phase|transcript" per line, answered by the conversational chef with running history. One
        // session per phase carries over between lines, recipe edits are applied, and a check_ingredients call gets a
        // fixed camera result ("seen.txt") sent back to Gemma, as the app does.
        if let lines = try? String(contentsOf: folder.appendingPathComponent("agent.txt"), encoding: .utf8) {
            var history: [ChefAgent.Turn] = []
            var sessions: [String: CookingSession] = [:]
            let seen = (try? String(contentsOf: folder.appendingPathComponent("seen.txt"), encoding: .utf8)) ?? "Camera saw: none."
            for line in lines.split(separator: "\n").map(String.init) where line.contains("|") {
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                var turn = sessions[parts[0]] ?? {
                    var fresh = CookingSession()
                    if parts[0] != "needsDish" { fresh.start(plan) }
                    if ["cooking", "ask", "guard"].contains(parts[0]) {
                        fresh.beginCooking()
                        let target = plan.steps.firstIndex { parts[0] == "ask" ? $0.kind == .ask : parts[0] == "guard" ? $0.isGuarded : !$0.wrongSize.isEmpty }
                        if let target { fresh.selectStep(target) }
                    }
                    return fresh
                }()
                do {
                    let reply = try await ChefAgent.respond(to: parts[1], session: turn, history: history, runner: runner)
                    let calls = reply.actions.map { "\($0.name)(\($0.arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", ")))" }
                    print(String(format: "REMY_EVAL agent %.0f ms %@ → \"%@\" %@", reply.elapsedMS, line, reply.speech, calls.joined(separator: " ")))
                    var results: [(String, String)] = []
                    for action in reply.actions {
                        switch action.name {
                        case "substitute_ingredient":
                            let (old, new) = (action.arguments["ingredient"] ?? "", action.arguments["substitute"] ?? "")
                            if turn.isUnavailable(new) || new.lowercased() == old.lowercased() {
                                turn.markUnavailable(old)
                                results.append((action.name, "The cook does not have \(new) either. Suggest a different substitute, or remove the ingredient."))
                                continue
                            }
                            results.append((action.name, turn.substitute(old, with: new)
                                ? "Recipe updated: \(new) replaces \(old) in the list and the steps." : "\(old) is not in this recipe."))
                        case "add_ingredient":
                            let new = action.arguments["ingredient"] ?? ""
                            results.append((action.name, turn.add(new, amount: action.arguments["amount"] ?? "")
                                ? "Recipe updated: added \(new)." : "\(new) is already in the recipe."))
                        case "remove_ingredient":
                            let old = action.arguments["ingredient"] ?? ""
                            results.append((action.name, turn.remove(old) ? "Recipe updated: cooking without \(old)." : "\(old) is not in this recipe."))
                        case "check_ingredients": results.append((action.name, seen.trimmingCharacters(in: .whitespacesAndNewlines)))
                        case "look": results.append((action.name, "The camera shows: " + ((try? String(contentsOf: folder.appendingPathComponent("camera.txt"), encoding: .utf8)) ?? "a counter.")))
                        default: break
                        }
                    }
                    var said = reply.speech
                    if !results.isEmpty && (reply.speech.isEmpty || results.contains { ["check_ingredients", "look"].contains($0.0) }) {
                        let followUp = try await ChefAgent.followUp(results, to: reply, session: turn, history: history, runner: runner)
                        said = followUp.speech
                        for action in followUp.actions where action.name == "substitute_ingredient" {
                            let (old, new) = (action.arguments["ingredient"] ?? "", action.arguments["substitute"] ?? "")
                            if !turn.isUnavailable(new) { turn.substitute(old, with: new) }
                        }
                        print("REMY_EVAL agent follow-up → \"\(said)\" \(followUp.actions.map { "\($0.name)(\($0.arguments))" })")
                    }
                    print("REMY_EVAL agent ingredients now: \(turn.plan?.ingredients.map(\.name).joined(separator: ", ") ?? "-")")
                    sessions[parts[0]] = turn
                    history.append(.init(cook: parts[1], chef: ChefAgent.remembered(said, actions: reply.actions)))
                } catch { print("REMY_EVAL agent \(line) error: \(error)") }
            }
        }

        for file in files {
            let name = file.lastPathComponent, ext = file.pathExtension.lowercased()
            do {
                if ext == "wav", name.hasPrefix("voice") {
                    // Hands-free turn. Name hints: dish / answer / added pick the situation; recent = chef just spoke.
                    var turnSession = CookingSession()
                    if !name.contains("dish") {
                        turnSession = session; turnSession.beginCooking()
                        let target = name.contains("answer") ? plan.steps.firstIndex { $0.kind == .ask }
                            : name.contains("added") ? plan.steps.firstIndex { $0.isGuarded }
                            : plan.steps.firstIndex { !$0.wrongSize.isEmpty }
                        if let target { turnSession.selectStep(target) }
                    }
                    if #available(iOS 26, *), let apple = await appleSpeech() {
                        let started = ProcessInfo.processInfo.systemUptime
                        let samples = HandsFreeListener.samples(fromWAV: try Data(contentsOf: file))
                        apple.begin(Array(samples.prefix(4800)))
                        // The microphone delivers ~2048-sample chunks; feed the clip the same way.
                        for start in stride(from: 4800, to: samples.count, by: 2048) { apple.append(Array(samples[start..<min(start + 2048, samples.count)])) }
                        let words = await apple.end()?.value ?? nil
                        print(String(format: "REMY_EVAL apple-speech %@ %.0f ms → %@", name, (ProcessInfo.processInfo.systemUptime - started) * 1000, words ?? "nil"))
                    }
                    let (heard, result) = try await ChefBrain.transcribe(try Data(contentsOf: file), session: turnSession, runner: runner)
                    let command = VoiceCommand.parse(heard, phase: turnSession.phase, secondsSinceChefSpoke: name.contains("recent") ? 3 : 60)
                    report("\(name) → \(command.intent.rawValue) \(command.value)", "voice", result, nil)
                    if command.intent == .agent {
                        let reply = try await ChefAgent.respond(to: heard, session: turnSession, history: [], runner: runner)
                        print("REMY_EVAL voice-agent \(name) → \"\(reply.speech)\" \(reply.actions.map(\.name))")
                    }
                } else if ext == "wav" {
                    let ask = plan.steps.first { $0.kind == .ask }
                    let question = name.hasPrefix("dish") ? ChefPrompt.dishQuestion : ask?.question ?? "How salty do you like it?"
                    let (_, result) = try await ChefBrain.hear(question: question, audio: try Data(contentsOf: file), runner: runner)
                    report(name, "answer", result, nil)
                } else if ["jpg", "jpeg"].contains(ext), name.hasPrefix("hazard_") {
                    // hazard_counter.jpg: what Gemma names as hot, then the boxes it draws for those names.
                    let (names, result) = try await ChefBrain.hazards(frame: try Data(contentsOf: file), runner: runner)
                    report("\(name) → hot: \(names)", "hazards", result, nil)
                    if !names.isEmpty {
                        let (boxes, boxed) = try await ChefBrain.locate(Array(names.prefix(3)), frame: try Data(contentsOf: file), runner: runner)
                        report("\(name) boxes → \(boxes.map { String(format: "%@ x%.2f y%.2f w%.2f h%.2f", $0.label, $0.x, $0.y, $0.width, $0.height) })", "hazard-boxes", boxed, nil)
                    }
                } else if ["jpg", "jpeg"].contains(ext), name.hasPrefix("box_") {
                    // box_chef-knife.jpg: where is the chef knife? box_cucumber+tomato.jpg: several in one call.
                    let items = file.deletingPathExtension().lastPathComponent.dropFirst(4).split(separator: "+")
                        .map { $0.replacingOccurrences(of: "-", with: " ") }
                    let (boxes, result) = try await ChefBrain.locate(items, frame: try Data(contentsOf: file), runner: runner)
                    report("\(name) → \(boxes.map { String(format: "%@ x%.2f y%.2f w%.2f h%.2f", $0.label, $0.x, $0.y, $0.width, $0.height) })", "box", result, nil)
                } else if ["jpg", "jpeg"].contains(ext), name.hasPrefix("look_") {
                    // look_do-you-see-red-onion.jpg: the spoken question is in the file name.
                    let question = file.deletingPathExtension().lastPathComponent.dropFirst(5).replacingOccurrences(of: "-", with: " ")
                    let (reply, hot, result) = try await ChefBrain.look(question: question, frame: try Data(contentsOf: file), session: session, runner: runner)
                    report("\(name) → \(reply) · hot: \(hot)", "look", result, nil)
                } else if ["jpg", "jpeg"].contains(ext), name.hasPrefix("ingredients") {
                    let (check, result) = try await ChefBrain.checkIngredients(session: session, frames: [try Data(contentsOf: file)], runner: runner)
                    report(name, "ingredients", result, nil)
                    // The app's verification: claimed items must be boxed in the same frame.
                    let claimed = check.items.filter { $0.status == .seen }.compactMap { item in plan.ingredients.first { $0.id == item.id }?.name }
                    if !claimed.isEmpty {
                        let (boxes, boxed) = try await ChefBrain.locate(claimed, frame: try Data(contentsOf: file), runner: runner)
                        report("\(name) verify \(claimed) → boxed \(boxes.map(\.label))", "verify", boxed, nil)
                    }
                } else if ["jpg", "jpeg"].contains(ext) {
                    let keyword = String(name.prefix { $0 != "_" && $0 != "." }).lowercased()
                    guard let index = plan.steps.firstIndex(where: { $0.kind == .do && "\($0.title) \($0.instruction)".lowercased().contains(keyword) }) else {
                        print("REMY_EVAL skipped \(name): no plan step mentions \(keyword)"); continue
                    }
                    var cooking = session
                    cooking.beginCooking(); cooking.selectStep(index)
                    let result = try await runner.run(ChefPrompt.board, prompt: ChefPrompt.make(session: cooking, frameCount: 1, span: 0),
                                                      images: [try Data(contentsOf: file)])
                    let valid = (try? ChefObservation.decode(result.text)) != nil
                    report("\(name) → step \(index + 1) \(plan.steps[index].title)\(valid ? "" : " INVALID")", "board", result, nil)
                }
            } catch { report(name, "file", nil, error) }
        }
        write(rows, to: documents)
    }

    private static func write(_ rows: [[String: Any]], to documents: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: documents.appendingPathComponent("eval-results.json"), options: .atomic)
        }
        print("REMY_EVAL_DONE \(rows.count) results")
    }
}
