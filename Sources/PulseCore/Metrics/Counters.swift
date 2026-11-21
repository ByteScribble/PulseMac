import Foundation

/// Width of a monotonically increasing hardware/kernel counter.
public enum CounterWidth: Sendable {
    /// Wraps at 2^32 (e.g. Mach CPU tick counters are `natural_t`).
    case bits32
    /// Treated as non-wrapping; a decrease means the counter was reset.
    case bits64
}

public enum Counter {
    /// Difference between two readings of a monotonically increasing counter.
    ///
    /// - 32-bit counters: a decrease is interpreted as a single wrap-around.
    /// - 64-bit counters: a decrease is interpreted as a reset (interface re-created,
    ///   driver reloaded, process restarted) and returns `nil` so callers skip the interval
    ///   instead of reporting a huge or negative value.
    public static func delta(previous: UInt64, current: UInt64, width: CounterWidth) -> UInt64? {
        if current >= previous { return current - previous }
        switch width {
        case .bits32:
            guard previous <= UInt64(UInt32.max), current <= UInt64(UInt32.max) else { return nil }
            return (UInt64(UInt32.max) - previous) + current + 1
        case .bits64:
            return nil
        }
    }
}

/// Converts successive cumulative counter readings into a per-second rate.
///
/// Returns `nil` for the first reading, after a reset, and when the interval between
/// readings exceeds `maximumGap` (system sleep, suspended app) — a rate averaged across a
/// sleep would be misleading.
public struct RateCalculator: Sendable {
    public let width: CounterWidth
    public let maximumGap: TimeInterval
    private var last: (value: UInt64, time: TimeInterval)?

    public init(width: CounterWidth = .bits64, maximumGap: TimeInterval = 30) {
        self.width = width
        self.maximumGap = maximumGap
    }

    /// - Parameters:
    ///   - value: cumulative counter reading
    ///   - time: monotonic timestamp in seconds (use a monotonic clock, not wall time)
    public mutating func rate(value: UInt64, at time: TimeInterval) -> Double? {
        defer { last = (value, time) }
        guard let last else { return nil }
        let elapsed = time - last.time
        guard elapsed > 0, elapsed <= maximumGap else { return nil }
        guard let delta = Counter.delta(previous: last.value, current: value, width: width) else { return nil }
        return Double(delta) / elapsed
    }

    public mutating func reset() { last = nil }
}
