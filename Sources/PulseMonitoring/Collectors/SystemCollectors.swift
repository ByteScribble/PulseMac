#if os(macOS)
import Darwin
import Foundation
import PulseCore

// MARK: - CPU

/// Source: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` (Mach, public, no permissions).
public final class CPUCollector: Collector {
    public let descriptor = CollectorDescriptor(
        id: "cpu", capabilities: [.cpu], source: "host_processor_info (Mach) · getloadavg",
        expectedCost: "< 0.1 ms per call"
    )
    private var previous: [CPUTicks]?

    public init() {}

    public static func topology() -> CPUTopology {
        let logical = Int(Sysctl.integer("hw.logicalcpu") ?? Int64(ProcessInfo.processInfo.activeProcessorCount))
        let levels = Sysctl.integer("hw.nperflevels") ?? 0
        let performance = levels >= 1 ? Sysctl.integer("hw.perflevel0.logicalcpu").map(Int.init) : nil
        let efficiency = levels >= 2 ? Sysctl.integer("hw.perflevel1.logicalcpu").map(Int.init) : nil
        let brand = Sysctl.string("machdep.cpu.brand_string") ?? "Unknown CPU"
        return CPUTopology(logicalCores: logical, performanceCores: performance, efficiencyCores: efficiency, brand: brand)
    }

    public func probe() -> [Capability] {
        let status: CapabilityStatus = (try? readTicks()) != nil ? .available : .failed("host_processor_info returned an error.")
        return [Capability(id: .cpu, status: status, source: descriptor.source)]
    }

    public func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws {
        let current = try readTicks()
        defer { previous = current }
        if let previous { snapshot.cpu = CPULoad.compute(previous: previous, current: current) }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { snapshot.loadAverage = loads[0] }
    }

    public func reset() { previous = nil }

    private func readTicks() throws -> [CPUTicks] {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            throw CollectorFailure(collector: "cpu", message: "host_processor_info failed (\(result))")
        }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(processorCount)).map { core in
            func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * stride + Int(state)])) }
            return CPUTicks(
                user: ticks(CPU_STATE_USER), system: ticks(CPU_STATE_SYSTEM),
                idle: ticks(CPU_STATE_IDLE), nice: ticks(CPU_STATE_NICE)
            )
        }
    }
}

// MARK: - Memory

/// Sources: `host_statistics64(HOST_VM_INFO64)`, `vm.swapusage`,
/// `kern.memorystatus_vm_pressure_level`, `hw.memsize`. No permissions.
public final class MemoryCollector: Collector {
    public let descriptor = CollectorDescriptor(
        id: "memory", capabilities: [.memory],
        source: "host_statistics64 (Mach) · sysctl vm.swapusage, kern.memorystatus_vm_pressure_level",
        expectedCost: "< 0.1 ms per call"
    )
    private let physical = UInt64(Sysctl.integer("hw.memsize") ?? 0)
    private let pageSize: UInt64
    private var pageIns = RateCalculator()
    private var pageOuts = RateCalculator()

    public init() {
        var size: vm_size_t = 0
        pageSize = host_page_size(mach_host_self(), &size) == KERN_SUCCESS ? UInt64(size) : UInt64(getpagesize())
    }

    public func probe() -> [Capability] {
        let status: CapabilityStatus
        if readVMStatistics() == nil {
            status = .failed("host_statistics64 returned an error.")
        } else if Sysctl.integer("kern.memorystatus_vm_pressure_level") == nil {
            status = .experimental(note: "Memory pressure level is unavailable on this macOS version; usage and swap are still shown.")
        } else {
            status = .available
        }
        return [Capability(id: .memory, status: status, source: descriptor.source)]
    }

    public func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws {
        guard let stats = readVMStatistics() else {
            throw CollectorFailure(collector: "memory", message: "host_statistics64 failed")
        }
        func bytes(_ pages: natural_t) -> UInt64 { UInt64(pages) * pageSize }
        let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self, initial: xsw_usage())
        let pressure = Sysctl.integer("kern.memorystatus_vm_pressure_level").flatMap { MemoryPressureLevel(kernelValue: Int($0)) }
        snapshot.memory = MemorySnapshot(
            physical: physical,
            free: bytes(stats.free_count) + bytes(stats.speculative_count),
            active: bytes(stats.active_count), inactive: bytes(stats.inactive_count), wired: bytes(stats.wire_count),
            compressed: bytes(stats.compressor_page_count), purgeable: bytes(stats.purgeable_count),
            external: bytes(stats.external_page_count), internal: bytes(stats.internal_page_count),
            swapTotal: swap?.xsu_total ?? 0, swapUsed: swap?.xsu_used ?? 0, pressure: pressure,
            cumulativePageIns: stats.pageins, cumulativePageOuts: stats.pageouts
        )
        snapshot.pageInsPerSecond = pageIns.rate(value: stats.pageins, at: monotonicTime)
        snapshot.pageOutsPerSecond = pageOuts.rate(value: stats.pageouts, at: monotonicTime)
    }

    public func reset() {
        pageIns.reset()
        pageOuts.reset()
    }

    private func readVMStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }
}

