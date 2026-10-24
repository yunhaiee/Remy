import SwiftUI
import UIKit
import Network
import RemyCore
import Speech

@MainActor final class AppModel: ObservableObject {
    @Published var cooking = AppModel.restoreSession() { didSet { saveSession(); camera.setIngredientFocus(cooking.phase == .ingredients); syncCookerSafety() } }
    @Published var dishRequest = ""
    /// The plan as Gemma writes it; cleared once the finished plan is validated.
    @Published var planPreview: PlanPreview?
    /// Hands-free: the microphone stays on and every request is spoken. On by default.
    @Published var handsFree = true { didSet { Task { await handsFree ? startListening() : stopListening() } } }
    /// The last thing the microphone heard, shown so the cook can see what Gemma understood.
    @Published var lastHeard = ""
    /// Speculative decoding for the chef's chat turns (LiteRT-LM multi-token prediction). Off by default.
    /// For timing tests only (Settings), off at every launch. On the iPhone GPU one speculative call breaks every
    /// later schema or image call until the engine is recreated (LiteRT-LM 0.18.1), so turning it off after it was
    /// used reloads Gemma.
    @Published var speculativeChat = false {
        didSet {
            Task { await runner.setSpeculativeChat(speculativeChat) }
            if !speculativeChat && speculativeUsed { Task { await reloadModel() } }
        }
    }
    private var speculativeUsed = false
    /// Recipes of at most 5 steps, for a two-minute demo. Stored across launches; on by default.
    @Published var shortRecipes = UserDefaults.standard.object(forKey: "shortRecipes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shortRecipes, forKey: "shortRecipes") }
    }
    /// The fixed pasta-salad preset (five ingredients, three app-written steps, no Gemma plan call) for the exact
    /// "make pasta salad" request. Off, every dish is planned by Gemma, so the judges see Gemma write the recipe. Off by default.
    @Published var demoPreset = UserDefaults.standard.object(forKey: "demoPreset") as? Bool ?? false {
        didSet { UserDefaults.standard.set(demoPreset, forKey: "demoPreset") }
    }
    /// LiteRT schema-constrained decoding for JSON tasks. Off by default after a native abort seen on iPhone; on, the
    /// schema is enforced token by token. Open question for the team.
    @Published var constrainedDecoding = UserDefaults.standard.object(forKey: "constrainedDecoding") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(constrainedDecoding, forKey: "constrainedDecoding")
            Task { await runner.setConstrainedDecoding(constrainedDecoding); await ingredientRunner.setConstrainedDecoding(constrainedDecoding) }
        }
    }
    /// Items Gemma located in the camera picture, drawn on the video for a few seconds.
    @Published var boxes: [ItemBox] = []
    @Published var showObjectBoxes = UserDefaults.standard.object(forKey: "showObjectBoxes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showObjectBoxes, forKey: "showObjectBoxes") }
    }
    @Published var safetyBoxesEnabled = UserDefaults.standard.object(forKey: "safetyBoxesEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(safetyBoxesEnabled, forKey: "safetyBoxesEnabled")
            syncCookerSafety(); nextHazardScan = 0
            if safetyBoxesEnabled && hotWatchEnabled { Task { await scanForHazards() } }
        }
    }
    /// YOLOX-M on Core ML instead of EfficientDet-Lite0 on LiteRT, when the compiled model is bundled. Off by default,
    /// so the hand tracker, the detector and Gemma are three LiteRT models running at once.
    @Published var coreMLDetector = UserDefaults.standard.object(forKey: "coreMLDetector") as? Bool ?? false {
        didSet { UserDefaults.standard.set(coreMLDetector, forKey: "coreMLDetector"); camera.objects.setCoreML(coreMLDetector) }
    }
    var coreMLDetectorAvailable: Bool { Bundle.main.url(forResource: "yolox_m", withExtension: "mlmodelc") != nil }
    /// The detector that produced the latest boxes, for Evidence.
    var detectorName: String {
        objectSample?.model ?? (coreMLDetector && coreMLDetectorAvailable ? FastObjectDetector.coreMLName : FastObjectDetector.liteRTName)
    }
    /// Gemma calls, tool calls, vision checks, boxes and audio this session, for Evidence.
    @Published var tally = GemmaTally.shared.snapshot
    /// Visibility changes never change hazard detection or its always-visible overlay.
    var visibleObjectBoxes: [ItemBox] {
        guard showObjectBoxes else { return [] }
        let fast = liveObjects.filter { live in
            !boxes.contains { $0.label.lowercased() == live.label.lowercased() }
            && (cooking.phase != .ingredients || FastObjectPresentation.isSpecificIdentityReliable(live.label))
        }.map(FastObjectPresentation.displayBox)
        return boxes + fast
    }
    @Published private var objectSample: ObjectDetectionSample?
    /// Fresh detector boxes only. Never retain a box across a source/orientation change.
    var liveObjects: [ItemBox] {
        guard videoEnabled, let found = objectSample, let frame,
              ProcessInfo.processInfo.systemUptime - found.time < 0.5,
              abs(found.aspect - frame.image.size.width / frame.image.size.height) < 0.02 else { return [] }
        return found.boxes
    }
    var detectorMS: Double? { objectSample?.elapsedMS }

    /// Hot things on the counter (pot, pan). A hand reaching one is warned at once by the fast loop, no Gemma call.
    @Published var hazards: [HazardZone] = []
    /// Gemma's work, live, for the activity drawer.
    let activity = AgentActivity()
    /// The brief ingredient-selection stage; instruction preparation keeps the ingredient UI live.
    @Published var planning = false
    @Published var instructionsPreparing = false
    @Published var instructionsError: String?
    private var runningIngredientRegression = false
    @Published private(set) var ingredientChecking = false
    private struct IngredientLookRequest {
        let expectedID: String?
        let announcement: IngredientAnnouncement
        let source: UUID
        let session: UUID
        let requestedAt = ProcessInfo.processInfo.systemUptime
    }
    private var pendingIngredientLook: IngredientLookRequest?
    private var ingredientLookTask: Task<String?, Never>?
    private var recipePreparationTask: Task<Void, Never>?
    private var startWhenRecipeReady = false
    private var readyPromptSession: UUID?
    private var ingredientAnnouncementUntil = 0.0

    private let ingredientRunner = GemmaRunner()
    @Published private(set) var ingredientModelReady = false
    private var ingredientModelLoading = false
    private var wakeGate = ChefWakeGate()
    private var partialWakeID: UUID?
    private struct IngredientPreview {
        let source: UUID
        let session: UUID
        let epoch: UUID
        let started: Double
        let independent: Bool
        let result: Task<ChefBrain.PresentedIngredientResult?, Never>
    }
    private var ingredientPreview: IngredientPreview?
    private var previewInFlight = false
    /// Capture-to-alarm time of the last reflex warning, measured on this phone.
    @Published var lastReflexMS: Double?
    /// The banner over the video while `alertUntil` is in the future.
    @Published var alertTitle = ""
    @Published var alertSubtitle = ""
    @Published var alertSymbol = "hand.raised.fill"
    private var hazardWatch = HazardWatch()
    private var hazardGeometryEpoch = UUID()
    private var cookerScanRunning = false
    private var latestCookerTrack: (time: Double, zones: [HazardZone])?
    private var cookerCandidate: (zone: HazardZone, session: UUID, geometry: UUID)?
    private func syncCookerSafety() {
        if !safetyBoxesEnabled || cooking.cookerPowerOn == false {
            hazards = []; cookerCandidate = nil; latestCookerTrack = nil
            hazardGeometryEpoch = UUID(); camera.clearHazardTargets(); hazardWatch = HazardWatch()
            return
        }
        if cooking.phase != .cooking || cooking.isComplete { hazards = []; camera.clearHazardTargets(); latestCookerTrack = nil }
        guard cooking.usesCookerSafetySequence else { cookerCandidate = nil; return }
        if !cooking.cookerSafetyArmed {
            hazards = []; hazardWatch = HazardWatch()
        } else if usingGoPro, let tracked = latestCookerTrack,
                  ProcessInfo.processInfo.systemUptime - tracked.time < 0.3 {
            hazards = tracked.zones
        } else if hazards.isEmpty, let candidate = cookerCandidate,
                  candidate.session == cooking.id, candidate.geometry == hazardGeometryEpoch, !usingGoPro {
            hazards = [candidate.zone]
        }
    }
    /// Locate during step 1 without displaying a hot label or arming the warning. If the picture
    /// stays unchanged, the real box is ready as soon as the cook confirms the cooker is on.
    private func prepareCookerZone() async {
        guard safetyBoxesEnabled, cooking.cookerPowerOn != false, cooking.usesCookerSafetySequence, cooking.phase == .cooking, !cooking.isComplete,
              isLoaded, !cookerScanRunning else { return }
        cookerScanRunning = true; defer { cookerScanRunning = false }
        let session = cooking.id, geometry = hazardGeometryEpoch, source = sourceRequestID
        guard let picture = await freshSnapshot() else { return }
        let found = await locate(CookerSafetyTargets.queries, in: picture)
        guard safetyBoxesEnabled, cooking.cookerPowerOn != false, cooking.usesCookerSafetySequence, !cooking.isComplete, cooking.id == session,
              hazardGeometryEpoch == geometry, sourceRequestID == source,
              let zone = CookerSafetyTargets.zones(from: found).first else { return }
        cookerCandidate = (zone, session, geometry)
        camera.setHazardTargets([zone], snapshot: picture, id: geometry)
        syncCookerSafety()
    }
    private var hotWatchEnabled: Bool {
        safetyBoxesEnabled && cooking.phase == .cooking && !cooking.isComplete &&
            (!cooking.usesCookerSafetySequence || cooking.cookerSafetyArmed)
    }
    /// The automatic watcher repeats nothing it said in the last 30 s.
    private var lastConcern = ("", 0.0)
    private var failedChecks = 0
    /// Hand gestures (MediaPipe): thumbs up next, thumbs down back, open palm quiet, pointing up repeat.
    @Published var gesturesEnabled = UserDefaults.standard.object(forKey: "gestures") as? Bool ?? true {
        didSet { UserDefaults.standard.set(gesturesEnabled, forKey: "gestures") }
    }
    private var heldGesture = ("", 0.0)
    private var gestureQuietUntil = 0.0
    /// Pots and pans are looked for once per recipe after the first ingredient check.
    /// The hazard scan retries while nothing hot has been found (and after the camera moves).
    private var nextHazardScan = 0.0
    /// Gemma is turning the last utterance into text.
    @Published var understanding = false
    @Published var frame: CameraSample?
    @Published var videoEnabled = false
    @Published var chefLine = "Tell me what we're making."
    @Published var status = "Open Settings to load Gemma."
    @Published var isLoaded = false
    @Published var isBusy = false
    @Published var isLoading = false
    @Published var automaticChecks = false
    @Published var markSaltLocation = false
    @Published var voiceEnabled = true { didSet { audio.enabled = voiceEnabled } }
    @Published var gripHints = false
    @Published var useGPU = true
    @Published var lastInferenceMS: Double?
    @Published var rawResponse = ""
    @Published var smokePassed = false
    @Published var visionCompleted = false
    @Published var alertUntil: TimeInterval = 0
    @Published var networkAvailable = false
    @Published var receiptURL: URL?
    @Published var error: String? {
        didSet {
            guard let error, error != oldValue else { return }
            // Keep one bounded local error receipt, without prompts, replies, audio or other sensor content.
            let detail = String(error.prefix(1800))
            let report: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
                "error": detail, "backend": backend, "busy": isBusy, "loaded": isLoaded,
                "applicationState": UIApplication.shared.applicationState.rawValue]
            if var directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true).appendingPathComponent("RuntimeDiagnostics", isDirectory: true) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                         attributes: [.protectionKey: FileProtectionType.complete])
                var flags = URLResourceValues(); flags.isExcludedFromBackup = true
                try? directory.setResourceValues(flags)
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("latest-error.json"), options: [.atomic, .completeFileProtection])
                }
            }
        }
    }
    var userFacingError: String? {
        guard let error else { return nil }
        guard error.hasPrefix("Invalid response from native layer:") else { return error }
        if error.contains("vision_litert_compiled_model_executor") {
            return "The image check couldn’t finish. Keep the camera open and try again. Your session is saved."
        }
        return "The local AI couldn’t complete that request. Please try again. Your session is saved."
    }
    @Published var backend = "Not loaded"
    @Published var loadMS: Double?
    @Published var alertCount = 0
    @Published var usingGoPro = false
    let camera = CameraService()
    let goPro = GoProSource()
    let goProBluetooth = GoProBluetooth()
    let models = ModelStore()
    let audio = AudioCoach()
    let voice = VoiceInput()
    let listener = HandsFreeListener()
    private var latestUtterance = UUID()
    private var listenerStartID: UUID?
    /// When the cook last finished a sentence; the automatic watcher waits a few seconds after it.
    private var lastUtterance = 0.0
    private let runner = GemmaRunner()
    /// LiteRT-LM's measured speed of the last Gemma call, for the Evidence screen.
    func gemmaSpeed() async -> String? { await runner.lastSpeed }
    private let network = NWPathMonitor()
    private var samples: [CameraSnapshot] = []
    private var toldHowToStart = false
    /// The plan has been announced (auto ingredient checks wait for it).
    private var toldPlan = false
    private var boxesShown = UUID()
    /// The last few spoken exchanges, so the chef can follow up ("How about lemon fish?" → "Sure, let's do it").
    private var agentHistory: [ChefAgent.Turn] = []
    private var trackers: [String: ReachTracker] = [:]
    private var nextCheck = 0.0
    private var flatFrames = 0
    private var lastGripHint = 0.0
    private var sourceRequestID = UUID()
    private var appIsBackgrounded = false
    private var semanticEpoch = UUID()
    private var inferenceSceneRevision = 0
    private var resumeVideoAfterBackground = false
    private var resumeGoProAfterBackground = false
    private var resumeAutomaticChecksAfterBackground = false
    private var sceneTransitions: [String] = []

    func sceneChanged(_ phase: ScenePhase) {
        sceneTransitions.append("\(Date().timeIntervalSince1970):\(String(describing: phase))")
        if sceneTransitions.count > 20 { sceneTransitions.removeFirst() }
        if phase == .background {
            appIsBackgrounded = true
            wakeGate = ChefWakeGate(); ingredientPreview = nil
            semanticEpoch = UUID()
            latestUtterance = UUID()
            inferenceSceneRevision += 1
            let revision = inferenceSceneRevision
            Task {
                await runner.setSuspended(true, revision: revision)
                await ingredientRunner.setSuspended(true, revision: revision)
            }
            // Several inactive/background events can arrive before one active event.
            // Preserve the first video intent after pause() turns videoEnabled off.
            if videoEnabled {
                resumeVideoAfterBackground = true
                resumeGoProAfterBackground = usingGoPro
                resumeAutomaticChecksAfterBackground = automaticChecks
            }
            pause()
            Task { await stopListening() }
        } else if phase == .active {
            appIsBackgrounded = false
            inferenceSceneRevision += 1
            let revision = inferenceSceneRevision
            Task {
                await runner.setSuspended(false, revision: revision)
                await ingredientRunner.setSuspended(false, revision: revision)
            }
            if resumeVideoAfterBackground {
                resumeVideoAfterBackground = false
                if resumeGoProAfterBackground {
                    videoEnabled = true
                    let request = UUID(); sourceRequestID = request
                    Task {
                        // pause() and video-off invalidate this request. A temporary inactive
                        // permission sheet must not discard the pending GoPro resume.
                        guard sourceRequestID == request, videoEnabled else { return }
                        await startGoPro()
                    }
                } else { startPhoneCamera() }
                automaticChecks = resumeAutomaticChecksAfterBackground
            }
            if handsFree { Task { await startListening() } }
            if isLoaded && !ingredientModelReady { Task { await self.prepareIngredientModel() } }
            if cooking.instructionsPending && !runningIngredientRegression { scheduleRecipePreparation() }
        }
    }


    init() {
        camera.setIngredientFocus(cooking.phase == .ingredients)
        switch cooking.phase {
        case .ingredients: chefLine = "Welcome back. Let's finish checking your ingredients."; toldPlan = true
        case .cooking: chefLine = "Welcome back. We were on \(cooking.step?.title ?? "your recipe")."
        case .needsDish: break
        }
        voice.onRecordingEnded = { [weak self] succeeded in
            guard let self else { return }
            if succeeded { Task { await self.finishListening() } }
            else {
                _ = self.voice.stop()
                self.error = "The microphone stopped unexpectedly. Tap it to try again."
            }
        }
        camera.objects.setCoreML(coreMLDetector)
        camera.objects.onResult = { [weak self] sample in self?.objectSample = sample }
        GemmaTally.shared.onChange = { [weak self] counts in self?.tally = counts }
        camera.onSnapshot = { [weak self] snapshot in
            guard let self, self.videoEnabled else { return }
            self.samples.append(snapshot)
            if self.samples.count > 5 { self.samples.removeFirst() }
        }
        audio.onSpeaking = { [weak self] speaking in self?.listener.setMuted(speaking) }
        audio.onSay = { [weak self] line in self?.activity.log(.says, line) }
        listener.onUtterance = { [weak self] wav, words in Task { await self?.handleUtterance(wav, words: words) } }
        camera.onFrame = { [weak self] sample in self?.receive(sample) }
        goPro.onFrame = { [camera] pixel in camera.ingestExternal(pixel) }
        camera.onMovement = { [weak self] in
            guard let self else { return }
            self.boxes = []; self.hazards = []; self.nextHazardScan = 0; self.hazardGeometryEpoch = UUID(); self.cookerCandidate = nil; self.latestCookerTrack = nil; self.camera.clearHazardTargets(); self.hazardWatch.reset()
            guard self.cooking.zone != nil else { return }
            self.cooking.invalidateZone(); self.trackers = [:]
            guard self.cooking.phase == .cooking else { return }
            self.chefLine = "The camera moved. Mark the \(self.cooking.step?.guardItem ?? "item")'s location again."
        }
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkAvailable = path.status == .satisfied }
        }
        network.start(queue: DispatchQueue(label: "remy.network-status"))
    }

    /// A fresh engine (after speculative decoding), then the same warm-up and microphone start as at launch.
    func reloadModel() async {
        for _ in 0..<40 where isBusy { try? await Task.sleep(for: .milliseconds(250)) }
        await stopListening()
        isLoaded = false; speculativeUsed = false
        await loadModel()
    }

    func loadModel() async {
        guard !isLoading, !isBusy, !isLoaded, let url = models.modelURL else { return }
        isLoading = true; error = nil; status = "Loading Gemma on this iPhone…"
        do {
            loadMS = try await runner.load(path: url.path, useGPU: useGPU) { [weak self] value in
                Task { @MainActor in self?.backend = value }
            }
            backend = await runner.backend
            isLoaded = true; isLoading = false
            activity.log(.system, "Gemma 4 E2B · LiteRT-LM 0.18.1", detail: String(format: "%@ · loaded in %.1f s", backend, (loadMS ?? 0) / 1000))
            await runner.setSpeculativeChat(speculativeChat)
            await runner.setConstrainedDecoding(constrainedDecoding)
            await warmUp()
            if handsFree { await startListening() }
            if !runningIngredientRegression { Task { await self.prepareIngredientModel() } }
            if cooking.instructionsPending && !runningIngredientRegression { scheduleRecipePreparation() }
            if !runningIngredientRegression { offerCookingIfReady() }
        } catch { self.error = error.localizedDescription; status = "Could not load Gemma. Turn off GPU in Settings and try again." }
        isLoading = false
    }

    /// One tiny real call right after loading, so first-use setup (image encoder, constrained decoding, GPU
    /// kernels) happens now instead of inside the first plan or board check. A failure here never blocks cooking.
    private func warmUp() async {
        isBusy = true; defer { isBusy = false }
        status = "Warming up Gemma…"
        let size = CGSize(width: 64, height: 64)
        let image = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.7) { context in
            UIColor.gray.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
        let start = ProcessInfo.processInfo.systemUptime
        _ = try? await runner.run(ChefPrompt.glance, prompt: "Warm-up. Step is done when: the board is visible.", images: [image])
        status = String(format: "Gemma ready on this iPhone (warm-up %.1f s).", ProcessInfo.processInfo.systemUptime - start)
        print("REMY_WARMUP \(status)")
    }

    func smokeTest(withCamera: Bool) async {
        guard isLoaded, !isBusy else { return }
        isBusy = true; error = nil; defer { isBusy = false }
        do {
            let images: [Data]
            let prompt: String
            let marker = "REMY_" + UUID().uuidString.prefix(8)
            if withCamera {
                guard let frame = samples.last, ProcessInfo.processInfo.systemUptime - frame.time < 2 else { throw RunnerError.missingImage }
                images = [frame.jpeg]
                prompt = "Describe exactly what is visible in this image in one short sentence. Do not guess hidden objects."
            } else {
                images = []
                prompt = "Repeat exactly this marker and nothing else: \(marker)"
            }
            status = withCamera ? "Gemma is reading the camera image…" : "Running a real local inference…"
            let result = try await runner.run(prompt: prompt, images: images)
            rawResponse = result.text; lastInferenceMS = result.elapsedMS
            if withCamera { visionCompleted = true }
            else { smokePassed = result.text.trimmingCharacters(in: .whitespacesAndNewlines) == marker }
            status = withCamera ? "Image inference completed. Check the description below." : smokePassed ? "Local text test passed." : "Gemma replied; marker test did not match."
            saveReceipt(kind: withCamera ? "camera-image" : "text-marker", result: result,
                        passed: withCamera ? nil : smokePassed, expected: withCamera ? nil : String(marker))
        } catch { self.error = error.localizedDescription; status = "Test failed" }
    }

    /// Device regression for the two crash stacks. Uses a labelled synthetic image and real local inference;
    /// it never changes the cook's session or exports microphone, camera or other sensor content.
    func stabilitySmoke(withCamera: Bool = false) async {
        if ProcessInfo.processInfo.arguments.contains("--force-cpu-smoke") { useGPU = false }
        var checks: [String: Bool] = [:]
        var footprints: [Double] = []
        var timings: [String: Double] = [:]
        var diagnostics: [String: String] = [:]
        var microphoneHealth: [String: [String: Any]] = [:]
        let regressionRunID = UUID().uuidString
        let previousHandsFree = handsFree, previousVoice = voiceEnabled
        let previousUtterance = listener.onUtterance
        listener.onUtterance = nil
        handsFree = false; voiceEnabled = false
        await stopListening()
        defer { listener.onUtterance = previousUtterance; handsFree = previousHandsFree; voiceEnabled = previousVoice }
        // Permission sheets and lock transitions make camera/microphone tests invalid.
        for _ in 0..<120 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(500))
        }
        checks["foregroundAtStart"] = UIApplication.shared.applicationState == .active
        await loadModel()
        checks["modelLoaded"] = isLoaded
        guard isLoaded else { return }
        if ProcessInfo.processInfo.arguments.contains("--exercise-cpu-recovery") {
            do { try await runner.rebuildCPUForDeviceRegression(); checks["cpuRebuiltAfterGPUWarmup"] = true }
            catch { checks["cpuRebuiltAfterGPUWarmup"] = false; diagnostics["rebuildError"] = error.localizedDescription }
        }
        isBusy = true
        defer { isBusy = false }
        func record() {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let report: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()),
                "processID": ProcessInfo.processInfo.processIdentifier, "runID": regressionRunID,
                "checks": checks, "backend": backend, "applicationState": UIApplication.shared.applicationState.rawValue,
                "sceneTransitions": sceneTransitions,
                "injectedRepeatedBackground": ProcessInfo.processInfo.arguments.contains("--exercise-repeated-background"),
                "microphoneScope": "Restart cycles and fresh audio at the end of the camera run; not continuous two-minute recording.",
                "videoEnabled": videoEnabled, "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "speechAuthorization": SFSpeechRecognizer.authorizationStatus().rawValue,
                "physicalFootprintMB": footprints, "latencyMS": timings, "microphoneHealth": microphoneHealth,
                "syntheticInputDiagnostics": diagnostics, "input": withCamera ? "real camera and microphone; no sensor content exported" : "synthetic gray image; real on-device Gemma and microphone lifecycle",
                "passed": checks["completed"] == true && checks.values.allSatisfy { $0 }, "completed": checks["completed"] == true]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("stability-smoke.json"), options: [.atomic, .completeFileProtection])
            }
        }
        record()
        var image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).jpegData(withCompressionQuality: 0.7) { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        let cameraStart = ProcessInfo.processInfo.systemUptime
        if withCamera {
            startPhoneCamera()
            if let snapshot = await freshSnapshot() { image = snapshot.jpeg; checks["cameraStarted"] = true }
            else { checks["cameraStarted"] = false; record(); return }
            if ProcessInfo.processInfo.arguments.contains("--exercise-repeated-background") {
                // Inject the duplicated scene events seen on the device, then require fresh capture.
                // This validates app intent handling, not an actual iOS background transition.
                let previousAutomaticChecks = automaticChecks
                automaticChecks = true
                sceneChanged(.background)
                sceneChanged(.background)
                checks["backgroundSnapshotDoesNotRestartCamera"] = await freshSnapshot() == nil && !videoEnabled
                sceneChanged(.active)
                let resumedIntent = videoEnabled
                for _ in 0..<20 where frame.map({ ProcessInfo.processInfo.systemUptime - $0.time < 1 }) != true {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                checks["cameraResumedAfterInjectedRepeatedBackground"] = resumedIntent && frame.map { ProcessInfo.processInfo.systemUptime - $0.time < 1 } == true
                checks["automaticWatchingIntentResumed"] = automaticChecks
                sceneChanged(.active)
                checks["duplicateActiveKeepsCamera"] = videoEnabled && frame != nil
                toggleVideo()
                sceneChanged(.background)
                sceneChanged(.background)
                sceneChanged(.active)
                checks["cameraOffIntentPreserved"] = !videoEnabled
                checks["disabledSnapshotDoesNotRestartCamera"] = await freshSnapshot() == nil && !videoEnabled
                automaticChecks = previousAutomaticChecks
                startPhoneCamera()
                for _ in 0..<20 where frame == nil { try? await Task.sleep(for: .milliseconds(250)) }
            }
            if ProcessInfo.processInfo.arguments.contains("--exercise-capture-recovery") {
                camera.interruptForDeviceRegression()
                try? await Task.sleep(for: .seconds(5))
                checks["cameraRecoveredAfterInjectedStop"] = frame.map { ProcessInfo.processInfo.systemUptime - $0.time < 1 } ?? false
            }
        }
        for index in 1...5 {
            do {
                let (_, result) = try await ChefBrain.hazards(frame: image, runner: runner)
                timings["hazard\(index)"] = result.elapsedMS
                if !withCamera { diagnostics["hazard\(index)"] = String(result.text.prefix(800)) }
                let object = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]
                checks["hazardJSON\(index)"] = object?["hot"] is [String]
            } catch {
                checks["hazardJSON\(index)"] = false
                if !withCamera { diagnostics["hazardError\(index)"] = error.localizedDescription }
            }
            footprints.append(Self.physicalFootprintMB())
            record()
        }
        if withCamera {
            for index in 1...2 {
                do {
                    _ = try await ChefBrain.locate(["pot"], frame: image, runner: runner)
                    checks["objectLocation\(index)Completed"] = true
                } catch { checks["objectLocation\(index)Completed"] = false }
                footprints.append(Self.physicalFootprintMB()); record()
            }
        }
        var validationSession = CookingSession()
        do {
            let (plan, result) = try await ChefBrain.plan(dish: "a simple guacamole", maxSteps: 4, runner: runner)
            timings["recipePlan"] = result.elapsedMS
            validationSession.start(plan)
            checks["validatedRecipePlan"] = plan.problems.isEmpty
        } catch {
            checks["validatedRecipePlan"] = false
            diagnostics["planError"] = error.localizedDescription
            if !withCamera, let failure = error as? GemmaReplyError { diagnostics["planReply"] = String(failure.result.text.prefix(800)) }
        }
        do {
            let reply = try await ChefAgent.respond(to: "Hello Chef. Please say hello.", session: CookingSession(), history: [], runner: runner)
            checks["conversationReply"] = !reply.speech.isEmpty || !reply.actions.isEmpty
        } catch { checks["conversationReply"] = false; diagnostics["conversationError"] = error.localizedDescription }
        record()
        if withCamera {
            // The previous regression stopped after text recovery. Exercise real image requests
            // again on that engine: these are the ingredient/glance paths used during a cook.
            let visionRounds = ProcessInfo.processInfo.arguments.contains("--extended-vision-stress") ? 12 : 3
            for index in 1...visionRounds {
                do {
                    let latest = await freshSnapshot()?.jpeg ?? image
                    _ = try await ChefBrain.checkIngredients(session: validationSession, frames: [latest], runner: runner)
                    checks["ingredientCheckAfterText\(index)"] = true
                    let (_, result) = try await ChefBrain.review(prompt: "The board should be visible. Describe only what is visible.", frames: [latest], guarded: false, runner: runner)
                    timings["glance\(index)"] = result.elapsedMS
                    checks["glanceAfterText\(index)"] = true
                } catch {
                    checks["visionRoundTrip\(index)"] = false
                    diagnostics["visionRoundTripError\(index)"] = error.localizedDescription
                    if let failure = error as? GemmaReplyError,
                       let reply = try? JSONSerialization.jsonObject(with: Data(failure.result.text.utf8)) as? [String: Any] {
                        diagnostics["invalidTask\(index)"] = failure.task
                        if failure.task == "ingredient check" {
                            let known = Set(validationSession.plan?.ingredients.map(\.id) ?? [])
                            let found = (reply["seen"] as? [String] ?? []) + (reply["unsure"] as? [String] ?? [])
                            diagnostics["invalidIngredientIDs\(index)"] = found.filter { !known.contains($0) }.prefix(6).joined(separator: ",")
                        }
                        diagnostics["invalidConcern\(index)"] = String(describing: reply["concern"] ?? "missing")
                        diagnostics["invalidLineLength\(index)"] = String((reply["line"] as? String)?.count ?? -1)
                        diagnostics["invalidKeys\(index)"] = reply.keys.sorted().joined(separator: ",")
                    }
                }
                footprints.append(Self.physicalFootprintMB()); record()
            }
            do {
                let reply = try await ChefAgent.respond(to: "Hello Chef. Please say hello.", session: CookingSession(), history: [], runner: runner)
                checks["conversationAfterVision"] = !reply.speech.isEmpty || !reply.actions.isEmpty
            } catch { checks["conversationAfterVision"] = false; diagnostics["conversationAfterVisionError"] = error.localizedDescription }
            record()
        }
        let microphoneCycles = ProcessInfo.processInfo.arguments.contains("--extended-vision-stress") ? 12 : 4
        for index in 1...microphoneCycles {
            handsFree = true
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<3 { group.addTask { await self.startListening() } }
            }
            for _ in 0..<80 where !listener.isOn { try? await Task.sleep(for: .milliseconds(250)) }
            checks["micStart\(index)"] = listener.isOn
            for _ in 0..<40 where !listener.hasFreshAudio { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(400))
            checks["micBuffers\(index)"] = listener.hasFreshAudio
            microphoneHealth["cycle\(index)"] = listener.healthSnapshot()
            handsFree = false
            await stopListening()
            checks["micStop\(index)"] = !listener.isOn
            record()
        }
        if withCamera {
            handsFree = true
            await startListening()
            for _ in 0..<80 where !listener.isOn { try? await Task.sleep(for: .milliseconds(250)) }
            while ProcessInfo.processInfo.systemUptime - cameraStart < 120 {
                try? await Task.sleep(for: .seconds(2))
                record()
            }
            checks["cameraLiveAfterTwoMinutes"] = frame.map { ProcessInfo.processInfo.systemUptime - $0.time < 2 } ?? false
            checks["microphoneLiveAfterTwoMinutes"] = listener.isOn
            for _ in 0..<40 where !listener.hasFreshAudio { try? await Task.sleep(for: .milliseconds(100)) }
            checks["microphoneBuffersAfterTwoMinutes"] = listener.hasFreshAudio
            microphoneHealth["final"] = listener.healthSnapshot()
            checks["objectDetectorLiveAfterTwoMinutes"] = objectSample.map { ProcessInfo.processInfo.systemUptime - $0.time < 1 } ?? false
            let detectorReceipt = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RuntimeDiagnostics/detector-performance.json")
            let expectedDetector = coreMLDetector && coreMLDetectorAvailable ? "YOLOX-M float16" : "EfficientDet-Lite0 int8"
            if let data = try? Data(contentsOf: detectorReceipt),
               let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                checks["preparedObjectDetectorLoaded"] = receipt["model"] as? String == expectedDetector
                timings["objectDetectorMedian"] = receipt["medianMS"] as? Double
                timings["objectDetectorP95"] = receipt["p95MS"] as? Double
            } else { checks["preparedObjectDetectorLoaded"] = false }
            footprints.append(Self.physicalFootprintMB())
        }
        backend = await runner.backend
        checks["completed"] = true; record()
        status = checks.values.allSatisfy { $0 } ? "Device stability regression passed." : "Device stability check found an issue; see its local receipt."
        print("REMY_STABILITY \(status)")
    }

    private static func physicalFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_000_000 : 0
    }

    // MARK: Plan → ingredients → cook

    /// Explicit device regression: real local Gemma, synthetic pantry taps, no sensor content exported.
    /// Restores the cook's saved recipe after the check instead of leaving a test recipe behind.
    func ingredientFirstSmoke() async {
        let savedCooking = cooking, savedDish = dishRequest, savedLine = chefLine
        let savedHandsFree = handsFree, savedVoice = voiceEnabled, savedAutomatic = automaticChecks
        let savedListener = listener.onUtterance
        runningIngredientRegression = true
        handsFree = false; voiceEnabled = false; automaticChecks = false; listener.onUtterance = nil
        await stopListening()
        var checks: [String: Bool] = [:], timings: [String: Double] = [:]
        var diagnostics: [String: String] = [:]
        let runID = UUID().uuidString
        func record() {
            var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RuntimeDiagnostics", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try? directory.setResourceValues(flags)
            let report: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()),
                "runID": runID, "processID": ProcessInfo.processInfo.processIdentifier,
                "checks": checks, "latencyMS": timings, "diagnostics": diagnostics,
                "backend": backend, "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "applicationState": UIApplication.shared.applicationState.rawValue,
                "sceneTransitions": sceneTransitions, "physicalFootprintMB": Self.physicalFootprintMB(),
                "input": "real on-device Gemma; app preset and synthetic pantry taps; no sensor content exported",
                "completed": checks["completed"] == true,
                "passed": checks["completed"] == true && checks.values.allSatisfy { $0 }]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("ingredient-first-smoke.json"), options: [.atomic, .completeFileProtection])
            }
        }
        defer {
            cooking = savedCooking; dishRequest = savedDish; chefLine = savedLine
            instructionsError = nil; runningIngredientRegression = false
            listener.onUtterance = savedListener; handsFree = savedHandsFree; voiceEnabled = savedVoice
            automaticChecks = savedAutomatic
            record()
        }
        // A freshly installed app can enter its task before iOS finishes bringing it forward.
        // Wait for both UIKit and the scene callback; an inactive launch is not model failure.
        for _ in 0..<120 where UIApplication.shared.applicationState != .active || appIsBackgrounded {
            try? await Task.sleep(for: .milliseconds(500))
        }
        checks["foregroundAtStart"] = UIApplication.shared.applicationState == .active && !appIsBackgrounded
        guard checks["foregroundAtStart"] == true else { return }
        await loadModel()
        checks["modelLoaded"] = isLoaded
        record()
        guard isLoaded, !isBusy else { return }
        if ProcessInfo.processInfo.arguments.contains("--with-camera") {
            startPhoneCamera()
            checks["cameraStarted"] = await freshSnapshot() != nil
        }
        let epoch = semanticEpoch
        cooking = CookingSession(); dishRequest = "pasta salad"
        let start = ProcessInfo.processInfo.systemUptime
        let work = Task { await self.planDish() }
        for _ in 0..<200 where cooking.plan == nil { try? await Task.sleep(for: .milliseconds(10)) }
        timings["ingredientsVisible"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let exact = ["pasta", "lemon", "onion", "cucumber", "tomato"]
        checks["exactFiveIngredientsInitially"] = cooking.plan?.ingredients.map(\.id) == exact
        checks["ingredientsBeforeInstructions"] = cooking.instructionsPending && cooking.plan?.steps.isEmpty == true
        checks["preparationDoesNotCoverIngredients"] = !planning
        checks["cookingBlockedBeforeInstructions"] = cooking.phase == .ingredients && !cooking.instructionsReady
        // The list intentionally renders one turn before instruction work starts. Exercise
        // edits during that work rather than racing the intentional presentation yield.
        for _ in 0..<100 where !instructionsPreparing && cooking.instructionsPending && !appIsBackgrounded {
            try? await Task.sleep(for: .milliseconds(10))
        }
        cooking.setPantry("cucumber", .seen)
        cooking.setPantry("onion", .missing)
        checks["ingredientControlsWhilePreparing"] = instructionsPreparing && cooking.pantry["cucumber"]?.status == .seen
        record()
        await work.value
        timings["instructionsReady"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        checks["instructionsReady"] = cooking.instructionsReady
        checks["exactSixIngredientsFinally"] = cooking.plan?.ingredients.map(\.id) == exact
        checks["pantrySelectionsPreserved"] = cooking.pantry["cucumber"]?.status == .seen && cooking.pantry["onion"]?.status == .missing
        checks["staysInIngredientReview"] = cooking.phase == .ingredients
        checks["foregroundNotInterrupted"] = epoch == semanticEpoch && UIApplication.shared.applicationState == .active
        if let instructionsError { diagnostics["instructionsError"] = instructionsError }
        if ProcessInfo.processInfo.arguments.contains("--with-camera") {
            checks["cameraStillLive"] = frame.map { ProcessInfo.processInfo.systemUptime - $0.time < 2 } ?? false
        }
        record()
        guard !runner.requiresRestart, !appIsBackgrounded else { return }
        isBusy = true
        do {
            let (draft, result) = try await ChefBrain.ingredientDraft(dish: "Tomato cucumber salad", runner: runner)
            checks["genericDishDraftValid"] = draft.problems.isEmpty
            timings["genericDishIngredients"] = result.elapsedMS
        } catch {
            checks["genericDishDraftValid"] = false
            diagnostics["genericDraftError"] = error.localizedDescription
        }
        isBusy = false
        checks["nativeRuntimeHealthy"] = !runner.requiresRestart
        checks["completed"] = true
        status = checks.values.allSatisfy { $0 } ? "Ingredient-first device check passed." : "Ingredient-first device check found an issue."
    }

    func planDish() async {
        let dish = dishRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appIsBackgrounded, isLoaded, !isBusy, !dish.isEmpty else { return }
        let epoch = semanticEpoch
        isBusy = true; planning = true; error = nil; instructionsError = nil; planPreview = nil
        let entry = activity.begin(.plan, "Ingredients for \(dish)")
        status = "Choosing your ingredients…"
        chefLine = "I'll get the ingredients ready first."
        var draft: IngredientDraft?
        do {
            if demoPreset, let preset = IngredientDraft.preset(for: dish) {
                draft = preset
                activity.finish(entry, detail: "Your saved five-ingredient pasta salad list")
            } else {
                let (generated, result) = try await ChefBrain.ingredientDraft(dish: dish, runner: runner)
                draft = generated
                activity.finish(entry, detail: "\(generated.ingredients.count) ingredients", ms: result.elapsedMS)
                rawResponse = result.text; lastInferenceMS = result.elapsedMS
                saveReceipt(kind: "ingredient-draft", result: result, passed: true, expected: nil)
            }
        } catch {
            activity.finish(entry, detail: error.localizedDescription, failed: true)
            if !appIsBackgrounded, semanticEpoch == epoch {
                keepFailedReply(error); self.error = error.localizedDescription
                status = "Could not prepare the ingredients. Try again."
            }
        }
        planning = false
        guard !appIsBackgrounded, semanticEpoch == epoch, let draft, cooking.startIngredients(draft) else {
            isBusy = false
            return
        }
        trackers = [:]; toldHowToStart = false; agentHistory = []; toldPlan = true
        if #available(iOS 26, *) { (listener.live as? AppleSpeech)?.hints = speechHints }
        startWhenRecipeReady = false
        chefLine = "\(draft.dish): \(Self.list(draft.ingredients.map(\.name))). Show me one at a time."
        status = "Show me an ingredient. Open Session to correct the checklist."
        ingredientAnnouncementUntil = ProcessInfo.processInfo.systemUptime + 1
        audio.say(chefLine, priority: true)
        isBusy = false
        if !runningIngredientRegression {
            if !videoEnabled {
                if usingGoPro { videoEnabled = true; Task { await self.startGoPro() } }
                else { startPhoneCamera() }
            }
            scheduleRecipePreparation()
        } else { await retryInstructions() }
    }

    /// Only model work is serialized. Ingredient taps and exact spoken confirmations remain live.
    func retryInstructions() async {
        guard !appIsBackgrounded, isLoaded, !isBusy, cooking.instructionsPending,
              let initial = cooking.plan else { return }
        let epoch = semanticEpoch, sessionID = cooking.id
        let initialDraft = IngredientDraft(dish: initial.dish, ingredients: initial.ingredients)
        if let preset = initialDraft.presetInstructions {
            if cooking.applyInstructions(preset, expectedSessionID: sessionID, expectedIngredients: initial.ingredients) {
                instructionsError = nil
                activity.log(.plan, "Pasta salad instructions ready", detail: "Validated app recipe preset · 3 steps; no model generation")
                if startWhenRecipeReady { beginCooking() }
            }
            return
        }
        instructionsPreparing = true; instructionsError = nil; isBusy = true
        let entry = activity.begin(.plan, "Preparing \(initial.dish) instructions")
        defer {
            isBusy = false; instructionsPreparing = false
            // A scene change invalidates semantic output, never the lifetime of pending native work.
            if !runningIngredientRegression, epoch != semanticEpoch, !appIsBackgrounded, cooking.id == sessionID,
               cooking.instructionsPending, !runner.requiresRestart {
                self.scheduleRecipePreparation()
            }
        }
        for _ in 0..<3 {
            guard !appIsBackgrounded, semanticEpoch == epoch, cooking.id == sessionID,
                  let current = cooking.plan else {
                activity.finish(entry, detail: "Preparation paused; ingredient choices kept")
                return
            }
            let draft = IngredientDraft(dish: current.dish, ingredients: current.ingredients)
            do {
                let (plan, result) = try await ChefBrain.instructions(draft: draft,
                    maxSteps: shortRecipes ? 5 : RecipePlan.maxSteps, runner: runner)
                guard !appIsBackgrounded, semanticEpoch == epoch, cooking.id == sessionID else {
                    activity.finish(entry, detail: "Discarded an interrupted preparation")
                    return
                }
                if cooking.applyInstructions(plan, expectedSessionID: sessionID, expectedIngredients: draft.ingredients) {
                    rawResponse = result.text; lastInferenceMS = result.elapsedMS
                    activity.finish(entry, detail: "\(plan.steps.count) steps ready; ingredient checks preserved", ms: result.elapsedMS)
                    // Background recipe completion must not interrupt ingredient guidance or speech.
                    if startWhenRecipeReady { beginCooking() }
                    saveReceipt(kind: "recipe-instructions", result: result, passed: true, expected: nil)
                    return
                }
                // Pantry checks do not invalidate the plan. Actual ingredient edits do.
                activity.update(entry, detail: "Ingredients changed; preparing steps for the new list")
            } catch {
                activity.finish(entry, detail: error.localizedDescription, failed: true)
                guard !appIsBackgrounded, semanticEpoch == epoch, cooking.id == sessionID else { return }
                instructionsError = error.localizedDescription
                status = "Keep showing your ingredients. Your checklist is saved."
                keepFailedReply(error)
                return
            }
        }
        instructionsError = "The ingredient list changed during preparation."
        activity.finish(entry, detail: "Waiting for the ingredient list to settle", failed: true)
    }

    enum IngredientAnnouncement { case full, newOnly, silent }

    func prepareIngredientModel() async {
        if ingredientModelLoading {
            for _ in 0..<600 where ingredientModelLoading { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        guard !ingredientModelReady, !appIsBackgrounded else { return }
        ingredientModelLoading = true
        defer { ingredientModelLoading = false }
        for _ in 0..<600 where models.isWorking { try? await Task.sleep(for: .milliseconds(100)) }
        guard !appIsBackgrounded, let path = models.modelURL else { return }
        do {
            _ = try await ingredientRunner.load(path: path.path, useGPU: true)
            await ingredientRunner.setConstrainedDecoding(constrainedDecoding)
            ingredientModelReady = true
            activity.log(.system, "Careful ingredient recognition ready", detail: "Gemma 4 E2B · Metal GPU · independent of recipe generation")
        } catch {
            activity.log(.system, "Ingredient model unavailable", detail: error.localizedDescription)
        }
    }

    /// Defer the longer recipe call until ingredients are collected (or cooking is explicitly
    /// requested), keeping the ingredient stage's inference budget for recognition.
    private func scheduleRecipePreparation() {
        guard recipePreparationTask == nil, cooking.instructionsPending, !runningIngredientRegression else { return }
        let session = cooking.id
        recipePreparationTask = Task {
            defer { recipePreparationTask = nil }
            while !Task.isCancelled, !appIsBackgrounded, cooking.id == session, cooking.instructionsPending {
                let ingredientsCollected = cooking.plan?.ingredients.allSatisfy { cooking.pantry[$0.id]?.status == .seen } == true
                if (ingredientsCollected || startWhenRecipeReady), !previewInFlight, !ingredientChecking,
                   !isBusy && (ingredientModelReady || (ingredientLookTask == nil && pendingIngredientLook == nil && !audio.isSpeaking && !listener.hearing)) {
                    let epoch = semanticEpoch
                    await retryInstructions()
                    if epoch != semanticEpoch, !appIsBackgrounded, cooking.id == session,
                       cooking.instructionsPending, !runner.requiresRestart { continue }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// A spoken item name is only a hint for feedback. Only the actual image can confirm presence.
    @discardableResult func checkIngredients(announce: IngredientAnnouncement = .full,
                                             expectedIngredientID: String? = nil) async -> String? {
        guard !appIsBackgrounded, isLoaded, !runner.requiresRestart, cooking.phase == .ingredients else { return nil }
        if !videoEnabled {
            if usingGoPro { videoEnabled = true; await startGoPro() }
            else { startPhoneCamera() }
        }
        if announce == .full { chefLine = "Thinking…"; audio.captureThinking() }
        let request = IngredientLookRequest(expectedID: expectedIngredientID, announcement: announce,
                                             source: sourceRequestID, session: cooking.id)
        // Explicit presentations win over timer-driven checks. Keep the newest request, not old frames.
        if pendingIngredientLook == nil || announce != .newOnly { pendingIngredientLook = request }
        if let work = ingredientLookTask { return await work.value }
        let work = Task { await self.runIngredientLookQueue() }
        ingredientLookTask = work
        return await work.value
    }

    private func runIngredientLookQueue() async -> String? {
        defer { ingredientLookTask = nil; ingredientChecking = false }
        var response: String?
        await prepareIngredientModel()
        while var request = pendingIngredientLook {
            response = nil
            pendingIngredientLook = nil
            // The independent recognition engine does not wait behind instruction generation.
            for _ in 0..<600 where audio.isSpeaking || ProcessInfo.processInfo.systemUptime < ingredientAnnouncementUntil || (!ingredientModelReady && isBusy) {
                guard !appIsBackgrounded, cooking.id == request.session, snapshotRequestIsCurrent(request.source) else { return response }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let newer = pendingIngredientLook { request = newer; pendingIngredientLook = nil }
            guard !appIsBackgrounded, cooking.id == request.session, cooking.phase == .ingredients,
                  snapshotRequestIsCurrent(request.source), let snapshot = await freshSnapshot(),
                  ingredientModelReady || !isBusy, let plan = cooking.plan else { continue }
            let epoch = semanticEpoch, revision = cooking.revision
            let alreadySeen = Set(cooking.pantry.filter { $0.value.status == .seen }.keys)
            ingredientChecking = true
            let independent = ingredientModelReady
            if !independent { isBusy = true }
            var usedPreview = false
            let checkEntry = activity.begin(.vision, "Looking at the presented ingredient")
            do {
                let result: ChefBrain.PresentedIngredientResult
                if let preview = ingredientPreview, preview.source == request.source,
                   preview.session == request.session, preview.epoch == epoch, preview.independent == independent,
                   ProcessInfo.processInfo.systemUptime - preview.started < 20 {
                    ingredientPreview = nil
                    if let prefetched = await preview.result.value { result = prefetched; usedPreview = true }
                    else {
                        result = try await ChefBrain.presentedIngredient(frame: snapshot.jpeg,
                            runner: independent ? ingredientRunner : runner)
                    }
                } else {
                    result = try await ChefBrain.presentedIngredient(frame: snapshot.jpeg,
                        runner: independent ? ingredientRunner : runner)
                }
                if !independent { isBusy = false }
                ingredientChecking = false
                guard !appIsBackgrounded, semanticEpoch == epoch, cooking.id == request.session,
                      cooking.phase == .ingredients,
                      snapshotRequestIsCurrent(request.source), cooking.plan?.ingredients == plan.ingredients else { continue }
                let ingredient = result.ingredient(in: plan.ingredients)
                let identity = result.identity
                var confirmed = false
                if let ingredient {
                    confirmed = cooking.applyIngredientCheck(.init(items: [.init(id: ingredient.id, status: .seen)], line: ""),
                        expectedSessionID: request.session, expectedRevision: revision)
                    if confirmed, let box = identity.box { show([ItemBox(label: ingredient.name, x: box.x, y: box.y, width: box.width, height: box.height)], for: 3) }
                }
                if ingredient != nil && !confirmed {
                    activity.finish(checkEntry, detail: "Pantry changed during recognition; keeping the cook's choice")
                    continue
                }
                let verifiedIdentity = result.verification.map { identity.isCorroborated(by: $0) } == true
                let newlySeen = ingredient.map { !alreadySeen.contains($0.id) } ?? false
                let allReady = plan.ingredients.allSatisfy { cooking.pantry[$0.id]?.status == .seen }
                if let ingredient, confirmed, newlySeen || request.announcement == .full {
                    response = "Got the \(ingredient.name)." + (allReady ? " That's all \(plan.ingredients.count) ingredients. Ready to cook?" : " Show me the next ingredient.")
                } else if request.announcement == .full {
                    if verifiedIdentity {
                        let missing = plan.ingredients.filter { cooking.pantry[$0.id]?.status != .seen }.prefix(3).map(\.name)
                        let article = "aeiou".contains(identity.name.lowercased().first ?? "x") ? "an" : "a"
                        response = "I see \(article) \(identity.name)." + (missing.isEmpty ? " That isn't on our ingredient list." : " Do you have \(Self.list(missing))?")
                    } else {
                        response = "I can't identify that clearly yet. Bring it closer and hold it steady."
                    }
                }
                activity.finish(checkEntry, detail: confirmed ? "Confirmed \(ingredient?.name ?? "ingredient") from image and close crop" : "No ingredient confirmed", ms: result.result.elapsedMS)
                saveReceipt(kind: "presented-ingredient", result: result.result, passed: confirmed, expected: nil)
                writeIngredientRecognitionHealth(name: verifiedIdentity ? identity.name : "unknown", confirmedID: confirmed ? ingredient?.id : nil,
                    expectedID: request.expectedID, elapsedMS: result.result.elapsedMS, independent: independent,
                    requestMS: (ProcessInfo.processInfo.systemUptime - request.requestedAt) * 1000, usedPreview: usedPreview)
                if request.announcement != .silent, let response, newlySeen || request.announcement == .full {
                    if allReady { readyPromptSession = cooking.id }
                    chefLine = response; audio.say(response, priority: true)
                }
                status = "Show one ingredient at a time. Open Session to correct the checklist."
            } catch {
                if !independent { isBusy = false }
                ingredientChecking = false
                activity.finish(checkEntry, detail: error.localizedDescription, failed: true)
                keepFailedReply(error)
                guard !appIsBackgrounded, semanticEpoch == epoch, cooking.id == request.session else { continue }
                writeIngredientRecognitionHealth(name: "unknown", confirmedID: nil, expectedID: request.expectedID,
                    elapsedMS: nil, independent: independent,
                    requestMS: (ProcessInfo.processInfo.systemUptime - request.requestedAt) * 1000, usedPreview: usedPreview)
                if runner.requiresRestart {
                    self.error = RunnerError.restartRequired.localizedDescription
                    status = "Remy paused safely. Reopen the app to restart the model."
                    pendingIngredientLook = nil
                    return response
                }
                if request.announcement == .full {
                    response = "I couldn't get a clear identification. Hold it steady and show me again."
                    chefLine = response!; audio.say(response!, priority: true)
                }
            }
        }
        return response
    }

    /// A bounded local receipt contains food identities and timing only; never images, audio or private inputs.
    private func writeIngredientRecognitionHealth(name: String, confirmedID: String?, expectedID: String?, elapsedMS: Double?, independent: Bool, requestMS: Double, usedPreview: Bool) {
        let report: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()),
            "processID": ProcessInfo.processInfo.processIdentifier,
            "requestToResultMS": requestMS, "reusedWakePreview": usedPreview,
            "recognizedName": name, "confirmedID": confirmedID as Any? ?? NSNull(),
            "requestedID": expectedID as Any? ?? NSNull(), "elapsedMS": elapsedMS as Any? ?? NSNull(),
            "model": independent ? "Gemma 4 E2B GPU verifier" : "Gemma 4 E2B GPU fallback",
            "physicalFootprintMB": Self.physicalFootprintMB(), "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "instructionsPreparing": instructionsPreparing, "ingredientCount": cooking.plan?.ingredients.count ?? 0,
            "seenIDs": cooking.pantry.filter { $0.value.status == .seen }.keys.sorted()]
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RuntimeDiagnostics")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("ingredient-recognition.json"), options: [.atomic, .completeFileProtection])
        }
    }

    private static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// Unknown → have it; have it ↔ missing. The cook's tap always wins over the camera.
    func cyclePantry(_ id: String) {
        cooking.setPantry(id, cooking.pantry[id]?.status == .seen ? .missing : .seen)
        if !cooking.ingredientsCollected { readyPromptSession = nil }
        offerCookingIfReady()
    }

    var readyToCook: Bool { cooking.phase == .ingredients && cooking.ingredientsCollected }

    private func offerCookingIfReady() {
        guard readyToCook, readyPromptSession != cooking.id, !startWhenRecipeReady else { return }
        readyPromptSession = cooking.id
        chefLine = "That's all \(cooking.plan?.ingredients.count ?? 0) ingredients. Ready to cook?"
        audio.say(chefLine, priority: true)
        status = "Say yes when you're ready."
    }

    func beginCooking() {
        guard cooking.instructionsReady else {
            startWhenRecipeReady = true
            chefLine = "Let's cook. One moment."
            audio.say(chefLine, priority: true)
            scheduleRecipePreparation()
            return
        }
        startWhenRecipeReady = false; readyPromptSession = nil; ingredientPreview = nil
        cooking.beginCooking(); trackers = [:]; samples = []
        if !videoEnabled {
            if usingGoPro { videoEnabled = true; Task { await self.startGoPro() } }
            else { startPhoneCamera() }
        }
        // Hands-free cooking watches the board on its own; it only speaks up when something needs attention.
        if handsFree { automaticChecks = true }
        announceStep()
    }

    /// `spoken: false` is the automatic watch: it only talks when there is a concern or the step looks done.
    func reviewBoard(spoken: Bool = true) async {
        let request = sourceRequestID
        guard snapshotRequestIsCurrent(request), isLoaded, !isBusy, !isLoading, cooking.phase == .cooking, cooking.step?.kind == .do else { return }
        isBusy = true; error = nil; defer { isBusy = false; nextCheck = ProcessInfo.processInfo.systemUptime + 2 }
        do {
            guard let newest = samples.last, ProcessInfo.processInfo.systemUptime - newest.time < 2 else { throw RunnerError.missingImage }
            // iPhone 17: a one-frame glance takes ~1.3 s; the full two-frame check (~4-5 s) is kept for guarded
            // steps, where spotting the addition needs motion and an evidence sentence.
            let guarded = cooking.step?.isGuarded == true
            let sequence = Array(samples.suffix(guarded ? 2 : 1))
            let revision = cooking.revision
            let sessionID = cooking.id
            let prompt = ChefPrompt.make(session: cooking, frameCount: sequence.count,
                                         span: (sequence.last?.time ?? 0) - (sequence.first?.time ?? 0))
            status = "Gemma is checking the board…"
            let (observation, result) = try await ChefBrain.review(prompt: prompt, frames: sequence.map(\.jpeg), guarded: guarded, runner: runner)
            guard snapshotRequestIsCurrent(request) else { return }
            rawResponse = result.text; lastInferenceMS = result.elapsedMS
            if !guarded { watchHot(ChefBrain.glanceHot(result.text)) }
            activity.log(.vision, spoken ? "Checking the step" : "Glance at the board", detail: "\(observation.concern) · \(observation.line)", ms: result.elapsedMS)
            let accepted = cooking.apply(observation, expectedSessionID: sessionID, expectedRevision: revision,
                                         frameAge: ProcessInfo.processInfo.systemUptime - newest.time,
                                         frameCount: sequence.count)
            guard accepted else { status = "Scene changed during the check. Discarded old result."; return }
            status = observation.confidence < 0.7 ? "Gemma is uncertain. Check the evidence." : "Board checked locally."
            // Unasked, the chef speaks only about a mistake it can see (wrong size, wrong knife), and never the same
            // one twice in 30 s. "Can't see it" or "looks done" stay on screen; the cook asked for a quiet chef.
            let now = ProcessInfo.processInfo.systemUptime
            let mistake = ["size", "knife"].contains(observation.concern)
            let repeated = observation.concern == lastConcern.0 && now - lastConcern.1 < 30
            let worthSaying = spoken || (mistake && !repeated)
            if worthSaying && observation.confidence >= 0.7 && now > alertUntil {
                chefLine = observation.line
                audio.say(observation.line, priority: spoken)
                if mistake { lastConcern = (observation.concern, now) }
            }
            saveReceipt(kind: "recipe-observation", result: result, passed: nil, expected: nil)
            failedChecks = 0
        } catch {
            // The automatic watcher shrugs off a missing picture or a busy model; it stops only after repeated
            // real failures, and only an asked-for check shows the error.
            failedChecks += 1
            if spoken { self.error = error.localizedDescription }
            status = "Check failed. Recipe state was preserved."
            if failedChecks >= 3 { automaticChecks = false; failedChecks = 0 }
        }
    }

    // MARK: Voice answers

    /// What a spoken answer is for right now: the dish name, or the current ask step.
    var listeningQuestion: String? {
        switch cooking.phase {
        case .needsDish: return ChefPrompt.dishQuestion
        case .cooking where cooking.step?.kind == .ask: return cooking.step?.question
        default: return nil
        }
    }

    func toggleListening() async {
        if voice.isStarting { _ = voice.stop(); status = "Microphone off."; return }
        if voice.isRecording { await finishListening(); return }
        guard isLoaded, !isBusy, listeningQuestion != nil else { return }
        error = nil; audio.stop()
        do { try await voice.start(); status = "Listening… tap again when you're done." }
        catch is CancellationError {
            if !voice.isStarting && !voice.isRecording { status = "Microphone off." }
        }
        catch { self.error = error.localizedDescription }
    }

    private func finishListening() async {
        guard let wav = voice.stop() else { status = "That was too short. Try again."; return }
        guard let question = listeningQuestion, !isBusy else { return }
        let (sessionID, revision) = (cooking.id, cooking.revision)
        isBusy = true; error = nil; status = "Gemma is listening to your answer…"
        do {
            let (answer, result) = try await ChefBrain.hear(question: question, audio: wav, runner: runner)
            rawResponse = result.text; lastInferenceMS = result.elapsedMS
            saveReceipt(kind: "voice-answer", result: result, passed: nil, expected: nil)
            isBusy = false
            guard cooking.id == sessionID, cooking.revision == revision else { status = "The step changed while listening."; return }
            guard answer.value.lowercased() != "unclear" else {
                chefLine = answer.line; audio.say(answer.line, priority: true); status = "Heard: \"\(answer.heard)\""; return
            }
            if cooking.phase == .needsDish {
                dishRequest = answer.value; await planDish()
            } else {
                cooking.answer(answer.value, heard: answer.heard, origin: .user)
                chefLine = answer.line; status = "Heard: \"\(answer.heard)\""
                audio.say(answer.line, priority: true)
                announceStep(speak: false)
            }
        } catch {
            isBusy = false; keepFailedReply(error); self.error = error.localizedDescription
            status = "Could not understand the answer. Try again or type it."
        }
    }

    /// Typed fallback for an ask step.
    func answerTyped(_ text: String) {
        cooking.answer(text, heard: nil, origin: .user)
        announceStep()
    }

    // MARK: Hands-free voice

    func startListening() async {
        guard isLoaded, handsFree, !listener.isOn, listenerStartID == nil,
              UIApplication.shared.applicationState == .active else { return }
        let request = UUID(); listenerStartID = request
        defer { if listenerStartID == request { listenerStartID = nil } }
        if #available(iOS 26, *), listener.live == nil {
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                _ = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
            }
            let speech = await AppleSpeech.prepare()
            speech?.hints = speechHints
            speech?.onPartial = { [weak self] id, text in
                Task { @MainActor in self?.receiveSpeechProgress(id: id, text: text) }
            }
            guard listenerStartID == request, handsFree else { return }
            listener.live = speech
            if listener.live == nil {
                status = "On-device wake listening unavailable. Use the screen controls."
                return
            }
        }
        // A failed start (the audio system busy for a moment) is retried; hands-free stays on, so the mic
        // does not silently stay off for the rest of the session.
        for attempt in 1...3 {
            guard listenerStartID == request, handsFree, UIApplication.shared.applicationState == .active else { return }
            do {
                try await listener.start(); status = cooking.phase == .cooking ? "Listening. Ask a question or tell me when you’re done." : "Say Chef or Hey Chef."
                if listener.isOn, error?.hasPrefix("Microphone:") == true { error = nil }
                activity.log(.system, "Microphone on", detail: listener.live == nil ? "Gemma transcribes speech" : "Apple on-device speech, Gemma hears answers")
                return
            }
            catch is CancellationError { return }
            catch {
                print("REMY_MIC start failed (attempt \(attempt)): \(error.localizedDescription)")
                self.error = "Microphone: \(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopListening() async { listenerStartID = nil; listener.stop() }

    /// On-device transcription detects the wake phrase. Unaddressed speech is discarded before
    /// any command, transcript UI, event log or Gemma request is produced.
    private func handleUtterance(_ wav: Data, words: Task<String?, Never>?) async {
        let id = UUID(); latestUtterance = id
        let started = ProcessInfo.processInfo.systemUptime
        lastUtterance = started
        // Debug only (--keep-audio): keep the last utterance to compare the phone's audio with the simulator.
        if ProcessInfo.processInfo.arguments.contains("--keep-audio") {
            try? wav.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("last-utterance.wav"))
        }
        guard let heard = await words?.value, latestUtterance == id, !heard.isEmpty else { return }
        let source = "apple"
        guard let addressed = wakeGate.accept(heard, now: ProcessInfo.processInfo.systemUptime,
            conversationOpen: cooking.phase == .cooking || readyToCook || startWhenRecipeReady) else {
            ingredientPreview = nil
            return
        }
        lastHeard = heard
        if ChefWakeGate.hasPrefix(heard), ingredientPreview == nil { startIngredientPreview() }
        if addressed.isEmpty {
            chefLine = "Listening…"
            return
        }
        if cooking.usesCookerSafetySequence, cooking.phase == .cooking,
           let power = CookerPowerCommand.parse(addressed) {
            cooking.reportCookerPower(on: power == .on)
            nextHazardScan = 0
            chefLine = power == .off ? "Got it. Kettle safety monitoring paused." :
                (safetyBoxesEnabled ? "Got it. Kettle safety monitoring resumed." : "Kettle is on. Turn on Safety box & alerts to resume monitoring.")
            if power == .on && cooking.isComplete { chefLine = "The recipe is finished. Start a new cooking session to resume kettle monitoring." }
            audio.say(chefLine, priority: true)
            if hotWatchEnabled { Task { await scanForHazards() } }
            return
        }
        if readyToCook || startWhenRecipeReady {
            if let decision = CookingReadinessReply.parse(addressed) {
                if decision == .ready { beginCooking() }
                else {
                    startWhenRecipeReady = false
                    chefLine = "Take your time. Tell me when you're ready."
                    audio.say(chefLine, priority: true)
                }
                return
            }
        }
        if cooking.phase == .cooking, cooking.suggestedCompletion, cooking.step?.kind == .do,
           CookingReadinessReply.parse(addressed) == .ready {
            nextStep(); return
        }
        if cooking.phase == .ingredients, let plan = cooking.plan,
           let cue = IngredientPresentationCue.parse(addressed, ingredients: plan.ingredients) {
            boxes = []
            Task { await self.checkIngredients(announce: .full, expectedIngredientID: cue.ingredientID) }
            return
        }
        let command = VoiceCommand.parse("Hey Chef " + addressed, phase: cooking.phase, secondsSinceChefSpoke: 60)
        cooking.record("Heard \"\(heard)\" → \(command.intent.rawValue)", origin: .user)
        let heardMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        print(String(format: "REMY_HEARD %@ %.0f ms \"%@\" → %@", source, heardMS, heard, command.intent.rawValue))
        activity.log(.heard, "“\(heard)”", detail: "\(source == "apple" ? "Apple on-device speech" : "Gemma transcription") → \(command.intent.rawValue)", ms: heardMS)
        switch command.intent {
        case .ignore: status = "Not for me: \"\(heard)\""
        case .wake: chefLine = "Yes?"; audio.say(chefLine, priority: true)
        case .startCooking: beginCooking()
        case .next: if cooking.step?.kind == .ask { announceStep() } else { nextStep() }
        case .previous: selectStep(max(0, cooking.currentStep - 1))
        case .repeat: announceStep()
        case .agent:
            if !heard.contains("?"), cooking.phase == .ingredients, let plan = cooking.plan,
               let confirmation = IngredientConfirmation.parse(command.value, ingredients: plan.ingredients) {
                if confirmation.status == .seen {
                    Task { await self.checkIngredients(announce: .full, expectedIngredientID: confirmation.ingredientID) }
                    return
                }
                cooking.setPantry(confirmation.ingredientID, confirmation.status)
                let name = plan.ingredients.first { $0.id == confirmation.ingredientID }?.name ?? confirmation.ingredientID
                chefLine = confirmation.status == .seen ? "Got it, \(name) is ready." : "Marked \(name) as missing."
                audio.say(chefLine, priority: true)
                return
            }
            if isBusy { audio.say("One moment.", priority: false) }
            guard await waitForGemma(id) else { return }
            // The chef just asked something ("How salty?"): Gemma hears the reply itself, from the audio, and
            // saves the answer. Anything that is not an answer goes to the conversation as usual.
            if cooking.phase == .cooking, cooking.step?.kind == .ask, await hearAnswer(wav) { return }
            await converse(heard)
        }
    }

    private func receiveSpeechProgress(id: UUID, text: String) {
        guard !appIsBackgrounded, handsFree, ChefWakeGate.hasPrefix(text), partialWakeID != id else { return }
        partialWakeID = id
        startIngredientPreview()
    }

    private func startIngredientPreview() {
        guard cooking.phase == .ingredients, isLoaded, ingredientModelReady, !appIsBackgrounded, !previewInFlight,
              !ingredientChecking, ingredientLookTask == nil, !runner.requiresRestart,
              ingredientModelReady || !isBusy,
              videoEnabled, let snapshot = samples.last,
              ProcessInfo.processInfo.systemUptime - snapshot.time < 1 else { return }
        let source = sourceRequestID, session = cooking.id, epoch = semanticEpoch
        let independent = ingredientModelReady
        previewInFlight = true
        if !independent { isBusy = true }
        let task = Task { () -> ChefBrain.PresentedIngredientResult? in
            defer { previewInFlight = false; if !independent { isBusy = false } }
            do {
                return try await ChefBrain.presentedIngredient(frame: snapshot.jpeg,
                    runner: independent ? ingredientRunner : runner)
            } catch {
                // Native ownership is held by the runner. A tentative wake never publishes a result.
                activity.log(.vision, "Wake preview unavailable", detail: error.localizedDescription)
                return nil
            }
        }
        ingredientPreview = .init(source: source, session: session, epoch: epoch,
            started: ProcessInfo.processInfo.systemUptime, independent: independent, result: task)
    }

    /// Words Apple's recognizer should expect: the wake word, commands, and this recipe's dish and ingredients.
    private var speechHints: [String] {
        ["Chef", "Hey Chef", "Remy", "Hey Remy", "yes", "I'm ready", "I'm done", "next step", "Hey Chef here's the first ingredient", "make", "cook", "next step", "start cooking", "check my ingredients", "go back", "say that again",
         "where's the", "which knife", "how salty", "cold pasta salad", "guacamole", "quesadilla", "lasagna"]
        + (cooking.plan.map { [$0.dish] + $0.ingredients.map(\.name) } ?? [])
    }

    /// One conversational turn with Gemma as the chef (ChefAgent): it may speak, call tools, or both. The tools run
    /// here, after Gemma is free again, since most of them use Gemma themselves (look, find, plan, check). When a
    /// tool produces a result the chef should talk about (what the ingredient check saw), the result goes back to
    /// Gemma and its reply is spoken, instead of a fixed sentence.
    private func converse(_ heard: String) async {
        guard !appIsBackgrounded else { return }
        let epoch = semanticEpoch
        if speculativeChat { speculativeUsed = true }
        let turn = activity.begin(.thinking, "Remy is thinking", detail: "\(ChefAgent.tools(cooking).count) tools offered")
        isBusy = true; understanding = true
        let reply = try? await ChefAgent.respond(to: heard, session: cooking, history: agentHistory, runner: runner)
        isBusy = false; understanding = false
        guard !appIsBackgrounded, semanticEpoch == epoch else { return }
        if runner.requiresRestart {
            error = RunnerError.restartRequired.localizedDescription
            status = "Remy paused safely. Reopen the app to restart the model."
            activity.finish(turn, detail: "Local runtime needs restart", failed: true)
            return
        }
        if let reply {
            let actions = reply.actions.map(\.name).joined(separator: ", ")
            activity.finish(turn, detail: (reply.speech.isEmpty ? "" : "“\(reply.speech)”") + (actions.isEmpty ? "" : (reply.speech.isEmpty ? "" : " · ") + "calls \(actions)"),
                            ms: reply.elapsedMS)
        } else {
            activity.finish(turn, detail: "reply unreadable; answering plainly instead", failed: true)
        }
        guard let reply, !(reply.speech.isEmpty && reply.actions.isEmpty) else {
            // Fall back to a plain answer if the reply could not be read or was empty.
            isBusy = true
            let answer = try? await ChefBrain.answer(question: heard, session: cooking, runner: runner).0
            isBusy = false
            guard !appIsBackgrounded, semanticEpoch == epoch else { return }
            if let answer, !answer.isEmpty { chefLine = answer; audio.say(answer, priority: true) }
            return
        }
        lastInferenceMS = reply.elapsedMS
        print(String(format: "REMY_AGENT %.0f ms \"%@\" → \"%@\" %@", reply.elapsedMS, heard, reply.speech,
                     reply.actions.map { "\($0.name)\($0.arguments)" }.joined(separator: " ")))
        // An action that announces itself (the next step, "Got it, mild") would cut the reply off mid-word,
        // so the reply is shown but not spoken then.
        let announcing: Set<String> = ["next_step", "previous_step", "repeat_step", "save_preference", "mark_added", "start_cooking"]
        if !reply.speech.isEmpty {
            chefLine = reply.speech
            if !reply.actions.contains(where: { announcing.contains($0.name) }) { audio.say(reply.speech, priority: true) }
        }
        let lineBeforeActions = chefLine
        var results: [(String, String)] = []
        for action in reply.actions {
            guard !appIsBackgrounded, semanticEpoch == epoch else { return }
            if let result = await run(action, heard: heard) { results.append((action.name, result)) }
        }
        var said = reply.actions.contains(where: { $0.name == "start_cooking" }) && !cooking.instructionsReady ? chefLine : reply.speech
        // Gemma speaks about the results when it has not said anything yet, or when a result is news (what the
        // camera saw); a plain confirmation after it already spoke needs no second turn.
        if !results.isEmpty && (reply.speech.isEmpty || results.contains { ["check_ingredients", "look"].contains($0.0) }) {
            await waitUntilGemmaIsFree()
            guard !appIsBackgrounded, semanticEpoch == epoch else { return }
            let reading = activity.begin(.thinking, "Remy reads the results", detail: results.map(\.0).joined(separator: ", "))
            isBusy = true; understanding = true
            let followUp = try? await ChefAgent.followUp(results, to: reply, session: cooking, history: agentHistory, runner: runner)
            isBusy = false; understanding = false
            guard !appIsBackgrounded, semanticEpoch == epoch else { return }
            activity.finish(reading, detail: (followUp?.speech).flatMap { $0.isEmpty ? nil : "“\($0)”" }
                            ?? (followUp.map { "calls \($0.actions.map(\.name).joined(separator: ", "))" } ?? "no reply"), failed: followUp == nil)
            print("REMY_AGENT follow-up \(results) → \"\(followUp?.speech ?? "failed")\" \(followUp?.actions.map(\.name) ?? [])")
            // Never silent after doing something: an empty follow-up still gets a short spoken confirmation.
            let line = (followUp?.speech).flatMap { $0.isEmpty ? nil : $0 } ?? (reply.speech.isEmpty ? ChefAgent.remembered("", actions: reply.actions) : "")
            if !line.isEmpty { chefLine = line; audio.say(line, priority: true); said = line }
            // One level of acting on what it learned (a hot pot it just saw); no further follow-up.
            for action in followUp?.actions ?? [] {
                guard !appIsBackgrounded, semanticEpoch == epoch else { return }
                _ = await run(action, heard: heard)
            }
        }
        // What the chef actually said ("There's the salt"), not a placeholder the model would copy later.
        if said.isEmpty && chefLine != lineBeforeActions { said = chefLine }
        agentHistory.append(.init(cook: heard, chef: ChefAgent.remembered(said, actions: reply.actions)))
        if agentHistory.count > 6 { agentHistory.removeFirst() }
        offerCookingIfReady()
    }

    /// Carry out one tool call. Returns what the chef should hear back about it, if anything.
    private func run(_ action: ChefAgent.Action, heard: String) async -> String? {
        let entry = activity.begin(.tool, Self.describe(action))
        GemmaTally.shared.add(tools: 1)
        let result = await execute(action, heard: heard)
        activity.finish(entry, detail: result ?? "done")
        return result
    }

    /// "substitute_ingredient · feta → lemon": the tool name the model called, with what it asked for.
    private static func describe(_ action: ChefAgent.Action) -> String {
        let value = { (key: String) in action.arguments[key]?.trimmingCharacters(in: .whitespaces) ?? "" }
        switch action.name {
        case "substitute_ingredient": return "\(action.name) · \(value("ingredient")) → \(value("substitute"))"
        case "remove_ingredient", "add_ingredient", "have_ingredient": return "\(action.name) · \(value("ingredient"))"
        case "find", "hot_object": return "\(action.name) · \(value("item"))"
        case "look": return value("question").isEmpty ? action.name : "\(action.name) · \(value("question"))"
        case "plan_recipe": return "\(action.name) · \(value("dish"))"
        case "save_preference": return "\(action.name) · \(value("value"))"
        default: return action.name
        }
    }

    private func execute(_ action: ChefAgent.Action, heard: String) async -> String? {
        let argument = { (key: String) in
            let value = action.arguments[key]?.trimmingCharacters(in: .whitespaces) ?? ""
            return ["nil", "null", "none"].contains(value.lowercased()) ? "" : value
        }
        switch action.name {
        case "plan_recipe" where !argument("dish").isEmpty: dishRequest = argument("dish"); await planDish()
        case "check_ingredients": return await checkIngredients(announce: .silent)
        case "substitute_ingredient":
            // Never swap back to something the cook already said they lack, and a swap to itself ("I don't have
            // that one either") means they lack it too; either way Gemma is told to pick another.
            let same = argument("substitute").lowercased() == argument("ingredient").lowercased()
            if cooking.isUnavailable(argument("substitute")) || same {
                cooking.markUnavailable(argument("ingredient"))
                return "The cook does not have \(argument("substitute")) either. Suggest a different substitute, or remove the ingredient."
            }
            return cooking.substitute(argument("ingredient"), with: argument("substitute"))
                ? "Recipe updated: \(argument("substitute")) replaces \(argument("ingredient")) in the list and the steps."
                : "\(argument("ingredient")) is not in this recipe."
        case "have_ingredient":
            guard let item = cooking.ingredient(named: argument("ingredient")) else { return "\(argument("ingredient")) is not in this recipe." }
            cooking.setPantry(item.id, .seen)
            let left = cooking.plan?.ingredients.filter { cooking.pantry[$0.id]?.status != .seen }.map(\.name) ?? []
            return "Marked \(item.name) as ready. " + (left.isEmpty ? "Every ingredient is ready." : "Still needed: \(left.joined(separator: ", ")).")
        case "add_ingredient":
            return cooking.add(argument("ingredient"), amount: argument("amount"))
                ? "Recipe updated: added \(argument("ingredient"))." : "\(argument("ingredient")) is already in the recipe."
        case "remove_ingredient":
            return cooking.remove(argument("ingredient")) ? "Recipe updated: cooking without \(argument("ingredient"))."
                : "\(argument("ingredient")) is not in this recipe."
        case "start_cooking":
            guard cooking.instructionsReady else {
                beginCooking()
                return "The cook asked to start. Keep checking ingredients until the first cooking step is announced."
            }
            beginCooking()
        case "next_step": if cooking.step?.kind == .ask { announceStep() } else { nextStep() }
        case "previous_step": selectStep(max(0, cooking.currentStep - 1))
        case "repeat_step": announceStep()
        case "check_step": await reviewBoard(spoken: true)
        case "look": return await look(argument("question").isEmpty ? heard : argument("question"), announce: false)
        case "find" where !argument("item").isEmpty: await find(argument("item"))
        case "save_preference" where !argument("value").isEmpty:
            cooking.answer(argument("value"), heard: heard, origin: .user); announceStep(prefix: "Got it, \(argument("value")).")
        case "mark_added": confirmSalt(); audio.say(chefLine, priority: true)
        case "hot_object" where !argument("item").isEmpty:
            let marked = await markHot([argument("item")])
            return marked ? "Marked the \(argument("item")); the cook is warned if the whole tracked hand enters its marked area." : "Could not find the \(argument("item")) in the camera picture."
        default: print("REMY_AGENT ignored tool \(action.name)")
        }
        return nil
    }

    /// Gemma listens to the cook's spoken reply (native audio input) and extracts the answer. False when it was
    /// not an answer to the question, so the conversation handles it.
    private func hearAnswer(_ wav: Data) async -> Bool {
        guard let question = cooking.step?.question, !question.isEmpty else { return false }
        isBusy = true; understanding = true
        defer { isBusy = false; understanding = false }
        guard let (answer, result) = try? await ChefBrain.hear(question: question, audio: wav, runner: runner) else { return false }
        rawResponse = result.text; lastInferenceMS = result.elapsedMS
        print(String(format: "REMY_HEAR %.0f ms heard \"%@\" → %@", result.elapsedMS, answer.heard, answer.value))
        activity.log(.thinking, "Gemma heard the answer (audio)", detail: "“\(answer.heard)” → \(answer.value)", ms: result.elapsedMS)
        guard answer.value.lowercased() != "unclear" else { return false }
        cooking.answer(answer.value, heard: answer.heard, origin: .user)
        isBusy = false
        announceStep(prefix: "Got it, \(answer.value)." + (answer.line.isEmpty ? "" : " \(answer.line)"))
        return true
    }

    /// Gemma runs one request at a time: wait for the current one (up to 15 s) rather than dropping what the cook
    /// said. False when the cook has said something newer meanwhile.
    private func waitForGemma(_ utterance: UUID) async -> Bool {
        for _ in 0..<60 where isBusy || isLoading { try? await Task.sleep(for: .milliseconds(250)) }
        return latestUtterance == utterance && !isBusy && isLoaded
    }

    private func snapshotRequestIsCurrent(_ request: UUID) -> Bool {
        !appIsBackgrounded && videoEnabled && sourceRequestID == request
    }

    /// Wait for the selected source without overriding video-off or changing GoPro to iPhone.
    private func freshSnapshot() async -> CameraSnapshot? {
        let request = sourceRequestID
        guard snapshotRequestIsCurrent(request) else { return nil }
        for _ in 0..<12 where samples.last.map({ ProcessInfo.processInfo.systemUptime - $0.time > 2 }) ?? true {
            try? await Task.sleep(for: .milliseconds(250))
            guard snapshotRequestIsCurrent(request) else { return nil }
        }
        guard snapshotRequestIsCurrent(request), let newest = samples.last,
              ProcessInfo.processInfo.systemUptime - newest.time < 2 else { return nil }
        return newest
    }

    /// A spoken question about what the camera sees, answered from the newest frame.
    /// `announce: false` when the chef asked: the answer goes back to the chef, which says it and can act on it.
    @discardableResult private func look(_ question: String, announce: Bool = true) async -> String? {
        let request = sourceRequestID
        guard let newest = await freshSnapshot() else {
            guard snapshotRequestIsCurrent(request) else { return nil }
            let none = "I can't see the counter yet. Point the camera at it."
            if announce { chefLine = none; audio.say(chefLine, priority: true) }
            return "The camera has no picture yet."
        }
        await waitUntilGemmaIsFree()
        guard snapshotRequestIsCurrent(request), !isBusy else { return nil }
        isBusy = true; understanding = true; defer { isBusy = false; understanding = false }
        do {
            let (reply, hot, result) = try await ChefBrain.look(question: question, frame: newest.jpeg, session: cooking, runner: runner)
            guard snapshotRequestIsCurrent(request) else { return nil }
            rawResponse = result.text; lastInferenceMS = result.elapsedMS
            print(String(format: "REMY_LOOK %.0f ms \"%@\" hot: %@", result.elapsedMS, reply, hot.joined(separator: ", ")))
            activity.log(.vision, "Looking: \(question)", detail: reply + (hot.isEmpty ? "" : " · hot: \(hot.joined(separator: ", "))"), ms: result.elapsedMS)
            watchHot(hot)
            guard !reply.isEmpty else { return nil }
            if announce { chefLine = reply; audio.say(reply, priority: true) }
            return "The camera shows: \(reply)"
        } catch { self.error = error.localizedDescription; return nil }
    }

    // MARK: Boxes

    /// "Where's the salt?" / "Which knife?": Gemma draws a box around it on the video. The item comes from the chef as
    /// a visual description ("the smallest knife"): on photos E2B boxed knives by size or look, not by name.
    private func find(_ item: String) async {
        let request = sourceRequestID
        let tool = cooking.step?.tool ?? ""
        guard let newest = await freshSnapshot() else {
            guard snapshotRequestIsCurrent(request) else { return }
            chefLine = "I can't see the counter yet. Point the camera at it."; audio.say(chefLine, priority: true); return
        }
        let found = await locate([Self.boxQuery(item)], in: newest)
        guard snapshotRequestIsCurrent(request) else { return }
        if let box = found.first {
            show([ItemBox(label: item, x: box.x, y: box.y, width: box.width, height: box.height)], for: 10)
            chefLine = !tool.isEmpty && item.lowercased().contains("knife") ? "Use this one for this step." : "There's the \(item)."
        } else {
            chefLine = "I can't find the \(item). Hold it up to the camera."
        }
        audio.say(chefLine, priority: true)
    }

    /// Measured on photos: E2B boxed "smallest knife" and "largest knife" correctly but picked the wrong knife for
    /// "paring knife", "chef's knife" and "serrated knife". Knife names become sizes for the box search only.
    static func boxQuery(_ item: String) -> String {
        let name = item.lowercased()
        guard name.contains("knife") else { return item }
        if ["paring", "small", "little", "peeling", "utility"].contains(where: name.contains) { return "the smallest knife" }
        if ["chef", "big", "large", "chopping", "santoku", "cook"].contains(where: name.contains) { return "the biggest knife" }
        return item
    }

    /// A guarded step (salt): Gemma finds the salt and marks its spot, so the reach warning works without a tap.
    private func markGuardItemAutomatically() async {
        guard let step = cooking.step, step.isGuarded, cooking.zone == nil else { return }
        let stepID = step.id
        for _ in 0..<40 where isBusy { try? await Task.sleep(for: .milliseconds(250)) }
        guard !isBusy, cooking.step?.id == stepID, cooking.zone == nil, let newest = await freshSnapshot() else { return }
        // One retry with a newer picture: a hand in the way or a busy model should not leave the alarm unarmed.
        var found = await locate([step.guardItem], in: newest).first
        if found == nil, let newer = await freshSnapshot() { found = await locate([step.guardItem], in: newer).first }
        guard let box = found else { return }
        guard cooking.step?.id == stepID, cooking.zone == nil else { return }
        cooking.markZone(.init(center: box.center)); trackers = [:]
        cooking.record("Gemma found the \(step.guardItem) and marked its spot.", origin: .system)
        show([ItemBox(label: step.guardItem, x: box.x, y: box.y, width: box.width, height: box.height)], for: 6)
    }

    /// Hot things Gemma reported in a look or glance that are not watched yet get a zone, after the current call.
    private func watchHot(_ items: [String]) {
        let new = items.map { $0.lowercased() }.filter { item in HazardZone.looksHot(item) && !hazards.contains { $0.label == item } }
        guard !new.isEmpty, hotWatchEnabled, !usingGoPro || cooking.usesCookerSafetySequence else { return }
        Task { await markHot(Array(new.prefix(2))) }
    }

    /// Once per recipe, and again after the camera moves: Gemma names what on the counter is or may be hot, then
    /// boxes each identified item; from then on the fast loop guards it. An empty or failed scan never invents
    /// targets for more native image calls.
    func scanForHazards() async {
        guard hotWatchEnabled, (!usingGoPro || cooking.usesCookerSafetySequence), isLoaded, !cookerScanRunning else { return }
        if cooking.usesCookerSafetySequence {
            cookerScanRunning = true
            defer { cookerScanRunning = false }
            _ = await markHot(CookerSafetyTargets.queries)
            return
        }
        await waitUntilGemmaIsFree()
        guard cooking.phase == .cooking, let newest = await freshSnapshot(), !isBusy else { return }
        isBusy = true
        let entry = activity.begin(.vision, "Scanning for anything hot")
        var names: [String] = []
        do {
            let (found, result) = try await ChefBrain.hazards(frame: newest.jpeg, runner: runner)
            names = found.filter(HazardZone.looksHot); rawResponse = result.text
            print("REMY_HAZARDS \(found) → heat: \(names)")
            activity.finish(entry, detail: names.isEmpty ? "nothing named hot; boxing pot, pan, cooker, kettle" : names.joined(separator: ", "), ms: result.elapsedMS)
        } catch {
            activity.finish(entry, detail: error.localizedDescription, failed: true)
            isBusy = false
            return // A native/format failure does not trigger a second vision request.
        }
        isBusy = false
        // Preserve the common-vessel search after a valid empty heat scan, as tested upstream.
        guard cooking.phase == .cooking else { return }
        if names.isEmpty { names = ["pot", "pan", "cooker", "kettle"] }
        await markHot(Array(names.prefix(4)))
    }

    /// Gemma finds the hot object(s) once and the fast loop watches hands against them from then on.
    @discardableResult func markHot(_ items: [String]) async -> Bool {
        for _ in 0..<40 where isBusy { try? await Task.sleep(for: .milliseconds(250)) }
        guard hotWatchEnabled, (!usingGoPro || cooking.usesCookerSafetySequence), let newest = await freshSnapshot() else { return false }
        let geometry = hazardGeometryEpoch, source = sourceRequestID, session = cooking.id
        let found = await locate(items, in: newest)
        guard hotWatchEnabled, geometry == hazardGeometryEpoch, source == sourceRequestID,
              session == cooking.id, !found.isEmpty else { return false }
        if cooking.usesCookerSafetySequence {
            let named = found.map { box in
                ItemBox(label: box.label.isEmpty && items.count == 1 ? items[0] : box.label,
                        x: box.x, y: box.y, width: box.width, height: box.height)
            }
            let zones = CookerSafetyTargets.zones(from: named)
            guard !zones.isEmpty else { return false }
            camera.setHazardTargets(zones, snapshot: newest, id: geometry)
            if !usingGoPro { hazards = zones }
            cooking.record("Located cooker/pot for tracked heat caution.", origin: .system)
            return true
        }
        var zones: [HazardZone] = []
        for box in found {
            let zone = HazardZone(box, label: items.count == 1 ? items[0] : (box.label.isEmpty ? items[0] : box.label))
            // The same object under two names ("pot" and "pan") stays one zone.
            if !zones.contains(where: { $0.overlaps(zone) }) { zones.append(zone) }
        }
        hazards = hazards.filter { old in !zones.contains { $0.label == old.label || $0.overlaps(old) } } + zones
        cooking.record("Gemma marked hot: \(zones.map(\.label).joined(separator: ", ")).", origin: .system)
        return true
    }

    /// Gemma answers one request at a time; an automatic check may have slipped in. Wait for it (up to 10 s).
    private func waitUntilGemmaIsFree() async {
        for _ in 0..<40 where isBusy { try? await Task.sleep(for: .milliseconds(250)) }
    }

    private func locate(_ items: [String], in snapshot: CameraSnapshot) async -> [ItemBox] {
        let request = sourceRequestID
        guard snapshotRequestIsCurrent(request) else { return [] }
        // Only exact detector classes can bypass Gemma. "Smallest knife", salt, oil, and fine
        // ingredient names still need semantic visual reasoning; a generic box cannot prove them.
        let current = liveObjects.filter { FastObjectPresentation.isSpecificIdentityReliable($0.label) }
        let matches = items.map { item in current.filter { $0.label.lowercased() == item.lowercased() } }
        if !matches.isEmpty, matches.allSatisfy({ !$0.isEmpty }) { return matches.flatMap { $0 } }
        await waitUntilGemmaIsFree()
        guard snapshotRequestIsCurrent(request), isLoaded, !isBusy else { return [] }
        isBusy = true; defer { isBusy = false }
        do {
            let (boxes, result) = try await ChefBrain.locate(items, frame: snapshot.jpeg, runner: runner)
            guard snapshotRequestIsCurrent(request) else { return [] }
            rawResponse = result.text; lastInferenceMS = result.elapsedMS
            print(String(format: "REMY_BOX %.0f ms %@ → %d boxes", result.elapsedMS, items.joined(separator: ", "), boxes.count))
            activity.log(.vision, "Boxing: \(items.joined(separator: ", "))", detail: boxes.isEmpty ? "nothing found" : "boxed \(boxes.map(\.label).joined(separator: ", "))", ms: result.elapsedMS)
            return boxes
        } catch { self.error = error.localizedDescription; return [] }
    }

    /// Boxes stay on screen for a while; the camera moving or the step changing clears them sooner.
    private func show(_ found: [ItemBox], for seconds: Double) {
        boxes = found
        let shown = UUID(); boxesShown = shown
        Task { try? await Task.sleep(for: .seconds(seconds)); if boxesShown == shown { boxes = [] } }
    }

    /// After planning, wait for the selected camera only while its request is still current.
    private func autoCheckIngredients() async {
        let request = sourceRequestID
        guard cooking.phase == .ingredients, await freshSnapshot() != nil else { return }
        try? await Task.sleep(for: .seconds(1))
        guard snapshotRequestIsCurrent(request) else { return }
        for _ in 0..<40 where isBusy {
            try? await Task.sleep(for: .milliseconds(250))
            guard snapshotRequestIsCurrent(request) else { return }
        }
        guard snapshotRequestIsCurrent(request) else { return }
        await checkIngredients()
    }

    private func announceStep(speak: Bool = true, prefix: String = "") {
        guard let step = cooking.step, cooking.phase == .cooking else { return }
        if step.kind == .ask {
            chefLine = prefix.isEmpty ? step.question : "\(prefix) \(step.question)"
            audio.say(chefLine, priority: true)
        } else if speak {
            // Layer 0: the warning is spoken as the step starts, before anything irreversible can happen.
            chefLine = (prefix.isEmpty ? "" : "\(prefix) ") + "Step \(cooking.currentStep + 1) of \(cooking.plan?.steps.count ?? 0). \(step.instruction)"
            let spoken = (step.warning.isEmpty ? "" : "\(step.warning) ") + chefLine
            audio.say(spoken, priority: true)
        }
        if step.isGuarded && cooking.zone == nil { Task { await markGuardItemAutomatically() } }
        if cooking.usesCookerSafetySequence && !cooking.cookerSafetyArmed && !cooking.isComplete {
            Task { await prepareCookerZone() }
        }
        if hotWatchEnabled && hazards.isEmpty {
            nextHazardScan = ProcessInfo.processInfo.systemUptime + (cooking.usesCookerSafetySequence ? 5 : 15)
            Task { await scanForHazards() }
        }
    }

    // MARK: Fast loop

    private func receive(_ sample: CameraSample) {
        guard videoEnabled else { return }
        frame = sample
        if cooking.phase == .ingredients {
            // The last pre-focus hand callback may still arrive. Keep its video, never its actions.
            if !trackers.isEmpty { trackers = [:] }
            heldGesture = ("", 0); flatFrames = 0
            return
        }
        if safetyBoxesEnabled && cooking.cookerPowerOn != false && cooking.usesCookerSafetySequence {
            if let tracking = sample.hazardTracking, tracking.id == hazardGeometryEpoch {
                latestCookerTrack = (sample.time, tracking.zones)
                if cooking.cookerSafetyArmed { hazards = tracking.zones }
            } else if usingGoPro { hazards = []; latestCookerTrack = nil }
        }
        let ids = Set(sample.hands.map(\.id))
        for id in Array(trackers.keys) where !ids.contains(id) { trackers[id]?.reset() }
        // Unknown/duplicated chirality is not a stable track identity, so it cannot trigger a reach alert.
        for hand in sample.hands where hand.id != "unknown" && sample.hands.filter({ $0.id == hand.id }).count == 1 {
            var tracker = trackers[hand.id] ?? ReachTracker()
            let warning = tracker.update(point: hand.reachPoint, time: sample.time,
                                         zone: cooking.zone, armed: cooking.guardArmed && !usingGoPro)
            trackers[hand.id] = tracker
            if warning && sample.time > alertUntil {
                alertUntil = sample.time + 2; alertCount += 1
                let item = cooking.step?.guardItem ?? "that"
                alertTitle = "Already added \(item)"; alertSubtitle = "Taste it first."; alertSymbol = "hand.raised.fill"
                chefLine = "Already added \(item). Taste it first!"
                cooking.record("Fast visual loop detected an approach to the marked \(item) location.", origin: .system)
                audio.alarm()
                let latency = (ProcessInfo.processInfo.systemUptime - sample.time) * 1000
                lastReflexMS = latency
                print(String(format: "REMY_REFLEX %@ %.0f ms after the frame", item, latency))
                activity.log(.reflex, "Reaching for the \(item) again", detail: "alarm from the fast loop, no model call", ms: latency)
            }
        }
        // Gestures must be held ~0.6 s (a passing hand shape is not a command), then 2.5 s of rest. A fist is not
        // used: holding a knife looks like one.
        if gesturesEnabled && !runningIngredientRegression, let gesture = sample.hands.compactMap(\.gesture).first(where: { ["Thumb_Up", "Thumb_Down", "Open_Palm"].contains($0) }) {
            if gesture != heldGesture.0 { heldGesture = (gesture, sample.time) }
            else if sample.time - heldGesture.1 >= (gesture == "Open_Palm" ? 1.0 : 0.6) && sample.time > gestureQuietUntil {
                gestureQuietUntil = sample.time + 2.5
                perform(gesture: gesture)
            }
        } else { heldGesture = ("", 0) }
        // The requested cooker sequence warns on image-space proximity; other recipes keep
        // the whole-hand rule. GoPro cooker boxes use frame-matched Vision tracking.
        if hotWatchEnabled && !hazards.isEmpty && (!usingGoPro || cooking.cookerSafetyArmed) {
            hazardWatch.proximityMargin = cooking.cookerSafetyArmed ? 0.07 : 0
            hazardWatch.cooldown = cooking.cookerSafetyArmed ? 6 : 2
            let hands = sample.hands.map { hand in
                HazardWatch.Hand(id: hand.id, points: (0..<21).compactMap { hand.points[String($0)] },
                                 isReliable: hand.id != "unknown")
            }
            if let zone = hazardWatch.check(hands: hands, zones: hazards, time: sample.time,
                                            now: ProcessInfo.processInfo.systemUptime) {
                alertUntil = sample.time + 2.5; alertCount += 1
                alertTitle = "Careful — hot cooker"; alertSubtitle = "Keep hands clear of the pot."; alertSymbol = "flame.fill"
                chefLine = cooking.cookerSafetyArmed ? "Be careful of the pot on the stove!" : "Hot: \(zone.label). Hands back."
                cooking.record("Fast visual loop: a hand approached the marked \(zone.label) in the camera image.", origin: .system)
                audio.alarm(); audio.say(chefLine, priority: true)
                let latency = (ProcessInfo.processInfo.systemUptime - sample.time) * 1000
                lastReflexMS = latency
                print(String(format: "REMY_REFLEX hot %@ %.0f ms after the frame", zone.label, latency))
                activity.log(.reflex, "Hand reached the hot \(zone.label)", detail: "alarm from the fast loop, no model call", ms: latency)
            }
        }
        let cutting = cooking.phase == .cooking && cooking.step.map { $0.kind == .do && !$0.wrongSize.isEmpty } == true
        if gripHints && cutting && sample.hands.contains(where: \.flatHint) {
            flatFrames += 1
            if flatFrames >= 4 && sample.time - lastGripHint > 12 && sample.time > alertUntil {
                chefLine = "Check your guiding hand. Curl those fingertips away from the blade."
                audio.say(chefLine); lastGripHint = sample.time
            }
        } else { flatFrames = 0 }
        let conversationQuiet = !listener.hearing && !audio.isSpeaking
            && ProcessInfo.processInfo.systemUptime - audio.lastFinished > 3 && ProcessInfo.processInfo.systemUptime - lastUtterance > 4
        let freshPicture = samples.last.map { ProcessInfo.processInfo.systemUptime - $0.time < 2 } ?? false
        // Only look for the cooker after step 1 is confirmed. Retry if it was out of view;
        // never substitute a made-up box when localization fails.
        if hotWatchEnabled && !ingredientChecking && !runningIngredientRegression && hazards.isEmpty && sample.time > nextHazardScan && !isBusy && isLoaded && conversationQuiet && freshPicture && (!usingGoPro || cooking.cookerSafetyArmed) {
            nextHazardScan = sample.time + (cooking.usesCookerSafetySequence ? 5 : 15)
            Task { await scanForHazards() }
        }
        if !cooking.isComplete && automaticChecks && sample.time > nextCheck && !isBusy && isLoaded && cooking.step?.kind == .do && conversationQuiet && freshPicture {
            nextCheck = sample.time + 6
            Task { await reviewBoard(spoken: false) }
        }
    }

    private func perform(gesture: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        cooking.record("Gesture: \(gesture)", origin: .user)
        print("REMY_GESTURE \(gesture)")
        let name = gesture.replacingOccurrences(of: "_", with: " ").lowercased()
        switch (gesture, cooking.phase) {
        case ("Open_Palm", _): audio.stop(); status = "Quiet."; activity.log(.gesture, "Open palm", detail: "Remy goes quiet")
        case ("Thumb_Up", .ingredients): activity.log(.gesture, "Thumbs up", detail: "start cooking"); beginCooking()
        case ("Thumb_Up", .cooking):
            activity.log(.gesture, "Thumbs up", detail: "next step")
            if cooking.step?.kind == .ask { announceStep() } else { nextStep() }
        case ("Thumb_Down", .cooking): activity.log(.gesture, "Thumbs down", detail: "back one step"); selectStep(max(0, cooking.currentStep - 1))
        default: activity.log(.gesture, name.capitalized, detail: "nothing to do right now")
        }
    }

    func placeSalt(at point: Point2) {
        cooking.markZone(.init(center: point)); markSaltLocation = false; trackers = [:]
        chefLine = "\(cooking.step?.guardItem.capitalized ?? "Item") location marked. Mark it again whenever it moves."
    }
    func confirmSalt() { cooking.confirmSalt(); chefLine = "Remembered. Taste before adding more." }
    func nextStep() {
        if !cooking.isComplete { cooking.nextStep() }
        trackers = [:]; samples = []; boxes = []
        if cooking.isComplete {
            automaticChecks = false
            chefLine = "Your \(cooking.plan?.dish.lowercased() ?? "dish") is ready. Enjoy!"
            status = "Finished."
            audio.say(chefLine, priority: true)
        } else { announceStep() }
    }
    func selectStep(_ index: Int) { cooking.selectStep(index); trackers = [:]; samples = []; boxes = []; announceStep() }
    func reset() {
        semanticEpoch = UUID()
        instructionsError = nil; startWhenRecipeReady = false; pendingIngredientLook = nil
        if !instructionsPreparing { recipePreparationTask?.cancel(); recipePreparationTask = nil }
        cooking = CookingSession(); dishRequest = ""; trackers = [:]; samples = []; alertCount = 0; agentHistory = []; hazards = []
        GemmaTally.shared.reset()
        nextHazardScan = 0; toldPlan = false
        audio.stop(); automaticChecks = false; boxes = []
        chefLine = "Fresh start. What are we making?"
    }
    func startPhoneCamera() {
        guard !appIsBackgrounded else { return }
        videoEnabled = true
        UIApplication.shared.isIdleTimerDisabled = true
        sourceRequestID = UUID(); hazardGeometryEpoch = UUID(); cookerCandidate = nil; latestCookerTrack = nil; camera.clearHazardTargets(); hazards = []; hazardWatch.reset()
        goPro.stop(); usingGoPro = false; objectSample = nil; cooking.invalidateZone(); samples = []; frame = nil; trackers = [:]
        camera.start()
    }
    func startGoPro() async {
        guard !appIsBackgrounded else { return }
        videoEnabled = true
        UIApplication.shared.isIdleTimerDisabled = true
        let requestID = UUID(); sourceRequestID = requestID
        hazards = []; cookerCandidate = nil; latestCookerTrack = nil; camera.clearHazardTargets(); hazardGeometryEpoch = UUID(); hazardWatch.reset()
        usingGoPro = true; objectSample = nil; cooking.invalidateZone(); samples = []; frame = nil; trackers = [:]
        camera.prepareExternal()
        await goPro.start()
        guard sourceRequestID == requestID else { return }
        // Keep the external consumer ready while GoPro performs a bounded automatic reconnect.
    }
    /// Publish intent immediately; warm tracking survives a video-only pause.
    func toggleVideo() {
        if videoEnabled {
            videoEnabled = false; frame = nil; samples = []; trackers = [:]
            sourceRequestID = UUID(); hazardGeometryEpoch = UUID(); cookerCandidate = nil; latestCookerTrack = nil; camera.clearHazardTargets(); hazards = []; hazardWatch.reset(); automaticChecks = false; cooking.invalidateZone()
            camera.stop(retainingTracker: true); goPro.stop()
            UIApplication.shared.isIdleTimerDisabled = voice.isRecording || audio.isSpeaking
        } else if usingGoPro {
            videoEnabled = true
            let requestID = UUID(); sourceRequestID = requestID
            Task { guard sourceRequestID == requestID, videoEnabled else { return }; await startGoPro() }
        }
        else { startPhoneCamera() }
    }
    func pause() {
        videoEnabled = false; frame = nil
        UIApplication.shared.isIdleTimerDisabled = false
        sourceRequestID = UUID(); hazardGeometryEpoch = UUID(); cookerCandidate = nil; latestCookerTrack = nil; camera.clearHazardTargets(); hazards = []; hazardWatch.reset()
        automaticChecks = false; camera.stop(); goPro.stop(); audio.stop(); samples = []; frame = nil
        if voice.isRecording || voice.isStarting { _ = voice.stop() }
        cooking.invalidateZone(); trackers = [:]
    }

    /// An unusable Gemma reply is still evidence: show it under Evidence and save a receipt for debugging.
    private func keepFailedReply(_ error: Error) {
        guard let failure = error as? GemmaReplyError else { return }
        rawResponse = failure.result.text; lastInferenceMS = failure.result.elapsedMS
        saveReceipt(kind: "failed-\(failure.task.replacingOccurrences(of: " ", with: "-"))", result: failure.result, passed: false, expected: nil)
    }

    // MARK: Persistence

    private static var sessionURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("session.json")
    }
    /// A multi-hour cook survives the app being closed; the saved guard location is never trusted again.
    private static func restoreSession() -> CookingSession {
        guard let data = try? Data(contentsOf: sessionURL),
              var session = try? JSONDecoder().decode(CookingSession.self, from: data), session.plan != nil else { return CookingSession() }
        if let plan = session.plan, IngredientDraft.preset(for: plan.dish) != nil,
           session.removeForReplanning("salt"), let updated = try? JSONEncoder().encode(session) {
            try? updated.write(to: sessionURL, options: .atomic)
        }
        session.refreshLegacyPastaInstructions()
        session.restoredAfterLaunch()
        return session
    }
    private func saveSession() {
        guard !runningIngredientRegression else { return }
        guard let data = try? JSONEncoder().encode(cooking) else { return }
        try? data.write(to: Self.sessionURL, options: .atomic)
    }

    private func saveReceipt(kind: String, result: InferenceResult, passed: Bool?, expected: String?) {
        let report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()), "kind": kind,
            "device": UIDevice.current.model, "os": UIDevice.current.systemVersion,
            "runtime": models.manifest.runtime, "modelRevision": models.manifest.revision,
            "modelSHA256": models.manifest.sha256, "configuredBackend": backend,
            "elapsedMS": result.elapsedMS, "images": result.imageCount,
            "networkPathAvailable": networkAvailable, "response": result.text,
            "markerMatched": passed.map { $0 as Any } ?? NSNull(),
            "expectedMarker": expected.map { $0 as Any } ?? NSNull(),
            "note": "A network-path check is not an airplane-mode or packet-capture audit."
        ]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Receipts", isDirectory: true)
        let url = directory.appendingPathComponent("latest-inference-receipt.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try data.write(to: url.deletingLastPathComponent().appendingPathComponent("latest-\(kind)-receipt.json"), options: .atomic)
            receiptURL = url
        }
        catch { self.error = "Inference worked, but saving its receipt failed: \(error.localizedDescription)" }
    }
}
