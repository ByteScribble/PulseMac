#if os(macOS)
import Darwin
import Foundation
import PulseCore

/// Enumerates processes and their resource use.
///
/// Sources:
/// - `sysctl(KERN_PROC_ALL)` → PID, parent, UID, start time, short name for *all* processes.
/// - `proc_pidpath` → executable path (most processes).
/// - `proc_pid_rusage(RUSAGE_INFO_V4)` → CPU time, physical footprint, disk I/O.
///   Succeeds only for processes owned by the current user; others are marked `.limited`
///   (macOS restricts this without root, and PulseMac never runs as root).
/// - `proc_pidinfo(PROC_PIDTASKINFO)` → thread count (same-user only).
public final class ProcessCollector: Collector {
    public let descriptor = CollectorDescriptor(
        id: "processes", capabilities: [.processes, .perProcessDiskIO, .processCPUOtherUsers],
        source: "sysctl KERN_PROC_ALL · libproc (proc_pid_rusage, proc_pidpath, proc_pidinfo)",
        expectedCost: "2–8 ms per call for ~600 processes (profile on target hardware)"
    )

    private struct Previous {
        var cpuNanoseconds: UInt64
        var diskRead: UInt64
        var diskWritten: UInt64
        var time: TimeInterval
    }

    private let timebase = MachTimebase()
    private var previous: [ProcessIdentity: Previous] = [:]
    private var pathCache: [ProcessIdentity: String] = [:]
    private var userNames: [UInt32: String] = [:]
    private let currentUser = getuid()

    public init() {}

    public func probe() -> [Capability] {
        let ok = Self.listProcesses() != nil
        return [
            Capability(id: .processes, status: ok ? .available : .failed("Could not list processes."), source: descriptor.source),
            Capability(id: .perProcessDiskIO, status: ok ? .available : .failed("Could not list processes."), source: "proc_pid_rusage (current user's processes)"),
            Capability(
                id: .processCPUOtherUsers,
                status: .needsPermission("macOS only shares CPU and memory of other users' and system processes with administrator tools. PulseMac does not use administrator privileges, so these appear without resource figures."),
                source: "proc_pid_rusage"
            ),
        ]
    }

    public func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws {
        guard let entries = Self.listProcesses() else {
            throw CollectorFailure(collector: "processes", message: "sysctl KERN_PROC_ALL failed")
        }
        var seen = Set<ProcessIdentity>()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(entries.count)

        for entry in entries {
            let identity = ProcessIdentity(pid: entry.pid, startTime: entry.startTime)
            seen.insert(identity)
            let path = executablePath(for: identity)
            var sample = ProcessSample(
                identity: identity, parentPID: entry.parentPID,
                name: path.map { ($0 as NSString).lastPathComponent } ?? entry.shortName,
                executablePath: path, userID: entry.userID, userName: userName(entry.userID),
                access: .limited, cpuPercent: nil, memoryFootprint: nil, diskReadRate: nil, diskWriteRate: nil,
                threadCount: nil
            )
            if let usage = Self.resourceUsage(entry.pid) {
                sample.access = .full
                sample.memoryFootprint = usage.ri_phys_footprint
                let cpu = timebase.nanoseconds(usage.ri_user_time) + timebase.nanoseconds(usage.ri_system_time)
                if let last = previous[identity], monotonicTime > last.time {
                    let wall = UInt64((monotonicTime - last.time) * 1_000_000_000)
                    sample.cpuPercent = cpu >= last.cpuNanoseconds
                        ? ProcessCPU.percentOfOneCore(cpuTimeDeltaNanoseconds: cpu - last.cpuNanoseconds, wallDeltaNanoseconds: wall)
                        : nil
                    let seconds = monotonicTime - last.time
                    sample.diskReadRate = Counter.delta(previous: last.diskRead, current: usage.ri_diskio_bytesread, width: .bits64).map { Double($0) / seconds }
                    sample.diskWriteRate = Counter.delta(previous: last.diskWritten, current: usage.ri_diskio_byteswritten, width: .bits64).map { Double($0) / seconds }
                }
                previous[identity] = Previous(
                    cpuNanoseconds: cpu, diskRead: usage.ri_diskio_bytesread,
                    diskWritten: usage.ri_diskio_byteswritten, time: monotonicTime
                )
                sample.threadCount = Self.threadCount(entry.pid)
            }
            samples.append(sample)
        }
        // Forget exited processes so state stays bounded.
        previous = previous.filter { seen.contains($0.key) }
        pathCache = pathCache.filter { seen.contains($0.key) }
        snapshot.processes = samples
    }

    public func reset() { previous.removeAll() }

    // MARK: - Helpers

    struct Entry {
        var pid: Int32
        var parentPID: Int32
        var userID: UInt32
        var startTime: Date
        var shortName: String
    }

    static func listProcesses() -> [Entry]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        size += size / 8 // headroom for processes started between calls
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        size = buffer.count * stride // report the real buffer length
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        let count = size / stride
        return buffer.prefix(count).compactMap { process -> Entry? in
            let pid = process.kp_proc.p_pid
            guard Int32(process.kp_proc.p_stat) != SZOMB else { return nil }
            let started = process.kp_proc.p_un.__p_starttime
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { raw -> String in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Entry(
                pid: pid, parentPID: process.kp_eproc.e_ppid, userID: process.kp_eproc.e_ucred.cr_uid,
                startTime: Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1e6),
                shortName: name
            )
        }
    }

    static func resourceUsage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    static func threadCount(_ pid: Int32) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }

    private func executablePath(for identity: ProcessIdentity) -> String? {
        if let cached = pathCache[identity] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(identity.pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        pathCache[identity] = path
        return path
    }

    private func userName(_ uid: UInt32) -> String? {
        if let cached = userNames[uid] { return cached }
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        let value = String(cString: name)
        userNames[uid] = value
        return value
    }
}

/// On-demand details for the process inspector (not collected every tick).
public enum ProcessDetails {
    /// Command-line arguments via `KERN_PROCARGS2`. Available for the current user's processes.
    /// Arguments may contain secrets: callers must pass them through `Redactor` before
    /// copying or exporting, and the UI hides them until the user reveals them.
    public static func arguments(pid: Int32) -> [String]? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var length = buffer.count
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip executable path and its NUL padding.
        while index < length, buffer[index] != 0 { index += 1 }
        while index < length, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < length {
            let start = index
            while index < length, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Re-reads a PID's start time to confirm it still refers to the same process
    /// (PIDs are reused). Used immediately before any process action.
    public static func isSameProcess(_ identity: ProcessIdentity) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, identity.pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        let started = info.kp_proc.p_un.__p_starttime
        let start = Double(started.tv_sec) + Double(started.tv_usec) / 1e6
        return abs(start - identity.startTime.timeIntervalSince1970) < 0.001
    }
}
#endif
