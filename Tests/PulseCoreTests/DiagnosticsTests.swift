import XCTest
@testable import PulseCore

/// Drives the incident engine with a synthetic CPU series.
final class IncidentEngineTests: XCTestCase {
    private var history: MetricHistory!
    private var engine: IncidentEngine!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var t: TimeInterval = 0

    override func setUp() {
        history = MetricHistory(capacityPerMetric: 10_000)
        engine = IncidentEngine(rules: [SustainedCPURule(minimumObservation: 120)])
        t = 0
    }

    /// Feeds `seconds` of 1 Hz CPU samples at `value`, evaluating each second.
    @discardableResult
    private func feed(_ value: Double, seconds: Int) -> [Incident] {
        var changed: [Incident] = []
        for _ in 0..<seconds {
            let now = start.addingTimeInterval(t)
            history.append([Sample(metric: .cpuTotal, time: now, value: value)])
            changed += engine.evaluate(RuleContext(now: now, history: history, processes: nil))
            t += 1
        }
        return changed
    }

    func testShortSpikeDoesNotOpenIncident() {
        feed(10, seconds: 60)
        feed(99, seconds: 90)
        feed(10, seconds: 60)
        XCTAssertTrue(engine.allIncidents.isEmpty, "A 90 s spike is transient, not sustained")
    }

    func testSustainedLoadOpensIncidentWithStartAtFirstTrigger() throws {
        feed(10, seconds: 60)
        feed(97, seconds: 200)
        let incident = try XCTUnwrap(engine.activeIncidents.first)
        XCTAssertEqual(incident.ruleID, "cpu.sustained")
        // Window mean crosses 85% after ~27 s of high load; start must precede the 120 s observation.
        XCTAssertLessThan(incident.startedAt.timeIntervalSince(start), 60 + 40)
        XCTAssertTrue(incident.evidence.contains { $0.kind == .observation && $0.metric == .cpuTotal })
        XCTAssertTrue(incident.evidence.contains { $0.kind == .limitation }, "Missing process data must be stated")
    }

    func testHysteresisKeepsIncidentOpenInBand() {
        feed(97, seconds: 200)
        feed(78, seconds: 300) // between clear (70) and trigger (85)
        XCTAssertEqual(engine.activeIncidents.count, 1)
    }

    func testResolvesAfterClearDuration() throws {
        feed(97, seconds: 200)
        feed(20, seconds: 200)
        let incident = try XCTUnwrap(engine.allIncidents.first)
        XCTAssertNotNil(incident.resolvedAt)
        XCTAssertTrue(engine.activeIncidents.isEmpty)
    }

    func testRetriggerDuringCooldownReopensSameIncident() {
        feed(97, seconds: 200)
        feed(20, seconds: 120)
        XCTAssertTrue(engine.activeIncidents.isEmpty)
        feed(97, seconds: 60)
        XCTAssertEqual(engine.allIncidents.count, 1, "Deduplicated")
        XCTAssertEqual(engine.activeIncidents.count, 1)
    }

    func testMissingDataNeitherOpensNorResolves() {
        // No samples at all: unknown.
        for second in 0..<300 {
            engine.evaluate(RuleContext(now: start.addingTimeInterval(Double(second)), history: history, processes: nil))
        }
        XCTAssertTrue(engine.allIncidents.isEmpty)

        feed(97, seconds: 200)
        // Gap: time advances with no samples (e.g. collector failing).
        for _ in 0..<600 {
            engine.evaluate(RuleContext(now: start.addingTimeInterval(t), history: history, processes: nil))
            t += 1
        }
        XCTAssertEqual(engine.activeIncidents.count, 1, "Unknown data must not resolve an incident")
    }

    func testDiscontinuityResetsPendingObservation() {
        feed(97, seconds: 100) // pending, not yet 120 s
        engine.noteDiscontinuity()
        feed(97, seconds: 60)
        XCTAssertTrue(engine.allIncidents.isEmpty, "Observation must restart after sleep/wake")
    }

    func testUserStateAndVisibility() throws {
        feed(97, seconds: 200)
        let id = try XCTUnwrap(engine.activeIncidents.first?.id)
        engine.setUserState(.snoozed(until: start.addingTimeInterval(10_000)), for: id)
        XCTAssertFalse(engine.incident(id)!.isVisible(at: start.addingTimeInterval(300)))
        XCTAssertTrue(engine.incident(id)!.isVisible(at: start.addingTimeInterval(10_001)))
    }

    func testContributorsAreCorrelationsFromProcesses() throws {
        let process = ProcessSample(
            identity: ProcessIdentity(pid: 42, startTime: start), parentPID: 1, name: "node", executablePath: "/usr/local/bin/node",
            userID: 501, userName: nil, access: .full, cpuPercent: 700, memoryFootprint: 1, diskReadRate: nil, diskWriteRate: nil, threadCount: 1
        )
        for _ in 0..<200 {
            let now = start.addingTimeInterval(t)
            history.append([Sample(metric: .cpuTotal, time: now, value: 97)])
            engine.evaluate(RuleContext(now: now, history: history, processes: [process]))
            t += 1
        }
        let incident = try XCTUnwrap(engine.activeIncidents.first)
        XCTAssertEqual(incident.contributors.first?.name, "node")
        let correlation = try XCTUnwrap(incident.evidence.first { $0.kind == .correlation })
        XCTAssertTrue(correlation.statement.contains("does not prove"))
    }

