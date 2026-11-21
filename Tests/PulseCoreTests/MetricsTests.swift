import XCTest
@testable import PulseCore

final class CounterTests: XCTestCase {
    func testDeltaIncreasing() {
        XCTAssertEqual(Counter.delta(previous: 10, current: 25, width: .bits64), 15)
    }

    func testDelta32BitWrap() {
        let previous = UInt64(UInt32.max) - 4
        XCTAssertEqual(Counter.delta(previous: previous, current: 5, width: .bits32), 10)
    }

    func testDelta64BitResetReturnsNil() {
        XCTAssertNil(Counter.delta(previous: 1_000, current: 10, width: .bits64))
    }

    func testRateFirstReadingIsNil() {
        var rate = RateCalculator()
        XCTAssertNil(rate.rate(value: 100, at: 0))
        XCTAssertEqual(rate.rate(value: 300, at: 2), 100)
    }

    func testRateSkipsSleepGap() {
        var rate = RateCalculator(maximumGap: 30)
        _ = rate.rate(value: 0, at: 0)
        XCTAssertNil(rate.rate(value: 1_000_000, at: 3600), "Rate across a sleep gap must not be reported")
        XCTAssertEqual(rate.rate(value: 1_000_100, at: 3601), 100)
    }

    func testRateResetIsNil() {
        var rate = RateCalculator()
        _ = rate.rate(value: 5_000, at: 0)
        XCTAssertNil(rate.rate(value: 10, at: 1))
        XCTAssertEqual(rate.rate(value: 20, at: 2), 10)
    }
}

final class CPUTests: XCTestCase {
    func testCPULoadAggregatesAcrossCores() throws {
        let previous = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [CPUTicks(user: 50, system: 25, idle: 25, nice: 0), CPUTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let load = try XCTUnwrap(CPULoad.compute(previous: previous, current: current))
        XCTAssertEqual(load.total, 37.5, accuracy: 0.001)
        XCTAssertEqual(load.user, 25, accuracy: 0.001)
        XCTAssertEqual(load.system, 12.5, accuracy: 0.001)
        XCTAssertEqual(load.perCore, [75, 0])
    }

    func testCPULoadHandlesTickWrap() throws {
        let max = UInt64(UInt32.max)
        let previous = [CPUTicks(user: max - 9, system: 0, idle: max - 9, nice: 0)]
        let current = [CPUTicks(user: 40, system: 0, idle: 40, nice: 0)]
        let load = try XCTUnwrap(CPULoad.compute(previous: previous, current: current))
        XCTAssertEqual(load.total, 50, accuracy: 0.001)
    }

    func testCPULoadCoreCountChangeIsNil() {
        XCTAssertNil(CPULoad.compute(previous: [], current: [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)]))
    }

    func testNiceCountsAsUser() throws {
        let load = try XCTUnwrap(CPULoad.compute(
            previous: [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
            current: [CPUTicks(user: 0, system: 0, idle: 50, nice: 50)]
        ))
        XCTAssertEqual(load.user, 50, accuracy: 0.001)
    }

    func testProcessCPUSemantics() {
        // 4 seconds of CPU in 1 second of wall time = 400% of one core = 40% of a 10-core system.
        let oneCore = ProcessCPU.percentOfOneCore(cpuTimeDeltaNanoseconds: 4_000_000_000, wallDeltaNanoseconds: 1_000_000_000)
        XCTAssertEqual(oneCore, 400, accuracy: 0.001)
        XCTAssertEqual(ProcessCPU.percentOfSystem(percentOfOneCore: oneCore, logicalCores: 10), 40, accuracy: 0.001)
        XCTAssertEqual(ProcessCPU.percentOfOneCore(cpuTimeDeltaNanoseconds: 1, wallDeltaNanoseconds: 0), 0)
    }
}

final class MemoryTests: XCTestCase {
    private func snapshot(pressure: MemoryPressureLevel?, internal: UInt64 = 8_000_000_000) -> MemorySnapshot {
        MemorySnapshot(
            physical: 16_000_000_000, free: 500_000_000, active: 0, inactive: 0, wired: 2_000_000_000,
            compressed: 1_000_000_000, purgeable: 500_000_000, external: 3_000_000_000, internal: `internal`,
            swapTotal: 2_000_000_000, swapUsed: 500_000_000, pressure: pressure, cumulativePageIns: 0, cumulativePageOuts: 0
        )
    }

