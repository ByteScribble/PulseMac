#if os(macOS)
import Foundation
import IOKit
import IOKit.ps
import PulseCore

/// Reads all properties of an IORegistry entry as a Swift dictionary.
func registryProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
    return properties?.takeRetainedValue() as? [String: Any]
}

/// Calls `body` for every service matching `className`, releasing each.
func forEachService(matching className: String, _ body: (io_service_t) -> Void) -> Bool {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
        return false
    }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        body(service)
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return true
}

// MARK: - Disk I/O

/// Source: IOKit `IOBlockStorageDriver` "Statistics" (public registry, no permissions).
/// Sums all block storage drivers (internal and external disks).
public final class DiskIOCollector: Collector {
    public let descriptor = CollectorDescriptor(
        id: "diskIO", capabilities: [.diskIO], source: "IOKit IOBlockStorageDriver statistics",
        expectedCost: "~0.3 ms per call"
    )
    private var readRate = RateCalculator()
    private var writeRate = RateCalculator()

    public init() {}

    public func probe() -> [Capability] {
        [Capability(id: .diskIO, status: readTotals() == nil ? .failed("No block storage statistics found.") : .available, source: descriptor.source)]
    }

    public func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws {
        guard let totals = readTotals() else {
            throw CollectorFailure(collector: "diskIO", message: "IOBlockStorageDriver statistics unavailable")
        }
        snapshot.disk = DiskIOSnapshot(
            readRate: readRate.rate(value: totals.read, at: monotonicTime),
            writeRate: writeRate.rate(value: totals.written, at: monotonicTime),
            totalRead: totals.read, totalWritten: totals.written
        )
    }

    public func reset() {
        readRate.reset()
        writeRate.reset()
    }

    private func readTotals() -> (read: UInt64, written: UInt64)? {
        var read: UInt64 = 0
        var written: UInt64 = 0
        var found = false
        let ok = forEachService(matching: "IOBlockStorageDriver") { service in
            guard let statistics = registryProperties(service)?["Statistics"] as? [String: Any] else { return }
            found = true
            read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return ok && found ? (read, written) : nil
    }
}

// MARK: - Volumes

/// Source: Foundation volume resource values. `volumeAvailableCapacityForImportantUsage`
/// includes purgeable space and matches Finder's "Available".
public final class VolumeCollector: Collector {
    public let descriptor: CollectorDescriptor

    public init(cadence: Int = 30) {
        descriptor = CollectorDescriptor(
            id: "volumes", capabilities: [.volumes], source: "URLResourceValues (volume capacity keys)",
            cadence: cadence, expectedCost: "1–5 ms per call (important-usage capacity is computed by the OS)"
        )
    }

    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey, .volumeIsRemovableKey,
        .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey,
    ]

    public func probe() -> [Capability] {
        [Capability(id: .volumes, status: .available, source: descriptor.source)]
    }

    public func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws {
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys, options: [.skipHiddenVolumes]) else {
            throw CollectorFailure(collector: "volumes", message: "Could not list mounted volumes")
        }
        snapshot.volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            return VolumeInfo(
                name: values.volumeName ?? url.lastPathComponent, mountPath: url.path,
                fileSystem: values.volumeLocalizedFormatDescription,
                totalBytes: UInt64(total), freeBytes: UInt64(max(values.volumeAvailableCapacity ?? 0, 0)),
                availableForImportantUse: values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) },
                isBoot: values.volumeIsRootFileSystem ?? false, isRemovable: values.volumeIsRemovable ?? false
            )
        }
    }

    public func reset() {}
}

// MARK: - Power

/// Sources: IOKit power sources API (public) for charge/state; `AppleSmartBattery` registry
/// entry for cycle count and capacities (readable without permissions, keys undocumented).
public final class PowerCollector: Collector {
    public let descriptor: CollectorDescriptor

