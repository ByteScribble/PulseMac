import Foundation

public enum BuiltInRules {
    public static var all: [any DiagnosticRule] {
        [
            SustainedCPURule(),
            MemoryPressureRule(),
            SwapGrowthRule(),
            SustainedDiskWriteRule(),
            LowDiskSpaceRule(),
            ThermalPressureRule(),
            RapidDischargeRule(),
        ]
    }
}

// MARK: - Shared helpers

enum RuleSupport {
    /// Window stats if the window has at least `minimumCount` samples covering at least
    /// `minimumCoverage` of the requested duration; otherwise nil (→ `.unknown`).
    static func window(
        _ context: RuleContext, _ metric: MetricID, seconds: TimeInterval,
        minimumCount: Int = 3, minimumCoverage: Double = 0.5
    ) -> WindowStats? {
        let samples = context.history.samples(metric, last: seconds, endingAt: context.now)
        guard samples.count >= minimumCount, let stats = WindowStats(samples) else { return nil }
        guard stats.coverage >= seconds * minimumCoverage else { return nil }
        return stats
    }

    static func topProcesses(
        _ processes: [ProcessSample]?, by metric: MetricID, limit: Int = 3,
        minimum: Double, value: (ProcessGroup) -> Double?, unitLabel: (Double) -> String
    ) -> [Contributor] {
        guard let processes else { return [] }
        return AppGrouping.group(processes)
            .compactMap { group -> (ProcessGroup, Double)? in
                guard let reading = value(group), reading >= minimum else { return nil }
                return (group, reading)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { group, reading in
                Contributor(
                    name: group.name, pid: group.members.count == 1 ? group.members[0].pid : nil,
                    metric: metric, value: reading, unitLabel: unitLabel(reading)
                )
            }
    }

    static func limitedAccessNote(_ processes: [ProcessSample]?) -> Evidence? {
        guard let processes else {
            return Evidence(.limitation, "Process details were not being collected, so contributors are unknown.")
        }
        let limited = processes.filter { $0.access == .limited }.count
        guard limited > 0 else { return nil }
        return Evidence(
            .limitation,
            "\(limited) processes owned by other users or macOS could not be measured without administrator access."
        )
    }

    static func contributorEvidence(_ contributors: [Contributor], what: String) -> Evidence? {
        guard !contributors.isEmpty else { return nil }
        let list = contributors.map { "\($0.name) (\($0.unitLabel))" }.joined(separator: ", ")
        return Evidence(.correlation, "Highest \(what) while this was happening: \(list). High use at the same time does not prove these apps caused it.")
    }
}

// MARK: - CPU

public struct SustainedCPURule: DiagnosticRule {
    public let id = "cpu.sustained"
    public let primaryMetric = MetricID.cpuTotal
    public var triggerPercent = 85.0
    public var clearPercent = 70.0
    public var window: TimeInterval = 30
    public let minimumObservation: TimeInterval
    public let clearDuration: TimeInterval = 60
    public let cooldown: TimeInterval = 600

    public init(minimumObservation: TimeInterval = 120) { self.minimumObservation = minimumObservation }

    public func evaluate(_ context: RuleContext) -> RuleSignal {
        guard let stats = RuleSupport.window(context, .cpuTotal, seconds: window) else { return .unknown }
        if stats.mean >= triggerPercent { return .triggered(value: stats.mean) }
        if stats.mean <= clearPercent { return .clear }
        return .holding
    }

    public func content(_ context: RuleContext, startedAt: Date, peak: Double?) -> IncidentContent {
        let duration = Format.duration(context.now.timeIntervalSince(startedAt))
        let contributors = RuleSupport.topProcesses(
            context.processes, by: .cpuTotal, minimum: 20, value: \.cpuPercent,
            unitLabel: { Format.percent($0) + " of a core" }
        )
        var evidence = [
            Evidence(.observation, "CPU usage stayed above \(Int(triggerPercent))% of total capacity for \(duration).", metric: .cpuTotal),
        ]
        if let peak { evidence.append(Evidence(.observation, "Peak 30-second average: \(Format.percent(peak)).", metric: .cpuTotal)) }
        if let item = RuleSupport.contributorEvidence(contributors, what: "CPU use") { evidence.append(item) }
        if let note = RuleSupport.limitedAccessNote(context.processes) { evidence.append(note) }
        return IncidentContent(
            title: "Sustained high CPU usage",
            summary: "The CPU has been busy for \(duration). Apps may respond slowly and the Mac may get warm.",
            severity: .warning, evidence: evidence, contributors: contributors,
            nextStep: "Check whether the busiest apps are doing expected work (builds, exports, indexing). If not, inspect them."
        )
    }
}

// MARK: - Memory

public struct MemoryPressureRule: DiagnosticRule {
    public let id = "memory.pressure"
    public let primaryMetric = MetricID.memoryPressureLevel
    public let minimumObservation: TimeInterval = 60
    public let clearDuration: TimeInterval = 120
    public let cooldown: TimeInterval = 900