    func testUsedMatchesActivityMonitorDefinition() {
        let memory = snapshot(pressure: .normal)
        XCTAssertEqual(memory.appMemory, 7_500_000_000)
        XCTAssertEqual(memory.used, 10_500_000_000)
        XCTAssertEqual(memory.cachedFiles, 3_500_000_000)
    }

    func testUsedIsClampedToPhysical() {
        XCTAssertEqual(snapshot(pressure: .normal, internal: 40_000_000_000).used, 16_000_000_000)
    }

    func testPressureKernelMapping() {
        XCTAssertEqual(MemoryPressureLevel(kernelValue: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(kernelValue: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(kernelValue: 4), .critical)
        XCTAssertNil(MemoryPressureLevel(kernelValue: 3))
    }

    /// Acceptance C: high cached memory is distinguished from genuine pressure.
    func testHighUsageWithNormalPressureIsHealthy() {
        let full = snapshot(pressure: .normal, internal: 14_000_000_000)
        let assessment = MemoryInterpreter.assess(full, swapGrowthBytes: 0, pageOutsPerSecond: 0)
        XCTAssertEqual(assessment.status, .healthy)
        XCTAssertTrue(assessment.detail.contains("normal"))
    }

    func testWarningPressureIsConstrained() {
        let assessment = MemoryInterpreter.assess(snapshot(pressure: .warning), swapGrowthBytes: 1_000_000_000, pageOutsPerSecond: 500)
        XCTAssertEqual(assessment.status, .constrained)
        XCTAssertTrue(assessment.detail.contains("Swap"))
    }

    func testUnknownPressureIsUnknownNotHealthy() {
        XCTAssertEqual(MemoryInterpreter.assess(snapshot(pressure: nil), swapGrowthBytes: nil, pageOutsPerSecond: nil).status, .unknown)
    }

    func testSwapGrowthWithNormalPressureIsWatch() {
        XCTAssertEqual(MemoryInterpreter.assess(snapshot(pressure: .normal), swapGrowthBytes: 600_000_000, pageOutsPerSecond: 0).status, .watch)
    }
}

final class FormatTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Format.bytes(999), "999 B")
        XCTAssertEqual(Format.bytes(1_500), "1.50 KB")
        XCTAssertEqual(Format.bytes(15_300_000), "15.3 MB")
        XCTAssertEqual(Format.bytes(250_000_000_000), "250 GB")
        XCTAssertEqual(Format.bytes(.nan), "—")
    }

    func testDuration() {
        XCTAssertEqual(Format.duration(42), "42s")
        XCTAssertEqual(Format.duration(252), "4m 12s")
        XCTAssertEqual(Format.duration(7500), "2h 05m")
        XCTAssertEqual(Format.duration(90_000), "1d 1h")
    }

    func testEveryMetricHasUnitNameAndExplanation() {
        for metric in MetricID.allCases {
            XCTAssertFalse(metric.displayName.isEmpty)
            XCTAssertGreaterThan(metric.explanation.count, 20, "\(metric) needs a real explanation")
            _ = metric.unit
        }
    }
}

final class SnapshotTests: XCTestCase {
    func testMissingDomainsProduceNoSamples() {
        let snapshot = SystemSnapshot(timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(snapshot.samples.isEmpty, "Unavailable data must never be recorded as zero")
    }

    func testDesktopMacHasNoBatterySamples() {
        var snapshot = SystemSnapshot(timestamp: Date())
        snapshot.power = PowerSnapshot(hasBattery: false, chargePercent: nil, isCharging: nil, source: .adapter, minutesRemaining: nil, cycleCount: nil, healthFraction: nil, condition: nil)
        XCTAssertFalse(snapshot.samples.contains { $0.metric == .batteryChargePercent || $0.metric == .batteryOnExternalPower })
    }

    func testNonFiniteValuesAreDropped() {
        var snapshot = SystemSnapshot(timestamp: Date())
        snapshot.loadAverage = .infinity
        XCTAssertTrue(snapshot.samples.isEmpty)
    }
}
