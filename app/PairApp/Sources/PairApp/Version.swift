import Foundation

/// Single source of truth for version info.
/// Updated by scripts/release.sh
enum AppVersion {
    static let version = "0.3.14"
    static let buildDate = "2026-04-16"

    static var displayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: buildDate) {
            let display = DateFormatter()
            display.dateFormat = "MMM d"
            return "v\(version) · \(display.string(from: date))"
        }
        return "v\(version)"
    }
}
