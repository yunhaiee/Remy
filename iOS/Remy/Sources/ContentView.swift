import SwiftUI
import UniformTypeIdentifiers
import RemyCore

private let accent = AppTheme.accent
private let textColor = AppTheme.text
private let screenBackground = AppTheme.background

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var activityOpen = ProcessInfo.processInfo.arguments.contains("--drawer-open")
    @State private var brain = false
    @State private var showSteps = false
    @State private var showSession = false
    @State private var showGoPro = ProcessInfo.processInfo.arguments.contains("--gopro-setup")

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                Group {
                    if landscape { landscapeLayout }
                    else { portraitLayout }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(screenBackground)
                .statusBarHidden(landscape)
                .persistentSystemOverlays(landscape ? .hidden : .automatic)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $brain) { BrainView(model: model, store: model.models) }
            .sheet(isPresented: $showGoPro) { GoProSetupView(model: model, source: model.goPro, bluetooth: model.goProBluetooth) }
            .sheet(isPresented: $showSession) {
                NavigationStack {
                    ScrollView { VStack(alignment: .leading, spacing: 22) { chef; flowCard }.padding(24) }
                        .appScreen().navigationTitle("Your session")
                        .toolbar { Button("Done") { showSession = false } }
                }.tint(accent).preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showSteps) {
                NavigationStack {
                    List(Array((model.cooking.plan?.steps ?? []).enumerated()), id: \.element.id) { index, step in
                        Button { model.selectStep(index); showSteps = false } label: {
                            HStack {
                                Text(String(format: "%02d", index + 1)).monospaced()
                                Text(step.kind == .ask ? "Ask · \(step.title)" : step.title)
                                Spacer()
                                if model.cooking.currentStep == index { Image(systemName: "arrowtriangle.right.fill").font(.app(.caption)) }
                                else if model.cooking.done.contains(step.id) { Image(systemName: "checkmark").foregroundStyle(accent) }
                            }.foregroundStyle(textColor)
                        }.listRowBackground(AppTheme.surface.opacity(0.82)).buttonStyle(.plain)
                    }.appScreen().navigationTitle(model.cooking.plan?.dish ?? "Recipe")
                        .toolbar { Button("Done") { showSteps = false } }
                }.tint(accent)
            }
        }.tint(accent)
        .overlay {
            GeometryReader { window in
                if window.size.width > window.size.height {
                    FrostedGlassGroup {
                        VStack(spacing: 0) {
                            LandscapeGuidanceHeader(text: model.chefLine, listener: model.listener, thinking: model.understanding || model.ingredientChecking || (model.isBusy && !model.instructionsPreparing),
                                                    seconds: model.lastInferenceMS.map { $0 / 1000 },
                                                    reflexMS: ProcessInfo.processInfo.systemUptime < model.alertUntil ? (model.lastReflexMS ?? 0) : nil,
                                                    openSession: { showSession = true })
                                .padding(.horizontal, 24).padding(.top, 14)
                            Spacer(minLength: 16)
                            HStack(spacing: 0) {
                                GlassControlDock(model: model, voice: model.voice, listener: model.listener, openBrain: { brain = true },
                                                 toggleActivity: { activityOpen.toggle() }, activityOpen: activityOpen)
                                Spacer(minLength: 12)
                                PrimaryAction(model: model, voice: model.voice, openBrain: { brain = true }, compact: true)
                                Spacer(minLength: 12)
                                HStack(spacing: LandscapeChrome.controlGap) {
                                    LandscapeSessionButton { showSession = true }
                                    landscapeSettings
                                }.frame(width: LandscapeChrome.dockWidth)
                            }
                            .padding(.horizontal, 18).padding(.bottom, 12)
                        }
                    }
                }
            }.ignoresSafeArea()
        }
        .overlay(alignment: .leading) {
            if model.isLoaded || !model.activity.entries.isEmpty {
                AgentDrawer(model: model, activity: model.activity, open: $activityOpen)
            }
        }
    }

    private var portraitLayout: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    camera
                    chef
                    if model.cooking.phase != .ingredients { flowCard }
                }.padding(20)
            }.appScreen()
            .safeAreaInset(edge: .bottom) {
                PrimaryAction(model: model, voice: model.voice, openBrain: { brain = true })
                .padding(.horizontal, 20).padding(.vertical, 10).background(screenBackground)
            }
    }

    private func cameraSurface(fill: Bool) -> some View {
            ZStack {
                Color.black
                if let frame = model.frame {
                    if model.usingGoPro {
                        LiveVideoPreview(frames: model.goPro.videoFrames, enabled: !showGoPro, scaling: fill ? .fill : .fit)
                    } else {
                        GeometryReader { imageGeometry in
                            let rect = displayRect(imageRatio: frame.image.size.width / frame.image.size.height, size: imageGeometry.size, fill: fill)
                            Image(uiImage: frame.image).resizable().frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                        }.clipped()
                    }
                    GeometryReader { proxy in
                        Canvas { context, size in
                            let imageRatio = frame.image.size.width / frame.image.size.height
                            let rect = displayRect(imageRatio: imageRatio, size: size, fill: fill)
                            func point(_ p: Point2) -> CGPoint { .init(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }
                            let freshHands = ProcessInfo.processInfo.systemUptime - frame.time < 0.15 ? frame.hands : []
                            for hand in freshHands {
                                let chains = [[0,1,2,3,4], [0,5,6,7,8], [5,9,10,11,12], [9,13,14,15,16], [13,17,18,19,20], [0,17]]
                                for chain in chains {
                                    var path = Path()
                                    for (index, joint) in chain.enumerated() {
                                        guard let p = hand.points[String(joint)] else { continue }
                                        if index == 0 { path.move(to: point(p)) } else { path.addLine(to: point(p)) }
                                    }
                                    context.stroke(path, with: .color(AppTheme.accentLight.opacity(0.7)), lineWidth: 1.5)
                                }
                                for p in hand.points.values {
                                    let at = point(p)
                                    context.fill(Path(ellipseIn: CGRect(x: at.x - 2.5, y: at.y - 2.5, width: 5, height: 5)), with: .color(AppTheme.accentLight))
                                }
                                let at = point(hand.reachPoint)
                                context.stroke(Path(ellipseIn: CGRect(x: at.x - 8, y: at.y - 8, width: 16, height: 16)), with: .color(AppTheme.accentLight), lineWidth: 2)
                            }
                            if let zone = model.cooking.zone {
                                let center = point(zone.center), rx = zone.radius * rect.width, ry = zone.radius * rect.height
                                let circle = Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2))
                                context.fill(circle, with: .color(accent.opacity(model.cooking.guardArmed ? 0.25 : 0.1)))
                                context.stroke(circle, with: .color(model.cooking.guardArmed ? accent : AppTheme.accentLight), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            }
                            // Hot zones (pot, pan): dashed orange, labelled, for as long as they are watched.
                            for zone in model.hazards {
                                let topLeft = point(.init(zone.x, zone.y)), bottomRight = point(.init(zone.x + zone.width, zone.y + zone.height))
                                let hot = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
                                let alerting = ProcessInfo.processInfo.systemUptime < model.alertUntil
                                if alerting { context.fill(Path(roundedRect: hot, cornerRadius: 10), with: .color(AppTheme.warning.opacity(0.22))) }
                                context.stroke(Path(roundedRect: hot, cornerRadius: 10), with: .color(AppTheme.warning),
                                               style: StrokeStyle(lineWidth: alerting ? 4 : 2.5, dash: [8, 5]))
                                let label = context.resolve(Text("hot · \(zone.label)").font(.app(13, .medium)).foregroundColor(.black))
                                let size = label.measure(in: CGSize(width: 220, height: 40))
                                let tag = CGRect(x: hot.minX, y: max(0, hot.minY - size.height - 8), width: size.width + 14, height: size.height + 6)
                                context.fill(Path(roundedRect: tag, cornerRadius: tag.height / 2), with: .color(AppTheme.warning))
                                context.draw(label, at: CGPoint(x: tag.midX, y: tag.midY))
                            }
                            // Items Gemma located ("Where's the salt?"), in the same normalized space as the hands.
                            for box in model.visibleObjectBoxes {
                                let topLeft = point(.init(box.x, box.y)), bottomRight = point(.init(box.x + box.width, box.y + box.height))
                                let frameRect = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
                                context.stroke(Path(roundedRect: frameRect, cornerRadius: 10), with: .color(accent), lineWidth: 3)
                                guard !box.label.isEmpty else { continue }
                                let label = context.resolve(Text(box.label).font(.app(13, .medium)).foregroundColor(.white))
                                let size = label.measure(in: CGSize(width: 220, height: 40))
                                let tag = CGRect(x: frameRect.minX, y: max(0, frameRect.minY - size.height - 8), width: size.width + 14, height: size.height + 6)
                                context.fill(Path(roundedRect: tag, cornerRadius: tag.height / 2), with: .color(accent))
                                context.draw(label, at: CGPoint(x: tag.midX, y: tag.midY))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            guard model.markSaltLocation else { return }
                            let rect = displayRect(imageRatio: frame.image.size.width / frame.image.size.height, size: proxy.size, fill: fill)
                            guard rect.contains(value.location) else { return }
                            model.placeSalt(at: .init((value.location.x - rect.minX) / rect.width, (value.location.y - rect.minY) / rect.height))
                        })
                    }
                    if model.planning { Color.black.opacity(0.45) }
                    if !fill && ProcessInfo.processInfo.systemUptime < model.alertUntil {
                        // Sideways, the voice pill carries the alarm; the card gets one small line.
                        HStack(spacing: 8) {
                            Circle().fill(.white).frame(width: 6, height: 6)
                            Text("\(model.alertTitle) · \(model.alertSubtitle)").font(.app(13, .medium))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(AppTheme.warning, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 14)
                        .allowsHitTesting(false)
                    } else if model.markSaltLocation {
                        Text("Tap the \(model.cooking.step?.guardItem ?? "item")").font(.app(.headline, .medium)).padding(12).background(.black.opacity(fill ? 0 : 0.8), in: Capsule())
                            .frostedGlass(in: Capsule(), interactive: false, enabled: fill).foregroundStyle(.white).allowsHitTesting(false)
                    }
                } else if !fill {
                    VStack(spacing: 14) {
                        Image(systemName: "viewfinder").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(accent)
                        Text("Show me what’s cooking.").font(.app(.headline, .medium)).foregroundStyle(textColor)
                        Text("Keep both hands and the board in view.").font(.app(.subheadline)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Open camera", systemImage: "camera.fill") { model.startPhoneCamera() }.buttonStyle(FrostedActionStyle())
                    }.padding(20)
                }
            }.clipped()

    }

    private var landscapeLayout: some View {
        cameraSurface(fill: true).ignoresSafeArea()
    }

    private var landscapeSettings: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            brain = true
        } label: {
            Image(systemName: "gearshape").font(.system(size: 15.75, weight: .semibold)).foregroundStyle(.white)
        }
        .buttonStyle(FrostedControlStyle())
        .accessibilityLabel("Settings")
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Gemma 4 · LiteRT")
                Text("Remy").font(.app(30, .medium, relativeTo: .largeTitle)).tracking(-0.6).foregroundStyle(textColor)
            }
            Spacer()
            Button { brain = true } label: {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .regular)).foregroundStyle(AppTheme.secondary)
                    .frame(width: 44, height: 44).overlay { Circle().stroke(AppTheme.outline, lineWidth: 1) }
            }.buttonStyle(.plain).accessibilityLabel("Settings")
        }.padding(.horizontal, 4)
    }

    private var camera: some View {
        VStack(spacing: 0) {
            cameraSurface(fill: false).frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay { RoundedRectangle(cornerRadius: 24).stroke(AppTheme.outline, lineWidth: 1) }
        }
    }

    private var chef: some View {
        // The chef's line is the headline of the screen, light and large, like the Gemma site's titles.
        VStack(alignment: .leading, spacing: 10) {
            Text(model.chefLine).font(.app(28, relativeTo: .title)).tracking(-0.5).foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
            if model.handsFree && model.isLoaded {
                ListeningBadge(listener: model.listener, lastHeard: model.lastHeard, understanding: model.understanding || model.ingredientChecking || (model.isBusy && !model.instructionsPreparing),
                               seconds: model.lastInferenceMS.map { $0 / 1000 })
            }
            Text(model.status).font(.app(.footnote)).foregroundStyle(AppTheme.secondary)
            if let error = model.userFacingError ?? model.camera.error { Text(error).font(.app(.footnote)).foregroundStyle(AppTheme.warning) }
        }.padding(.horizontal, 4)
    }

    @ViewBuilder private var flowCard: some View {
        switch model.cooking.phase {
        case .needsDish: dishCard
        case .ingredients: ingredientsCard
        case .cooking: stepCard
        }
    }

    private var dishCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // A chat composer: type and send on one line, like messaging an assistant.
            HStack(spacing: 8) {
                TextField("Say it, or type a dish", text: $model.dishRequest)
                    .font(.app(.body)).foregroundStyle(textColor).submitLabel(.send)
                    .onSubmit { Task { await model.planDish() } }
                Button { Task { await model.planDish() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(AppTheme.gradient, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Plan this dish")
                .disabled(!model.isLoaded || model.isBusy || model.dishRequest.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(model.dishRequest.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                MicButton(model: model, voice: model.voice, label: "Say it")
            }
            .padding(.leading, 18).padding(.trailing, 6).frame(minHeight: 50)
            .background(AppTheme.surfaceHigh, in: Capsule())
            if let preview = model.planPreview { planPreview(preview).padding(.horizontal, 4) }
        }
    }

    /// The plan filling in while Gemma writes it: ingredients first, then each finished step.
    private func planPreview(_ preview: PlanPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Eyebrow("Writing the plan · \(preview.ingredients.count) ingredients · \(preview.steps.count) steps so far", color: AppTheme.accentLight)
            if !preview.ingredients.isEmpty {
                Text(preview.ingredients.map(\.name).joined(separator: " · ")).font(.app(.subheadline)).foregroundStyle(textColor)
            }
            ForEach(Array(preview.steps.enumerated()), id: \.offset) { index, step in
                Text("\(String(format: "%02d", index + 1))  \(step.kind == .ask ? "Ask · " : "")\(step.title)")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    private var ingredientsCard: some View {
        let plan = model.cooking.plan
        let ready = plan?.ingredients.filter { model.cooking.pantry[$0.id]?.status == .seen }.count ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(plan?.dish ?? "")
                Spacer(); Eyebrow("\(ready) of \(plan?.ingredients.count ?? 0) ready")
            }
            Text("Show me your ingredients").font(.app(26, relativeTo: .title2)).tracking(-0.4).foregroundStyle(textColor)
            ForEach(plan?.ingredients ?? []) { item in
                Button { model.cyclePantry(item.id) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).foregroundStyle(textColor)
                        Text(item.amount).font(.app(.caption)).foregroundStyle(.secondary)
                        Spacer()
                        pantryLabel(model.cooking.pantry[item.id])
                    }
                }
            }
            Text("Tap an item to correct it. Your word beats the camera.").font(.app(.caption)).foregroundStyle(.secondary)
            Button("Start cooking") { model.beginCooking() }.buttonStyle(FrostedActionStyle())
        }.appCard()
    }

    private func pantryLabel(_ item: CookingSession.PantryItem?) -> some View {
        let (text, color): (String, Color) = switch item?.status {
        case .seen: ("Have it", accent)
        case .missing: ("Missing", AppTheme.warning)
        case .unsure: ("Check?", AppTheme.accentLight)
        case nil: ("—", AppTheme.secondary)
        }
        return Text(text + (item?.origin == .user ? " · you" : "")).font(.app(.footnote, .medium)).foregroundStyle(color)
    }

    private var stepCard: some View {
        let cooking = model.cooking
        return VStack(alignment: .leading, spacing: 14) {
            let total = max(cooking.plan?.steps.count ?? 1, 1)
            Button { showSteps = true } label: {
                HStack(spacing: 12) {
                    Eyebrow("Step \(cooking.currentStep + 1) of \(total)")
                    // The Gemma gradient as a thin progress line.
                    GeometryReader { bar in
                        Capsule().fill(AppTheme.outline)
                            .overlay(alignment: .leading) {
                                Capsule().fill(AppTheme.gradient).frame(width: bar.size.width * CGFloat(cooking.currentStep + 1) / CGFloat(total))
                            }
                    }.frame(height: 2)
                }
            }.buttonStyle(.plain).accessibilityLabel("Step \(cooking.currentStep + 1) of \(total). Show all steps")
            if let step = cooking.step {
                Text(step.title).font(.app(30, relativeTo: .title)).tracking(-0.6).foregroundStyle(textColor)
                Text(step.kind == .ask ? step.question : step.instruction).font(.app(.callout)).foregroundStyle(AppTheme.secondary)
                if !step.warning.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow("Heads up", color: AppTheme.warning)
                        Text(step.warning).font(.app(.subheadline)).foregroundStyle(textColor)
                    }.padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: 16))
                }
                if !step.tool.isEmpty { Text("Tool · \(step.tool)").font(.app(.footnote)).foregroundStyle(AppTheme.secondary) }
                if !cooking.unmetNeeds.isEmpty {
                    Text("Not done yet: \(cooking.unmetNeeds.map(\.title).joined(separator: ", "))").font(.app(.footnote)).foregroundStyle(AppTheme.warning)
                }
                if step.kind == .ask { AskAnswer(model: model) }
                if step.isGuarded {
                    Divider()
                    Label(cooking.salted ? "\(step.guardItem.capitalized) remembered · \(cooking.saltOrigin == .camera ? "Gemma observed" : "you confirmed")" : "\(step.guardItem.capitalized) not added yet", systemImage: cooking.salted ? "checkmark.circle.fill" : "circle")
                        .font(.app(.caption, .medium)).foregroundStyle(cooking.salted ? accent : textColor)
                    Label(cooking.zone == nil ? "Mark where the \(step.guardItem) is" : "Location marked by you · re-mark after moving it", systemImage: "scope").font(.app(.caption)).foregroundStyle(.secondary)
                    if model.usingGoPro {
                        Text("Moving GoPro view: fixed-location reach alerts are disabled. Gemma coaching remains available.").font(.app(.caption)).foregroundStyle(AppTheme.warning)
                    }
                    HStack {
                        Button(model.markSaltLocation ? "Cancel marking" : "Mark \(step.guardItem)") { model.markSaltLocation.toggle() }.buttonStyle(FrostedActionStyle())
                        if !cooking.salted { Button("I added it") { model.confirmSalt() }.buttonStyle(FrostedActionStyle()) }
                        else { Button("Allow more") { model.cooking.allowMoreSalt() }.buttonStyle(FrostedActionStyle()) }
                    }.font(.app(.caption, .medium)).disabled(model.usingGoPro)
                }
                if step.kind == .do {
                    let finished = cooking.isLastStep && cooking.done.contains(step.id)
                    Button(finished ? "Dish finished" : cooking.suggestedCompletion ? "Confirm step complete" : cooking.isLastStep ? "Finish" : "Next step", systemImage: "arrow.right") { model.nextStep() }
                        .buttonStyle(FrostedActionStyle()).disabled(finished)
                }
            }
            if !cooking.preferences.isEmpty {
                Text("You said · " + cooking.preferences.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }
        }.appCard()
    }
}

