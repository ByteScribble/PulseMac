import Foundation

/// Deterministic, locale-independent formatting for numeric readings.
/// UI may wrap these with localized formatters later; tests rely on these exact outputs.
public enum Format {
    /// Binary-prefixed bytes using macOS-style decimal units (1 KB = 1000 B), matching Finder.
    public static func bytes(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var magnitude = abs(value)
        var index = 0
        while magnitude >= 1000, index < units.count - 1 {
            magnitude /= 1000
            index += 1
        }
        let sign = value < 0 ? "-" : ""
        if index == 0 { return "\(sign)\(Int(magnitude)) B" }
        let digits = magnitude >= 100 ? 0 : (magnitude >= 10 ? 1 : 2)
        return sign + String(format: "%.\(digits)f", magnitude) + " " + units[index]
    }

    public static func bytesPerSecond(_ value: Double) -> String {
        bytes(value) + "/s"
    }

    public static func percent(_ value: Double, fractionDigits: Int = 0) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(fractionDigits)f%%", value)
    }

    /// "4m 12s", "2h 05m", "3d 4h".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    public static func value(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .percent: return percent(value)
        case .bytes: return bytes(value)
        case .bytesPerSecond: return bytesPerSecond(value)
        case .count: return String(format: "%.2f", value)
        case .perSecond: return String(format: "%.0f/s", value)
        case .celsius: return String(format: "%.0f °C", value)
        case .level: return String(format: "%.0f", value)
        case .milliseconds: return String(format: "%.0f ms", value)
        case .percentPerHour: return String(format: "%.1f%%/h", value)
        }
    }
}
