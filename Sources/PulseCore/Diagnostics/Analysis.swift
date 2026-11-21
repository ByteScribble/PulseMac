import Foundation

/// Overall status line for the Overview and menu bar. Deliberately not a numeric "health score":
/// it is derived only from active incidents and explicit unknowns.
public struct HealthSummary: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case calm, attention, urgent, unknown }
    public var status: Status
    public var headline: String
    public var detail: String

    public static func make(activeIncidents: [Incident], hasRecentData: Bool, at date: Date) -> HealthSummary {
        guard hasRecentData else {
            return HealthSummary(
                status: .unknown, headline: "Waiting for measurements",
                detail: "PulseMac needs a few seconds of data before it can describe your Mac's state."
            )
        }
        let visible = activeIncidents.filter { $0.isVisible(at: date) }.sorted { $0.severity > $1.severity }
        guard let worst = visible.first else {
            return HealthSummary(
                status: .calm, headline: "No significant resource pressure detected",
                detail: "CPU, memory, disk and thermal readings are within normal ranges."
            )
        }
        let others = visible.count - 1
        let suffix = others > 0 ? " Plus \(others) other \(others == 1 ? "observation" : "observations")." : ""
        return HealthSummary(
            status: worst.severity == .urgent ? .urgent : .attention,
            headline: worst.title,
            detail: worst.summary + suffix
        )
    }
}

/// Heuristic for "is this process's memory steadily growing?" — explicitly not a leak detector.
public enum MemoryGrowthAnalyzer {
    public enum Assessment: Equatable, Sendable {
        case insufficientData(needed: TimeInterval)
        case stable
        case fluctuating
        /// Grows steadily (good linear fit) — consistent with a leak, but also with caches or
        /// growing workloads.
        case steadyGrowth(bytesPerHour: Double, rSquared: Double)

        public var explanation: String {
            switch self {
            case let .insufficientData(needed):
                return "Not enough history yet. PulseMac needs about \(Format.duration(needed)) of samples for this process."
            case .stable:
                return "Memory footprint is stable."
            case .fluctuating:
                return "Memory rises and falls with activity. This is typical of apps that allocate and release memory as they work."
            case let .steadyGrowth(rate, _):
                return "Memory has grown steadily at about \(Format.bytes(rate)) per hour. This is consistent with a leak, but also with caches or a workload that is legitimately growing. Restarting the app and watching whether growth resumes is the simplest test."
            }
        }

        public var isSuspicious: Bool {
            if case .steadyGrowth = self { return true }
            return false
        }
    }

    public static func assess(
        _ samples: [Sample], minimumDuration: TimeInterval = 1800,
        minimumGrowthBytes: Double = 300_000_000, minimumRSquared: Double = 0.85
    ) -> Assessment {
        guard let trend = TrendStatistics.fit(samples), trend.duration >= minimumDuration else {
            let covered = samples.count >= 2 ? samples.last!.time.timeIntervalSince(samples.first!.time) : 0
            return .insufficientData(needed: max(minimumDuration - covered, 0))
        }
        let growth = trend.slope * trend.duration
        if growth >= minimumGrowthBytes, trend.rSquared >= minimumRSquared {
            return .steadyGrowth(bytesPerHour: trend.slope * 3600, rSquared: trend.rSquared)
        }
        if abs(growth) < minimumGrowthBytes / 3 { return .stable }
        return .fluctuating
    }
}

/// Before/after comparison used to verify whether an action had a measurable effect.
public enum EffectVerifier {
    public enum Verdict: Equatable, Sendable {
        case insufficientData
        case improved(before: Double, after: Double)
        case unchanged(before: Double, after: Double)
        case worse(before: Double, after: Double)
    }

    /// - Parameters:
    ///   - lowerIsBetter: true for CPU, memory pressure, swap growth, disk writes.
    ///   - relativeThreshold: minimum relative change to count as a difference (default 15%).
    public static func compare(
        baseline: [Sample], after: [Sample], lowerIsBetter: Bool = true,
        relativeThreshold: Double = 0.15, minimumSamples: Int = 5
    ) -> Verdict {
        guard baseline.count >= minimumSamples, after.count >= minimumSamples,
              let before = WindowStats(baseline)?.mean, let later = WindowStats(after)?.mean
        else { return .insufficientData }
        let scale = max(abs(before), 1e-9)
        let change = (later - before) / scale
        if abs(change) < relativeThreshold { return .unchanged(before: before, after: later) }
        let better = lowerIsBetter ? change < 0 : change > 0
        return better ? .improved(before: before, after: later) : .worse(before: before, after: later)
    }

    /// Plain-language result. Never claims a permanent fix.
    public static func describe(_ verdict: Verdict, metric: MetricID) -> String {
        let name = metric.displayName.lowercased()
        let unit = metric.unit
        switch verdict {
        case .insufficientData:
            return "Not enough measurements yet to tell whether \(name) changed. Keep PulseMac open for a minute."
        case let .improved(before, after):
            return "\(metric.displayName) went from \(Format.value(before, unit: unit)) to \(Format.value(after, unit: unit)) after the action. This shows a change at that time, not a permanent fix."
        case let .unchanged(before, after):
            return "No meaningful change in \(name) (\(Format.value(before, unit: unit)) → \(Format.value(after, unit: unit)))."
        case let .worse(before, after):
            return "\(metric.displayName) rose from \(Format.value(before, unit: unit)) to \(Format.value(after, unit: unit)) after the action. Something else may be involved."
        }
    }
}