/// The big bottom button does the one thing the current phase needs.
struct PrimaryAction: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceInput
    let openBrain: () -> Void
    var compact = false
    var body: some View {
        let phase = model.cooking.phase
        let asking = phase == .cooking && model.cooking.step?.kind == .ask
        let title: String =
            !model.isLoaded ? (model.isLoading ? "Loading Gemma…" : "Set up Remy")
            : phase == .ingredients ? (model.readyToCook ? "Start cooking" : "Check ingredients")
            : phase == .cooking && model.cooking.isComplete ? "All done"
            : phase == .needsDish ? "Plan ingredients"
            : model.frame == nil ? "Open camera"
            : asking && model.handsFree ? "Just say your answer"
            : asking ? (voice.isRecording ? "Done talking" : "Answer out loud")
            : model.cooking.isLastStep ? "Finish" : "Next step"
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if !model.isLoaded { openBrain() }
            else if phase == .ingredients {
                if model.readyToCook { model.beginCooking() }
                else { Task { await model.checkIngredients() } }
            }
            else if phase == .needsDish { Task { await model.planDish() } }
            else if model.frame == nil { model.startPhoneCamera() }
            else if asking && model.handsFree { }
            else if asking { Task { await model.toggleListening() } }
            else { model.nextStep() }
        } label: {
            if compact {
                Text(!model.isLoaded ? "Set up Remy" : title)
                    .lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 12)
            } else {
                Text(title).frame(maxWidth: .infinity)
            }
        }
        .primaryActionStyle(compact: compact)
        .accessibilityLabel(title)
        .disabled(model.isLoading
                  || (model.cooking.isComplete)
                  || ((phase == .needsDish || asking) && model.isBusy && !voice.isRecording)
                  || (phase == .needsDish && model.isLoaded && model.dishRequest.trimmingCharacters(in: .whitespaces).isEmpty))
    }
}

