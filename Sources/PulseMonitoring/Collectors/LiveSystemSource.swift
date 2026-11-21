#if os(macOS)
import Foundation
import PulseCore

/// Composition root for live collectors. Capabilities that are intentionally not collected
/// are registered with an honest status so the UI can explain them (acceptance G).
public enum LiveSystemSource {
    public static func make(registry: CapabilityRegistry = CapabilityRegistry()) -> CollectorSet {
        registry.set(Capability(
            id: .perProcessNetwork,
            status: .deferred("macOS has no public API for per-app network usage. Planned as an optional feature using nettop-equivalent data for your own processes."),
            source: "—"
        ))
        registry.set(Capability(
            id: .temperatureSensors,
            status: .deferred("Sensor temperatures require undocumented SMC/HID interfaces whose keys change with every Apple chip. PulseMac shows macOS's thermal state instead."),
            source: "—"
        ))
        registry.set(Capability(id: .fans, status: .deferred("Fan speed requires undocumented SMC access. Fan control is out of scope."), source: "—"))
        registry.set(Capability(id: .perProcessGPU, status: .unsupported("macOS does not attribute GPU time to individual processes through public APIs."), source: "—"))
        registry.set(Capability(id: .neuralEngine, status: .unsupported("No public API reports Neural Engine activity."), source: "—"))
        registry.set(Capability(id: .listeningPorts, status: .deferred("Planned for the Developer module (your own processes only)."), source: "libproc PROC_PIDFDSOCKETINFO"))
        registry.set(Capability(
            id: .storageScan, status: .available,
            source: "FileManager. Some folders (Mail, Messages, other apps' data) need Full Disk Access and are reported as unreadable without it."
        ))

        let collectors: [any Collector] = [
            CPUCollector(),
            MemoryCollector(),
            NetworkCollector(),
            DiskIOCollector(),
            VolumeCollector(),
            PowerCollector(),
            ThermalCollector(),
            GPUCollector(),
            ProcessCollector(),
        ]
        return CollectorSet(collectors: collectors, topology: CPUCollector.topology(), registry: registry)
    }
}
#endif
