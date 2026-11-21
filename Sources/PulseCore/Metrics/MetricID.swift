import Foundation

/// Unit of a recorded measurement. Every stored sample carries exactly one unit,
/// defined by its `MetricID`. See docs/architecture/capability-matrix.md.
public enum MetricUnit: String, Codable, Sendable {
    /// 0...100, relative to the denominator documented on the metric.
    case percent
    case bytes
    case bytesPerSecond
    case count
    case perSecond
    case celsius
    /// Ordinal level (e.g. memory pressure 0 normal / 1 warning / 2 critical).
    case level
    case milliseconds
    case percentPerHour
}

/// Stable identifier of a scalar time series. Raw values are persisted — never rename.
public enum MetricID: String, Codable, Sendable, CaseIterable, Hashable {
    // CPU — share of total logical-CPU capacity (all cores = 100%).
    case cpuTotal = "cpu.total"
    case cpuUser = "cpu.user"
    case cpuSystem = "cpu.system"
    case loadAverage1m = "cpu.load1"

    // Memory
    case memoryUsedBytes = "mem.used"
    case memoryCompressedBytes = "mem.compressed"
    case memoryWiredBytes = "mem.wired"
    case memoryCachedFilesBytes = "mem.cached"
    case memoryPressureLevel = "mem.pressure"
    case swapUsedBytes = "mem.swap.used"
    case pageInsPerSecond = "mem.pageins"
    case pageOutsPerSecond = "mem.pageouts"

    // Network (interface throughput — not internet bandwidth)
    case networkReceiveRate = "net.rx"
    case networkSendRate = "net.tx"

    // Disk activity
    case diskReadRate = "disk.read"
    case diskWriteRate = "disk.write"
    case bootVolumeAvailableBytes = "disk.boot.available"

    // GPU (experimental source; see capability matrix)
    case gpuUtilization = "gpu.util"

    // Power & thermal
    case batteryChargePercent = "power.charge"
    case batteryOnExternalPower = "power.external"
    case thermalStateLevel = "thermal.state"

    public var unit: MetricUnit {
        switch self {
        case .cpuTotal, .cpuUser, .cpuSystem, .gpuUtilization, .batteryChargePercent: return .percent
        case .loadAverage1m: return .count
        case .memoryUsedBytes, .memoryCompressedBytes, .memoryWiredBytes, .memoryCachedFilesBytes,
             .swapUsedBytes, .bootVolumeAvailableBytes:
            return .bytes
        case .memoryPressureLevel, .thermalStateLevel, .batteryOnExternalPower: return .level
        case .pageInsPerSecond, .pageOutsPerSecond: return .perSecond
        case .networkReceiveRate, .networkSendRate, .diskReadRate, .diskWriteRate: return .bytesPerSecond
        }
    }

    public var displayName: String {
        switch self {
        case .cpuTotal: return "CPU"
        case .cpuUser: return "CPU (user)"
        case .cpuSystem: return "CPU (system)"
        case .loadAverage1m: return "Load average (1 min)"
        case .memoryUsedBytes: return "Memory used"
        case .memoryCompressedBytes: return "Compressed memory"
        case .memoryWiredBytes: return "Wired memory"
        case .memoryCachedFilesBytes: return "Cached files"
        case .memoryPressureLevel: return "Memory pressure"
        case .swapUsedBytes: return "Swap used"
        case .pageInsPerSecond: return "Page-ins"
        case .pageOutsPerSecond: return "Page-outs"
        case .networkReceiveRate: return "Download"
        case .networkSendRate: return "Upload"
        case .diskReadRate: return "Disk read"
        case .diskWriteRate: return "Disk write"
        case .bootVolumeAvailableBytes: return "Startup disk available"
        case .gpuUtilization: return "GPU"
        case .batteryChargePercent: return "Battery"
        case .batteryOnExternalPower: return "On power adapter"
        case .thermalStateLevel: return "Thermal state"
        }
    }

    /// Plain-language meaning shown in tooltips. Single source of truth for metric explanations.
    public var explanation: String {
        switch self {
        case .cpuTotal:
            return "Share of all CPU cores in use, averaged over the sampling interval. 100% means every core is busy."
        case .cpuUser:
            return "CPU time spent running apps and other user processes."
        case .cpuSystem:
            return "CPU time spent in the macOS kernel on behalf of processes (I/O, memory management, scheduling)."
        case .loadAverage1m:
            return "Average number of threads running or waiting to run over the last minute. Compare it with the number of cores; it is not a percentage."
        case .memoryUsedBytes:
            return "App memory + wired + compressed, the same definition Activity Monitor uses. High usage alone is normal on macOS."
        case .memoryCompressedBytes:
            return "Memory macOS compressed to avoid swapping. Some compression is healthy; rapid growth suggests memory is tight."
        case .memoryWiredBytes:
            return "Memory the kernel must keep resident. It cannot be compressed or swapped."
        case .memoryCachedFilesBytes:
            return "Recently used file data kept in memory. macOS reclaims it instantly when apps need memory."
        case .memoryPressureLevel:
            return "macOS's own assessment of how hard it is working to provide memory. This is the best single indicator of a memory shortage."
        case .swapUsedBytes:
            return "Memory written out to disk. Growing swap during normal work means memory demand exceeds physical memory."
        case .pageInsPerSecond:
            return "Pages read from disk into memory (file data and swapped memory)."
        case .pageOutsPerSecond:
            return "Pages written from memory to disk. Sustained page-outs indicate memory pressure."
        case .networkReceiveRate:
            return "Bytes received across active network interfaces. This is traffic, not your internet speed."
        case .networkSendRate:
            return "Bytes sent across active network interfaces. This is traffic, not your internet speed."
        case .diskReadRate:
            return "Bytes read from physical storage devices."
        case .diskWriteRate:
            return "Bytes written to physical storage devices. Sustained heavy writes can slow the system and indicate runaway logging or sync."
        case .bootVolumeAvailableBytes:
            return "Space available on the startup disk for important use, including purgeable space macOS can free on demand."
        case .gpuUtilization:
            return "GPU busy percentage reported by the graphics driver. Experimental: read from an undocumented IOKit property."
        case .batteryChargePercent:
            return "Current battery charge as reported by macOS power management."
        case .batteryOnExternalPower:
            return "1 when the Mac draws power from an adapter, 0 when on battery."
        case .thermalStateLevel:
            return "macOS thermal state (0 nominal, 1 fair, 2 serious, 3 critical). At serious and above macOS reduces performance to cool down."
        }
    }
}
