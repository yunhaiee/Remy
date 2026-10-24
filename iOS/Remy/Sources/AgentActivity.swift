import Foundation

/// Gemma's work as it happens, for the live drawer: what it heard, each tool call with its timing and result,
/// vision checks, the plan streaming in, reflex alarms with their latency. Entries are kept in memory only.
@MainActor final class AgentActivity: ObservableObject {
    enum Kind: String {
        case heard, thinking, tool, vision, plan, reflex, gesture, says, system
        var label: String {
            switch self {
            case .heard: "Heard"
            case .thinking: "Gemma"
            case .tool: "Tool"
            case .vision: "Vision"
            case .plan: "Plan"
            case .reflex: "Reflex"
            case .gesture: "Gesture"
            case .says: "Remy says"
            case .system: "System"
            }
        }
    }
    enum State { case running, done, failed }
    struct Entry: Identifiable {
        let id: UUID
        let kind: Kind
        var title: String
        var detail: String
        var ms: Double?
        var state: State
        let at: Date
    }

    @Published private(set) var entries: [Entry] = []
    private var started: [UUID: TimeInterval] = [:]

    /// A call that is now running; `finish` it with what came back.
    @discardableResult func begin(_ kind: Kind, _ title: String, detail: String = "") -> UUID {
        let id = UUID()
        started[id] = ProcessInfo.processInfo.systemUptime
        append(Entry(id: id, kind: kind, title: title, detail: detail, ms: nil, state: .running, at: Date()))
        return id
    }

    func update(_ id: UUID, detail: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].detail = detail
    }

    /// `ms` nil means "measure from begin".
    func finish(_ id: UUID, detail: String, ms: Double? = nil, failed: Bool = false) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let measured = started.removeValue(forKey: id).map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 }
        entries[index].detail = detail
        entries[index].ms = ms ?? measured
        entries[index].state = failed ? .failed : .done
    }

    /// Something that already happened.
    func log(_ kind: Kind, _ title: String, detail: String = "", ms: Double? = nil, failed: Bool = false) {
        append(Entry(id: UUID(), kind: kind, title: title, detail: detail, ms: ms, state: failed ? .failed : .done, at: Date()))
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > 80 { entries.removeFirst(entries.count - 80) }
    }
}
