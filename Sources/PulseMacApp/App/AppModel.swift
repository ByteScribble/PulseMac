import AppKit
import Observation
import PulseCore
import PulseMonitoring
import PulsePersistence
import SwiftUI

/// Where the app's data comes from. Fixture sources never write to the history database.
enum DataSourceKind: Hashable {
    case live
    case fixture(FixtureScenario)

    var label: String {
        switch self {
        case .live: return "Live (this Mac)"
        case let .fixture(scenario): return "Fixture: \(scenario.title)"
        }
    }
}

/// UI surfaces that drive the sampling mode.
enum Surface: Hashable { case dashboard, popover, investigation }

/// Main-actor façade over the monitoring stack. Views read published state; they never call
/// collectors or the database directly (architecture rule: UI ↛ instrumentation).
@Observable
@MainActor
final class AppModel {
    private(set) var coordinator: SamplingCoordinator
    private(set) var source: DataSourceKind
    private(set) var snapshot: SystemSnapshot?
    private(set) var activeIncidents: [Incident] = []
    private(set) var allIncidents: [Incident] = []
    private(set) var capabilities: [CapabilityID: Capability] = [:]
    private(set) var overhead = SelfOverhead()
    private(set) var actionLog: [ActionRecord] = []
    private(set) var storeError: String?
    private(set) var isPaused = false
    /// Increments every tick; chart accessors read it so views refresh with new data.
    private(set) var revision = 0
    /// Per-process footprint/CPU history for the inspector (bounded, exited processes dropped).
    private var processMemory: [ProcessIdentity: RingBuffer<Sample>] = [:]
    private var processCPU: [ProcessIdentity: RingBuffer<Sample>] = [:]

    var selection: SidebarItem? = .overview
    var detailRoute: DetailRoute?
    var inspectedProcess: ProcessIdentity?
    var investigationFocus: Incident?

    let store: HistoryStore?
    private var visibleSurfaces: Set<Surface> = []
    private var updatesTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    let executor = ActionExecutor()

    init() {
        let store: HistoryStore?
        var storeError: String?
        do {
            store = try HistoryStore(path: HistoryStore.defaultURL().path)
        } catch {
            store = nil
            storeError = "History is unavailable: \(error.localizedDescription). Live monitoring still works."
        }
        self.store = store
        let initial = Self.initialSource()
        source = initial
        coordinator = Self.makeCoordinator(initial, store: store)
        self.storeError = storeError
        start()
        observeSystem()
    }

    private static func initialSource() -> DataSourceKind {
        // `-PulseFixture memoryPressure` launches with a fixture scenario (UI development).
        if let name = UserDefaults.standard.string(forKey: "PulseFixture"), let scenario = FixtureScenario(rawValue: name) {
            return .fixture(scenario)
        }
        return .live
    }

    private static func makeCoordinator(_ kind: DataSourceKind, store: HistoryStore?) -> SamplingCoordinator {
        switch kind {
        case .live:
            return SamplingCoordinator(source: LiveSystemSource.make(), store: store)
        case let .fixture(scenario):
            return SamplingCoordinator(source: FixtureSource(scenario: scenario), store: nil)
        }
    }

    // MARK: - Lifecycle

