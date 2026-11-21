import AppKit
import PulseCore
import SwiftUI

/// Design tokens. Single source of truth for spacing, radii, colour and type
/// (documented in docs/design/design-system.md).
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let small: CGFloat = 6
    static let card: CGFloat = 10
    static let window: CGFloat = 12
}

extension Color {
    /// Adaptive colour from light/dark sRGB hex values.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}

enum Palette {
    /// Restrained blue/cyan accent.
    static let accent = Color(light: 0x0B72B9, dark: 0x4CB3EA)
    static let accentSoft = Color(light: 0xE3F1FA, dark: 0x16303F)

    // Semantic status. Never the only carrier of meaning: always paired with icon + text.
    static let neutral = Color(nsColor: .secondaryLabelColor)
    static let warning = Color(light: 0xB86E00, dark: 0xF2B441)
    static let urgent = Color(nsColor: .systemRed)
    /// Only for verified healthy / successful states.
    static let verified = Color(nsColor: .systemGreen)

    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.35)

    /// Chart series colours (distinguishable in both appearances and for common colour-vision deficiencies).
    static let series: [Color] = [accent, Color(light: 0x7A5AC8, dark: 0xA88BEB), Color(light: 0xC2410C, dark: 0xF59E68), Color(light: 0x0F766E, dark: 0x5EC9BC)]
}

/// Visual treatment of a status level.
enum StatusStyle {
    case calm, attention, urgent, unknown, verified

    init(_ status: HealthSummary.Status) {
        switch status {
        case .calm: self = .calm
        case .attention: self = .attention
        case .urgent: self = .urgent
        case .unknown: self = .unknown
        }
    }

    init(_ severity: Severity) {
        switch severity {
        case .info: self = .calm
        case .warning: self = .attention
        case .urgent: self = .urgent
        }
    }

    var color: Color {
        switch self {
        case .calm: return Palette.accent
        case .attention: return Palette.warning
        case .urgent: return Palette.urgent
        case .unknown: return Palette.neutral
        case .verified: return Palette.verified
        }
    }

    var symbol: String {
        switch self {
        case .calm: return "checkmark.circle"
        case .attention: return "exclamationmark.triangle.fill"
        case .urgent: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        case .verified: return "checkmark.seal.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .calm: return "Normal"
        case .attention: return "Needs attention"
        case .urgent: return "Urgent"
        case .unknown: return "Unknown"
        case .verified: return "Verified"
        }
    }
}

extension Font {
    /// Large live reading; monospaced digits keep columns stable while values change.
    static let metricValue = Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
    static let metricValueSmall = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
    static let metricUnit = Font.system(size: 12, weight: .medium)
    static let cardTitle = Font.system(size: 12, weight: .semibold)
}
