import Foundation
import PulseCore
import PulsePersistence

/// How aggressively to sample. The app switches modes based on what is visible, so the
/// monitor stays cheap when nobody is looking (product principle 2.5).
public enum SamplingMode: String, Sendable, CaseIterable {
    /// Menu bar only / app in background.
    case background
    /// Dashboard or popover visible.
    case interactive
    /// Investigation workspace open: processes every tick.
    case investigation

    public var interval: TimeInterval {
        switch self {
        case .background: return 5
        case .interactive, .investigation: return 1
        }
    }

    /// Process enumeration is the most expensive collector; sample it less often.
    public var processEveryTicks: Int {
        switch self {
        case .background: return 3      // every 15 s
        case .interactive: return 2     // every 2 s
        case .investigation: return 1   // every 1 s
        }
    }
}

/// One published update.
public struct MonitorUpdate: Sendable {
    public var snapshot: SystemSnapshot
    public var changedIncidents: [Incident]
    public var activeIncidents: [Incident]
    public var overhead: SelfOverhead
    public var isFixture: Bool
}

/// Measured cost of PulseMac's own sampling (acceptance criterion K).
public struct SelfOverhead: Sendable, Equatable {
    public var lastTickMilliseconds: Double = 0
    public var averageTickMilliseconds: Double = 0
    /// Own process CPU over the last ~minute, % of one core.
    public var processCPUPercent: Double?
    public var ticks: Int = 0
}

/// Central sampling loop. Owns collectors (via `SnapshotSource`), the in-memory history,
/// the diagnostics engine and the batched persistence write path. UI never calls collectors
/// directly; it subscribes to `updates()`.
public actor SamplingCoordinator {
    private let source: any SnapshotSource
    public nonisolated let history: MetricHistory
    private let store: HistoryStore?
    private let engine: IncidentEngine
    private var summarizer = ProcessSummarizer()

    private var mode: SamplingMode = .background
    private var lowPowerMode = false
    private var loop: Task<Void, Never>?
    private var tick = 0
    private var subscribers: [UUID: AsyncStream<MonitorUpdate>.Continuation] = [:]
    private var lastProcesses: [ProcessSample]?
    private var overhead = SelfOverhead()
    private var cpuClock = OwnCPUClock()
    private var lastFlush = Date.distantPast
    private var lastRollup = Date.distantPast
    private var lastRetention = Date.distantPast
    private let clock: @Sendable () -> Date
    private let monotonic: @Sendable () -> TimeInterval
    public nonisolated let isFixture: Bool
    public nonisolated let topology: CPUTopology

    public var flushInterval: TimeInterval = 30

    public init(
        source: any SnapshotSource,
        history: MetricHistory = MetricHistory(),
        store: HistoryStore?,
        engine: IncidentEngine = IncidentEngine(),
        clock: @escaping @Sendable () -> Date = { Date() },
        monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.source = source
        self.history = history
        self.store = store
        self.engine = engine
        self.clock = clock
        self.monotonic = monotonic
        isFixture = source.isFixture
        topology = source.topology
        if let store, let restored = try? store.incidents(since: clock().addingTimeInterval(-7 * 86_400)) {
            engine.restore(restored)
        }
    }

    // MARK: - Subscription

    public func updates() -> AsyncStream<MonitorUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MonitorUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    // MARK: - Lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.performTick()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        try? store?.flush()
    }

    public var isRunning: Bool { loop != nil }

    public func setMode(_ newMode: SamplingMode) { mode = newMode }
    public func currentMode() -> SamplingMode { mode }
    public func setLowPowerMode(_ enabled: Bool) { lowPowerMode = enabled }

    /// Call from NSWorkspace.willSleepNotification.
    public func systemWillSleep() {
        try? store?.flush()
    }

    /// Call from NSWorkspace.didWakeNotification. Counter deltas spanning sleep are discarded.
    public func systemDidWake() {
        source.resetCounters()
        engine.noteDiscontinuity()
        cpuClock = OwnCPUClock()
    }

    public func capabilities() -> [Capability] { source.capabilities() }

    // MARK: - Incident management

    public func incidents() -> [Incident] { engine.allIncidents }

    public func setUserState(_ state: IncidentUserState, for id: UUID) {
        engine.setUserState(state, for: id)
        if let incident = engine.incident(id) { try? store?.save(incident) }
    }

    public func setNotes(_ notes: String, for id: UUID) {
        engine.setNotes(notes, for: id)
        if let incident = engine.incident(id) { try? store?.save(incident) }
    }

    public func record(_ action: ActionRecord) {
        try? store?.save(action)
    }

    public func clearHistory() throws {
        history.removeAll()
        try store?.clearAll()
    }

    // MARK: - Tick

    /// Runs one sampling tick and returns the delay until the next one.
    @discardableResult
    public func performTick() -> TimeInterval {
        let started = monotonic()
        let now = clock()
        let includeProcesses = tick % mode.processEveryTicks == 0
        let snapshot = source.snapshot(at: now, monotonicTime: started, tick: tick, includeProcesses: includeProcesses)
        tick += 1

        let samples = snapshot.samples
        history.append(samples)
        store?.enqueue(samples)
        if let processes = snapshot.processes {
            lastProcesses = processes
            let finished = summarizer.add(processes, at: now)
            if !finished.isEmpty { try? store?.recordProcessSummaries(finished) }
        }

        let changed = engine.evaluate(RuleContext(now: now, history: history, processes: lastProcesses))
        for incident in changed { try? store?.save(incident) }

        maintainStore(now: now)

        let elapsedMs = (monotonic() - started) * 1000
        overhead.ticks += 1
        overhead.lastTickMilliseconds = elapsedMs
        overhead.averageTickMilliseconds += (elapsedMs - overhead.averageTickMilliseconds) / Double(min(overhead.ticks, 60))
        if let cpu = cpuClock.sample(monotonic: monotonic()) { overhead.processCPUPercent = cpu }

        let update = MonitorUpdate(
            snapshot: snapshot, changedIncidents: changed, activeIncidents: engine.activeIncidents,
            overhead: overhead, isFixture: source.isFixture
        )
        for continuation in subscribers.values { continuation.yield(update) }
        return mode.interval * (lowPowerMode ? 2 : 1)
    }

    private func maintainStore(now: Date) {
        guard let store else { return }
        if now.timeIntervalSince(lastFlush) >= flushInterval {
            try? store.flush()
            lastFlush = now
        }
        if now.timeIntervalSince(lastRollup) >= 300 {
            try? store.rollUp(now: now)
            lastRollup = now
        }
        if now.timeIntervalSince(lastRetention) >= 3600 {
            _ = try? store.applyRetention(now: now)
            lastRetention = now
        }
    }
}

/// Measures PulseMac's own CPU time via getrusage(RUSAGE_SELF).
struct OwnCPUClock {
    private var last: (cpu: TimeInterval, wall: TimeInterval)?

    mutating func sample(monotonic: TimeInterval) -> Double? {
        var usage = rusage()
        #if os(Linux)
        let who = RUSAGE_SELF.rawValue
        #else
        let who = RUSAGE_SELF
        #endif
        guard getrusage(who, &usage) == 0 else { return nil }
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        defer { if last == nil || monotonic - (last?.wall ?? 0) >= 60 { last = (cpu, monotonic) } }
        guard let last, monotonic - last.wall >= 5 else { return nil }
        return (cpu - last.cpu) / (monotonic - last.wall) * 100
    }
}
