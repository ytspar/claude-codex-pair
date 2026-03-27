import AppKit

/// Parses ~/.config/ghostty/config for terminal colors.
/// Falls back to devbar theme if no Ghostty config found.
struct GhosttyConfig {
    var background: NSColor?
    var foreground: NSColor?
    var cursorColor: NSColor?
    var palette: [Int: NSColor] = [:]
    var theme: String?
    var fontFamily: String?
    var fontSize: CGFloat?

    /// Load from the user's Ghostty config file.
    static func load() -> GhosttyConfig {
        var config = GhosttyConfig()

        // Check for config file
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPaths = [
            "\(home)/.config/ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
        ]

        guard let configPath = configPaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return config
        }

        // If there's a theme, try to load it
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }

            let key = parts[0]
            let value = parts[1]

            switch key {
            case "background":
                config.background = NSColor(hex: value)
            case "foreground":
                config.foreground = NSColor(hex: value)
            case "cursor-color":
                config.cursorColor = NSColor(hex: value)
            case "font-family":
                config.fontFamily = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "font-size":
                config.fontSize = CGFloat(Double(value) ?? 13.0)
            case "theme":
                config.theme = value
                loadTheme(named: value, into: &config)
            default:
                // Palette entries: palette = N=RRGGBB
                if key == "palette" {
                    let paletteParts = value.split(separator: "=", maxSplits: 1)
                    if paletteParts.count == 2,
                       let index = Int(paletteParts[0]),
                       let color = NSColor(hex: String(paletteParts[1])) {
                        config.palette[index] = color
                    }
                }
            }
        }

        return config
    }

    /// Try to load a Ghostty theme file.
    private static func loadTheme(named name: String, into config: inout GhosttyConfig) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let themePaths = [
            "\(home)/.config/ghostty/themes/\(name)",
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(name)",
        ]

        guard let path = themePaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return
        }

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }

            switch parts[0] {
            case "background":
                if config.background == nil { config.background = NSColor(hex: parts[1]) }
            case "foreground":
                if config.foreground == nil { config.foreground = NSColor(hex: parts[1]) }
            case "cursor-color":
                if config.cursorColor == nil { config.cursorColor = NSColor(hex: parts[1]) }
            case "palette":
                let paletteParts = parts[1].split(separator: "=", maxSplits: 1)
                if paletteParts.count == 2,
                   let index = Int(paletteParts[0]),
                   config.palette[index] == nil,
                   let color = NSColor(hex: String(paletteParts[1])) {
                    config.palette[index] = color
                }
            default:
                break
            }
        }
    }

    /// Whether any custom colors were found.
    var hasCustomColors: Bool {
        background != nil || foreground != nil || !palette.isEmpty || theme != nil
    }
}

// MARK: - Devbar fallback palette

extension GhosttyConfig {
    /// The devbar default palette — used when no Ghostty config is found.
    static let devbarPalette: [Int: String] = [
        0: "1e293b", 1: "ef4444", 2: "10b981", 3: "f59e0b",
        4: "3b82f6", 5: "a855f7", 6: "06b6d4", 7: "94a3b8",
        8: "6b7280", 9: "fc8781", 10: "34d399", 11: "fbbf24",
        12: "60a5fa", 13: "c084fc", 14: "22d3ee", 15: "f1f5f9",
    ]

    static let devbarBackground = NSColor(red: 0.039, green: 0.059, blue: 0.102, alpha: 1.0)
    static let devbarForeground = NSColor(red: 0.945, green: 0.961, blue: 0.976, alpha: 1.0)
    static let devbarCursor = NSColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 1.0)
}

// MARK: - NSColor hex parsing

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "000000" }
        return String(format: "%02x%02x%02x",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }

    convenience init?(hex: String) {
        var hexStr = hex.trimmingCharacters(in: .whitespaces)
        if hexStr.hasPrefix("#") { hexStr = String(hexStr.dropFirst()) }
        guard hexStr.count == 6, let val = UInt(hexStr, radix: 16) else { return nil }
        self.init(
            red: CGFloat((val >> 16) & 0xFF) / 255.0,
            green: CGFloat((val >> 8) & 0xFF) / 255.0,
            blue: CGFloat(val & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
