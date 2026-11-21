import Foundation

/// macOS memory pressure as reported by `kern.memorystatus_vm_pressure_level`
/// (1 = normal, 2 = warning, 4 = critical).
public enum MemoryPressureLevel: Int, Codable, Sendable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    public init?(kernelValue: Int) {
        switch kernelValue {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

/// Point-in-time memory accounting. All sizes in bytes; page counters are cumulative.
public struct MemorySnapshot: Equatable, Sendable, Codable {
    public var physical: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var purgeable: UInt64
    /// File-backed pages (cached files).
    public var external: UInt64
    /// Anonymous pages (app memory before purgeable is subtracted).
    public var `internal`: UInt64
    public var swapTotal: UInt64
    public var swapUsed: UInt64
    public var pressure: MemoryPressureLevel?
    public var cumulativePageIns: UInt64
    public var cumulativePageOuts: UInt64

    public init(
        physical: UInt64, free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64,
        compressed: UInt64, purgeable: UInt64, external: UInt64, internal: UInt64,
        swapTotal: UInt64, swapUsed: UInt64, pressure: MemoryPressureLevel?,
        cumulativePageIns: UInt64, cumulativePageOuts: UInt64
    ) {
        self.physical = physical
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.external = external
        self.internal = `internal`
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
        self.pressure = pressure
        self.cumulativePageIns = cumulativePageIns
        self.cumulativePageOuts = cumulativePageOuts
    }

    /// App memory: anonymous memory minus purgeable (Activity Monitor's definition).
    public var appMemory: UInt64 { `internal` > purgeable ? `internal` - purgeable : 0 }

    /// "Memory Used" = app + wired + compressed, clamped to physical memory.
    public var used: UInt64 { min(appMemory + wired + compressed, physical) }

    /// Memory the system can hand out quickly: free + cached files + purgeable.
    public var cachedFiles: UInt64 { external + purgeable }

    public var usedFraction: Double { physical > 0 ? Double(used) / Double(physical) : 0 }
}

/// Plain-language interpretation of memory state. Distinguishes "full but healthy"
/// (caches) from genuine constraint (pressure + swap activity).
public enum MemoryInterpreter {
    public struct Assessment: Equatable, Sendable {
        public enum Status: Equatable, Sendable { case healthy, watch, constrained, unknown }
        public var status: Status
        public var headline: String
        public var detail: String
    }

    /// - Parameters:
    ///   - swapGrowthBytes: change in swap used over the recent window (nil if unknown)
    ///   - pageOutsPerSecond: recent page-out rate (nil if unknown)
    public static func assess(
        _ snapshot: MemorySnapshot,
        swapGrowthBytes: Double?,
        pageOutsPerSecond: Double?
    ) -> Assessment {
        guard let pressure = snapshot.pressure else {
            return Assessment(
                status: .unknown,
                headline: "Memory pressure unavailable",
                detail: "macOS did not report a memory pressure level, so PulseMac cannot judge whether memory is constrained."
            )
        }
        let swapGrowing = (swapGrowthBytes ?? 0) > 256 * 1_000_000
        let pagingOut = (pageOutsPerSecond ?? 0) > 100

        switch pressure {
        case .critical:
            return Assessment(
                status: .constrained,
                headline: "Memory is critically constrained",
                detail: "macOS reports critical memory pressure. Apps may pause or be asked to release memory. Check the largest memory consumers."
            )
        case .warning:
            let evidence = swapGrowing ? " Swap usage grew recently, so memory is being written to disk." : ""
            return Assessment(
                status: .constrained,
                headline: "Memory pressure is elevated",
                detail: "macOS is compressing and possibly swapping memory to keep up with demand." + evidence
            )
        case .normal:
            if swapGrowing || pagingOut {
                return Assessment(
                    status: .watch,
                    headline: "Memory is adequate, with some swap activity",
                    detail: "Pressure is normal, but swap or page-outs increased recently. Keep an eye on it if the Mac feels slow."
                )
            }
            if snapshot.usedFraction > 0.85 {
                return Assessment(
                    status: .healthy,
                    headline: "Memory is well used, not under pressure",
                    detail: "Most memory is in use, which is normal on macOS: unused memory is wasted memory. Pressure is normal and swap is stable."
                )
            }
            return Assessment(
                status: .healthy,
                headline: "No memory pressure",
                detail: "Memory pressure is normal and swap is stable."
            )
        }
    }
}
