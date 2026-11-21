import Foundation

/// Cumulative per-core tick counters as reported by `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
/// Each field is a 32-bit Mach counter widened to UInt64; wrap-around is handled by `CPULoad.compute`.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// CPU utilization over one sampling interval.
///
/// Denominator: total logical-CPU capacity. `total == 100` means every logical core was busy
/// for the whole interval. Per-core values use that core's capacity as denominator.
public struct CPULoad: Equatable, Sendable, Codable {
    public var total: Double
    public var user: Double
    public var system: Double
    public var perCore: [Double]

    public init(total: Double, user: Double, system: Double, perCore: [Double]) {
        self.total = total
        self.user = user
        self.system = system
        self.perCore = perCore
    }

    /// Computes utilization from two tick snapshots. Returns `nil` if the core count changed
    /// or no time elapsed on any core.
    public static func compute(previous: [CPUTicks], current: [CPUTicks]) -> CPULoad? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var sumUser = 0.0, sumSystem = 0.0, sumBusy = 0.0, sumAll = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        for (old, new) in zip(previous, current) {
            guard
                let user = Counter.delta(previous: old.user, current: new.user, width: .bits32),
                let system = Counter.delta(previous: old.system, current: new.system, width: .bits32),
                let idle = Counter.delta(previous: old.idle, current: new.idle, width: .bits32),
                let nice = Counter.delta(previous: old.nice, current: new.nice, width: .bits32)
            else { return nil }
            let userTicks = Double(user + nice)
            let systemTicks = Double(system)
            let all = userTicks + systemTicks + Double(idle)
            perCore.append(all > 0 ? (userTicks + systemTicks) / all * 100 : 0)
            sumUser += userTicks
            sumSystem += systemTicks
            sumBusy += userTicks + systemTicks
            sumAll += all
        }
        guard sumAll > 0 else { return nil }
        return CPULoad(
            total: sumBusy / sumAll * 100,
            user: sumUser / sumAll * 100,
            system: sumSystem / sumAll * 100,
            perCore: perCore
        )
    }
}

/// Static CPU topology. Performance/efficiency cluster sizes come from
/// `hw.perflevel{0,1}.logicalcpu`; we do NOT map individual core indices to clusters because
/// that ordering is not documented.
public struct CPUTopology: Equatable, Sendable, Codable {
    public var logicalCores: Int
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var brand: String

    public init(logicalCores: Int, performanceCores: Int?, efficiencyCores: Int?, brand: String) {
        self.logicalCores = logicalCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.brand = brand
    }
}

public enum ProcessCPU {
    /// CPU usage of a process between two samples, as % of ONE logical core
    /// (Activity Monitor convention: a process using 4 cores fully shows 400%).
    public static func percentOfOneCore(cpuTimeDeltaNanoseconds: UInt64, wallDeltaNanoseconds: UInt64) -> Double {
        guard wallDeltaNanoseconds > 0 else { return 0 }
        return Double(cpuTimeDeltaNanoseconds) / Double(wallDeltaNanoseconds) * 100
    }

    /// Same reading expressed as % of total system capacity (all cores = 100%).
    public static func percentOfSystem(percentOfOneCore: Double, logicalCores: Int) -> Double {
        guard logicalCores > 0 else { return 0 }
        return percentOfOneCore / Double(logicalCores)
    }
}
