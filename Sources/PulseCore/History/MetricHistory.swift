import Foundation

/// Read access to recent samples. Implemented by the in-memory `MetricHistory` and by
/// replay fixtures in tests.
public protocol MetricHistoryReading: Sendable {
    func samples(_ metric: MetricID, from start: Date, to end: Date) -> [Sample]
}

extension MetricHistoryReading {
    public func samples(_ metric: MetricID, last seconds: TimeInterval, endingAt end: Date) -> [Sample] {
        samples(metric, from: end.addingTimeInterval(-seconds), to: end)
    }
}

/// High-resolution in-memory history: one ring buffer per metric.
/// Default capacity holds 15 minutes at 1 Hz. Older data lives in `PulsePersistence`.
public final class MetricHistory: MetricHistoryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [MetricID: RingBuffer<Sample>] = [:]
    public let capacityPerMetric: Int

    public init(capacityPerMetric: Int = 900) {
        self.capacityPerMetric = capacityPerMetric
    }

    public func append(_ samples: [Sample]) {
        lock.lock(); defer { lock.unlock() }
        for sample in samples {
            if let last = buffers[sample.metric]?.last, sample.time < last.time { continue } // keep time order
            buffers[sample.metric, default: RingBuffer(capacity: capacityPerMetric)].append(sample)
        }
    }

    public func samples(_ metric: MetricID, from start: Date, to end: Date) -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        guard let buffer = buffers[metric] else { return [] }
        return buffer.filter { $0.time >= start && $0.time <= end }
    }

    public func all(_ metric: MetricID) -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        return buffers[metric].map(Array.init) ?? []
    }

    public func latest(_ metric: MetricID) -> Sample? {
        lock.lock(); defer { lock.unlock() }
        return buffers[metric]?.last
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        buffers.removeAll()
    }
}

/// Window helpers used by rules. All return `nil` when data is insufficient, so rules can
/// report "unknown" instead of mistaking missing data for a healthy reading.
public struct WindowStats: Equatable, Sendable {
    public var mean: Double
    public var min: Double
    public var max: Double
    public var first: Sample
    public var last: Sample
    public var count: Int

    public var coverage: TimeInterval { last.time.timeIntervalSince(first.time) }

    public init?(_ samples: [Sample]) {
        guard let first = samples.first, let last = samples.last else { return nil }
        let values = samples.map(\.value)
        mean = values.reduce(0, +) / Double(values.count)
        min = values.min() ?? first.value
        max = values.max() ?? first.value
        self.first = first
        self.last = last
        count = samples.count
    }
}
