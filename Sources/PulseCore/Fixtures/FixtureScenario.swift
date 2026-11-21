import Foundation

/// Deterministic synthetic system behaviour used for UI development, demo mode and replay
/// tests. Every snapshot produced here is FIXTURE DATA; the app shows a persistent banner
/// whenever a fixture source is active.
public enum FixtureScenario: String, CaseIterable, Sendable {
    case calm
    case memoryPressure
    case runawayProcess
    case batteryDrain

    public var title: String {
        switch self {
        case .calm: return "Calm system"
        case .memoryPressure: return "Memory pressure building"
        case .runawayProcess: return "Runaway process"
        case .batteryDrain: return "Rapid battery drain"
        }
    }
}

/// Seeded linear congruential generator: reproducible noise across platforms.
public struct SeededRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9 : seed }

    public mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }

    public mutating func jitter(_ amplitude: Double) -> Double { (next() * 2 - 1) * amplitude }
}

public struct FixtureGenerator: Sendable {
    public let scenario: FixtureScenario
    public let start: Date
    public let physicalMemory: UInt64 = 16_000_000_000
    public let logicalCores = 10
    private var random: SeededRandom
    private var swapUsed: Double = 600_000_000
    private var charge: Double = 82
    private var totalRx: UInt64 = 0
    private var totalTx: UInt64 = 0

    public init(scenario: FixtureScenario, start: Date, seed: UInt64 = 42) {
        self.scenario = scenario
        self.start = start
        random = SeededRandom(seed: seed)
    }

    public static let topology = CPUTopology(logicalCores: 10, performanceCores: 6, efficiencyCores: 4, brand: "Fixture M-series (10-core)")

    /// Snapshot at `elapsed` seconds into the scenario. Call with increasing `elapsed`.
    public mutating func snapshot(at elapsed: TimeInterval, interval: TimeInterval = 1) -> SystemSnapshot {
        let time = start.addingTimeInterval(elapsed)
        var snapshot = SystemSnapshot(timestamp: time)
        let minutes = elapsed / 60

        // CPU
        var cpuBase = 12 + 6 * sin(elapsed / 37) + random.jitter(4)
        if scenario == .runawayProcess, minutes >= 1 { cpuBase = 93 + random.jitter(3) }
        if scenario == .batteryDrain { cpuBase = 34 + random.jitter(5) }
        let total = min(max(cpuBase, 1), 100)
        let perCore = (0..<logicalCores).map { index in
            min(max(total + Double(index % 3) * 4 - 4 + random.jitter(8), 0), 100)
        }
        snapshot.cpu = CPULoad(total: total, user: total * 0.72, system: total * 0.28, perCore: perCore)
        snapshot.loadAverage = total / 100 * Double(logicalCores) * 0.9

        // Memory
        var used = 9_800_000_000.0 + random.jitter(150_000_000)
        var pressure = MemoryPressureLevel.normal
        if scenario == .memoryPressure {
            used = min(9_800_000_000 + minutes * 900_000_000, 15_600_000_000)
            if minutes >= 4 { swapUsed += 6_000_000 * interval }
            if minutes >= 3 { pressure = .warning }
            if minutes >= 9 { pressure = .critical }
        }
        let compressed = scenario == .memoryPressure ? min(800_000_000 + minutes * 300_000_000, 4_500_000_000) : 900_000_000
        let wired = 2_400_000_000.0
        let app = max(used - wired - compressed, 0)
        snapshot.memory = MemorySnapshot(
            physical: physicalMemory, free: UInt64(max(Double(physicalMemory) - used - 2_000_000_000, 150_000_000)),
            active: UInt64(app * 0.6), inactive: UInt64(app * 0.4), wired: UInt64(wired), compressed: UInt64(compressed),
            purgeable: 200_000_000, external: 1_800_000_000, internal: UInt64(app + 200_000_000),
            swapTotal: UInt64(max(swapUsed * 1.5, 1_073_741_824)), swapUsed: UInt64(swapUsed), pressure: pressure,
            cumulativePageIns: 0, cumulativePageOuts: 0
        )
        snapshot.pageInsPerSecond = max(40 + random.jitter(30), 0)
        snapshot.pageOutsPerSecond = pressure == .normal ? 0 : 400 + random.jitter(100)

        // Network
        let rx = max(180_000 + 120_000 * sin(elapsed / 13) + random.jitter(60_000), 0)
        let tx = max(25_000 + random.jitter(15_000), 0)
        totalRx += UInt64(rx * interval)
        totalTx += UInt64(tx * interval)
        snapshot.network = NetworkSnapshot(
            interfaces: [
                NetworkInterfaceReading(name: "en0", kind: .wifiOrEthernet, isUp: true, receiveRate: rx, sendRate: tx, totalReceived: totalRx, totalSent: totalTx),
            ],
            receiveRate: rx, sendRate: tx, primaryInterface: "en0"
        )

        // Disk
        let write = scenario == .memoryPressure && pressure != .normal ? 60_000_000 + random.jitter(20_000_000) : max(2_000_000 + random.jitter(1_500_000), 0)
        snapshot.disk = DiskIOSnapshot(readRate: max(4_000_000 + random.jitter(3_000_000), 0), writeRate: write, totalRead: 0, totalWritten: 0)
        snapshot.volumes = [
            VolumeInfo(
                name: "Macintosh HD", mountPath: "/", fileSystem: "apfs", totalBytes: 994_662_584_320,
                freeBytes: 211_000_000_000, availableForImportantUse: 236_000_000_000, isBoot: true, isRemovable: false
            ),
        ]

        // Power & thermal
        // ~30%/hour in the drain scenario, ~7%/hour otherwise.
        charge = max(charge - (scenario == .batteryDrain ? 30.0 : 7.0) / 3600 * interval, 1)
        snapshot.power = PowerSnapshot(
            hasBattery: true, chargePercent: max(charge, 1), isCharging: false, source: .battery,
            minutesRemaining: nil, cycleCount: 214, healthFraction: 0.91, condition: "Normal"
        )
        snapshot.thermal = scenario == .runawayProcess && minutes >= 4 ? .serious : (total > 70 ? .fair : .nominal)
        snapshot.gpu = GPUSnapshot(name: "Fixture GPU", utilization: max(6 + random.jitter(4), 0), rendererUtilization: nil, tilerUtilization: nil)
        snapshot.processes = processes(at: time, elapsed: elapsed, cpuTotal: total, memoryUsed: used)
        return snapshot
    }

