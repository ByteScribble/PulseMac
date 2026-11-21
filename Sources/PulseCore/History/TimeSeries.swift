import Foundation

/// Fixed-capacity FIFO buffer. O(1) append; oldest element is overwritten when full.
public struct RingBuffer<Element>: Sequence {
    public let capacity: Int
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    public mutating func append(_ element: Element) {
        storage[(head + count) % capacity] = element
        if count < capacity {
            count += 1
        } else {
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    public var last: Element? { count == 0 ? nil : storage[(head + count - 1) % capacity] }
    public var isEmpty: Bool { count == 0 }

    public func makeIterator() -> AnyIterator<Element> {
        var index = 0
        return AnyIterator {
            guard index < count else { return nil }
            defer { index += 1 }
            return storage[(head + index) % capacity]
        }
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

/// Aggregated bucket used for downsampled history.
public struct AggregatePoint: Equatable, Sendable, Codable {
    public var start: Date
    public var min: Double
    public var max: Double
    public var mean: Double
    public var count: Int

    public init(start: Date, min: Double, max: Double, mean: Double, count: Int) {
        self.start = start
        self.min = min
        self.max = max
        self.mean = mean
        self.count = count
    }
}

public enum Downsampler {
    /// Buckets samples into fixed windows aligned to the Unix epoch. Empty buckets are omitted
    /// (gaps stay gaps; they are never interpolated as zero).
    public static func aggregate(_ samples: [Sample], bucket: TimeInterval) -> [AggregatePoint] {
        precondition(bucket > 0)
        var buckets: [Int64: (min: Double, max: Double, sum: Double, count: Int)] = [:]
        for sample in samples {
            let key = Int64((sample.time.timeIntervalSince1970 / bucket).rounded(.down))
            if var existing = buckets[key] {
                existing.min = Swift.min(existing.min, sample.value)
                existing.max = Swift.max(existing.max, sample.value)
                existing.sum += sample.value
                existing.count += 1
                buckets[key] = existing
            } else {
                buckets[key] = (sample.value, sample.value, sample.value, 1)
            }
        }
        return buckets.keys.sorted().map { key in
            let value = buckets[key]!
            return AggregatePoint(
                start: Date(timeIntervalSince1970: Double(key) * bucket),
                min: value.min, max: value.max, mean: value.sum / Double(value.count), count: value.count
            )
        }
    }

    /// Splits a time-ordered series into contiguous segments wherever consecutive samples are
    /// further apart than `maximumGap` (sleep, paused monitoring). Charts draw each segment
    /// separately so gaps are visible.
    public static func segments(_ samples: [Sample], maximumGap: TimeInterval) -> [[Sample]] {
        var result: [[Sample]] = []
        var current: [Sample] = []
        for sample in samples {
            if let previous = current.last, sample.time.timeIntervalSince(previous.time) > maximumGap {
                result.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Simple least-squares statistics over a window. Used for trend and growth heuristics.
public struct TrendStatistics: Equatable, Sendable {
    /// Units per second.
    public var slope: Double
    /// Coefficient of determination (0...1). How well a straight line explains the series.
    public var rSquared: Double
    public var first: Double
    public var last: Double
    public var duration: TimeInterval

    public static func fit(_ samples: [Sample]) -> TrendStatistics? {
        guard samples.count >= 3, let start = samples.first?.time, let end = samples.last?.time else { return nil }
        let xs = samples.map { $0.time.timeIntervalSince(start) }
        let ys = samples.map(\.value)
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            sxy += (x - meanX) * (y - meanY)
            syy += (y - meanY) * (y - meanY)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let rSquared = syy > 0 ? (sxy * sxy) / (sxx * syy) : 1
        return TrendStatistics(
            slope: slope, rSquared: rSquared, first: ys[0], last: ys[ys.count - 1],
            duration: end.timeIntervalSince(start)
        )
    }
}
