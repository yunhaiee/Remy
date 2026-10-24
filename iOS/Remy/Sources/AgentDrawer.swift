import SwiftUI
import RemyCore

/// A drawer on the left edge that slides over the video and shows Gemma's work live: what the chef heard, each
/// turn and tool call as it runs, what the camera checks saw, the plan streaming in, reflex alarms. Closed, it is
/// a slim tab.
struct AgentDrawer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var activity: AgentActivity
    @Binding var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The log keeps to what Gemma does; the chef's spoken lines are already in the pill, and system lines are noise.
    private var shown: [AgentActivity.Entry] { activity.entries.filter { $0.kind != .says && $0.kind != .system } }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if open {
                panel
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 14)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                open.toggle()
            } label: {
                Image(systemName: open ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 64)
                    .frostedGlass(in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide Gemma's work" : "Show Gemma's work")
        }
        .padding(.leading, 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: open)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Gemma · live", color: AppTheme.accentLight)
            Text("Gemma 4 E2B · LiteRT-LM · \(model.backend.contains("Metal") ? "Metal GPU" : model.backend)")
                .font(.app(11)).foregroundStyle(AppTheme.secondary).lineLimit(1)
            Rectangle().fill(AppTheme.outline).frame(height: 1)
            if shown.isEmpty {
                Text("Say “Chef…” and the work shows up here as it happens.").font(.app(.footnote)).foregroundStyle(AppTheme.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(shown) { entry in row(entry).id(entry.id) }
                        }
                        .padding(.bottom, 4)
                    }
                    .onAppear { if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: activity.entries.count) { _, _ in
                        guard let last = shown.last else { return }
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(16)
        .foregroundStyle(AppTheme.text)
        .frostedGlass(in: RoundedRectangle(cornerRadius: 22), interactive: false, frosted: true)
    }

    private func row(_ entry: AgentActivity.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            dot(entry).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.kind.label.uppercased()).font(.app(9, .medium)).tracking(1.2).foregroundStyle(color(entry))
                    Spacer(minLength: 6)
                    if let ms = entry.ms {
                        Text(ms >= 1000 ? String(format: "%.1f s", ms / 1000) : String(format: "%.0f ms", ms))
                            .font(.app(10)).monospacedDigit().foregroundStyle(AppTheme.secondary)
                    } else if entry.state == .running {
                        Text("running").font(.app(10)).foregroundStyle(AppTheme.accentLight)
                    }
                }
                Text(entry.title).font(.app(13, .medium)).lineLimit(2)
                if !entry.detail.isEmpty {
                    Text(entry.detail).font(.app(12)).foregroundStyle(AppTheme.secondary).lineLimit(3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func color(_ entry: AgentActivity.Entry) -> Color {
        switch (entry.state, entry.kind) {
        case (.failed, _): AppTheme.warning
        case (_, .reflex): AppTheme.warning
        case (_, .tool), (_, .plan): AppTheme.accentLight
        case (_, .heard), (_, .gesture): AppTheme.accent
        default: AppTheme.secondary
        }
    }

    @ViewBuilder private func dot(_ entry: AgentActivity.Entry) -> some View {
        if entry.state == .running {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
                let phase = (sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 0.9) + 1) / 2
                Circle().fill(AppTheme.accent).opacity(reduceMotion ? 1 : 0.35 + 0.65 * phase)
                    .shadow(color: AppTheme.accent.opacity(0.6 * phase), radius: 4)
            }
        } else {
            Circle().fill(color(entry)).opacity(entry.kind == .reflex || entry.state == .failed ? 1 : 0.55)
        }
    }
}

/// Shown over the paused camera while Gemma writes the recipe: the ingredients and steps as they stream in.
struct PlanningCard: View {
    let dish: String
    let preview: PlanPreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VoiceOrb(mode: .thinking)
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow("Gemma is writing the recipe", color: AppTheme.accentLight)
                    Text(dish.capitalized).font(.app(22, .medium)).foregroundStyle(AppTheme.text)
                }
            }
            if let preview, !preview.ingredients.isEmpty {
                Text(preview.ingredients.map(\.name).joined(separator: " · "))
                    .font(.app(.subheadline)).foregroundStyle(AppTheme.text).lineLimit(2)
            } else {
                Text("Choosing the ingredients…").font(.app(.subheadline)).foregroundStyle(AppTheme.secondary)
            }
            if let preview, !preview.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(preview.steps.suffix(5).enumerated()), id: \.offset) { offset, step in
                        let index = preview.steps.count - min(5, preview.steps.count) + offset + 1
                        Text("\(String(format: "%02d", index))  \(step.kind == .ask ? "Ask · " : "")\(step.title)")
                            .font(.app(12)).monospacedDigit().foregroundStyle(AppTheme.secondary)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .frostedGlass(in: RoundedRectangle(cornerRadius: 22), interactive: false, frosted: true)
    }
}
