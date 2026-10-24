import SwiftUI
import UIKit

/// The visible circles stay separate from their larger, invisible touch targets.
struct GlassControlDock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceInput
    @ObservedObject var listener: HandsFreeListener
    let openBrain: () -> Void
    let toggleActivity: () -> Void
    var activityOpen = false
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        HStack(spacing: LandscapeChrome.controlGap) {
            Button {
                tapFeedback()
                model.toggleVideo()
            } label: {
                symbol(model.videoEnabled ? "video.fill" : "video.slash.fill")
            }
            .accessibilityLabel(model.videoEnabled ? "Turn video off" : "Turn video on")
            .accessibilityValue(model.videoEnabled ? model.frame == nil ? "Starting video" : "Video on" : "Video off")

            Button {
                tapFeedback()
                if !model.isLoaded { openBrain(); return }
                // Hands-free: the always-on microphone is the input; this button turns it on and off.
                if model.handsFree || listener.isOn { model.handsFree.toggle(); return }
                if model.isBusy && !voice.isRecording {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    return
                }
                Task { await model.toggleListening() }
            } label: {
                symbol(listener.isOn ? listener.hearing ? "waveform" : "mic.fill" : voice.isRecording ? "mic.fill" : "mic.slash.fill")
            }
            .accessibilityLabel(voice.isStarting ? "Cancel microphone startup" : voice.isRecording ? "Send voice message" : model.isLoaded ? "Talk to Remy" : "Set up Remy")
            .accessibilityValue(listener.isOn ? listener.hearing ? "Hearing you" : "Listening for Chef" : voice.isStarting ? "Starting microphone" : voice.isRecording ? "Listening" : model.audio.isSpeaking ? "Remy speaking" : model.isBusy ? "Remy thinking" : "Ready")

            Button {
                tapFeedback()
                toggleActivity()
            } label: {
                symbol("sparkles")
            }
            .accessibilityLabel(activityOpen ? "Hide Gemma's work" : "Show Gemma's work")
        }
        .buttonStyle(FrostedControlStyle())
        .onAppear { haptic.prepare() }
    }

    private func symbol(_ name: String, crossed: Bool = false) -> some View {
        Image(systemName: name)
            .overlay {
                if crossed {
                    Path { path in
                        path.move(to: CGPoint(x: 1, y: 1)); path.addLine(to: CGPoint(x: 21, y: 21))
                    }
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 22, height: 22)
                }
            }
            .font(.system(size: 15.75, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: LandscapeChrome.controlDiameter, height: LandscapeChrome.controlDiameter)
            .fixedSize()
    }

    private func tapFeedback() {
        haptic.impactOccurred(intensity: 0.8)
        haptic.prepare()
    }
}

struct FrostedControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: LandscapeChrome.controlDiameter, height: LandscapeChrome.controlDiameter)
            .fixedSize()
            .frostedGlass(in: Circle())
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.12), value: configuration.isPressed)
            .frame(width: LandscapeChrome.touchSize, height: LandscapeChrome.touchSize)
            .contentShape(Rectangle())
    }
}

/// The material of everything floating over the video (voice pill, round controls), chosen in Settings.
/// Dark glass is the default: it stays readable over a bright counter.
enum GlassStyle: String, CaseIterable {
    case dark, light
    static let storageKey = "glassStyle"
}

/// Liquid Glass over the live video, so it stays visible through every control; dark or light per Settings.
private struct FrostedGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let enabled: Bool
    let frosted: Bool
    let accented: Bool
    @AppStorage(GlassStyle.storageKey) private var style = GlassStyle.dark

    @ViewBuilder func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(iOS 26.0, *) {
            let glass: Glass = style == .dark
                ? Glass.regular.tint(AppTheme.background.opacity(0.55))
                : (frosted ? Glass.regular : Glass.clear).tint(.white.opacity(accented ? 0.12 : 0.06))
            content.glassEffect(glass.interactive(interactive), in: shape)
        } else if style == .dark {
            content
                .background { shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark) }
                .background { shape.fill(AppTheme.background.opacity(0.45)) }
                .overlay { shape.stroke(AppTheme.outline, lineWidth: 1) }
        } else {
            content
                .background { shape.fill(.ultraThinMaterial).environment(\.colorScheme, .light).opacity(0.35) }
                .overlay { shape.stroke(.white.opacity(0.32), lineWidth: 1) }
        }
    }
}

extension View {
    func frostedGlass<S: Shape>(in shape: S, interactive: Bool = true, enabled: Bool = true, frosted: Bool = false, accented: Bool = false) -> some View {
        modifier(FrostedGlassSurface(shape: shape, interactive: interactive, enabled: enabled, frosted: frosted, accented: accented))
    }

    @ViewBuilder func primaryActionStyle(compact: Bool) -> some View {
        if compact { buttonStyle(BottomActionStyle()) }
        else { buttonStyle(GradientActionStyle()) }
    }

