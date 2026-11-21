import Foundation

public struct NetworkInterfaceReading: Equatable, Sendable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Coarse kind derived from interface type; "other" when unknown.
    public var kind: Kind
    public var isUp: Bool
    public var receiveRate: Double?
    public var sendRate: Double?
    public var totalReceived: UInt64
    public var totalSent: UInt64

    public enum Kind: String, Codable, Sendable { case wifiOrEthernet, cellular, loopback, virtual, other }

    public init(
        name: String, kind: Kind, isUp: Bool, receiveRate: Double?, sendRate: Double?,
        totalReceived: UInt64, totalSent: UInt64
    ) {
        self.name = name
        self.kind = kind
        self.isUp = isUp
        self.receiveRate = receiveRate
        self.sendRate = sendRate
        self.totalReceived = totalReceived
        self.totalSent = totalSent
    }
}

public struct NetworkSnapshot: Equatable, Sendable, Codable {
    public var interfaces: [NetworkInterfaceReading]
    /// Aggregate over non-loopback, non-virtual interfaces. `nil` until two readings exist.
    public var receiveRate: Double?
    public var sendRate: Double?
    public var primaryInterface: String?

    public init(interfaces: [NetworkInterfaceReading], receiveRate: Double?, sendRate: Double?, primaryInterface: String?) {
        self.interfaces = interfaces
        self.receiveRate = receiveRate
        self.sendRate = sendRate
        self.primaryInterface = primaryInterface
    }
}

public struct DiskIOSnapshot: Equatable, Sendable, Codable {
    public var readRate: Double?
    public var writeRate: Double?
    public var totalRead: UInt64
    public var totalWritten: UInt64

    public init(readRate: Double?, writeRate: Double?, totalRead: UInt64, totalWritten: UInt64) {
        self.readRate = readRate
        self.writeRate = writeRate
        self.totalRead = totalRead
        self.totalWritten = totalWritten
    }
}

public struct VolumeInfo: Equatable, Sendable, Codable, Identifiable {
    public var id: String { mountPath }
    public var name: String
    public var mountPath: String
    public var fileSystem: String?
    public var totalBytes: UInt64
    /// Raw free space reported by the file system.
    public var freeBytes: UInt64
    /// Space available for important use, including purgeable space macOS can reclaim.
    /// This matches what Finder shows as "Available". `nil` if not reported.
    public var availableForImportantUse: UInt64?
    public var isBoot: Bool
    public var isRemovable: Bool

    public init(
        name: String, mountPath: String, fileSystem: String?, totalBytes: UInt64, freeBytes: UInt64,
        availableForImportantUse: UInt64?, isBoot: Bool, isRemovable: Bool
    ) {
        self.name = name
        self.mountPath = mountPath
        self.fileSystem = fileSystem
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableForImportantUse = availableForImportantUse
        self.isBoot = isBoot
        self.isRemovable = isRemovable
    }

    public var available: UInt64 { availableForImportantUse ?? freeBytes }
    public var usedFraction: Double {
        totalBytes > 0 ? 1 - Double(min(available, totalBytes)) / Double(totalBytes) : 0
    }
}

public struct PowerSnapshot: Equatable, Sendable, Codable {
    public enum Source: String, Codable, Sendable { case battery, adapter, unknown }

    public var hasBattery: Bool
    public var chargePercent: Double?
    public var isCharging: Bool?
    public var source: Source
    /// Minutes, only when macOS provides a non-negative estimate (it returns -1 while "calculating").
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// Full-charge capacity as a fraction of design capacity, when the battery reports both.
    public var healthFraction: Double?
    public var condition: String?

    public init(
        hasBattery: Bool, chargePercent: Double?, isCharging: Bool?, source: Source,
        minutesRemaining: Int?, cycleCount: Int?, healthFraction: Double?, condition: String?
    ) {
        self.hasBattery = hasBattery
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.source = source
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.healthFraction = healthFraction
        self.condition = condition
    }
}

/// Mirrors `ProcessInfo.ThermalState` without depending on it (Linux compatibility).
public enum ThermalLevel: Int, Codable, Sendable, Comparable {
    case nominal = 0, fair = 1, serious = 2, critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }

    public var explanation: String {
        switch self {
        case .nominal: return "No thermal constraints."
        case .fair: return "Slightly elevated. Fans may run; performance is not reduced."
        case .serious: return "macOS is reducing performance to manage heat."
        case .critical: return "macOS is significantly limiting performance to cool down."
        }
    }
}

public struct GPUSnapshot: Equatable, Sendable, Codable {
    public var name: String?
    public var utilization: Double?
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?

    public init(name: String?, utilization: Double?, rendererUtilization: Double?, tilerUtilization: Double?) {
        self.name = name
        self.utilization = utilization
        self.rendererUtilization = rendererUtilization
        self.tilerUtilization = tilerUtilization
    }
}

/// Everything collected in one coordinator tick. Each domain is optional: `nil` means
/// "not collected this tick" or "unavailable" — never zero.
public struct SystemSnapshot: Sendable {
    public var timestamp: Date
    public var cpu: CPULoad?
    public var loadAverage: Double?
    public var memory: MemorySnapshot?
    public var pageInsPerSecond: Double?
    public var pageOutsPerSecond: Double?
    public var network: NetworkSnapshot?
    public var disk: DiskIOSnapshot?
    public var volumes: [VolumeInfo]?
    public var power: PowerSnapshot?
    public var thermal: ThermalLevel?
    public var gpu: GPUSnapshot?
    public var processes: [ProcessSample]?

    public init(timestamp: Date) { self.timestamp = timestamp }

    /// Flattens the snapshot into scalar samples for history and diagnostics.
    public var samples: [Sample] {
        var out: [Sample] = []
        func add(_ id: MetricID, _ value: Double?) {
            if let value, value.isFinite { out.append(Sample(metric: id, time: timestamp, value: value)) }
        }
        add(.cpuTotal, cpu?.total)
        add(.cpuUser, cpu?.user)
        add(.cpuSystem, cpu?.system)
        add(.loadAverage1m, loadAverage)
        if let memory {
            add(.memoryUsedBytes, Double(memory.used))
            add(.memoryCompressedBytes, Double(memory.compressed))
            add(.memoryWiredBytes, Double(memory.wired))
            add(.memoryCachedFilesBytes, Double(memory.cachedFiles))
            add(.swapUsedBytes, Double(memory.swapUsed))
            add(.memoryPressureLevel, memory.pressure.map { Double($0.rawValue) })
        }
        add(.pageInsPerSecond, pageInsPerSecond)
        add(.pageOutsPerSecond, pageOutsPerSecond)
        add(.networkReceiveRate, network?.receiveRate)
        add(.networkSendRate, network?.sendRate)
        add(.diskReadRate, disk?.readRate)
        add(.diskWriteRate, disk?.writeRate)
        add(.bootVolumeAvailableBytes, volumes?.first(where: \.isBoot).map { Double($0.available) })
        add(.gpuUtilization, gpu?.utilization)
        if let power, power.hasBattery {
            add(.batteryChargePercent, power.chargePercent)
            add(.batteryOnExternalPower, power.source == .unknown ? nil : (power.source == .adapter ? 1 : 0))
        }
        add(.thermalStateLevel, thermal.map { Double($0.rawValue) })
        return out
    }
}

/// One scalar observation.
public struct Sample: Equatable, Sendable, Codable {
    public var metric: MetricID
    public var time: Date
    public var value: Double

    public init(metric: MetricID, time: Date, value: Double) {
        self.metric = metric
        self.time = time
        self.value = value
    }
}