    private mutating func processes(at time: Date, elapsed: TimeInterval, cpuTotal: Double, memoryUsed: Double) -> [ProcessSample] {
        let boot = start.addingTimeInterval(-86_400)
        func make(_ pid: Int32, _ name: String, _ path: String?, cpu: Double?, memory: Double?, uid: UInt32 = 501, access: ProcessAccess = .full, parent: Int32 = 1, write: Double? = 0, threads: Int? = 12) -> ProcessSample {
            ProcessSample(
                identity: ProcessIdentity(pid: pid, startTime: boot.addingTimeInterval(Double(pid))), parentPID: parent, name: name,
                executablePath: path, userID: uid, userName: uid == 0 ? "root" : "fixture", access: access,
                cpuPercent: cpu.map { max($0 + random.jitter(2), 0) }, memoryFootprint: memory.map { UInt64(max($0, 0)) },
                diskReadRate: access == .full ? 0 : nil, diskWriteRate: write, threadCount: threads
            )
        }
        let runaway = scenario == .runawayProcess && elapsed >= 60
        let browserGrowth = scenario == .memoryPressure ? elapsed / 60 * 650_000_000 : 0
        return [
            make(0, "kernel_task", nil, cpu: nil, memory: nil, uid: 0, access: .limited, parent: 0, write: nil, threads: nil),
            make(1, "launchd", "/sbin/launchd", cpu: nil, memory: nil, uid: 0, access: .limited, parent: 0, write: nil, threads: nil),
            make(310, "WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", cpu: nil, memory: nil, uid: 88, access: .limited, write: nil, threads: nil),
            make(812, "Safari", "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 3, memory: 420_000_000),
            make(840, "Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", cpu: 6, memory: 650_000_000),
            make(845, "Google Chrome Helper (Renderer)", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", cpu: 9, memory: 900_000_000 + browserGrowth, parent: 840),
            make(846, "Google Chrome Helper (GPU)", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)", cpu: 4, memory: 310_000_000, parent: 840),
            make(1201, "Xcode", "/Applications/Xcode.app/Contents/MacOS/Xcode", cpu: 2, memory: 1_350_000_000, threads: 48),
            make(1240, "SourceKitService", "/Applications/Xcode.app/Contents/SharedFrameworks/SourceKit.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService", cpu: 1, memory: 780_000_000, parent: 1201),
            make(1502, "node", "/opt/homebrew/bin/node", cpu: runaway ? 780 : 4, memory: 310_000_000, write: runaway ? 1_500_000 : 0, threads: 11),
            make(1610, "com.docker.virtualization", "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization", cpu: 7, memory: 2_100_000_000, threads: 22),
            make(1777, "ollama", "/Applications/Ollama.app/Contents/Resources/ollama", cpu: 1, memory: 650_000_000),
            make(1800, "java", "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java", cpu: 3, memory: 1_100_000_000, threads: 64),
            make(1900, "Slack", "/Applications/Slack.app/Contents/MacOS/Slack", cpu: scenario == .batteryDrain ? 18 : 1, memory: 380_000_000),
            make(2001, "PulseMac", "/Applications/PulseMac.app/Contents/MacOS/PulseMac", cpu: 0.6, memory: 62_000_000),
        ]
    }

    /// Feeds `duration` seconds of the scenario into a history. Used by replay tests and the
    /// demo mode warm-up so charts are not empty.
    public mutating func replay(duration: TimeInterval, interval: TimeInterval = 1, into sink: (SystemSnapshot) -> Void) {
        var elapsed: TimeInterval = 0
        while elapsed <= duration {
            sink(snapshot(at: elapsed, interval: interval))
            elapsed += interval
        }
    }
}
