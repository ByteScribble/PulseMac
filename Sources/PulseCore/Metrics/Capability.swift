import Foundation

/// Honest availability of a measurement or feature on this Mac.
/// The UI renders every non-`available` state explicitly — never as zero.
public enum CapabilityStatus: Equatable, Sendable {
    case available
    /// Works, but relies on undocumented behaviour that may change between macOS releases.
    case experimental(note: String)
    /// Requires a permission the user has not granted (feature-gated, never requested up front).
    case needsPermission(String)
    /// Not provided by this hardware/OS (e.g. no battery on a Mac mini).
    case unsupported(String)
    /// Feasible but intentionally not built yet (see docs/roadmap.md).
    case deferred(String)
    /// Collector failed at runtime.
    case failed(String)

    public var isUsable: Bool {
        switch self {
        case .available, .experimental: return true
        default: return false
        }
    }

    public var shortLabel: String {
        switch self {
        case .available: return "Available"
        case .experimental: return "Experimental"
        case .needsPermission: return "Needs permission"
        case .unsupported: return "Not supported"
        case .deferred: return "Not yet available"
        case .failed: return "Unavailable"
        }
    }

    public var reason: String? {
        switch self {
        case .available: return nil
        case let .experimental(note): return note
        case let .needsPermission(reason), let .unsupported(reason), let .deferred(reason), let .failed(reason):
            return reason
        }
    }
}

public enum CapabilityID: String, CaseIterable, Sendable, Hashable {
    case cpu, memory, processes, processCPUOtherUsers, network, perProcessNetwork, diskIO, perProcessDiskIO
    case volumes, battery, thermalState, temperatureSensors, fans, gpuUtilization, perProcessGPU, neuralEngine
    case storageScan, listeningPorts

    public var title: String {
        switch self {
        case .cpu: return "CPU usage"
        case .memory: return "Memory & pressure"
        case .processes: return "Process list"
        case .processCPUOtherUsers: return "Resource usage of other users' processes"
        case .network: return "Network interface traffic"
        case .perProcessNetwork: return "Per-app network traffic"
        case .diskIO: return "Disk activity"
        case .perProcessDiskIO: return "Per-process disk activity"
        case .volumes: return "Storage capacity"
        case .battery: return "Battery"
        case .thermalState: return "Thermal state"
        case .temperatureSensors: return "Temperature sensors"
        case .fans: return "Fan speed"
        case .gpuUtilization: return "GPU utilization"
        case .perProcessGPU: return "Per-app GPU usage"
        case .neuralEngine: return "Neural Engine activity"
        case .storageScan: return "Folder size scanning"
        case .listeningPorts: return "Listening ports"
        }
    }
}

public struct Capability: Identifiable, Equatable, Sendable {
    public var id: CapabilityID
    public var status: CapabilityStatus
    /// Data source, e.g. "host_processor_info (Mach)". Shown in the metric's "About this number".
    public var source: String

    public init(id: CapabilityID, status: CapabilityStatus, source: String) {
        self.id = id
        self.status = status
        self.source = source
    }
}

/// Thread-safe registry of capability states. Collectors update it; UI reads snapshots.
public final class CapabilityRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CapabilityID: Capability] = [:]

    public init(_ initial: [Capability] = []) {
        for capability in initial { storage[capability.id] = capability }
    }

    public func set(_ capability: Capability) {
        lock.lock(); defer { lock.unlock() }
        storage[capability.id] = capability
    }

    public func status(of id: CapabilityID) -> CapabilityStatus {
        lock.lock(); defer { lock.unlock() }
        return storage[id]?.status ?? .deferred("Not evaluated yet.")
    }

    public func all() -> [Capability] {
        lock.lock(); defer { lock.unlock() }
        return CapabilityID.allCases.compactMap { storage[$0] }
    }
}
