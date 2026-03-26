import SwiftUI

/// Codex review panel — devbar-inspired terminal aesthetic.
struct CodexPanelView: View {
    @StateObject private var store = CodexStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            HStack {
                // Notched wing left
                Rectangle().fill(Theme.border).frame(width: 12, height: 1)
                Text("CODEX REVIEW")
                    .font(Theme.monoSmall)
                    .fontWeight(.bold)
                    .foregroundColor(Theme.emerald)
                    .tracking(1.5)
                // Notched wing right
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // ── Status row ──
            HStack(spacing: 10) {
                StatusDot(status: store.state.status)
                Text(store.state.status.uppercased())
                    .font(Theme.monoSmall)
                    .foregroundColor(statusColor(store.state.status))
                    .tracking(0.5)
                Spacer()
                Text("CYCLE \(store.state.cycle)")
                    .font(Theme.monoTiny)
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Theme.bgElevated)

            // ── Decision badge ──
            if !store.state.decision.isEmpty {
                HStack {
                    Text(store.state.decision)
                        .font(Theme.monoSmall)
                        .fontWeight(.bold)
                        .foregroundColor(decisionColor(store.state.decision))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(decisionColor(store.state.decision).opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            Divider().background(Theme.border).padding(.horizontal, 12).padding(.vertical, 8)

            // ── Scrollable content ──
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Task card
                    if !store.state.task.isEmpty {
                        CardView(title: "TASK") {
                            Text(store.state.task)
                                .font(Theme.monoTiny)
                                .foregroundColor(Theme.text)
                                .lineLimit(6)
                        }
                    }

                    // Feedback card
                    if !store.state.feedback.isEmpty {
                        CardView(title: "FEEDBACK") {
                            Text(store.state.feedback)
                                .font(Theme.monoTiny)
                                .foregroundColor(Theme.text)
                                .textSelection(.enabled)
                        }
                    }

                    // History card
                    if !store.interactions.isEmpty {
                        CardView(title: "HISTORY") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(store.interactions) { entry in
                                    HStack(spacing: 8) {
                                        Text("#\(entry.cycle)")
                                            .font(Theme.monoTiny)
                                            .foregroundColor(Theme.textMuted)
                                            .frame(width: 24, alignment: .trailing)
                                        Text(entry.decision)
                                            .font(Theme.monoTiny)
                                            .fontWeight(.bold)
                                            .foregroundColor(decisionColor(entry.decision))
                                        Text("\(entry.durationSec)s")
                                            .font(Theme.monoTiny)
                                            .foregroundColor(Theme.textMuted)
                                        Spacer()
                                    }
                                    if !entry.summary.isEmpty {
                                        Text(entry.summary)
                                            .font(Theme.monoTiny)
                                            .foregroundColor(Theme.textSecondary)
                                            .lineLimit(2)
                                            .padding(.leading, 32)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()

            // ── Footer ──
            HStack(spacing: 6) {
                Circle()
                    .fill(store.state.status == "reviewing" ? Theme.warning : Theme.textMuted)
                    .frame(width: 5, height: 5)
                Text("IPC: pair-terminal.sock")
                    .font(Theme.monoTiny)
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.bg)
    }

    func statusColor(_ s: String) -> Color {
        switch s {
        case "reviewing": return Theme.warning
        case "approved": return Theme.emerald
        case "feedback": return Theme.purple
        case "error": return Theme.error
        default: return Theme.textMuted
        }
    }

    func decisionColor(_ d: String) -> Color {
        switch d {
        case "APPROVE": return Theme.emerald
        case "FEEDBACK": return Theme.warning
        case "CONTEXT": return Theme.cyan
        default: return Theme.textMuted
        }
    }
}

/// Devbar-style notched card with wing header.
struct CardView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wing header
            HStack(spacing: 0) {
                Rectangle().fill(Theme.border).frame(width: 12, height: 1)
                Text(title)
                    .font(Theme.monoTiny)
                    .fontWeight(.bold)
                    .foregroundColor(Theme.emerald.opacity(0.7))
                    .tracking(1.0)
                    .padding(.horizontal, 6)
                Rectangle().fill(Theme.border).frame(height: 1)
            }

            // Content with side borders
            VStack(alignment: .leading) {
                content
            }
            .padding(10)
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
    }
}

/// Animated status dot.
struct StatusDot: View {
    let status: String

    var color: Color {
        switch status {
        case "reviewing": return Theme.warning
        case "approved": return Theme.emerald
        case "feedback": return Theme.purple
        case "error": return Theme.error
        default: return Theme.textMuted
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .fill(color.opacity(0.3))
                    .frame(width: 14, height: 14)
            )
    }
}

// MARK: - Data

struct CodexViewState {
    var cycle: Int = 0
    var status: String = "idle"
    var decision: String = ""
    var task: String = ""
    var feedback: String = ""
    var lastUpdate: Date = .distantPast
}

struct InteractionEntry: Identifiable {
    let id: Int
    let cycle: Int
    let decision: String
    let durationSec: Int
    let summary: String
}

class CodexStore: ObservableObject {
    @Published var state = CodexViewState()
    @Published var interactions: [InteractionEntry] = []
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let stateDir = "\(home)/.claude-codex-pair/state"
        let sessionsDir = "\(home)/.claude-codex-pair/sessions"

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir) else { return }

        var latestTime: Date = .distantPast
        var latestState: [String: Any]?
        var latestSessionId = ""

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
