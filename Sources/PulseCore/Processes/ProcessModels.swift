import Foundation

/// Identity of a process instance. PIDs are reused by the kernel, so a PID alone does not
/// identify a process across time; PID + start time does.
public struct ProcessIdentity: Hashable, Sendable, Codable {
    public var pid: Int32
    public var startTime: Date

    public init(pid: Int32, startTime: Date) {
        self.pid = pid
        self.startTime = startTime
    }
}

/// What PulseMac was allowed to read about a process. Without root, macOS restricts
/// task-level information for processes owned by other users.
public enum ProcessAccess: String, Sendable, Codable {
    /// Resource usage readable (same user).
    case full
    /// Only name/PID/parent/user readable (other user or protected process).
    case limited
}

public struct ProcessSample: Identifiable, Equatable, Sendable, Codable {
    public var id: ProcessIdentity { identity }
    public var identity: ProcessIdentity
    public var parentPID: Int32
    public var name: String
    public var executablePath: String?
    public var userID: UInt32
    public var userName: String?
    public var access: ProcessAccess
    /// % of one logical core (may exceed 100). `nil` until two samples exist or when access is limited.
    public var cpuPercent: Double?
    /// Physical footprint in bytes (matches Activity Monitor "Memory").
    public var memoryFootprint: UInt64?
    public var diskReadRate: Double?
    public var diskWriteRate: Double?
    public var threadCount: Int?

    public init(
        identity: ProcessIdentity, parentPID: Int32, name: String, executablePath: String?, userID: UInt32,
        userName: String?, access: ProcessAccess, cpuPercent: Double?, memoryFootprint: UInt64?,
        diskReadRate: Double?, diskWriteRate: Double?, threadCount: Int?
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.userID = userID
        self.userName = userName
        self.access = access
        self.cpuPercent = cpuPercent
        self.memoryFootprint = memoryFootprint
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
        self.threadCount = threadCount
    }

    public var pid: Int32 { identity.pid }

    /// Bundle path of the enclosing app (".../Foo.app"), used to group helpers with their app.
    public var appBundlePath: String? { AppGrouping.outermostAppBundle(in: executablePath) }
}

public enum AppGrouping {
    /// Returns the outermost `.app` bundle in a path, so
    /// `/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper`
    /// groups under `/Applications/Slack.app`.
    public static func outermostAppBundle(in path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else {
            if let path, path.hasSuffix(".app") { return path }
            return nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    public static func displayName(forBundlePath bundlePath: String) -> String {
        let last = (bundlePath as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// Groups processes by app bundle; processes outside bundles stand alone.
    public static func group(_ processes: [ProcessSample]) -> [ProcessGroup] {
        var buckets: [String: [ProcessSample]] = [:]
        var order: [String] = []
        for process in processes {
            let key = process.appBundlePath ?? "pid:\(process.pid):\(process.identity.startTime.timeIntervalSince1970)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(process)
        }
        return order.map { key in
            let members = buckets[key] ?? []
            let name = key.hasPrefix("pid:") ? (members.first?.name ?? key) : displayName(forBundlePath: key)
            return ProcessGroup(id: key, name: name, bundlePath: key.hasPrefix("pid:") ? nil : key, members: members)
        }
    }
}

public struct ProcessGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundlePath: String?
    public var members: [ProcessSample]

    /// Sums only members with readable values; `nil` if none are readable.
    public var cpuPercent: Double? {
        let values = members.compactMap(\.cpuPercent)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var memoryFootprint: UInt64? {
        let values = members.compactMap(\.memoryFootprint)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var diskWriteRate: Double? {
        let values = members.compactMap(\.diskWriteRate)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}