/// Hands-free status: the cook can see the chef is listening and what it understood.
struct ListeningBadge: View {
    @ObservedObject var listener: HandsFreeListener
    let lastHeard: String
    let understanding: Bool
    var seconds: Double? = nil
    var body: some View {
        let mode = VoiceOrb.Mode(listener: listener, thinking: understanding)
        HStack(spacing: 8) {
            VoiceOrb(mode: mode)
            if !lastHeard.isEmpty && mode != .hearing {
                Text("“\(lastHeard)”").font(.app(.footnote)).foregroundStyle(AppTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let seconds { GemmaTime(seconds: seconds) }
        }
        .accessibilityElement(children: .combine).accessibilityLabel(mode.label)
    }
}

struct MicButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceInput
    let label: String
    var body: some View {
        if !model.handsFree { tapButton }
    }
    private var tapButton: some View {
        Button(voice.isRecording ? "Done" : label, systemImage: voice.isRecording ? "stop.circle.fill" : "mic.fill") {
            Task { await model.toggleListening() }
        }
        .buttonStyle(FrostedActionStyle()).tint(voice.isRecording ? .red : nil)
        .disabled(!model.isLoaded || (model.isBusy && !voice.isRecording))
    }
}

/// Answer an ask step by voice, or type it.
struct AskAnswer: View {
    @ObservedObject var model: AppModel
    @State private var typed = ""
    var body: some View {
        HStack {
            MicButton(model: model, voice: model.voice, label: "Answer")
            TextField("or type it", text: $typed).textFieldStyle(.roundedBorder).submitLabel(.done)
                .onSubmit { model.answerTyped(typed); typed = "" }
            Button("Save") { model.answerTyped(typed); typed = "" }.disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }.font(.app(.caption, .medium))
    }
}

struct GoProSetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var source: GoProSource
    @ObservedObject var bluetooth: GoProBluetooth
    @Environment(\.dismiss) private var dismiss
    @State private var showWiFiPassword = false
    var body: some View {
        NavigationStack {
            Form {
                AppSection("HERO12 Black · experimental input") {
                    Picker("Connection", selection: $source.wiredMode) {
                        Text("USB cable").tag(true)
                        Text("Wi-Fi").tag(false)
                    }.pickerStyle(.segmented).disabled(source.running || source.connecting)
                    if source.wiredMode {
                        Text("Power on the HERO12, stop recording, and connect it directly with a USB-C data cable. Keep its battery installed and this screen open.").font(.app(.subheadline))
                        TextField("Last 3 serial-number digits", text: $source.serialSuffix).keyboardType(.numberPad)
                            .disabled(source.running || source.connecting)
                            .onChange(of: source.serialSuffix) { _, _ in source.useSerialAddress() }
                        LabeledContent("USB camera address", value: source.host.isEmpty ? "Enter 3 digits above" : source.host)
                            .font(.app(.caption))
                        Text("USB mode blocks Wi-Fi and cellular for camera control and video. Direct iPhone USB compatibility is being tested.").font(.app(.caption)).foregroundStyle(.secondary)
                    } else {
                        Text("Join the GoPro Wi-Fi network first. This mode is a manual fallback; the app never switches automatically.").font(.app(.subheadline))
                    }
                    DisclosureGroup("Advanced camera address") {
                        TextField("Camera IPv4 address", text: $source.host).keyboardType(.decimalPad).autocorrectionDisabled()
                            .disabled(source.running || source.connecting)
                    }
                }
                if !source.wiredMode {
                    AppSection("1 · Pair and enable camera Wi-Fi") {
                        Text(bluetooth.status)
                        Button(bluetooth.scanning ? "Searching…" : "Find GoPro over Bluetooth") {
                            bluetooth.scan(targetSuffix: source.serialSuffix)
                        }.disabled(bluetooth.scanning || bluetooth.connecting || bluetooth.connected)
                        ForEach(bluetooth.cameras) { camera in
                            Button(camera.name) { bluetooth.connect(camera) }.disabled(bluetooth.connecting || bluetooth.connected)
                        }
                        if let error = bluetooth.error { Text(error).font(.app(.caption)).foregroundStyle(AppTheme.warning) }
                        if bluetooth.connected || bluetooth.connecting { Button("Disconnect Bluetooth") { bluetooth.disconnect() } }
                    }
                    if !bluetooth.ssid.isEmpty {
                        AppSection("2 · Join the GoPro network") {
                            LabeledContent("Wi-Fi network", value: bluetooth.ssid).textSelection(.enabled)
                            if showWiFiPassword { Text(bluetooth.password).font(.app(.body)).textSelection(.enabled) }
                            Button(showWiFiPassword ? "Hide camera password" : "Show camera password") { showWiFiPassword.toggle() }
                            Text("On this iPhone, open Settings → Wi-Fi and join the camera network above. Return to Remy and tap Connect over Wi-Fi. Keep USB connected to the Mac during this test.").font(.app(.subheadline))
                            Text("No internet connection on the camera network is expected. Gemma remains on this phone.").font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                AppSection("Connection evidence") {
                    Text(source.status)
                    if source.wiredMode {
                        Label(source.wiredStatus, systemImage: source.wiredAvailable ? "cable.connector" : "cable.connector.slash")
                            .font(.app(.caption)).foregroundStyle(source.wiredAvailable ? accent : AppTheme.secondary)
                    } else {
                        Text(source.cameraSubnetStatus).font(.app(.caption)).foregroundStyle(.secondary)
                    }
                    LabeledContent("Camera control", value: source.connected ? "HERO12 reached" : "Not reached yet")
                    LabeledContent("Preview packets", value: String(source.packets))
                    LabeledContent("Decoded frames", value: String(source.frames))
                    if let error = source.error { Text(error).foregroundStyle(AppTheme.warning).font(.app(.caption)) }
                    Button(source.connecting ? "Connecting…" : source.running ? "Preview running" : source.wiredMode ? "Connect wired GoPro" : "Connect over Wi-Fi") {
                        Task { await model.startGoPro() }
                    }.disabled(source.running || source.connecting || !GoProAddress.isLocalIPv4(source.host))
                    Button("Test camera control only") { Task { await source.probe() } }.disabled(source.running || source.connecting || !GoProAddress.isLocalIPv4(source.host))
                    if source.running || source.connecting { Button("Stop GoPro preview", role: .destructive) { model.pause() } }
                    Button("Use iPhone camera") { model.startPhoneCamera(); dismiss() }
                }
                AppSection("Connection log") {
                    ForEach(Array(source.events.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.app(.caption)).textSelection(.enabled)
                    }
                    ShareLink("Export connection diagnostics", item: source.diagnosticsURL)
                        .simultaneousGesture(TapGesture().onEnded { _ = source.exportDiagnostics() })
                    Text("Diagnostics contain connection status and counters, not camera images.").font(.app(.caption)).foregroundStyle(.secondary)
                }
                AppSection("Egocentric mode") {
                    Text("Gemma processes the GoPro frames on this iPhone. The moving view disables fixed-location reach alerts. GoPro’s preview adds transport delay, so phone-camera warning timings do not apply.").font(.app(.subheadline))
                    if let frame = model.frame, model.usingGoPro {
                        LiveVideoPreview(frames: source.videoFrames)
                            .aspectRatio(frame.image.size.width / frame.image.size.height, contentMode: .fit)
                    }
                }
            }.appScreen().navigationTitle("GoPro input").toolbar { Button("Done") { dismiss() } }
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = model.camera.isRunning }
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--gopro-wireless-setup") else { return }
                    source.wiredMode = false
                    bluetooth.scan(targetSuffix: source.serialSuffix, automaticallyConnect: true)
                }
        }.tint(accent)
    }
}

private func displayRect(imageRatio: CGFloat, size: CGSize, fill: Bool) -> CGRect {
    let width = fill ? max(size.width, size.height * imageRatio) : min(size.width, size.height * imageRatio)
    let height = width / imageRatio
    return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
}

/// Settings: how the chef listens and watches, the camera source, the local model, and the session.
struct BrainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var showGoPro = false
    @State private var showEvidence = false
    @State private var confirmReset = false
    @AppStorage(GlassStyle.storageKey) private var glass = GlassStyle.dark
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Hands-free voice", isOn: $model.handsFree)
                    Toggle("Watch the board automatically", isOn: $model.automaticChecks).disabled(!model.isLoaded)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Object boxes", isOn: $model.showObjectBoxes)
                        Text("Shows everyday object detections independently of safety monitoring.")
                            .font(.app(.footnote)).foregroundStyle(AppTheme.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Core ML detector", isOn: $model.coreMLDetector).disabled(!model.coreMLDetectorAvailable)
                        Text(model.coreMLDetectorAvailable
                             ? "YOLOX-M on Core ML instead of EfficientDet-Lite0 on LiteRT. Off keeps all three models on LiteRT."
                             : "YOLOX-M is not in this build; EfficientDet-Lite0 runs on LiteRT.")
                            .font(.app(.footnote)).foregroundStyle(AppTheme.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Safety box & alerts", isOn: $model.safetyBoxesEnabled)
                        Text("Watches the cooker while cooking. Say “I turned the kettle off” to pause, or “I turned it back on” to resume.")
                            .font(.app(.footnote)).foregroundStyle(AppTheme.secondary)
                    }
                    Toggle("Spoken responses", isOn: $model.voiceEnabled)
                    Toggle("Short recipes (up to 5 steps)", isOn: $model.shortRecipes)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Pasta-salad demo preset", isOn: $model.demoPreset)
                        Text("“Make pasta salad” uses the fixed five ingredients and three app-written steps. Off, Gemma plans every dish.")
                            .font(.app(.footnote)).foregroundStyle(AppTheme.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Hand gestures", isOn: $model.gesturesEnabled)
                        Text("Thumbs up: next. Thumbs down: back. Open palm (hold): quiet.")
                            .font(.app(.footnote)).foregroundStyle(AppTheme.secondary)
                    }
                } header: { Eyebrow("Remy") }
                Section {
                    Picker("Camera", selection: Binding(
                        get: { model.usingGoPro ? "gopro" : "iphone" },
                        set: { $0 == "gopro" ? (showGoPro = true) : model.startPhoneCamera() })) {
                        Text("iPhone").tag("iphone")
                        Text("GoPro HERO12").tag("gopro")
                    }.pickerStyle(.menu)
                    if model.usingGoPro { Button("GoPro connection") { showGoPro = true } }
                } header: { Eyebrow("Camera") }
                Section {
                    Picker("Controls over the video", selection: $glass) {
                        Text("Dark glass").tag(GlassStyle.dark)
                        Text("Light glass").tag(GlassStyle.light)
                    }.pickerStyle(.menu)
                } header: { Eyebrow("Look") }
                Section {
                    LabeledContent("Model", value: store.modelURL == nil ? store.status : "Gemma 4 E2B")
                    if store.isWorking { ProgressView(value: store.progress) { Text("\(Int(store.progress * 100))% of 2.59 GB") } }
                    if store.modelURL == nil {
                        Button("Download on Wi-Fi") { store.download() }.disabled(store.isWorking)
                        Button("Import downloaded model") { importing = true }.disabled(store.isWorking)
                        if store.isWorking { Button("Cancel download", role: .destructive) { store.cancelDownload() } }
                    }
                    Toggle("Metal GPU acceleration", isOn: $model.useGPU).disabled(model.isLoaded || model.isLoading)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Schema-constrained decoding", isOn: $model.constrainedDecoding)
                        Text("LiteRT enforces the JSON schema token by token. Off, the schema is only described in the prompt (default, after a native crash seen on one iPhone).")
                            .font(.app(.footnote)).foregroundStyle(AppTheme.secondary)
                    }
                    #if DEBUG
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Speculative decoding (timing test)", isOn: $model.speculativeChat).disabled(!model.isLoaded || model.isLoading)
                        Text("Plan and chat only. Camera and answer checks fail while it is on; turning it off reloads Gemma.")
                            .font(.app(.footnote)).foregroundStyle(AppTheme.secondary)
                    }
                    #endif
                    if model.isLoaded {
                        LabeledContent("Running on", value: model.backend)
                    } else {
                        Button(model.isLoading ? "Loading Gemma…" : "Load Gemma") { Task { await model.loadModel() } }
                            .disabled(store.modelURL == nil || model.isLoading || store.isWorking)
                    }
                    if let error = store.error ?? model.userFacingError { Text(error).foregroundStyle(AppTheme.warning) }
                } header: { Eyebrow("Gemma on this iPhone") }

                Section {
                    Button("Evidence") { showEvidence = true }
                    Button("Run local text test") { Task { await model.smokeTest(withCamera: false) } }.disabled(!model.isLoaded || model.isBusy)
                    Button("Describe the live camera image") {
                        if model.frame == nil { model.startPhoneCamera() } else { Task { await model.smokeTest(withCamera: true) } }
                    }.disabled(!model.isLoaded || model.isBusy)
                    if model.smokePassed { Text("Local test passed").foregroundStyle(accent) }
                    if !model.rawResponse.isEmpty { Text(model.rawResponse).font(.app(.footnote)).foregroundStyle(AppTheme.secondary).lineLimit(4) }
                    Button("Reset recipe and memory", role: .destructive) { confirmReset = true }
                } header: { Eyebrow("Session") }
            }
            .appScreen().font(.app(.body)).listRowBackground(AppTheme.surface)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .sheet(isPresented: $showGoPro) { GoProSetupView(model: model, source: model.goPro, bluetooth: model.goProBluetooth) }
            .sheet(isPresented: $showEvidence) { EvidenceView(model: model) }
            .confirmationDialog("Start a fresh session?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset recipe and memory", role: .destructive) { model.reset(); dismiss() }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { Task { await store.importFile(url) } }
                else if case .failure(let error) = result { store.error = error.localizedDescription }
            }
        }.tint(accent)
    }
}

