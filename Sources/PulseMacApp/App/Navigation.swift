import PulseCore
import SwiftUI

/// Top-level sidebar destinations. Hardware domains (CPU, memory, …) are NOT top-level:
/// they are metric detail pages reached from Overview cards (docs/design/navigation.md).
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, processes, investigate, storage, insights, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .processes: return "Processes"
        case .investigate: return "Investigate"
        case .storage: return "Storage"
        case .insights: return "Insights"
        case .developer: return "Developer"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .processes: return "list.bullet.rectangle"
        case .investigate: return "waveform.path.ecg.rectangle"
        case .storage: return "internaldrive"
        case .insights: return "clock.arrow.circlepath"
        case .developer: return "hammer"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .processes: return "2"
        case .investigate: return "3"
        case .storage: return "4"
        case .insights: return "5"
        case .developer: return "6"
        }
    }
}

/// Context-sensitive detail pages pushed from Overview.
enum DetailRoute: String, Hashable, CaseIterable, Identifiable {
    case cpu, memory, network, disk, gpu, power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .disk: return "Disk"
        case .gpu: return "GPU"
        case .power: return "Battery & Thermal"
        }
    }
}

/// Menu bar display presets (docs/design/navigation.md § Menu bar).
enum MenuBarPreset: String, CaseIterable, Identifiable {
    case minimal, balanced, developer

    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: return "Minimal — status icon + CPU"
        case .balanced: return "Balanced — CPU, memory, network"
        case .developer: return "Developer — CPU, memory, disk writes"
        }
    }
}

enum PreferenceKey {
    static let menuBarPreset = "menuBarPreset"
    static let onboardingDone = "onboardingCompleted"
    static let notifyIncidents = "notifyIncidents"
    static let showAdvanced = "showAdvancedMetrics"
}