    func testRestoreMarksActiveIncidentsResolved() {
        let incident = Incident(
            ruleID: "x", title: "t", summary: "s", severity: .warning, startedAt: start, lastObservedAt: start.addingTimeInterval(60),
            peakValue: nil, primaryMetric: .cpuTotal, evidence: [], contributors: [], nextStep: ""
        )
        engine.restore([incident])
        XCTAssertEqual(engine.allIncidents.first?.resolvedAt, start.addingTimeInterval(60))
    }
}

/// Offline replay of fixture scenarios through all built-in rules.
final class ScenarioReplayTests: XCTestCase {
    private func replay(_ scenario: FixtureScenario, minutes: Double) -> IncidentEngine {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let history = MetricHistory(capacityPerMetric: 5000)
        let engine = IncidentEngine()
        var generator = FixtureGenerator(scenario: scenario, start: start)
        generator.replay(duration: minutes * 60) { snapshot in
            history.append(snapshot.samples)
            engine.evaluate(RuleContext(now: snapshot.timestamp, history: history, processes: snapshot.processes))
        }
        return engine
    }

    func testCalmScenarioProducesNoIncidents() {
        XCTAssertEqual(replay(.calm, minutes: 20).allIncidents.map(\.ruleID), [])
    }

    func testMemoryPressureScenario() {
        let rules = Set(replay(.memoryPressure, minutes: 15).allIncidents.map(\.ruleID))
        XCTAssertTrue(rules.contains("memory.pressure"))
        XCTAssertTrue(rules.contains("memory.swapGrowth"))
        XCTAssertFalse(rules.contains("cpu.sustained"))
    }

    func testRunawayProcessScenarioNamesTheProcess() throws {
        let engine = replay(.runawayProcess, minutes: 8)
        let cpu = try XCTUnwrap(engine.allIncidents.first { $0.ruleID == "cpu.sustained" })
        XCTAssertEqual(cpu.contributors.first?.name, "node")
        XCTAssertTrue(engine.allIncidents.contains { $0.ruleID == "thermal.pressure" })
    }

    func testBatteryDrainScenario() throws {
        let engine = replay(.batteryDrain, minutes: 15)
        let drain = try XCTUnwrap(engine.allIncidents.first { $0.ruleID == "power.rapidDischarge" })
        XCTAssertTrue(drain.evidence.contains { $0.kind == .limitation && $0.statement.contains("per-app energy") })
    }
}

final class AnalysisTests: XCTestCase {
    private func series(_ values: [Double], step: TimeInterval) -> [Sample] {
        values.enumerated().map { Sample(metric: .memoryUsedBytes, time: Date(timeIntervalSince1970: Double($0.offset) * step), value: $0.element) }
    }

    func testSteadyGrowthIsFlaggedWithCaveat() {
        let samples = series((0..<40).map { 1e9 + Double($0) * 25e6 }, step: 60)
        let assessment = MemoryGrowthAnalyzer.assess(samples)
        XCTAssertTrue(assessment.isSuspicious)
        XCTAssertTrue(assessment.explanation.contains("also with caches"))
    }

    func testFluctuatingIsNotSuspicious() {
        let samples = series((0..<40).map { 1e9 + ($0 % 2 == 0 ? 0 : 600e6) }, step: 60)
        XCTAssertFalse(MemoryGrowthAnalyzer.assess(samples).isSuspicious)
    }

    func testInsufficientHistory() {
        if case .insufficientData = MemoryGrowthAnalyzer.assess(series([1, 2, 3], step: 60)) {} else {
            XCTFail("Three minutes of data is not enough")
        }
    }

    func testEffectVerifier() {
        let before = series(Array(repeating: 90, count: 10), step: 1)
        let after = series(Array(repeating: 30, count: 10), step: 1)
        let verdict = EffectVerifier.compare(baseline: before, after: after)
        XCTAssertEqual(verdict, .improved(before: 90, after: 30))
        XCTAssertTrue(EffectVerifier.describe(verdict, metric: .cpuTotal).contains("not a permanent fix"))
        XCTAssertEqual(EffectVerifier.compare(baseline: before, after: series([30], step: 1)), .insufficientData)
        XCTAssertEqual(EffectVerifier.compare(baseline: before, after: before), .unchanged(before: 90, after: 90))
    }

    func testHealthSummary() {
        XCTAssertEqual(HealthSummary.make(activeIncidents: [], hasRecentData: false, at: Date()).status, .unknown)
        XCTAssertEqual(HealthSummary.make(activeIncidents: [], hasRecentData: true, at: Date()).status, .calm)
        let urgent = Incident(ruleID: "a", title: "A", summary: "s", severity: .urgent, startedAt: Date(), lastObservedAt: Date(), peakValue: nil, primaryMetric: .cpuTotal, evidence: [], contributors: [], nextStep: "")
        var dismissed = urgent
        dismissed.userState = .dismissed
        XCTAssertEqual(HealthSummary.make(activeIncidents: [urgent], hasRecentData: true, at: Date()).status, .urgent)
        XCTAssertEqual(HealthSummary.make(activeIncidents: [dismissed], hasRecentData: true, at: Date()).status, .calm)
    }
}