/// What actually ran: backend, detector, honest limits, session events and the last raw Gemma reply.
struct EvidenceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var speed: String?
    var body: some View {
        NavigationStack {
            List {
                AppSection("What is actually running") {
                    LabeledContent("Gemma", value: model.isLoaded ? "Gemma 4 E2B · LiteRT-LM · \(model.backend)" : "Not loaded")
                    if let speed { Text("Last call: \(speed)").font(.app(.footnote)).monospacedDigit() }
                    LabeledContent("Image tokens", value: "140 per image")
                    LabeledContent("Structured output", value: model.constrainedDecoding
                                   ? "LiteRT schema-constrained decoding, then validation"
                                   : "JSON parsing and validation; schema-constrained decoding off")
                    LabeledContent("Function calling", value: "16 tools, the app runs each call")
                    LabeledContent("Reflex latency", value: model.lastReflexMS.map { String(format: "%.0f ms, frame to alarm", $0) } ?? "not measured yet")
                    LabeledContent("Audio in", value: "Gemma hears answers to its questions")
                    LabeledContent("Speculative decoding", value: model.speculativeChat ? "on (timing test)" : "off")
                    LabeledContent("Hands", value: "MediaPipe gesture recognizer · LiteRT · CPU")
                    LabeledContent("Object detector", value: model.detectorName + (model.detectorMS.map { String(format: " · %.0f ms", $0) } ?? ""))
                    LabeledContent("Network path", value: model.networkAvailable ? "Available" : "Unavailable")
                    Text("Network availability is not proof of airplane mode. Inference uses local files; only model download uses the internet.").font(.app(.caption))
                    Toggle("Experimental finger-curl hints", isOn: $model.gripHints)
                    Text("Finger-curl hints do not detect the blade or establish a safe grip.").font(.app(.caption))
                }
                AppSection("Honest limits") {
                    Text("Gemma 4 E2B is a 2B model. It confuses look-alikes (a red pepper for a tomato), can't count reliably, and names things that aren't there when asked an open question. So boxes are the evidence, knives are found by size, the cook's word beats the camera, and alarms come from geometry, not the model. Remy doesn't measure temperature or promise to prevent injuries.")
                        .font(.app(.footnote))
                }
                AppSection("Session events") {
                    ForEach(model.cooking.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.message).font(.app(.subheadline))
                            Text("\(event.origin.rawValue.uppercased()) · \(event.timestamp.formatted(date: .omitted, time: .standard))").font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                AppSection("Last raw Gemma response") { Text(model.rawResponse.isEmpty ? "No response yet" : model.rawResponse).font(.app(.caption)).textSelection(.enabled) }
                if let url = model.receiptURL { ShareLink("Export inference receipt", item: url) }
            }.appScreen().navigationTitle("Evidence").toolbar { Button("Done") { dismiss() } }
                .task { speed = await model.gemmaSpeed() }
        }.tint(accent)
    }

}
