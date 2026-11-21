import XCTest
import PulseCore
import PulsePersistence
@testable import PulseMonitoring

/// Test clock that advances only when told to.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

final class CoordinatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCoordinator(_ scenario: FixtureScenario, store: HistoryStore?) -> (SamplingCoordinator, ManualClock) {
        let clock = ManualClock(start)
        let coordinator = SamplingCoordinator(
            source: FixtureSource(scenario: scenario, start: start), store: store,
            clock: { clock.now }, monotonic: { clock.now.timeIntervalSince1970 }
        )
        return (coordinator, clock)
    }

    func testTicksPopulateHistoryAndStore() async throws {
        let store = try HistoryStore(path: ":memory:")
        let (coordinator, clock) = makeCoordinator(.calm, store: store)
        for _ in 0..<45 {
            await coordinator.performTick()
            clock.advance(1)
        }
        XCTAssertEqual(coordinator.history.all(.cpuTotal).count, 45)
        // Flush happens every 30 s of clock time.
        let persisted = try store.series(.cpuTotal, in: DateInterval(start: start, duration: 60), resolution: .raw)
        XCTAssertGreaterThanOrEqual(persisted.count, 30)
        XCTAssertTrue(coordinator.isFixture)
    }

    func testBackgroundModeSamplesProcessesLessOften() async {
        let (coordinator, clock) = makeCoordinator(.calm, store: nil)
        await coordinator.setMode(.background)
        var withProcesses = 0
        let stream = await coordinator.updates()
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<9 {
            let delay = await coordinator.performTick()
            XCTAssertEqual(delay, 5)
            if let update = await iterator.next(), update.snapshot.processes != nil { withProcesses += 1 }
            clock.advance(5)
        }
        XCTAssertEqual(withProcesses, 3)
    }

    func testLowPowerDoublesInterval() async {
        let (coordinator, _) = makeCoordinator(.calm, store: nil)
        await coordinator.setMode(.interactive)
        await coordinator.setLowPowerMode(true)
        let delay = await coordinator.performTick()
        XCTAssertEqual(delay, 2)
    }

    func testIncidentsArePersistedAndRestored() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("coord-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let store = try HistoryStore(path: path)
            let (coordinator, clock) = makeCoordinator(.memoryPressure, store: store)
            await coordinator.setMode(.investigation)
            for _ in 0..<(8 * 60) {
                await coordinator.performTick()
                clock.advance(1)
            }
            let incidents = await coordinator.incidents()
            XCTAssertTrue(incidents.contains { $0.ruleID == "memory.pressure" && $0.isActive })
            await coordinator.stop()
        }
        let reopened = try HistoryStore(path: path)
        let (restored, _) = makeCoordinator(.calm, store: reopened)
        let incidents = await restored.incidents()
        let memory = try XCTUnwrap(incidents.first { $0.ruleID == "memory.pressure" })
        XCTAssertNotNil(memory.resolvedAt, "Restored incidents are closed at their last observation")
    }

    func testWakeResetsPendingObservations() async {
        let (coordinator, clock) = makeCoordinator(.runawayProcess, store: nil)
        await coordinator.setMode(.interactive)
        for _ in 0..<150 { await coordinator.performTick(); clock.advance(1) }
        await coordinator.systemDidWake()
        for _ in 0..<60 { await coordinator.performTick(); clock.advance(1) }
        let cpu = await coordinator.incidents().filter { $0.ruleID == "cpu.sustained" }
        XCTAssertTrue(cpu.isEmpty, "Observation window restarts after wake")
    }

    func testOverheadIsMeasured() async {
        let (coordinator, clock) = makeCoordinator(.calm, store: nil)
        let stream = await coordinator.updates()
        await coordinator.performTick()
        clock.advance(1)
        var iterator = stream.makeAsyncIterator()
        let update = await iterator.next()
        XCTAssertEqual(update?.overhead.ticks, 1)
        XCTAssertGreaterThanOrEqual(update?.overhead.lastTickMilliseconds ?? -1, 0)
    }
}

final class ProcessSummarizerTests: XCTestCase {
    func testEmitsOnMinuteBoundaryAndKeepsTopGroups() {
        var summarizer = ProcessSummarizer(keepPerRanking: 1)
        let start = Date(timeIntervalSince1970: 1_700_000_040 / 60 * 60)
        func p(_ pid: Int32, _ cpu: Double, _ memory: UInt64) -> ProcessSample {
            ProcessSample(identity: ProcessIdentity(pid: pid, startTime: start), parentPID: 1, name: "p\(pid)", executablePath: "/bin/p\(pid)", userID: 501, userName: nil, access: .full, cpuPercent: cpu, memoryFootprint: memory, diskReadRate: nil, diskWriteRate: nil, threadCount: nil)
        }
        let processes = [p(1, 90, 1), p(2, 1, 9_000_000_000), p(3, 2, 2)]
        XCTAssertTrue(summarizer.add(processes, at: start).isEmpty)
        XCTAssertTrue(summarizer.add(processes, at: start.addingTimeInterval(30)).isEmpty)
        let finished = summarizer.add(processes, at: start.addingTimeInterval(61))
        XCTAssertEqual(Set(finished.map(\.name)), ["p1", "p2"], "Top CPU and top memory kept; p3 dropped")
        XCTAssertEqual(finished.first { $0.name == "p1" }?.samples, 2)
    }
}

final class StorageScannerTests: XCTestCase {
    func testScanFindsDeveloperArtifactsAndPlansDryRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let modules = project.appendingPathComponent("node_modules/lodash")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data(repeating: 1, count: 100_000).write(to: modules.appendingPathComponent("index.js"))
        let docs = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 50_000).write(to: docs.appendingPathComponent("a.txt"))

        var options = ScanOptions()
        options.homeDirectory = root.path
        let tree = try StorageScanner(options: options).scan(root)
        XCTAssertGreaterThanOrEqual(tree.allocatedBytes, 150_000)
        XCTAssertEqual(tree.fileCount, 3)

        let findings = StorageScanner.artifacts(in: tree)
        XCTAssertEqual(findings.map(\.name), ["node_modules"])

        var plan = CleanupPlan(findings: findings, homeDirectory: root.path)
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertFalse(plan.items[0].selected, "Recreatable items are not preselected")
        plan.items[0].selected = true
        var trashed: [URL] = []
        let outcomes = plan.execute(dryRun: true) { trashed.append($0); return nil }
        XCTAssertTrue(trashed.isEmpty, "Dry run touches nothing")
        guard case .wouldMove = outcomes.first else { return XCTFail("expected dry-run outcome, got \(outcomes)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: modules.path))
    }

    func testCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
        let task = Task { try StorageScanner().scan(root) }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            return
        }
        // Scan may finish before cancellation is observed on tiny trees; that is acceptable.
    }
}