// MARK: - Network

/// Source: `sysctl(NET_RT_IFLIST2)` 64-bit interface counters. No permissions.
/// Measures interface traffic, not internet bandwidth.
public final class NetworkCollector: Collector {
    public let descriptor = CollectorDescriptor(
        id: "network", capabilities: [.network], source: "sysctl NET_RT_IFLIST2 (64-bit interface counters)",
        expectedCost: "< 0.2 ms per call"
    )
    private var receive: [String: RateCalculator] = [:]
    private var send: [String: RateCalculator] = [:]

    /// Interfaces whose traffic is excluded from totals: AirDrop/peer-to-peer links, VPN tunnels
    /// (their traffic is already counted on the physical interface), bridges and loopback.
    static let excludedPrefixes = ["lo", "awdl", "llw", "utun", "ipsec", "bridge", "gif", "stf", "anpi", "ap", "vmenet"]

    public init() {}

    public func probe() -> [Capability] {
        [Capability(id: .network, status: readInterfaces() == nil ? .failed("Interface statistics unavailable.") : .available, source: descriptor.source)]
    }

    public func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws {
        guard let raw = readInterfaces() else {
            throw CollectorFailure(collector: "network", message: "sysctl NET_RT_IFLIST2 failed")
        }
        var interfaces: [NetworkInterfaceReading] = []
        var totalRx = 0.0, totalTx = 0.0
        var anyRate = false
        for item in raw {
            // `subscript(_:default:)` mutates in place, so calculator state is retained.
            let rx = receive[item.name, default: RateCalculator()].rate(value: item.ibytes, at: monotonicTime)
            let tx = send[item.name, default: RateCalculator()].rate(value: item.obytes, at: monotonicTime)
            interfaces.append(NetworkInterfaceReading(
                name: item.name, kind: item.kind, isUp: item.isUp, receiveRate: rx, sendRate: tx,
                totalReceived: item.ibytes, totalSent: item.obytes
            ))
            if item.countsTowardTotal, let rx, let tx {
                totalRx += rx
                totalTx += tx
                anyRate = true
            }
        }
        let primary = interfaces
            .filter { reading in raw.first { $0.name == reading.name }?.countsTowardTotal == true }
            .max { ($0.receiveRate ?? 0) + ($0.sendRate ?? 0) < ($1.receiveRate ?? 0) + ($1.sendRate ?? 0) }?.name
        snapshot.network = NetworkSnapshot(
            interfaces: interfaces, receiveRate: anyRate ? totalRx : nil, sendRate: anyRate ? totalTx : nil,
            primaryInterface: primary
        )
    }

    public func reset() {
        receive.removeAll()
        send.removeAll()
    }

    struct RawInterface {
        var name: String
        var kind: NetworkInterfaceReading.Kind
        var isUp: Bool
        var ibytes: UInt64
        var obytes: UInt64
        var countsTowardTotal: Bool { isUp && (kind == .wifiOrEthernet || kind == .cellular) }
    }

    func readInterfaces() -> [RawInterface]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var result: [RawInterface] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                defer { offset += max(Int(header.ifm_msglen), 1) }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { continue }
                let name = String(cString: nameBuffer)
                let type = Int32(message.ifm_data.ifi_type)
                let excluded = Self.excludedPrefixes.contains { name.hasPrefix($0) }
                let kind: NetworkInterfaceReading.Kind
                if type == IFT_LOOP {
                    kind = .loopback
                } else if excluded {
                    kind = .virtual
                } else if type == IFT_ETHER {
                    kind = .wifiOrEthernet
                } else if type == IFT_CELLULAR {
                    kind = .cellular
                } else {
                    kind = .other
                }
                result.append(RawInterface(
                    name: name, kind: kind, isUp: (message.ifm_flags & IFF_UP) != 0,
                    ibytes: message.ifm_data.ifi_ibytes, obytes: message.ifm_data.ifi_obytes
                ))
            }
        }
        return result
    }
}

// MARK: - Thermal

/// Source: `ProcessInfo.thermalState` (public). Sensor temperatures are deliberately not read
/// (they require undocumented SMC/HID interfaces; see capability matrix).
public final class ThermalCollector: Collector {
    public let descriptor = CollectorDescriptor(
        id: "thermal", capabilities: [.thermalState], source: "ProcessInfo.thermalState", expectedCost: "negligible"
    )

    public init() {}

    public func probe() -> [Capability] {
        [Capability(id: .thermalState, status: .available, source: descriptor.source)]
    }

    public func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: snapshot.thermal = .nominal
        case .fair: snapshot.thermal = .fair
        case .serious: snapshot.thermal = .serious
        case .critical: snapshot.thermal = .critical
        @unknown default: snapshot.thermal = nil
        }
    }

    public func reset() {}
}
#endif
