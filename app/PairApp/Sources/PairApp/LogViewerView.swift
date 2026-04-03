import SwiftUI

/// Live-tailing log viewer that reads pairapp-debug.log and pairapp.log.
/// Opens as a special tab in the main window.
struct LogViewerView: View {
    @ObservedObject private var tm = ThemeManager.shared
    @State private var logLines: [LogLine] = []
    @State private var selectedFile: LogFile = .debug
    @State private var filterText = ""
    @State private var autoScroll = true
    @State private var timer: Timer?

    enum LogFile: String, CaseIterable {
        case debug = "pairapp-debug.log"
        case main = "pairapp.log"

        var path: String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/.claude-codex-pair/\(rawValue)"
        }

        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .main: return "INFO"
            }
        }
    }

    struct LogLine: Identifiable {
        let id: Int
        let text: String
        let level: String  // INFO, DEBUG, ERROR, CRASH, POLL, ACTION, SCREEN

        var color: Color {
            switch level {
            case "ERROR", "CRASH": return ThemeManager.shared.error
            case "DEBUG": return ThemeManager.shared.textMuted
            case "POLL": return ThemeManager.shared.accent.opacity(0.7)
            case "ACTION": return ThemeManager.shared.warning
            case "SCREEN": return ThemeManager.shared.textMuted.opacity(0.6)
            default: return ThemeManager.shared.textSecondary
            }
        }
    }

    var filteredLines: [LogLine] {
        if filterText.isEmpty { return logLines }
        let lower = filterText.lowercased()
        return logLines.filter { $0.text.lowercased().contains(lower) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                // File selector
                ForEach(LogFile.allCases, id: \.rawValue) { file in
                    Button(action: { selectedFile = file; reload() }) {
                        Text(file.label)
                            .font(Theme.monoTiny)
                            .foregroundColor(selectedFile == file ? tm.accent : tm.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(selectedFile == file ? tm.accent.opacity(0.1) : Color.clear)
                            .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Filter
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(tm.textMuted)
                    TextField("Filter\u{2026}", text: $filterText)
                        .font(Theme.monoTiny)
                        .textFieldStyle(.plain)
                        .foregroundColor(tm.text)
                        .frame(width: 160)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(tm.bgCard)
                .cornerRadius(4)

                // Auto-scroll toggle
                Button(action: { autoScroll.toggle() }) {
                    HStack(spacing: 3) {
                        Image(systemName: autoScroll ? "arrow.down.to.line" : "pause")
                            .font(.system(size: 9))
                        Text(autoScroll ? "Live" : "Paused")
                            .font(Theme.monoTiny)
                    }
                    .foregroundColor(autoScroll ? tm.accent : tm.textMuted)
                }
                .buttonStyle(.plain)

                // Line count
                Text("\(filteredLines.count) lines")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textMuted)

                // Clear
                Button(action: clearLog) {
                    Text("Clear")
                        .font(Theme.monoTiny)
                        .foregroundColor(tm.textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tm.bg)
            .overlay(Rectangle().fill(tm.border).frame(height: 1), alignment: .bottom)

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredLines) { line in
                            Text(line.text)
                                .font(.custom(Theme.fontName, size: 10))
                                .foregroundColor(line.color)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: filteredLines.count) { _ in
                    if autoScroll, let last = filteredLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(tm.bg)
        }
        .onAppear {
            reload()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                reload()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let path = selectedFile.path
            guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
                DispatchQueue.main.async { logLines = [] }
                return
            }
            let raw = data.split(separator: "\n", omittingEmptySubsequences: false)
            // Keep last 2000 lines for performance
            let tail = raw.suffix(2000)
            let parsed: [LogLine] = tail.enumerated().map { idx, line in
                let text = String(line)
                let level = extractLevel(text)
                return LogLine(id: idx, text: text, level: level)
            }
            DispatchQueue.main.async { logLines = parsed }
        }
    }

    private func extractLevel(_ line: String) -> String {
        // Format: [timestamp] LEVEL: message
        guard let bracket = line.firstIndex(of: "]"),
              bracket < line.endIndex else { return "INFO" }
        let after = line[line.index(after: bracket)...].trimmingCharacters(in: .whitespaces)
        if after.hasPrefix("DEBUG") { return "DEBUG" }
        if after.hasPrefix("ERROR") { return "ERROR" }
        if after.hasPrefix("CRASH") { return "CRASH" }
        if after.hasPrefix("POLL") { return "POLL" }
        if after.hasPrefix("ACTION") { return "ACTION" }
        if after.hasPrefix("SCREEN") { return "SCREEN" }
        return "INFO"
    }

    private func clearLog() {
        let path = selectedFile.path
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
        logLines = []
    }
}
