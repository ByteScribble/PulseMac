import XCTest
@testable import PulseCore

final class RingBufferTests: XCTestCase {
    func testOverwritesOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        XCTAssertEqual(Array(buffer), [3, 4, 5])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.last, 5)
    }

    func testRemoveAll() {
        var buffer = RingBuffer<Int>(capacity: 2)
        buffer.append(1)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.last)
    }
}

final class DownsamplerTests: XCTestCase {
    private func sample(_ t: Double, _ v: Double) -> Sample {
        Sample(metric: .cpuTotal, time: Date(timeIntervalSince1970: t), value: v)
    }

    func testAggregatesBuckets() {
        let points = Downsampler.aggregate([sample(0, 10), sample(30, 30), sample(60, 50), sample(119, 70)], bucket: 60)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].mean, 20)
        XCTAssertEqual(points[0].min, 10)
        XCTAssertEqual(points[1].max, 70)
        XCTAssertEqual(points[1].count, 2)
    }

    func testEmptyBucketsStayGaps() {
        let points = Downsampler.aggregate([sample(0, 1), sample(600, 1)], bucket: 60)
        XCTAssertEqual(points.count, 2, "No synthetic zero buckets between samples")
    }

    func testSegmentsSplitOnGaps() {
        let segments = Downsampler.segments([sample(0, 1), sample(1, 1), sample(100, 1), sample(101, 1)], maximumGap: 5)
        XCTAssertEqual(segments.map(\.count), [2, 2])
    }
}

final class TrendTests: XCTestCase {
    func testLinearFit() throws {
        let samples = (0..<10).map { Sample(metric: .swapUsedBytes, time: Date(timeIntervalSince1970: Double($0)), value: Double($0) * 2 + 5) }
        let trend = try XCTUnwrap(TrendStatistics.fit(samples))
        XCTAssertEqual(trend.slope, 2, accuracy: 1e-9)
        XCTAssertEqual(trend.rSquared, 1, accuracy: 1e-9)
    }

    func testTooFewSamples() {
        XCTAssertNil(TrendStatistics.fit([]))
    }
}

final class MetricHistoryTests: XCTestCase {
    func testWindowQueryAndOrdering() {
        let history = MetricHistory(capacityPerMetric: 10)
        let base = Date(timeIntervalSince1970: 1000)
        history.append((0..<5).map { Sample(metric: .cpuTotal, time: base.addingTimeInterval(Double($0)), value: Double($0)) })
        history.append([Sample(metric: .cpuTotal, time: base, value: 99)]) // out of order: ignored
        XCTAssertEqual(history.samples(.cpuTotal, from: base.addingTimeInterval(2), to: base.addingTimeInterval(4)).map(\.value), [2, 3, 4])
        XCTAssertEqual(history.latest(.cpuTotal)?.value, 4)
        XCTAssertTrue(history.all(.memoryUsedBytes).isEmpty)
    }
}
