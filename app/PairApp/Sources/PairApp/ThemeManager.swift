import SwiftUI

/// Manages the active color scheme  - switches between devbar theme and user's Ghostty config.
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    enum ThemeMode: String {
        case devbar = "Devbar"
        case ghostty = "Ghostty"
    }

    @Published var mode: ThemeMode = .devbar {
        didSet { reloadColors() }
    }

    // Resolved colors  - used throughout the UI
    @Published var bg: Color = Theme.bg
    @Published var bgCard: Color = Theme.bgCard
    @Published var bgElevated: Color = Theme.bgElevated
    @Published var text: Color = Theme.text
    @Published var textSecondary: Color = Theme.textSecondary
    @Published var textMuted: Color = Theme.textMuted
    @Published var border: Color = Theme.border
    @Published var borderSubtle: Color = Theme.borderSubtle
    @Published var accent: Color = Theme.emerald
    @Published var error: Color = Theme.error
    @Published var warning: Color = Theme.warning
    @Published var info: Color = Theme.info
    @Published var purple: Color = Theme.purple
    @Published var cyan: Color = Theme.cyan

    // Font settings from Ghostty config
    @Published var fontFamily: String = "SF Mono"
    @Published var fontSize: CGFloat = 13

    private var ghosttyConfig: GhosttyConfig?

    private init() {
        ghosttyConfig = GhosttyConfig.load()
        // Default to Ghostty theme if user has a config
        if ghosttyConfig?.hasCustomColors == true {
            mode = .ghostty
            reloadColors()
        }
    }

    func toggle() {
        PairLog.info("Theme toggle: \(mode.rawValue) → \(mode == .devbar ? "Ghostty" : "Devbar")")
        mode = (mode == .devbar) ? .ghostty : .devbar
        PairLog.info("Theme toggle complete")

        // Apply OSC color sequences to all Ghostty terminal surfaces
        applyTerminalColors()
    }

    /// Send OSC escape sequences to update terminal colors for all sessions.
    func applyTerminalColors() {
        let config = mode == .ghostty ? (ghosttyConfig ?? GhosttyConfig.load()) : nil

        let palette: [String]
        if mode == .ghostty, let cfg = config {
            // Use Ghostty config palette
            palette = (0..<16).map { i in
                cfg.palette[i]?.hexString ?? GhosttyConfig.devbarPalette[i] ?? "000000"
            }
        } else {
            // Devbar palette
            palette = (0..<16).map { GhosttyConfig.devbarPalette[$0] ?? "000000" }
        }

        let bgHex = mode == .ghostty
            ? (config?.background?.hexString ?? "0a0f1a")
            : "0a0f1a"
        let fgHex = mode == .ghostty
            ? (config?.foreground?.hexString ?? "f1f5f9")
            : "f1f5f9"

        // Build OSC sequence
        var osc = ""
        for (i, hex) in palette.enumerated() {
            let r = String(hex.prefix(2))
            let g = String(hex.dropFirst(2).prefix(2))
            let b = String(hex.dropFirst(4).prefix(2))
            osc += "\u{1B}]4;\(i);rgb:\(r)/\(g)/\(b)\u{07}"
        }
        osc += "\u{1B}]10;rgb:\(fgHex.prefix(2))/\(fgHex.dropFirst(2).prefix(2))/\(fgHex.dropFirst(4).prefix(2))\u{07}"
        osc += "\u{1B}]11;rgb:\(bgHex.prefix(2))/\(bgHex.dropFirst(2).prefix(2))/\(bgHex.dropFirst(4).prefix(2))\u{07}"

        // Send to all active sessions
        for session in SessionManager.shared.sessions {
            session.terminalView?.getTerminal().feed(text: osc)
        }
    }

    private func reloadColors() {
        switch mode {
        case .devbar:
            bg = Theme.bg
            bgCard = Theme.bgCard
            bgElevated = Theme.bgElevated
            text = Theme.text
            textSecondary = Theme.textSecondary
            textMuted = Theme.textMuted
            border = Theme.border
            borderSubtle = Theme.borderSubtle
            accent = Theme.emerald
            error = Theme.error
            warning = Theme.warning
            info = Theme.info
            purple = Theme.purple
            cyan = Theme.cyan

        case .ghostty:
            let config = ghosttyConfig ?? GhosttyConfig.load()
            let ghosttyBg = config.background ?? GhosttyConfig.devbarBackground
            let ghosttyFg = config.foreground ?? GhosttyConfig.devbarForeground

            // Fonts from Ghostty config
            if let family = config.fontFamily { fontFamily = family }
            if let size = config.fontSize { fontSize = size }

            bg = Color(nsColor: ghosttyBg)
            bgCard = Color(nsColor: ghosttyBg).opacity(0.95)
            bgElevated = Color(nsColor: ghosttyBg).opacity(0.98)
            text = Color(nsColor: ghosttyFg)
            textSecondary = Color(nsColor: ghosttyFg).opacity(0.6)
            textMuted = Color(nsColor: ghosttyFg).opacity(0.4)

            // Use green from palette[2] as accent, or fallback to emerald
            if let green = config.palette[2] {
                accent = Color(nsColor: green)
                border = Color(nsColor: green).opacity(0.2)
                borderSubtle = Color(nsColor: green).opacity(0.1)
            } else {
                accent = Theme.emerald
                border = Theme.border
                borderSubtle = Theme.borderSubtle
            }

            if let red = config.palette[1] { error = Color(nsColor: red) }
            if let yellow = config.palette[3] { warning = Color(nsColor: yellow) }
            if let blue = config.palette[4] { info = Color(nsColor: blue) }
            if let purp = config.palette[5] { purple = Color(nsColor: purp) }
            if let cy = config.palette[6] { self.cyan = Color(nsColor: cy) }
        }
    }
}
