import Foundation

/// Single source of truth for version info.
/// Updated by scripts/release.sh
enum AppVersion {
    static let version = "0.1.1"
    static let buildDate = "2026-03-26"

    static var displayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: buildDate) {
            let display = DateFormatter()
            display.dateFormat = "MMMM d, yyyy"
            return "v\(version) · \(display.string(from: date))"
        }
        return "v\(version)"
    }
}
