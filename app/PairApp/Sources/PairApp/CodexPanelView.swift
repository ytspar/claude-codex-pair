import SwiftUI
import Combine

/// Codex review panel — instrumentation-style sidebar.
/// Dense, scannable, no decorative borders. Uses spacing and color for hierarchy.
/// Keyboard-navigable: Tab to focus panel, arrow keys to move, Enter/Space to expand.
struct CodexPanelView: View {
    @StateObject private var store = CodexStore()
    @ObservedObject private var tm = ThemeManager.shared
    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var monitor = ClaudeMonitor.shared
    @ObservedObject private var taskQueue = TaskQueue.shared
    @State private var refreshTick = 0
    @State private var focusedIndex: Int? = nil
    @State private var expandedIds: Set<UUID> = []
    @State private var activeContentTab: ContentTab = .queue

    enum ContentTab { case queue, timeline }

    /// All focusable items: timeline entries (could add task/feedback later).
    private var focusableItems: [ClaudeMonitor.TimelineEntry] {
        monitor.timeline
    }

    var body: some View {
        let _ = refreshTick
        VStack(alignment: .leading, spacing: 0) {
            // ── Status strip ──
            statusStrip
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // ── Thin rule ──
            Rectangle().fill(tm.border).frame(height: 1)
                .padding(.horizontal, 14)

            // ── Scrollable content ──
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Task block
                        if !store.state.task.isEmpty {
                            sectionBlock(label: "TASK") {
                                Text(store.state.task)
                                    .font(Theme.monoTiny)
                                    .foregroundColor(tm.text)
                                    .lineLimit(6)
                            }
                        }

                        // Feedback block
                        if !store.state.feedback.isEmpty {
                            sectionBlock(label: "FEEDBACK") {
                                Text(store.state.feedback)
                                    .font(Theme.monoTiny)
                                    .foregroundColor(tm.text)
                                    .textSelection(.enabled)
                            }
                        }

                        // ── Queue / Timeline tab bar ──
                        contentTabBar
                            .padding(.top, 14)

                        // ── Tab content ──
                        switch activeContentTab {
                        case .queue:
                            TaskQueueView()
                                .padding(.top, 4)
                        case .timeline:
                            if !monitor.timeline.isEmpty {
                                TimelineSectionView(
                                    entries: monitor.timeline,
                                    tm: tm,
                                    colorForEvent: timelineColor,
                                    focusedIndex: focusedIndex,
                                    expandedIds: $expandedIds
                                )
                                .padding(.top, 4)
                            } else {
                                Text("No activity yet")
                                    .font(Theme.monoTiny)
                                    .foregroundColor(tm.textMuted.opacity(0.5))
                                    .padding(.top, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }
                .onChange(of: focusedIndex) { idx in
                    if let idx = idx, idx < focusableItems.count {
                        activeContentTab = .timeline
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(focusableItems[idx].id, anchor: .center)
                        }
                    }
                }
            }

            // ── Scratchpad ──
            ScratchpadView()

            // ── Footer ──
            footer
        }
        .background(tm.bg)
        .background(CodexKeyHandler(
            itemCount: focusableItems.count,
            focusedIndex: $focusedIndex,
            onToggle: { idx in
                guard idx < focusableItems.count else { return }
                let id = focusableItems[idx].id
                withAnimation(.easeOut(duration: 0.12)) {
                    if expandedIds.contains(id) { expandedIds.remove(id) }
                    else { expandedIds.insert(id) }
                }
            }
        ))
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            refreshTick += 1
        }
    }

    // MARK: - Status strip

    private var statusStrip: some View {
        HStack(spacing: 0) {
            // Left-edge color bar
            RoundedRectangle(cornerRadius: 1)
                .fill(statusColor(displayStatus))
                .frame(width: 3, height: 18)
                .padding(.trailing, 10)

            HStack(spacing: 6) {
                Text(statusLabel(displayStatus))
                    .font(Theme.monoTiny)
                    .fontWeight(.bold)
                    .foregroundColor(statusColor(displayStatus))
                    .tracking(0.8)

                if !store.state.decision.isEmpty {
                    Text(store.state.decision)
                        .font(Theme.monoTiny)
                        .foregroundColor(decisionColor(store.state.decision))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(decisionColor(store.state.decision).opacity(0.1))
                }

                Spacer()

                if monitor.backoffMultiplier > 1.0 {
                    Text("\(String(format: "%.0f", monitor.backoffMultiplier))x")
                        .font(Theme.monoTiny)
                        .foregroundColor(tm.warning)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(tm.warning.opacity(0.1))
                        .cornerRadius(2)
                        .help("Backing off: \(monitor.consecutiveUnhelpful) reviews without improvement")
                }

                if monitor.cycleCount > 0 {
                    Text("\(monitor.cycleCount)")
                        .font(Theme.monoTiny)
                        .foregroundColor(tm.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(tm.bgElevated)
                }
            }
        }
    }

    // MARK: - Section block (replaces CardView)

    private func sectionBlock<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.monoTiny)
                .foregroundColor(tm.textMuted)
                .tracking(1.0)

            HStack(spacing: 0) {
                // Left accent edge
                Rectangle()
                    .fill(tm.accent.opacity(0.3))
                    .frame(width: 2)

                content()
                    .padding(.leading, 10)
                    .padding(.vertical, 6)
            }
        }
        .padding(.top, 14)
    }

    // MARK: - Content tab bar

    private var contentTabBar: some View {
        HStack(spacing: 0) {
            contentTabButton("QUEUE", count: taskQueue.pendingCount, tab: .queue)
            contentTabButton("TIMELINE", count: monitor.timeline.count, tab: .timeline)
            Spacer()

            // Queue controls inline
            if activeContentTab == .queue {
                if !taskQueue.isRunning && taskQueue.pendingCount > 0 {
                    Button(action: { taskQueue.start() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 7))
                            Text("Start")
                                .font(Theme.monoTiny)
                        }
                        .foregroundColor(tm.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                }
                if taskQueue.isRunning {
                    Button(action: { taskQueue.stop() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 7))
                            Text("Pause")
                                .font(Theme.monoTiny)
                        }
                        .foregroundColor(tm.warning)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                }
                if !taskQueue.items.isEmpty {
                    Button(action: { taskQueue.clearAll() }) {
                        Text("Clear")
                            .font(Theme.monoTiny)
                            .foregroundColor(tm.textMuted.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func contentTabButton(_ label: String, count: Int, tab: ContentTab) -> some View {
        let isActive = activeContentTab == tab
        return HStack(spacing: 4) {
            Text(label)
                .font(Theme.monoTiny)
                .foregroundColor(isActive ? tm.accent : tm.textMuted)
                .tracking(1.0)
            if count > 0 {
                Text("\(count)")
                    .font(.custom(Theme.fontName, size: 8))
                    .foregroundColor(isActive ? tm.accent : tm.textMuted)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background((isActive ? tm.accent : tm.textMuted).opacity(0.1))
                    .cornerRadius(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(isActive ? tm.accent : Color.clear)
                .frame(height: 1),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture { activeContentTab = tab }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(monitor.status == "reviewing" ? tm.warning : (monitor.status == "error" ? tm.error : tm.accent))
                .frame(width: 4, height: 4)
            Text("\(sessionManager.sessions.count) session\(sessionManager.sessions.count == 1 ? "" : "s")")
                .font(Theme.monoTiny)
                .foregroundColor(tm.textSecondary)
            if monitor.cycleCount > 0 {
                Text("\u{00B7} \(monitor.cycleCount) review\(monitor.cycleCount == 1 ? "" : "s")")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textSecondary)
            }
            if taskQueue.pendingCount > 0 {
                Text("\u{00B7} \(taskQueue.pendingCount) queued")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textSecondary)
            }
            let totalOutcomes = monitor.sessionImproved + monitor.sessionNeutral + monitor.sessionRegressed
            if totalOutcomes > 0 {
                Text("\u{00B7} \(monitor.sessionImproved)/\(totalOutcomes) helped")
                    .font(Theme.monoTiny)
                    .foregroundColor(monitor.sessionImproved > monitor.sessionRegressed ? tm.accent : tm.warning)
            }
            Spacer()
            Text(AppVersion.displayString)
                .font(Theme.monoTiny)
                .foregroundColor(tm.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    // MARK: - State helpers

    var displayStatus: String {
        let m = monitor.status
        if m != "idle" { return m }
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

    func timelineColor(_ event: String) -> Color {
        // Muted monochrome — mostly grey, accent only for resolutions, errors subdued.
        switch event {
        case "APPROVED":                          return tm.accent.opacity(0.5)
        case "FEEDBACK", "CODEX_RESPONSE":        return tm.textMuted.opacity(0.7)
        case "REVIEWING", "STUCK":                return tm.textMuted.opacity(0.5)
        case "SELECT":                            return tm.textMuted.opacity(0.4)
        case "CODEX_EMPTY", "ERROR", "LOOP_DETECTED": return tm.error.opacity(0.4)
        default:                                  return tm.textMuted.opacity(0.4)
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
        case "reviewing": return tm.textSecondary
        case "approved": return tm.accent
        case "feedback": return tm.accent.opacity(0.7)
        case "error": return tm.error
        default: return tm.textMuted
        }
    }

    func decisionColor(_ d: String) -> Color {
        switch d {
        case "APPROVE": return tm.accent.opacity(0.7)
        case "FEEDBACK": return tm.accent.opacity(0.5)
        case "CONTEXT": return tm.textMuted
        default: return tm.textMuted.opacity(0.6)
        }
    }
}

// MARK: - Timeline

/// Timeline section — vertical spine through dots, no border box.
struct TimelineSectionView: View {
    let entries: [ClaudeMonitor.TimelineEntry]
    let tm: ThemeManager
    let colorForEvent: (String) -> Color
    var focusedIndex: Int? = nil
    @Binding var expandedIds: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isFirst = index == 0
                let isResolution = entry.event == "APPROVED" || entry.event == "FEEDBACK"
                let color = colorForEvent(entry.event)
                let isFocused = focusedIndex == index
                let isExpanded = expandedIds.contains(entry.id)

                TimelineEntryView(
                    entry: entry,
                    tm: tm,
                    color: color,
                    isLatest: isFirst,
                    isResolution: isResolution,
                    showTimestamp: shouldShowTimestamp(index),
                    isLast: index == entries.count - 1,
                    isFocused: isFocused,
                    isExpanded: isExpanded,
                    onToggle: {
                        withAnimation(.easeOut(duration: 0.12)) {
                            if expandedIds.contains(entry.id) { expandedIds.remove(entry.id) }
                            else { expandedIds.insert(entry.id) }
                        }
                    },
                    onRate: { rating in
                        ClaudeMonitor.shared.rateIntervention(entryId: entry.id, rating: rating)
                    }
                )
                .id(entry.id)
            }
        }
    }

    private func shouldShowTimestamp(_ index: Int) -> Bool {
        if index == 0 { return true }
        let current = timeBucket(entries[index].time)
        let previous = timeBucket(entries[index - 1].time)
        return current != previous
    }

    private func timeBucket(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        return "\(Int(s / 3600))h"
    }
}

/// Single timeline entry — dot with spine segment below it.
/// Supports focus highlight (keyboard nav) and expand/collapse.
struct TimelineEntryView: View {
    let entry: ClaudeMonitor.TimelineEntry
    let tm: ThemeManager
    let color: Color
    let isLatest: Bool
    let isResolution: Bool
    let showTimestamp: Bool
    var isLast: Bool = false
    var isFocused: Bool = false
    var isExpanded: Bool = false
    var onToggle: (() -> Void)? = nil
    var onRate: ((String) -> Void)? = nil
    @State private var userRating: String? = nil

    private var dotSize: CGFloat { isResolution ? 8 : 5 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Dot column
                VStack(spacing: 0) {
                    ZStack {
                        if isLatest || isFocused {
                            Circle()
                                .fill(color.opacity(isFocused ? 0.25 : 0.15))
                                .frame(width: 14, height: 14)
                        }
                        Circle()
                            .fill(color)
                            .frame(width: dotSize, height: dotSize)
                    }
                    .frame(width: 14, height: 14)

                    // Spine segment below dot
                    if !isLast {
                        Rectangle()
                            .fill(tm.border.opacity(0.4))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 14)

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    // Header row — tappable to expand/collapse
                    HStack(spacing: 6) {
                        Text(entry.event)
                            .font(Theme.monoTiny)
                            .fontWeight(.medium)
                            .foregroundColor(isLatest ? color : tm.textMuted)
                        // Source badge — distinguish user, codex, and monitor actions
                        Text(sourceLabel(entry.source))
                            .font(.custom(Theme.fontName, size: 8))
                            .foregroundColor(sourceColor(entry.source))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(sourceColor(entry.source).opacity(0.08))
                            .cornerRadius(2)
                        if let ms = entry.durationMs {
                            Text(formatDuration(ms))
                                .font(Theme.monoTiny)
                                .foregroundColor(tm.textMuted)
                        }
                        Spacer(minLength: 4)
                        if showTimestamp {
                            Text(timeAgo(entry.time))
                                .font(Theme.monoTiny)
                                .foregroundColor(tm.textMuted.opacity(0.7))
                                .layoutPriority(-1)
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7))
                            .foregroundColor(tm.textMuted.opacity(0.4))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onToggle?() }

                    // Detail text — selectable, not blocked by tap gesture
                    Text(entry.detail)
                        .font(Theme.monoTiny)
                        .foregroundColor(isLatest || isFocused ? tm.textSecondary : tm.textMuted)
                        .lineLimit(isExpanded ? nil : (isLatest ? 2 : 1))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    // Expanded: show full context
                    if isExpanded {
                        expandedContent
                    }
                }
                .padding(.bottom, isResolution ? 10 : 6)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Focus highlight
        .background(
            isFocused
                ? RoundedRectangle(cornerRadius: 3).fill(tm.accent.opacity(0.05)).padding(.horizontal, -4)
                : nil
        )
        .opacity(isLatest || isFocused ? 1.0 : 0.65)
    }

    // MARK: - Expanded content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Full Codex response
            if let response = entry.codexResponse, !response.isEmpty, response != entry.detail {
                expandedSection(label: "CODEX RESPONSE", text: response, copyable: true)
            }

            // Git diff summary
            if let diff = entry.diffSummary, !diff.isEmpty {
                expandedSection(label: "GIT DIFF", text: diff, copyable: false)
            }

            // Prompt sent to Codex
            if let prompt = entry.codexPrompt, !prompt.isEmpty {
                expandedSection(label: "PROMPT", text: prompt, copyable: true)
            }

            // Screen context
            if let snippet = entry.screenSnippet, !snippet.isEmpty {
                expandedSection(label: "SCREEN", text: snippet, copyable: false)
            }

            // Rating + copy buttons
            HStack(spacing: 10) {
                // Thumbs up/down — user feedback on whether this intervention helped
                if entry.source == .codex {
                    ratingButton(icon: "hand.thumbsup", rating: "improved",
                                 isActive: userRating == "improved", activeColor: tm.accent)
                    ratingButton(icon: "hand.thumbsdown", rating: "regressed",
                                 isActive: userRating == "regressed", activeColor: tm.error)
                }
                copyButton(label: "Copy response", text: entry.codexResponse)
                copyButton(label: "Copy all", text: allCopyText)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.top, 6)
    }

    private func expandedSection(label: String, text: String, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textMuted.opacity(0.6))
                    .tracking(0.8)
                if copyable {
                    copyButton(label: nil, text: text)
                }
            }
            Text(text)
                .font(Theme.monoTiny)
                .foregroundColor(tm.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .lineLimit(label == "PROMPT" ? 6 : nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(tm.bgElevated.opacity(0.3))
    }

    private func copyButton(label: String?, text: String?) -> some View {
        Button(action: {
            guard let text = text, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }) {
            HStack(spacing: 3) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 8))
                if let label = label {
                    Text(label)
                        .font(Theme.monoTiny)
                }
            }
            .foregroundColor(tm.textMuted.opacity(0.6))
        }
        .buttonStyle(.plain)
        .opacity(text?.isEmpty == false ? 1 : 0.3)
    }

    private func ratingButton(icon: String, rating: String, isActive: Bool, activeColor: Color) -> some View {
        Button(action: {
            withAnimation(.easeOut(duration: 0.15)) {
                userRating = isActive ? nil : rating
            }
            onRate?(isActive ? "neutral" : rating)
        }) {
            Image(systemName: isActive ? "\(icon).fill" : icon)
                .font(.system(size: 10))
                .foregroundColor(isActive ? activeColor : tm.textMuted.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private var allCopyText: String? {
        var parts: [String] = []
        parts.append("[\(entry.event)] \(timeAgo(entry.time))")
        parts.append(entry.detail)
        if let r = entry.codexResponse { parts.append("Response: \(r)") }
        if let d = entry.diffSummary { parts.append("Diff:\n\(d)") }
        if let p = entry.codexPrompt { parts.append("Prompt:\n\(p)") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private func timeAgo(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 5 { return "just now" }
        if s < 60 { return "\(Int(s))s ago" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        return "\(Int(s / 3600))h ago"
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    private func sourceLabel(_ source: ClaudeMonitor.TimelineSource) -> String {
        switch source {
        case .user: return "USER"
        case .codex: return "CODEX"
        case .monitor: return "AUTO"
        }
    }

    private func sourceColor(_ source: ClaudeMonitor.TimelineSource) -> Color {
        switch source {
        case .user: return tm.cyan
        case .codex: return tm.accent
        case .monitor: return tm.textMuted
        }
    }
}

/// Keyboard handler for Codex panel navigation.
/// Listens for arrow keys + Enter/Space when the Codex panel area is active.
struct CodexKeyHandler: NSViewRepresentable {
    let itemCount: Int
    @Binding var focusedIndex: Int?
    let onToggle: (Int) -> Void

    func makeNSView(context: Context) -> CodexKeyView {
        let view = CodexKeyView()
        view.handler = context.coordinator
        return view
    }

    func updateNSView(_ nsView: CodexKeyView, context: Context) {
        context.coordinator.itemCount = itemCount
        context.coordinator.focusedIndex = $focusedIndex
        context.coordinator.onToggle = onToggle
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(itemCount: itemCount, focusedIndex: $focusedIndex, onToggle: onToggle)
    }

    class Coordinator {
        var itemCount: Int
        var focusedIndex: Binding<Int?>
        var onToggle: (Int) -> Void

        init(itemCount: Int, focusedIndex: Binding<Int?>, onToggle: @escaping (Int) -> Void) {
            self.itemCount = itemCount
            self.focusedIndex = focusedIndex
            self.onToggle = onToggle
        }

        func handleKey(_ event: NSEvent) -> Bool {
            // Only handle when Option is held (so arrow keys don't conflict with terminal)
            guard event.modifierFlags.contains(.option) else { return false }

            switch event.keyCode {
            case 126: // Up arrow
                if let idx = focusedIndex.wrappedValue {
                    focusedIndex.wrappedValue = max(0, idx - 1)
                } else {
                    focusedIndex.wrappedValue = 0
                }
                return true
            case 125: // Down arrow
                if let idx = focusedIndex.wrappedValue {
                    focusedIndex.wrappedValue = min(itemCount - 1, idx + 1)
                } else {
                    focusedIndex.wrappedValue = 0
                }
                return true
            case 36, 49: // Enter or Space
                if let idx = focusedIndex.wrappedValue, idx < itemCount {
                    onToggle(idx)
                }
                return true
            case 53: // Escape
                focusedIndex.wrappedValue = nil
                return true
            default:
                return false
            }
        }
    }
}

class CodexKeyView: NSView {
    var handler: CodexKeyHandler.Coordinator?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if self?.handler?.handleKey(event) == true { return nil }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        super.removeFromSuperview()
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
