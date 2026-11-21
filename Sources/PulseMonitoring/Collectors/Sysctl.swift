#if os(macOS)
import Darwin
import Foundation

/// Thin, typed wrappers over sysctl. Each returns nil on failure; callers decide whether
/// that means "unsupported" or "failed".
enum Sysctl {
    /// Reads an integer sysctl of either 32- or 64-bit width.
    static func integer(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        case 8:
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        default:
            return nil
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Reads a fixed-size struct sysctl (e.g. `vm.swapusage` → `xsw_usage`).
    static func value<T>(_ name: String, as type: T.Type, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }
}

/// Converts Mach absolute time units to nanoseconds. On Apple Silicon one tick is not one
/// nanosecond (timebase is typically 125/3), so every Mach time value must go through this.
struct MachTimebase {
    let numerator: UInt64
    let denominator: UInt64

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numerator = UInt64(info.numer == 0 ? 1 : info.numer)
        denominator = UInt64(info.denom == 0 ? 1 : info.denom)
    }

    func nanoseconds(_ ticks: UInt64) -> UInt64 {
        // Split multiply to avoid overflow for large tick counts.
        let (high, low) = ticks.quotientAndRemainder(dividingBy: denominator)
        return high * numerator + low * numerator / denominator
    }
}
#endif
