import SwiftUI

/// Codex review panel — devbar-inspired terminal aesthetic.
struct CodexPanelView: View {
    @StateObject private var store = CodexStore()
    @ObservedObject private var tm = ThemeManager.shared
    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var monitor = ClaudeMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            HStack {
                // Notched wing left
                Rectangle().fill(tm.border).frame(width: 12, height: 1)
                Text("CODEX REVIEW")
                    .font(Theme.monoSmall)
                    .fontWeight(.bold)
                    .foregroundColor(tm.accent)
                    .tracking(1.5)
                // Notched wing right
                Rectangle().fill(tm.border).frame(height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // ── Status row ──
            HStack(spacing: 10) {
                StatusDot(status: displayStatus)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel(displayStatus))
                        .font(Theme.monoSmall)
                        .foregroundColor(statusColor(displayStatus))
                        .tracking(0.5)
                    Text(statusSubtitle(displayStatus))
                        .font(Theme.monoTiny)
                        .foregroundColor(tm.textMuted)
                }
                Spacer()
                if store.state.cycle > 0 {
                    Text("CYCLE \(store.state.cycle)")
                        .font(Theme.monoTiny)
                        .foregroundColor(tm.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(tm.bgElevated)

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

            Divider().background(tm.border).padding(.horizontal, 12).padding(.vertical, 8)

            // ── Scrollable content ──
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Task card
                    if !store.state.task.isEmpty {
                        CardView(title: "TASK") {
                            Text(store.state.task)
                                .font(Theme.monoTiny)
                                .foregroundColor(tm.text)
                                .lineLimit(6)
                        }
                    }

                    // Feedback card
                    if !store.state.feedback.isEmpty {
                        CardView(title: "FEEDBACK") {
                            Text(store.state.feedback)
                                .font(Theme.monoTiny)
                                .foregroundColor(tm.text)
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
                                            .foregroundColor(tm.textMuted)
                                            .frame(width: 24, alignment: .trailing)
                                        Text(entry.decision)
                                            .font(Theme.monoTiny)
                                            .fontWeight(.bold)
                                            .foregroundColor(decisionColor(entry.decision))
                                        Text("\(entry.durationSec)s")
                                            .font(Theme.monoTiny)
                                            .foregroundColor(tm.textMuted)
                                        Spacer()
                                    }
                                    if !entry.summary.isEmpty {
                                        Text(entry.summary)
                                            .font(Theme.monoTiny)
                                            .foregroundColor(tm.textSecondary)
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

            // ── Scratchpad ──
            ScratchpadView()

            // ── Footer ──
            HStack(spacing: 6) {
                Circle()
                    .fill(store.state.status == "reviewing" ? tm.warning : tm.textMuted)
                    .frame(width: 5, height: 5)
                Text("IPC: pair-terminal.sock")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textMuted)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(tm.bg)
    }

    var displayStatus: String {
        // Monitor status takes priority (it knows real-time state)
        let m = monitor.status
        if m != "idle" { return m }
        // Fall back to Codex state file status
        let s = store.state.status
        if s != "idle" { return s }
        return sessionManager.sessions.isEmpty ? "idle" : "watching"
    }

    func statusSubtitle(_ s: String) -> String {
        switch s {
        case "watching": return "Monitoring Claude, will review when it pauses"
        case "waiting": return "Claude is idle, waiting for input"
        case "idle": return "No active sessions"
        case "reviewing": return "Codex is reviewing Claude's work"
        case "approved": return "Task complete, Claude can stop"
        case "feedback": return "Feedback sent, Claude is continuing"
        case "responding": return "Answering Claude's question"
        case "error": return "Codex encountered an error"
        default: return ""
        }
    }

    func statusLabel(_ s: String) -> String {
        switch s {
        case "idle": return "IDLE"
        case "waiting": return "READY"
        case "watching": return "WATCHING"
        case "reviewing": return "REVIEWING"
        case "approved": return "APPROVED"
        case "feedback": return "FEEDBACK SENT"
        case "responding": return "RESPONDING"
        case "error": return "ERROR"
        default: return s.uppercased()
        }
    }

    func statusColor(_ s: String) -> Color {
        switch s {
        case "watching": return tm.cyan
        case "waiting": return tm.accent
        case "reviewing": return tm.warning
        case "approved": return tm.accent
        case "feedback": return tm.purple
        case "error": return tm.error
        default: return tm.textMuted
        }
    }

    func decisionColor(_ d: String) -> Color {
        switch d {
        case "APPROVE": return tm.accent
        case "FEEDBACK": return tm.warning
        case "CONTEXT": return tm.cyan
        default: return tm.textMuted
        }
    }
}

/// Devbar-style notched card with wing header.
struct CardView<Content: View>: View {
    @ObservedObject private var tm = ThemeManager.shared
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wing header
            HStack(spacing: 0) {
                Rectangle().fill(tm.border).frame(width: 12, height: 1)
                Text(title)
                    .font(Theme.monoTiny)
                    .fontWeight(.bold)
                    .foregroundColor(tm.accent.opacity(0.7))
                    .tracking(1.0)
                    .padding(.horizontal, 6)
                Rectangle().fill(tm.border).frame(height: 1)
            }

            // Content with side borders
            VStack(alignment: .leading) {
                content
            }
            .padding(10)
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(tm.border, lineWidth: 1)
            )
        }
    }
}

/// Animated status dot.
struct StatusDot: View {
    @ObservedObject private var tm = ThemeManager.shared
    let status: String

    var color: Color {
        switch status {
        case "watching": return tm.cyan
        case "waiting": return tm.accent
        case "reviewing": return tm.warning
        case "approved": return tm.accent
        case "feedback": return tm.purple
        case "error": return tm.error
        default: return tm.textMuted
        }
    }

    @State private var isPulsing = false

    private var shouldAnimate: Bool {
        status == "watching" || status == "reviewing" || status == "responding"
    }

    var body: some View {
        ZStack {
            // Outer glow ring — pulses when active
            Circle()
                .fill(color.opacity(shouldAnimate ? (isPulsing ? 0.4 : 0.1) : 0.2))
                .frame(width: 16, height: 16)

            // Inner dot
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            if shouldAnimate {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
        .onChange(of: status) { _ in
            if shouldAnimate {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            } else {
                isPulsing = false
            }
        }
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