    public init() {}

    public func evaluate(_ context: RuleContext) -> RuleSignal {
        guard let stats = RuleSupport.window(context, .memoryPressureLevel, seconds: 15, minimumCount: 2, minimumCoverage: 0.3)
        else { return .unknown }
        if stats.min >= Double(MemoryPressureLevel.warning.rawValue) { return .triggered(value: stats.max) }
        if stats.max <= Double(MemoryPressureLevel.normal.rawValue) { return .clear }
        return .holding
    }

    public func content(_ context: RuleContext, startedAt: Date, peak: Double?) -> IncidentContent {
        let duration = Format.duration(context.now.timeIntervalSince(startedAt))
        let critical = (peak ?? 0) >= Double(MemoryPressureLevel.critical.rawValue)
        var evidence = [
            Evidence(.observation, "macOS has reported \(critical ? "critical" : "elevated") memory pressure for \(duration).", metric: .memoryPressureLevel),
        ]
        let swap = context.history.samples(.swapUsedBytes, from: startedAt, to: context.now)
        if let first = swap.first, let last = swap.last, last.value - first.value > 64_000_000 {
            evidence.append(Evidence(.observation, "Swap grew by \(Format.bytes(last.value - first.value)) during this period.", metric: .swapUsedBytes))
        }
        let contributors = RuleSupport.topProcesses(
            context.processes, by: .memoryUsedBytes, minimum: 500_000_000,
            value: { $0.memoryFootprint.map(Double.init) }, unitLabel: Format.bytes
        )
        if let item = RuleSupport.contributorEvidence(contributors, what: "memory footprints") { evidence.append(item) }
        if let note = RuleSupport.limitedAccessNote(context.processes) { evidence.append(note) }
        return IncidentContent(
            title: critical ? "Memory is critically constrained" : "Memory pressure is elevated",
            summary: "macOS is working hard to provide memory (compressing and swapping). This can make switching apps and loading files slow.",
            severity: critical ? .urgent : .warning, evidence: evidence, contributors: contributors,
            nextStep: "Inspect the largest memory consumers and their trends. Quitting an unneeded large app usually relieves pressure."
        )
    }
}

public struct SwapGrowthRule: DiagnosticRule {
    public let id = "memory.swapGrowth"
    public let primaryMetric = MetricID.swapUsedBytes
    public var window: TimeInterval = 600
    public var triggerBytes = 1_000_000_000.0
    public var clearBytes = 128_000_000.0
    public let minimumObservation: TimeInterval = 0
    public let clearDuration: TimeInterval = 300
    public let cooldown: TimeInterval = 1800

    public init() {}

    public func evaluate(_ context: RuleContext) -> RuleSignal {
        guard let stats = RuleSupport.window(context, .swapUsedBytes, seconds: window, minimumCoverage: 0.8) else { return .unknown }
        let growth = stats.last.value - stats.first.value
        if growth >= triggerBytes { return .triggered(value: growth) }
        if growth <= clearBytes { return .clear }
        return .holding
    }