    func appCard() -> some View {
        padding(18).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    func appScreen() -> some View {
        tint(AppTheme.accent).foregroundStyle(AppTheme.text)
            .scrollContentBackground(.hidden)
            .font(.app(.body))
            .background { AppTheme.wallpaper.ignoresSafeArea() }
            .buttonStyle(FrostedActionStyle()).groupBoxStyle(AppGroupBoxStyle())
    }

}

struct FrostedActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(.subheadline, .medium)).foregroundStyle(configuration.role == .destructive ? Color.red : AppTheme.text)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(minHeight: 44)
            .overlay { Capsule().stroke(AppTheme.outlineStrong, lineWidth: 1) }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.12), value: configuration.isPressed)
    }
}

/// The one thing to do next: the Gemma blue gradient, white text.
struct GradientActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(.callout, .medium)).foregroundStyle(.white)
            .padding(.horizontal, 22).frame(minHeight: 52)
            .background(AppTheme.gradient, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.12), value: configuration.isPressed)
    }
}

struct FrostedGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else { content }
    }
}

/// Shared measurements keep the two bottom docks visually balanced.
enum LandscapeChrome {
    static let controlDiameter: CGFloat = 58 * 0.75
    static let touchSize: CGFloat = 54
    static let controlGap: CGFloat = 6
    static let dockWidth = touchSize * 3 + controlGap * 2
    static let pillWidth = dockWidth - (touchSize - controlDiameter)
}

/// The chef's voice over the camera: a floating pill with a blue orb and the chef's current line. While the
/// hands-free microphone is on, the pill also says what it is doing (listening, hearing you, thinking).
struct LandscapeGuidanceHeader: View {
    let text: String
    @ObservedObject var listener: HandsFreeListener
    let thinking: Bool
    /// How long Gemma's last answer took, shown small after the line.
    var seconds: Double? = nil
    /// While a reflex alarm is showing: how fast the alarm came after the camera frame. It replaces the Gemma time.
    var reflexMS: Double? = nil
    let openSession: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var visibleText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Ready when you are." : trimmed
    }
    private var mode: VoiceOrb.Mode { reflexMS == nil ? .init(listener: listener, thinking: thinking) : .alert }
    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            openSession()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VoiceOrb(mode: mode)
                Text(visibleText)
                    .font(.app(17, relativeTo: .headline)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 6)
                    .multilineTextAlignment(.leading).lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if let reflexMS {
                    Text(String(format: "Reflex %.0f ms", reflexMS)).font(.app(12, .medium)).monospacedDigit()
                        .foregroundStyle(AppTheme.warning).fixedSize()
                        .accessibilityLabel(String(format: "Reflex alarm in %.0f milliseconds", reflexMS))
                } else if let seconds { GemmaTime(seconds: seconds) }
            }
            .padding(.leading, 12).padding(.trailing, 22).padding(.vertical, 10)
            .frame(maxWidth: 600)
            .frostedGlass(in: Capsule(), interactive: false, frosted: true)
            .overlay { Capsule().stroke(reflexMS == nil ? Color.clear : AppTheme.warning, lineWidth: 1.5) }
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            .geometryGroup()
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: visibleText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remy guidance")
        .accessibilityValue("\(mode.label). \(visibleText)")
        .accessibilityHint("Opens the full session")
    }
}

/// "0.6 s": how long Gemma's last answer took.
struct GemmaTime: View {
    let seconds: Double
    var body: some View {
        Text(String(format: "%.1f s", seconds)).font(.app(12, .medium)).monospacedDigit()
            .foregroundStyle(AppTheme.secondary).fixedSize()
            .accessibilityLabel(String(format: "Gemma answered in %.1f seconds", seconds))
    }
}

