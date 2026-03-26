import SwiftUI

/// The Codex review panel — shows review status, feedback, and interaction history.
struct CodexPanelView: View {
    @StateObject private var store = CodexStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Codex Review")
                    .font(.headline)
                    .foregroundColor(.cyan)
                Spacer()
                StatusBadge(status: store.state.status)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.3))

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Cycle + Decision
                    HStack(spacing: 8) {
                        Text("Cycle \(store.state.cycle)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)

                        if !store.state.decision.isEmpty {
                            DecisionBadge(decision: store.state.decision)
                        }
                    }

                    // Task
                    if !store.state.task.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Task")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(store.state.task)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(4)
                        }
                    }

                    // Feedback
                    if !store.state.feedback.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Feedback")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(store.state.feedback)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                    }

                    // Interaction history
                    if !store.interactions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("History")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ForEach(store.interactions) { entry in
                                InteractionRow(entry: entry)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(12)
            }

            Divider()

            // Footer
            HStack {
                Circle()
                    .fill(store.state.status == "reviewing" ? Color.yellow : Color.gray)
                    .frame(width: 6, height: 6)
                Text("IPC: pair-terminal.sock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }
}

// MARK: - Subviews

struct StatusBadge: View {
    let status: String

    var color: Color {
        switch status {
        case "reviewing": return .yellow
        case "approved": return .green
        case "feedback": return .purple
        case "error": return .red
        default: return .gray
        }
    }

    var body: some View {
        Text(status)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

struct DecisionBadge: View {
    let decision: String

    var color: Color {
        switch decision {
        case "APPROVE": return .green
        case "FEEDBACK": return .yellow
        case "CONTEXT": return .cyan
        default: return .gray
        }
    }

    var body: some View {
        Text(decision)
            .font(.system(.caption, design: .monospaced))
            .bold()
            .foregroundColor(color)
    }
}

struct InteractionRow: View {
    let entry: InteractionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("#\(entry.cycle)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                DecisionBadge(decision: entry.decision)
                Text("\(entry.durationSec)s")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Data

struct InteractionEntry: Identifiable {
    let id: Int
    let cycle: Int
    let decision: String
    let durationSec: Int
    let summary: String
}

struct CodexViewState {
    var cycle: Int = 0
    var status: String = "idle"
    var decision: String = ""
    var task: String = ""
    var feedback: String = ""
    var lastUpdate: Date = .distantPast
}

/// Polls Codex state from the state/session files on disk.
class CodexStore: ObservableObject {
    @Published var state = CodexViewState()
    @Published var interactions: [InteractionEntry] = []

    private var timer: Timer?

    init() {
        // Poll every 2 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let stateDir = "\(home)/.claude-codex-pair/state"
        let sessionsDir = "\(home)/.claude-codex-pair/sessions"

        // Find the most recent state file
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir) else { return }

        var latestTime: Date = .distantPast
        var latestState: [String: Any]?
        var latestSessionId: String = ""

        for file in files where file.hasSuffix(".json") {
            let path = "\(stateDir)/\(file)"
            guard let data = FileManager.default.contents(atPath: path),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let updateStr = dict["lastUpdate"] as? String,
               let date = ISO8601DateFormatter().date(from: updateStr),
               date > latestTime {
                latestTime = date
                latestState = dict
                latestSessionId = file.replacingOccurrences(of: ".json", with: "")
            }
        }

        if let s = latestState {
            DispatchQueue.main.async { [weak self] in
                self?.state.cycle = s["cycle"] as? Int ?? 0
                self?.state.status = s["status"] as? String ?? "idle"
                self?.state.decision = s["lastDecision"] as? String ?? ""
                self?.state.task = s["task"] as? String ?? ""
                self?.state.feedback = (s["lastResponse"] as? String ?? "")
                    .split(separator: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .filter { !["APPROVE", "FEEDBACK", "CONTEXT"].contains($0.trimmingCharacters(in: .whitespaces)) }
                    .joined(separator: "\n")
                self?.state.lastUpdate = latestTime as Date
            }
        }

        // Load interaction history from JSONL
        let logFile = "\(sessionsDir)/\(latestSessionId).jsonl"
        if let data = FileManager.default.contents(atPath: logFile),
           let content = String(data: data, encoding: .utf8) {
            let entries: [InteractionEntry] = content.split(separator: "\n").compactMap { line in
                guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
                let cycle = d["cycle"] as? Int ?? 0
                let decision = d["codexDecision"] as? String ?? ""
                let durationMs = d["codexDurationMs"] as? Int ?? 0
                let response = d["codexResponse"] as? String ?? ""
                let summary = response.split(separator: "\n")
                    .filter { !["APPROVE", "FEEDBACK", "CONTEXT"].contains($0.trimmingCharacters(in: .whitespaces)) }
                    .first.map(String.init) ?? ""
                return InteractionEntry(id: cycle, cycle: cycle, decision: decision, durationSec: durationMs / 1000, summary: String(summary.prefix(120)))
            }
            DispatchQueue.main.async { [weak self] in
                self?.interactions = entries
            }
        }
    }
}