    private func start() {
        let coordinator = coordinator
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            let stream = await coordinator.updates()
            await coordinator.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
            await coordinator.start()
            let capabilities = await coordinator.capabilities()
            let incidents = await coordinator.incidents()
            self?.capabilities = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })
            self?.allIncidents = incidents
            self?.updateMode()
            for await update in stream {
                guard let self else { return }
                self.apply(update)
            }
        }
    }

    func switchSource(_ kind: DataSourceKind) {
        guard kind != source else { return }
        let old = coordinator
        Task { await old.stop() }
        source = kind
        snapshot = nil
        activeIncidents = []
        processMemory.removeAll()
        processCPU.removeAll()
        coordinator = Self.makeCoordinator(kind, store: store)
        start()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        let coordinator = coordinator
        Task {
            if paused { await coordinator.stop() } else { await coordinator.systemDidWake(); await coordinator.start() }
        }
    }

    func surfaceAppeared(_ surface: Surface) {
        visibleSurfaces.insert(surface)
        updateMode()
    }

    func surfaceDisappeared(_ surface: Surface) {
        visibleSurfaces.remove(surface)
        updateMode()
    }

    private func updateMode() {
        let mode: SamplingMode = visibleSurfaces.contains(.investigation)
            ? .investigation
            : (visibleSurfaces.isEmpty ? .background : .interactive)
        let coordinator = coordinator
        Task { await coordinator.setMode(mode) }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.coordinator.systemWillSleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.coordinator.systemDidWake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.coordinator.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled) }
        })
    }

    private func apply(_ update: MonitorUpdate) {
        // Low-cadence domains (volumes, power, GPU, processes) are absent on some ticks;
        // carry the last reading forward for display only. History and diagnostics use the
        // raw per-tick snapshot, so nothing is double-counted.
        var merged = update.snapshot
        if merged.volumes == nil { merged.volumes = snapshot?.volumes }
        if merged.power == nil { merged.power = snapshot?.power }
        if merged.gpu == nil { merged.gpu = snapshot?.gpu }
        if merged.processes == nil { merged.processes = snapshot?.processes }
        snapshot = merged
        activeIncidents = update.activeIncidents
        overhead = update.overhead
        for changed in update.changedIncidents {
            if let index = allIncidents.firstIndex(where: { $0.id == changed.id }) {
                allIncidents[index] = changed
            } else {
                allIncidents.append(changed)
            }
        }
        if let processes = update.snapshot.processes { recordProcessHistory(processes, at: update.snapshot.timestamp) }
        revision &+= 1
    }

    private func recordProcessHistory(_ processes: [ProcessSample], at time: Date) {
        var alive = Set<ProcessIdentity>()
        for process in processes where process.access == .full {
            alive.insert(process.identity)
            if let memory = process.memoryFootprint {
                processMemory[process.identity, default: RingBuffer(capacity: 3600)]
                    .append(Sample(metric: .memoryUsedBytes, time: time, value: Double(memory)))
            }
            if let cpu = process.cpuPercent {
                processCPU[process.identity, default: RingBuffer(capacity: 900)]
                    .append(Sample(metric: .cpuTotal, time: time, value: cpu))
            }
        }
        processMemory = processMemory.filter { alive.contains($0.key) }
        processCPU = processCPU.filter { alive.contains($0.key) }
    }

    // MARK: - Queries for views

    var isFixture: Bool { if case .fixture = source { return true } else { return false } }
    var fixtureTitle: String? { if case let .fixture(scenario) = source { return scenario.title } else { return nil } }
    var topology: CPUTopology { coordinator.topology }

    var health: HealthSummary {
        HealthSummary.make(activeIncidents: activeIncidents, hasRecentData: snapshot?.cpu != nil, at: Date())
    }

    var visibleIncidents: [Incident] {
        let now = Date()
        return activeIncidents.filter { $0.isVisible(at: now) }.sorted { $0.severity > $1.severity }
    }

    func capability(_ id: CapabilityID) -> CapabilityStatus {
        capabilities[id]?.status ?? .deferred("Not evaluated yet.")
    }

    func source(of id: CapabilityID) -> String? { capabilities[id]?.source }

    /// Recent in-memory samples (up to ~15 minutes).
    func series(_ metric: MetricID, last seconds: TimeInterval) -> [Sample] {
        _ = revision
        return coordinator.history.samples(metric, last: seconds, endingAt: snapshot?.timestamp ?? Date())
    }

    /// Samples for any interval: memory for the recent past, the database beyond it.
    func timeline(_ metric: MetricID, in interval: DateInterval) -> [Sample] {
        _ = revision
        let memory = coordinator.history.samples(metric, from: interval.start, to: interval.end)
        if let first = memory.first, first.time <= interval.start.addingTimeInterval(10) { return memory }
        guard let store else { return memory }
        try? store.flush()
        guard let result = try? store.series(metric, in: interval) else { return memory }
        let stored = result.1.map { Sample(metric: metric, time: $0.start, value: $0.mean) }
        let cutoff = memory.first?.time ?? .distantFuture
        return stored.filter { $0.time < cutoff } + memory
    }

    func processMemoryHistory(_ identity: ProcessIdentity) -> [Sample] {
        _ = revision
        return processMemory[identity].map(Array.init) ?? []
    }

    func processCPUHistory(_ identity: ProcessIdentity) -> [Sample] {
        _ = revision
        return processCPU[identity].map(Array.init) ?? []
    }

    func process(_ identity: ProcessIdentity) -> ProcessSample? {
        snapshot?.processes?.first { $0.identity == identity }
    }

    func topProcessGroups(in interval: DateInterval, by ranking: HistoryStore.ProcessRanking) -> [ProcessGroupSummary] {
        try? store?.flush()
        return (try? store?.topProcessGroups(in: interval, by: ranking)) ?? []
    }

    // MARK: - Incidents & actions

    func setUserState(_ state: IncidentUserState, for incident: Incident) {
        let coordinator = coordinator
        Task {
            await coordinator.setUserState(state, for: incident.id)
            self.allIncidents = await coordinator.incidents()
        }
        if let index = activeIncidents.firstIndex(where: { $0.id == incident.id }) { activeIncidents[index].userState = state }
    }

    func setNotes(_ notes: String, for incident: Incident) {
        let coordinator = coordinator
        Task { await coordinator.setNotes(notes, for: incident.id) }
        if let index = allIncidents.firstIndex(where: { $0.id == incident.id }) { allIncidents[index].notes = notes }
    }

    /// Performs a confirmed action and records it. Returns a user-facing message.
    @discardableResult
    func perform(_ kind: RemediationKind, on process: ProcessSample, incident: Incident?) -> String {
        var record: ActionRecord
        do {
            record = try executor.perform(kind, on: process, incidentID: incident?.id)
            record.verificationMetric = incident?.primaryMetric
            record.message = kind.isDestructive ? "Request sent. PulseMac will compare measurements before and after." : nil
        } catch {
            record = ActionRecord(
                kind: kind, targetDescription: process.name, incidentID: incident?.id, requestedAt: Date(),
                phase: .failed, message: error.localizedDescription
            )
        }
        actionLog.append(record)
        let coordinator = coordinator
        let saved = record
        Task { await coordinator.record(saved) }
        return record.message ?? (record.phase == .failed ? "Failed." : "Done.")
    }

    func recordCleanup(path: String) {
        let record = ActionRecord(
            kind: .moveToTrash, targetDescription: redactor.redact(path), incidentID: nil, requestedAt: Date(),
            phase: .succeeded, message: "Moved to Trash (recoverable)."
        )
        actionLog.append(record)
        let coordinator = coordinator
        Task { await coordinator.record(record) }
    }

    /// Before/after comparison for an action, using the action's verification metric.
    func verification(for record: ActionRecord, window: TimeInterval = 120) -> EffectVerifier.Verdict? {
        guard let metric = record.verificationMetric else { return nil }
        let before = coordinator.history.samples(metric, from: record.requestedAt.addingTimeInterval(-window), to: record.requestedAt)
        let after = coordinator.history.samples(metric, from: record.requestedAt.addingTimeInterval(15), to: record.requestedAt.addingTimeInterval(15 + window))
        return EffectVerifier.compare(baseline: before, after: after)
    }

    func clearHistory() {
        let coordinator = coordinator
        Task { try? await coordinator.clearHistory() }
        allIncidents = allIncidents.filter(\.isActive)
        actionLog.removeAll()
    }

    var redactor: Redactor {
        Redactor(homeDirectory: NSHomeDirectory(), userName: NSUserName(), hostName: Host.current().localizedName)
    }

    func report(for incident: Incident?, interval: DateInterval, notes: String) -> String {
        let metrics: [MetricID] = [.cpuTotal, .memoryPressureLevel, .swapUsedBytes, .diskWriteRate, .networkReceiveRate, .thermalStateLevel]
        let summaries = metrics.compactMap { metric in WindowStats(timeline(metric, in: interval)).map { (metric, $0) } }
        let report = DiagnosticReport(
            generatedAt: Date(), machine: topology.brand, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            incident: incident, window: interval, metricSummaries: summaries,
            actions: actionLog.filter { interval.contains($0.requestedAt) }, notes: notes
        )
        return report.markdown(redactor: redactor)
    }
}