    public init(cadence: Int = 5) {
        descriptor = CollectorDescriptor(
            id: "power", capabilities: [.battery], source: "IOPSCopyPowerSourcesInfo · AppleSmartBattery registry",
            cadence: cadence, expectedCost: "~0.5 ms per call"
        )
    }

    public func probe() -> [Capability] {
        var snapshot = SystemSnapshot(timestamp: Date())
        try? collect(into: &snapshot, monotonicTime: 0)
        let status: CapabilityStatus = snapshot.power?.hasBattery == true
            ? .available
            : .unsupported("This Mac has no battery.")
        return [Capability(id: .battery, status: status, source: descriptor.source)]
    }

    public func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            throw CollectorFailure(collector: "power", message: "Power source information unavailable")
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var power = PowerSnapshot(
            hasBattery: false, chargePercent: nil, isCharging: nil,
            source: providing == kIOPSACPowerValue ? .adapter : (providing == kIOPSBatteryPowerValue ? .battery : .unknown),
            minutesRemaining: nil, cycleCount: nil, healthFraction: nil, condition: nil
        )
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            power.hasBattery = true
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                power.chargePercent = Double(current) / Double(maximum) * 100
            }
            power.isCharging = description[kIOPSIsChargingKey] as? Bool
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes >= 0, power.source == .battery {
                power.minutesRemaining = minutes
            }
            power.condition = description[kIOPSBatteryHealthKey] as? String
        }
        if power.hasBattery { readSmartBattery(into: &power) }
        snapshot.power = power
    }

    private func readSmartBattery(into power: inout PowerSnapshot) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        power.cycleCount = property("CycleCount")
        // Apple Silicon reports MaxCapacity as a percentage; the raw mAh value is AppleRawMaxCapacity.
        if let design = property("DesignCapacity"), design > 0,
           let fullCharge = property("AppleRawMaxCapacity") ?? property("NominalChargeCapacity") {
            power.healthFraction = min(Double(fullCharge) / Double(design), 1.2)
        }
    }

    public func reset() {}
}

// MARK: - GPU

/// Source: IOKit `IOAccelerator` "PerformanceStatistics" → "Device Utilization %".
/// The registry API is public; the property keys are undocumented driver output and may
/// change between macOS releases, so this capability is labelled Experimental.
public final class GPUCollector: Collector {
    public let descriptor = CollectorDescriptor(
        id: "gpu", capabilities: [.gpuUtilization], source: "IOKit IOAccelerator PerformanceStatistics (undocumented keys)",
        cadence: 2, expectedCost: "~0.5 ms per call"
    )

    public init() {}

    public func probe() -> [Capability] {
        var snapshot = SystemSnapshot(timestamp: Date())
        try? collect(into: &snapshot, monotonicTime: 0)
        let status: CapabilityStatus = snapshot.gpu?.utilization != nil
            ? .experimental(note: "Read from an undocumented graphics driver property. Values may be unavailable after macOS updates.")
            : .unsupported("The graphics driver did not report utilization.")
        return [Capability(id: .gpuUtilization, status: status, source: descriptor.source)]
    }

    public func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws {
        var best: GPUSnapshot?
        _ = forEachService(matching: "IOAccelerator") { service in
            guard let statistics = registryProperties(service)?["PerformanceStatistics"] as? [String: Any] else { return }
            func percent(_ key: String) -> Double? { (statistics[key] as? NSNumber)?.doubleValue }
            guard let utilization = percent("Device Utilization %") ?? percent("GPU Activity(%)") else { return }
            var className = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(service, &className)
            let name = String(cString: className)
            let reading = GPUSnapshot(
                name: name.hasPrefix("AGX") ? "Apple GPU" : name, utilization: utilization,
                rendererUtilization: percent("Renderer Utilization %"), tilerUtilization: percent("Tiler Utilization %")
            )
            if (best?.utilization ?? -1) < utilization { best = reading }
        }
        snapshot.gpu = best
    }

    public func reset() {}
}
#endif