    public func content(_ context: RuleContext, startedAt: Date, peak: Double?) -> IncidentContent {
        let growth = peak ?? triggerBytes
        return IncidentContent(
            title: "Swap is growing quickly",
            summary: "About \(Format.bytes(growth)) of memory was moved to disk within \(Int(window / 60)) minutes. Memory demand is exceeding physical memory.",
            severity: .warning,
            evidence: [
                Evidence(.observation, "Swap used increased by \(Format.bytes(growth)) in \(Int(window / 60)) minutes.", metric: .swapUsedBytes),
                Evidence(.hypothesis, "A recently started or growing workload is the most common reason. Compare memory trends of the largest apps."),
            ],
            contributors: [],
            nextStep: "Open the Memory detail page and sort processes by memory growth."
        )
    }
}

// MARK: - Disk

public struct SustainedDiskWriteRule: DiagnosticRule {
    public let id = "disk.sustainedWrites"
    public let primaryMetric = MetricID.diskWriteRate
    public var triggerRate = 150_000_000.0
    public var clearRate = 50_000_000.0
    public let minimumObservation: TimeInterval = 300
    public let clearDuration: TimeInterval = 120
    public let cooldown: TimeInterval = 1800

    public init() {}

    public func evaluate(_ context: RuleContext) -> RuleSignal {
        guard let stats = RuleSupport.window(context, .diskWriteRate, seconds: 60) else { return .unknown }
        if stats.mean >= triggerRate { return .triggered(value: stats.mean) }
        if stats.mean <= clearRate { return .clear }
        return .holding
    }

    public func content(_ context: RuleContext, startedAt: Date, peak: Double?) -> IncidentContent {
        let duration = Format.duration(context.now.timeIntervalSince(startedAt))
        let contributors = RuleSupport.topProcesses(
            context.processes, by: .diskWriteRate, minimum: 5_000_000, value: \.diskWriteRate,
            unitLabel: Format.bytesPerSecond
        )
        var evidence = [
            Evidence(.observation, "Disk writes averaged above \(Format.bytesPerSecond(triggerRate)) for \(duration).", metric: .diskWriteRate),
        ]
        if let item = RuleSupport.contributorEvidence(contributors, what: "disk writes") { evidence.append(item) }
        evidence.append(Evidence(.limitation, "Swap and file-system activity by macOS itself is not attributed to any app."))
        return IncidentContent(
            title: "Heavy disk writes for an extended period",
            summary: "Something has been writing heavily to disk for \(duration). Common causes are builds, backups, sync clients, downloads and swap.",
            severity: .info, evidence: evidence, contributors: contributors,
            nextStep: "Check whether the writer is expected (Time Machine, a build, a download). Unexpected sustained writes are worth inspecting."
        )
    }
}

public struct LowDiskSpaceRule: DiagnosticRule {
    public let id = "disk.lowSpace"
    public let primaryMetric = MetricID.bootVolumeAvailableBytes
    public var triggerBytes = 10_000_000_000.0
    public var urgentBytes = 5_000_000_000.0
    public var clearBytes = 15_000_000_000.0
    public let minimumObservation: TimeInterval = 0
    public let clearDuration: TimeInterval = 60
    public let cooldown: TimeInterval = 3600

    public init() {}

    public func evaluate(_ context: RuleContext) -> RuleSignal {
        guard let latest = context.history.samples(.bootVolumeAvailableBytes, last: 300, endingAt: context.now).last
        else { return .unknown }
        // Invert so "peak" tracks the worst (lowest) available space.
        if latest.value < triggerBytes { return .triggered(value: -latest.value) }
        if latest.value > clearBytes { return .clear }
        return .holding
    }

    public func content(_ context: RuleContext, startedAt: Date, peak: Double?) -> IncidentContent {
        let available = context.history.samples(.bootVolumeAvailableBytes, last: 300, endingAt: context.now).last?.value ?? 0
        let urgent = available < urgentBytes
        return IncidentContent(
            title: "Startup disk is low on space",
            summary: "Only \(Format.bytes(available)) is available. macOS needs free space for swap, updates and caches; very low space slows the system.",
            severity: urgent ? .urgent : .warning,
            evidence: [
                Evidence(.observation, "Available space (including purgeable space) is \(Format.bytes(available)).", metric: .bootVolumeAvailableBytes),
            ],
            contributors: [],
            nextStep: "Open Storage to find large folders and rebuildable developer caches. Nothing is deleted without your review."
        )
    }
}

// MARK: - Thermal & power

public struct ThermalPressureRule: DiagnosticRule {
    public let id = "thermal.pressure"
    public let primaryMetric = MetricID.thermalStateLevel
    public let minimumObservation: TimeInterval = 60
    public let clearDuration: TimeInterval = 120
    public let cooldown: TimeInterval = 900

    public init() {}

