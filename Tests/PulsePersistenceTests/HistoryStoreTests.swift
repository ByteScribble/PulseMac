import XCTest
import PulseCore
@testable import PulsePersistence

final class HistoryStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_040) // not minute-aligned on purpose

    private func makeStore(policy: RetentionPolicy = RetentionPolicy()) throws -> HistoryStore {
        try HistoryStore(path: ":memory:", policy: policy)
    }

    private func samples(_ metric: MetricID, count: Int, from start: Date, value: (Int) -> Double) -> [Sample] {
        (0..<count).map { Sample(metric: metric, time: start.addingTimeInterval(Double($0)), value: value($0)) }
    }

    func testBatchedWritesOnlyHitDiskOnFlush() throws {
        let store = try makeStore()
        store.enqueue(samples(.cpuTotal, count: 10, from: base) { Double($0) })
        XCTAssertEqual(store.pendingCount, 10)
        let interval = DateInterval(start: base, duration: 60)
        XCTAssertTrue(try store.series(.cpuTotal, in: interval, resolution: .raw).isEmpty)
        try store.flush()
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(try store.series(.cpuTotal, in: interval, resolution: .raw).map(\.mean), (0..<10).map(Double.init))
    }

    func testRollupProducesMinuteAndQuarterTiers() throws {
        let store = try makeStore()
        // 30 minutes of 1 Hz data with value = minute index.
        store.enqueue(samples(.cpuTotal, count: 1800, from: base) { Double($0 / 60) })
        try store.flush()
        try store.rollUp(now: base.addingTimeInterval(1800 + 900))
        let interval = DateInterval(start: base.addingTimeInterval(-60), duration: 1900)
        let minutes = try store.series(.cpuTotal, in: interval, resolution: .minute)
        XCTAssertGreaterThanOrEqual(minutes.count, 30)
        XCTAssertEqual(minutes.reduce(0) { $0 + $1.count }, 1800)
        let quarters = try store.series(.cpuTotal, in: DateInterval(start: base.addingTimeInterval(-900), duration: 3600), resolution: .quarterHour)
        XCTAssertFalse(quarters.isEmpty)
        XCTAssertEqual(quarters.reduce(0) { $0 + $1.count }, 1800, "Weighted rollup preserves sample counts")
    }

    func testRollupIsIdempotentAndHandlesLateSamples() throws {
        let store = try makeStore()
        store.enqueue(samples(.diskWriteRate, count: 30, from: base) { _ in 10 })
        try store.flush()
        try store.rollUp(now: base.addingTimeInterval(120))
        // Late batch for the same minute arrives after the rollup.
        store.enqueue(samples(.diskWriteRate, count: 10, from: base.addingTimeInterval(30)) { _ in 10 })
        try store.flush()
        try store.rollUp(now: base.addingTimeInterval(150))
        try store.rollUp(now: base.addingTimeInterval(150))
        let points = try store.series(.diskWriteRate, in: DateInterval(start: base.addingTimeInterval(-60), duration: 300), resolution: .minute)
        XCTAssertEqual(points.reduce(0) { $0 + $1.count }, 40)
    }

    func testRetentionRemovesOldRawData() throws {
        var policy = RetentionPolicy()
        policy.rawSeconds = 60
        let store = try makeStore(policy: policy)
        store.enqueue(samples(.cpuTotal, count: 120, from: base) { _ in 1 })
        try store.flush()
        let removed = try store.applyRetention(now: base.addingTimeInterval(120))
        XCTAssertGreaterThanOrEqual(removed, 59)
        let remaining = try store.series(.cpuTotal, in: DateInterval(start: base, duration: 200), resolution: .raw)
        XCTAssertTrue(remaining.allSatisfy { $0.start >= base.addingTimeInterval(60) })
    }

    func testResolutionSelection() {
        let now = base
        let policy = RetentionPolicy()
        XCTAssertEqual(HistoryStore.resolution(for: DateInterval(start: now.addingTimeInterval(-600), end: now), now: now, policy: policy), .raw)
        XCTAssertEqual(HistoryStore.resolution(for: DateInterval(start: now.addingTimeInterval(-86_400), end: now), now: now, policy: policy), .minute)
        XCTAssertEqual(HistoryStore.resolution(for: DateInterval(start: now.addingTimeInterval(-30 * 86_400), end: now), now: now, policy: policy), .quarterHour)
    }

    func testIncidentsAndActionsRoundTrip() throws {
        let store = try makeStore()
        let incident = Incident(
            ruleID: "memory.pressure", title: "t", summary: "s", severity: .warning, startedAt: base, lastObservedAt: base,
            peakValue: 1, primaryMetric: .memoryPressureLevel, evidence: [Evidence(.observation, "x", metric: .memoryPressureLevel)],
            contributors: [], nextStep: "n", userState: .snoozed(until: base.addingTimeInterval(60)), notes: "my note"
        )
        try store.save(incident)
        try store.save(incident) // upsert
        XCTAssertEqual(try store.incidents(since: base.addingTimeInterval(-1)), [incident])

        let action = ActionRecord(kind: .quitApp, targetDescription: "Slack", incidentID: incident.id, requestedAt: base, phase: .succeeded)
        try store.save(action)
        XCTAssertEqual(try store.actions(since: base.addingTimeInterval(-1)), [action])
    }

    func testProcessSummariesRanking() throws {
        let store = try makeStore()
        let minute = Date(timeIntervalSince1970: 1_700_000_040 / 60 * 60)
        try store.recordProcessSummaries([
            ProcessGroupSummary(bucket: minute, groupKey: "a", name: "A", cpuMean: 10, cpuMax: 20, memoryMax: 5e9, diskWriteMean: nil, samples: 30),
            ProcessGroupSummary(bucket: minute, groupKey: "b", name: "B", cpuMean: 90, cpuMax: 99, memoryMax: 1e9, diskWriteMean: 1e6, samples: 30),
        ])
        let interval = DateInterval(start: minute, duration: 120)
        XCTAssertEqual(try store.topProcessGroups(in: interval, by: .cpu).map(\.name), ["B", "A"])
        XCTAssertEqual(try store.topProcessGroups(in: interval, by: .memory).map(\.name), ["A", "B"])
        let byWrites = try store.topProcessGroups(in: interval, by: .diskWrite)
        XCTAssertEqual(byWrites.first?.name, "B")
        XCTAssertNil(byWrites.last?.diskWriteMean, "NULL stays nil")
    }

    func testClearAll() throws {
        let store = try makeStore()
        store.enqueue(samples(.cpuTotal, count: 5, from: base) { _ in 1 })
        try store.flush()
        try store.clearAll()
        XCTAssertTrue(try store.series(.cpuTotal, in: DateInterval(start: base, duration: 60), resolution: .raw).isEmpty)
    }

    func testCSVExport() throws {
        let store = try makeStore()
        store.enqueue(samples(.cpuTotal, count: 3, from: base) { Double($0) })
        try store.flush()
        let csv = try store.exportCSV(metrics: [.cpuTotal], in: DateInterval(start: base, duration: 10), now: base.addingTimeInterval(10))
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "metric,unit,start,min,max,mean,count,resolution_seconds")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[1].hasPrefix("cpu.total,percent,"))
    }

    func testFileBackedStoreSurvivesReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let store = try HistoryStore(path: path)
            store.enqueue(samples(.cpuTotal, count: 3, from: base) { _ in 1 })
            try store.flush()
        }
        let reopened = try HistoryStore(path: path)
        XCTAssertEqual(try reopened.series(.cpuTotal, in: DateInterval(start: base, duration: 10), resolution: .raw).count, 3)
        XCTAssertGreaterThan(try reopened.sizeBytes(), 0)
    }
}
