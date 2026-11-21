import Foundation
import PulseCore
import PulsePersistence

/// Accumulates process samples into per-minute group summaries so history can answer
/// "what was busy during that spike?" without persisting every process every second.
/// Only the top groups by CPU, memory and disk writes are kept per minute.
public struct ProcessSummarizer {
    private struct Accumulator {
        var name: String
        var cpuSum = 0.0
        var cpuCount = 0
        var cpuMax = 0.0
        var memoryMax = 0.0
        var writeSum = 0.0
        var writeCount = 0
        var samples = 0
    }

    public let keepPerRanking: Int
    private var minute: Int64?
    private var groups: [String: Accumulator] = [:]

    public init(keepPerRanking: Int = 15) { self.keepPerRanking = keepPerRanking }

    /// Adds a sample. Returns finished summaries when a minute boundary is crossed.
    public mutating func add(_ processes: [ProcessSample], at date: Date) -> [ProcessGroupSummary] {
        let bucket = Int64(date.timeIntervalSince1970) / 60 * 60
        var finished: [ProcessGroupSummary] = []
        if let minute, minute != bucket { finished = drain() }
        minute = bucket
        for group in AppGrouping.group(processes) {
            var accumulator = groups[group.id] ?? Accumulator(name: group.name)
            accumulator.samples += 1
            if let cpu = group.cpuPercent {
                accumulator.cpuSum += cpu
                accumulator.cpuCount += 1
                accumulator.cpuMax = max(accumulator.cpuMax, cpu)
            }
            if let memory = group.memoryFootprint { accumulator.memoryMax = max(accumulator.memoryMax, Double(memory)) }
            if let write = group.diskWriteRate {
                accumulator.writeSum += write
                accumulator.writeCount += 1
            }
            groups[group.id] = accumulator
        }
        return finished
    }

    /// Emits summaries for the current minute and clears state.
    public mutating func drain() -> [ProcessGroupSummary] {
        guard let minute else { return [] }
        let bucket = Date(timeIntervalSince1970: Double(minute))
        let all = groups.map { key, value in
            ProcessGroupSummary(
                bucket: bucket, groupKey: key, name: value.name,
                cpuMean: value.cpuCount > 0 ? value.cpuSum / Double(value.cpuCount) : nil,
                cpuMax: value.cpuCount > 0 ? value.cpuMax : nil,
                memoryMax: value.memoryMax > 0 ? value.memoryMax : nil,
                diskWriteMean: value.writeCount > 0 ? value.writeSum / Double(value.writeCount) : nil,
                samples: value.samples
            )
        }
        var keep = Set<String>()
        for ranking in [\ProcessGroupSummary.cpuMean, \.memoryMax, \.diskWriteMean] {
            let top = all.filter { $0[keyPath: ranking] != nil }
                .sorted { ($0[keyPath: ranking] ?? 0) > ($1[keyPath: ranking] ?? 0) }
                .prefix(keepPerRanking)
            keep.formUnion(top.map(\.groupKey))
        }
        groups.removeAll(keepingCapacity: true)
        self.minute = nil
        return all.filter { keep.contains($0.groupKey) }.sorted { $0.groupKey < $1.groupKey }
    }
}