    public func evaluate(_ context: RuleContext) -> RuleSignal {
        guard let stats = RuleSupport.window(context, .thermalStateLevel, seconds: 30, minimumCount: 2, minimumCoverage: 0.3)
        else { return .unknown }
        if stats.min >= Double(ThermalLevel.serious.rawValue) { return .triggered(value: stats.max) }
        if stats.max <= Double(ThermalLevel.fair.rawValue) { return .clear }
        return .holding
    }

    public func content(_ context: RuleContext, startedAt: Date, peak: Double?) -> IncidentContent {
        let level = ThermalLevel(rawValue: Int(peak ?? 2)) ?? .serious
        var evidence = [
            Evidence(.observation, "macOS reported a \(level.label.lowercased()) thermal state for \(Format.duration(context.now.timeIntervalSince(startedAt))).", metric: .thermalStateLevel),
        ]
        if let cpu = RuleSupport.window(context, .cpuTotal, seconds: 120) {
            evidence.append(Evidence(.correlation, "CPU averaged \(Format.percent(cpu.mean)) over the last 2 minutes.", metric: .cpuTotal))
        }
        evidence.append(Evidence(.limitation, "Thermal state is macOS's summary; individual sensor temperatures are not read in this version."))
        return IncidentContent(
            title: "Mac is reducing performance to manage heat",
            summary: level.explanation,
            severity: level == .critical ? .urgent : .warning,
            evidence: evidence, contributors: [],
            nextStep: "Check for sustained CPU or GPU work. Make sure vents are not blocked and the Mac is on a hard surface."
        )
    }
}

public struct RapidDischargeRule: DiagnosticRule {
    public let id = "power.rapidDischarge"
    public let primaryMetric = MetricID.batteryChargePercent
    public var window: TimeInterval = 600
    /// Percentage points per hour (positive number = discharge speed).
    public var triggerRate = 20.0
    public var clearRate = 12.0
    public let minimumObservation: TimeInterval = 0
    public let clearDuration: TimeInterval = 300
    public let cooldown: TimeInterval = 1800

    public init() {}

    enum DischargeReading: Equatable { case unknown, onPower, rate(Double) }

    /// Discharge speed in percentage points per hour, from a least-squares fit of the charge
    /// over the window. Requires the whole window to be on battery.
    func discharge(_ context: RuleContext) -> DischargeReading {
        guard let external = RuleSupport.window(context, .batteryOnExternalPower, seconds: window, minimumCoverage: 0.8)
        else { return .unknown }
        if external.max > 0 { return .onPower }
        let samples = context.history.samples(.batteryChargePercent, last: window, endingAt: context.now)
        guard let trend = TrendStatistics.fit(samples), trend.duration >= window * 0.8 else { return .unknown }
        return .rate(-trend.slope * 3600)
    }

    public func evaluate(_ context: RuleContext) -> RuleSignal {
        switch discharge(context) {
        case .unknown: return .unknown
        case .onPower: return .clear
        case let .rate(rate):
            if rate >= triggerRate { return .triggered(value: rate) }
            if rate <= clearRate { return .clear }
            return .holding
        }
    }

    public func content(_ context: RuleContext, startedAt: Date, peak: Double?) -> IncidentContent {
        let rate = peak ?? triggerRate
        let contributors = RuleSupport.topProcesses(
            context.processes, by: .cpuTotal, minimum: 15, value: \.cpuPercent,
            unitLabel: { Format.percent($0) + " of a core" }
        )
        var evidence = [
            Evidence(.observation, "Battery fell at about \(String(format: "%.0f", rate))% per hour over the last \(Int(window / 60)) minutes while unplugged.", metric: .batteryChargePercent),
        ]
        if let item = RuleSupport.contributorEvidence(contributors, what: "CPU use") { evidence.append(item) }
        evidence.append(Evidence(.limitation, "macOS does not expose exact per-app energy use to other apps. CPU activity is shown as a proxy, not as an energy measurement."))
        return IncidentContent(
            title: "Battery is draining quickly",
            summary: "At this rate a full battery would last roughly \(Int(100 / max(rate, 1))) hours.",
            severity: .warning, evidence: evidence, contributors: contributors,
            nextStep: "Look for background apps with steady CPU use, and check display brightness and connected devices."
        )
    }
}