/// The Gemma sparkle in the Gemma blue, showing the chef's state by motion instead of words: dim and still when
/// the microphone is off, slowly turning and breathing while listening, turning faster with a pulse while it hears
/// you, spinning while it thinks, and glowing while it speaks.
struct VoiceOrb: View {
    enum Mode: Equatable { case off, listening, hearing, thinking, speaking, alert }
    let mode: Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: mode == .off || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let wave = { (period: Double) in (sin(t * 2 * .pi / period) + 1) / 2 }
            let (angle, glow, scale): (Double, Double, Double) = switch mode {
            case .off: (0, 0, 1)
            case .listening: ((t * 30).truncatingRemainder(dividingBy: 360), 0.35 + 0.45 * wave(2.0), 1 + 0.06 * wave(2.0))
            case .hearing: ((t * 90).truncatingRemainder(dividingBy: 360), 0.7 + 0.3 * wave(0.5), 1 + 0.15 * wave(0.5))
            case .thinking: ((t * 300).truncatingRemainder(dividingBy: 360), 0.8, 1)
            case .speaking: (0, 0.6 + 0.4 * wave(0.4), 1 + 0.1 * wave(0.4))
            case .alert: (0, 1, 1 + 0.14 * wave(0.3))
            }
            Sparkle()
                .stroke(mode == .alert ? AnyShapeStyle(AppTheme.warning) : AnyShapeStyle(AppTheme.gradient),
                        style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                .frame(width: 22, height: 22)
                // Turns around the vertical axis, like a coin spinning in place.
                .rotation3DEffect(.degrees(reduceMotion ? 0 : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .scaleEffect(reduceMotion ? 1 : scale)
                .shadow(color: (mode == .alert ? AppTheme.warning : AppTheme.accent).opacity(glow), radius: 4 + 12 * glow)
                .shadow(color: AppTheme.accentLight.opacity(glow * 0.6), radius: 2)
                .opacity(mode == .off ? 0.45 : 1)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

extension VoiceOrb.Mode {
    init(listener: HandsFreeListener, thinking: Bool) {
        self = !listener.isOn ? .off : listener.chefTalking ? .speaking : listener.hearing ? .hearing : thinking ? .thinking : .listening
    }
    var label: String {
        switch self {
        case .off: "Microphone off"
        case .listening: "Listening for Chef"
        case .hearing: "Hearing you"
        case .thinking: "Thinking"
        case .speaking: "Remy speaking"
        case .alert: "Reflex alarm"
        }
    }
}

/// Four points joined by curves that bow toward the centre.
struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let points = [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                      CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
        var path = Path()
        path.move(to: points[0])
        for index in 1...4 { path.addQuadCurve(to: points[index % 4], control: c) }
        path.closeSubpath()
        return path
    }
}

struct LandscapeSessionButton: View {
    let openSession: () -> Void
    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            openSession()
        } label: {
            Text("Session")
                .font(.app(14, .medium))
                .foregroundStyle(.white)
                .frame(width: LandscapeChrome.touchSize * 2 + LandscapeChrome.controlGap - (LandscapeChrome.touchSize - LandscapeChrome.controlDiameter),
                       height: LandscapeChrome.controlDiameter)
                .frostedGlass(in: Capsule())
                .frame(width: LandscapeChrome.touchSize * 2 + LandscapeChrome.controlGap,
                       height: LandscapeChrome.touchSize)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct BottomActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(14, .medium)).foregroundStyle(.white)
            .frame(width: LandscapeChrome.pillWidth, height: LandscapeChrome.controlDiameter)
            .background(AppTheme.gradient, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.12), value: configuration.isPressed)
            .frame(width: LandscapeChrome.dockWidth, height: LandscapeChrome.touchSize)
            .contentShape(Rectangle())
    }
}

/// Shared visual tokens for every native screen, taken from the Gemma site (deepmind.google): near-black surfaces,
/// off-white text, one blue gradient used sparingly (primary action, progress, the chef's voice).
enum AppTheme {
    static let accent = Color(hex: 0x2E96FF)
    static let accentLight = Color(hex: 0xACB7FF)
    static let text = Color(hex: 0xF8F9FC)
    static let secondary = Color(hex: 0xB2BBC5)
    static let background = Color(hex: 0x121317)
    static let surface = Color(hex: 0x18191D)
    static let surfaceHigh = Color(hex: 0x212226)
    static let outline = Color(hex: 0xE6EAF0).opacity(0.12)
    static let outlineStrong = Color(hex: 0xE6EAF0).opacity(0.24)
    static let warning = Color(hex: 0xFFA552)
    static let gradient = LinearGradient(stops: [.init(color: Color(hex: 0x3B6BFF), location: 0), .init(color: Color(hex: 0x2E96FF), location: 0.65),
                                                 .init(color: Color(hex: 0xACB7FF), location: 1)], startPoint: .leading, endPoint: .trailing)
    static let wallpaper = background
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    /// Google Sans Flex (bundled, SIL Open Font License), the Gemma site's typeface. Scales with Dynamic Type.
    static func app(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let face = [.bold, .heavy, .black].contains(weight) ? "Bold" : [.medium, .semibold].contains(weight) ? "Medium" : "Regular"
        return .custom("GoogleSansFlex-\(face)", size: size, relativeTo: style)
    }
    static func app(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        let size: CGFloat = switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        default: 11
        }
        return app(size, weight, relativeTo: style)
    }
}

/// Small spaced capitals above a title ("STEP 3 OF 9"), as on the Gemma site.
struct Eyebrow: View {
    let text: String
    var color = AppTheme.secondary
    init(_ text: String, color: Color = AppTheme.secondary) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.app(11, .medium, relativeTo: .caption2)).tracking(1.5).foregroundStyle(color)
    }
}

struct AppGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.app(.headline, .medium))
            configuration.content
        }.frame(maxWidth: .infinity, alignment: .leading).appCard()
    }
}

struct AppSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        Section { content } header: {
            Text(title).font(.app(.subheadline, .medium)).foregroundStyle(AppTheme.accent).textCase(nil)
        }.listRowBackground(AppTheme.surface.opacity(0.82))
    }
}
