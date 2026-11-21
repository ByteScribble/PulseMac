import Foundation
import PulseCore

/// Retention defaults (subject to profiling — docs/engineering/performance-budgets.md).
public struct RetentionPolicy: Equatable, Sendable {
    public var rawSeconds: TimeInterval = 6 * 3600
    public var minuteSeconds: TimeInterval = 7 * 86_400
    public var quarterHourSeconds: TimeInterval = 90 * 86_400
    public var processSummarySeconds: TimeInterval = 7 * 86_400
    public var incidentSeconds: TimeInterval = 90 * 86_400
    /// Soft cap; when exceeded the oldest high-resolution data is trimmed first.
    public var maximumDatabaseBytes: Int64 = 200_000_000

    public init() {}
}

/// Per-minute summary of one process group (app or standalone process).
public struct ProcessGroupSummary: Equatable, Sendable, Codable {
    public var bucket: Date
    public var groupKey: String
    public var name: String
    public var cpuMean: Double?
    public var cpuMax: Double?
    public var memoryMax: Double?
    public var diskWriteMean: Double?
    public var samples: Int

    public init(
        bucket: Date, groupKey: String, name: String, cpuMean: Double?, cpuMax: Double?,
        memoryMax: Double?, diskWriteMean: Double?, samples: Int
    ) {
        self.bucket = bucket
        self.groupKey = groupKey
        self.name = name
        self.cpuMean = cpuMean
        self.cpuMax = cpuMax
        self.memoryMax = memoryMax
        self.diskWriteMean = diskWriteMean
        self.samples = samples
    }
}

public enum Resolution: Int, Sendable {
    case raw = 0
    case minute = 60
    case quarterHour = 900
}

/// Bounded, local-only time-series history backed by SQLite (WAL mode).
///
/// Write path: callers `enqueue` samples (cheap, in memory) and the coordinator calls
/// `flush()` periodically so disk writes are batched (default every 30 s).
/// All database access is serialized on a private queue.
public final class HistoryStore: @unchecked Sendable {
    public static let schemaVersion = 1

    private let queue = DispatchQueue(label: "PulseMac.HistoryStore")
    private let database: SQLiteDatabase
    private var pending: [Sample] = []
    public let policy: RetentionPolicy
    public let path: String

    /// - Parameter path: file path, or ":memory:" for tests.
    public init(path: String, policy: RetentionPolicy = RetentionPolicy()) throws {
        self.path = path
        self.policy = policy
        database = try SQLiteDatabase(path: path)
        try database.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try migrate()
    }

    /// Default location: ~/Library/Application Support/PulseMac/history.sqlite
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("PulseMac", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    // MARK: - Schema

    private func migrate() throws {
        let version = try database.userVersion
        if version < 1 {
            try database.transaction {
                try database.execute("""
                CREATE TABLE IF NOT EXISTS samples_raw (
                    metric TEXT NOT NULL, ts INTEGER NOT NULL, value REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS samples_raw_metric_ts ON samples_raw(metric, ts);
                CREATE TABLE IF NOT EXISTS samples_rollup (
                    tier INTEGER NOT NULL, metric TEXT NOT NULL, bucket INTEGER NOT NULL,
                    min REAL NOT NULL, max REAL NOT NULL, mean REAL NOT NULL, count INTEGER NOT NULL,
                    PRIMARY KEY (tier, metric, bucket)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS process_summary (
                    bucket INTEGER NOT NULL, group_key TEXT NOT NULL, name TEXT NOT NULL,
                    cpu_mean REAL, cpu_max REAL, memory_max REAL, disk_write_mean REAL, samples INTEGER NOT NULL,
                    PRIMARY KEY (bucket, group_key)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS incidents (
                    id TEXT PRIMARY KEY, started INTEGER NOT NULL, body BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS actions (
                    id TEXT PRIMARY KEY, ts INTEGER NOT NULL, body BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
                """)
                try database.setUserVersion(1)
            }
        }
        // Future migrations: `if version < 2 { ... setUserVersion(2) }`. Never edit version 1.
    }

    // MARK: - Writes

    public func enqueue(_ samples: [Sample]) {
        queue.sync { pending.append(contentsOf: samples) }
    }

    public var pendingCount: Int { queue.sync { pending.count } }

    /// Writes all pending samples in one transaction.
    public func flush() throws {
        try queue.sync {
            guard !pending.isEmpty else { return }
            let batch = pending
            try database.transaction {
                let insert = try database.prepare("INSERT INTO samples_raw (metric, ts, value) VALUES (?, ?, ?)")
                for sample in batch {
                    try insert.bind(sample.metric.rawValue, Self.millis(sample.time), sample.value).run()
                }
            }
            pending.removeAll(keepingCapacity: true)
        }
    }

    public func recordProcessSummaries(_ summaries: [ProcessGroupSummary]) throws {
        try queue.sync {
            try database.transaction {
                let insert = try database.prepare("""
                INSERT OR REPLACE INTO process_summary
                (bucket, group_key, name, cpu_mean, cpu_max, memory_max, disk_write_mean, samples)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
                for item in summaries {
                    try insert.bind(
                        Int64(item.bucket.timeIntervalSince1970), item.groupKey, item.name, item.cpuMean,
                        item.cpuMax, item.memoryMax, item.diskWriteMean, item.samples
                    ).run()
                }
            }
        }
    }

    public func save(_ incident: Incident) throws {
        let body = try JSONEncoder().encode(incident)
        try queue.sync {
            try database.prepare("INSERT OR REPLACE INTO incidents (id, started, body) VALUES (?, ?, ?)")
                .bind(incident.id.uuidString, Int64(incident.startedAt.timeIntervalSince1970), body).run()
        }
    }

    public func save(_ action: ActionRecord) throws {
        let body = try JSONEncoder().encode(action)
        try queue.sync {
            try database.prepare("INSERT OR REPLACE INTO actions (id, ts, body) VALUES (?, ?, ?)")
                .bind(action.id.uuidString, Int64(action.requestedAt.timeIntervalSince1970), body).run()
        }
    }

    // MARK: - Rollup & retention

    /// Aggregates completed raw minutes into the minute tier and completed minute data into the
    /// quarter-hour tier. Idempotent; safe to call repeatedly (every few minutes).
    public func rollUp(now: Date) throws {
        try queue.sync {
            let nowSeconds = Int64(now.timeIntervalSince1970)
            let minuteCutoff = nowSeconds / 60 * 60
            // Re-aggregate the last two minutes too: samples are flushed in batches and may land late.
            let minuteSince = max((try watermark("minute") ?? 0) - 120, 0)
            try database.transaction {
                try database.prepare("""
                INSERT OR REPLACE INTO samples_rollup (tier, metric, bucket, min, max, mean, count)
                SELECT 60, metric, (ts / 60000) * 60, MIN(value), MAX(value), AVG(value), COUNT(*)
                FROM samples_raw WHERE ts >= ? AND ts < ? GROUP BY metric, ts / 60000
                """).bind(minuteSince * 1000, minuteCutoff * 1000).run()
                try setWatermark("minute", minuteCutoff)

                let quarterCutoff = nowSeconds / 900 * 900
                let quarterSince = max((try watermark("quarter") ?? 0) - 1800, 0)
                try database.prepare("""
                INSERT OR REPLACE INTO samples_rollup (tier, metric, bucket, min, max, mean, count)
                SELECT 900, metric, (bucket / 900) * 900, MIN(min), MAX(max), SUM(mean * count) / SUM(count), SUM(count)
                FROM samples_rollup WHERE tier = 60 AND bucket >= ? AND bucket < ? GROUP BY metric, bucket / 900
                """).bind(quarterSince, quarterCutoff).run()
                try setWatermark("quarter", quarterCutoff)
            }
        }
    }

    /// Deletes data older than the policy allows. Returns number of rows removed.
    @discardableResult
    public func applyRetention(now: Date) throws -> Int {
        try queue.sync {
            let seconds = now.timeIntervalSince1970
            var removed = 0
            try database.transaction {
                try database.prepare("DELETE FROM samples_raw WHERE ts < ?")
                    .bind(Int64((seconds - policy.rawSeconds) * 1000)).run()
                removed += database.changes
                try database.prepare("DELETE FROM samples_rollup WHERE tier = 60 AND bucket < ?")
                    .bind(Int64(seconds - policy.minuteSeconds)).run()
                removed += database.changes
                try database.prepare("DELETE FROM samples_rollup WHERE tier = 900 AND bucket < ?")
                    .bind(Int64(seconds - policy.quarterHourSeconds)).run()
                removed += database.changes
                try database.prepare("DELETE FROM process_summary WHERE bucket < ?")
                    .bind(Int64(seconds - policy.processSummarySeconds)).run()
                removed += database.changes
                try database.prepare("DELETE FROM incidents WHERE started < ?")
                    .bind(Int64(seconds - policy.incidentSeconds)).run()
                removed += database.changes
            }
            if try sizeBytesLocked() > policy.maximumDatabaseBytes {
                // Over budget: halve raw retention window first (it is the largest table).
                try database.prepare("DELETE FROM samples_raw WHERE ts < ?")
                    .bind(Int64((seconds - policy.rawSeconds / 2) * 1000)).run()
                removed += database.changes
            }
            return removed
        }
    }

    /// Removes all history, incidents and action logs. Irreversible; UI confirms first.
    public func clearAll() throws {
        try queue.sync {
            pending.removeAll()
            try database.transaction {
                try database.execute("""
                DELETE FROM samples_raw; DELETE FROM samples_rollup; DELETE FROM process_summary;
                DELETE FROM incidents; DELETE FROM actions; DELETE FROM meta;
                """)
            }
            try database.execute("VACUUM")
        }
    }

    // MARK: - Reads

    /// Returns points for a time range, choosing the finest resolution that still covers it.
    public func series(_ metric: MetricID, in interval: DateInterval, now: Date = Date()) throws -> (Resolution, [AggregatePoint]) {
        let resolution = Self.resolution(for: interval, now: now, policy: policy)
        let points = try series(metric, in: interval, resolution: resolution)
        return (resolution, points)
    }

    public static func resolution(for interval: DateInterval, now: Date, policy: RetentionPolicy) -> Resolution {
        let rawFloor = now.addingTimeInterval(-policy.rawSeconds)
        if interval.duration <= 2 * 3600, interval.start >= rawFloor { return .raw }
        if interval.duration <= 3 * 86_400 { return .minute }
        return .quarterHour
    }

    public func series(_ metric: MetricID, in interval: DateInterval, resolution: Resolution) throws -> [AggregatePoint] {
        try queue.sync {
            var points: [AggregatePoint] = []
            switch resolution {
            case .raw:
                let statement = try database.prepare(
                    "SELECT ts, value FROM samples_raw WHERE metric = ? AND ts >= ? AND ts <= ? ORDER BY ts"
                ).bind(metric.rawValue, Self.millis(interval.start), Self.millis(interval.end))
                while try statement.step() {
                    let value = statement.double(1)
                    points.append(AggregatePoint(
                        start: Date(timeIntervalSince1970: Double(statement.int64(0)) / 1000),
                        min: value, max: value, mean: value, count: 1
                    ))
                }
            case .minute, .quarterHour:
                let statement = try database.prepare("""
                SELECT bucket, min, max, mean, count FROM samples_rollup
                WHERE tier = ? AND metric = ? AND bucket >= ? AND bucket <= ? ORDER BY bucket
                """).bind(
                    resolution.rawValue, metric.rawValue,
                    Int64(interval.start.timeIntervalSince1970) / Int64(resolution.rawValue) * Int64(resolution.rawValue),
                    Int64(interval.end.timeIntervalSince1970)
                )
                while try statement.step() {
                    points.append(AggregatePoint(
                        start: Date(timeIntervalSince1970: Double(statement.int64(0))),
                        min: statement.double(1), max: statement.double(2), mean: statement.double(3),
                        count: Int(statement.int64(4))
                    ))
                }
            }
            return points
        }
    }

    public enum ProcessRanking: Sendable { case cpu, memory, diskWrite }

    /// Top process groups across an interval, for "what was running during this spike?".
    public func topProcessGroups(in interval: DateInterval, by ranking: ProcessRanking, limit: Int = 10) throws -> [ProcessGroupSummary] {
        let order: String
        switch ranking {
        case .cpu: order = "cpu_mean"
        case .memory: order = "memory_max"
        case .diskWrite: order = "disk_write_mean"
        }
        return try queue.sync {
            let statement = try database.prepare("""
            SELECT group_key, MAX(name), SUM(cpu_mean * samples) / SUM(samples) AS cpu_mean, MAX(cpu_max),
                   MAX(memory_max) AS memory_max, SUM(disk_write_mean * samples) / SUM(samples) AS disk_write_mean,
                   SUM(samples), MIN(bucket)
            FROM process_summary WHERE bucket >= ? AND bucket <= ?
            GROUP BY group_key ORDER BY \(order) DESC NULLS LAST LIMIT ?
            """).bind(Int64(interval.start.timeIntervalSince1970) / 60 * 60, Int64(interval.end.timeIntervalSince1970), limit)
            var result: [ProcessGroupSummary] = []
            while try statement.step() {
                func optional(_ column: Int32) -> Double? {
                    statement.isNull(column) ? nil : statement.double(column)
                }
                result.append(ProcessGroupSummary(
                    bucket: Date(timeIntervalSince1970: Double(statement.int64(7))),
                    groupKey: statement.string(0) ?? "", name: statement.string(1) ?? "",
                    cpuMean: optional(2), cpuMax: optional(3), memoryMax: optional(4), diskWriteMean: optional(5),
                    samples: Int(statement.int64(6))
                ))
            }
            return result
        }
    }

    public func incidents(since: Date) throws -> [Incident] {
        try queue.sync {
            let statement = try database.prepare("SELECT body FROM incidents WHERE started >= ? ORDER BY started")
                .bind(Int64(since.timeIntervalSince1970))
            var result: [Incident] = []
            let decoder = JSONDecoder()
            while try statement.step() {
                if let data = statement.data(0), let incident = try? decoder.decode(Incident.self, from: data) {
                    result.append(incident)
                }
            }
            return result
        }
    }

    public func actions(since: Date) throws -> [ActionRecord] {
        try queue.sync {
            let statement = try database.prepare("SELECT body FROM actions WHERE ts >= ? ORDER BY ts")
                .bind(Int64(since.timeIntervalSince1970))
            var result: [ActionRecord] = []
            let decoder = JSONDecoder()
            while try statement.step() {
                if let data = statement.data(0), let action = try? decoder.decode(ActionRecord.self, from: data) {
                    result.append(action)
                }
            }
            return result
        }
    }

    public func sizeBytes() throws -> Int64 { try queue.sync { try sizeBytesLocked() } }

    // MARK: - Export

    /// CSV with ISO-8601 timestamps. Columns: metric, unit, start, min, max, mean, count, resolution.
    public func exportCSV(metrics: [MetricID], in interval: DateInterval, now: Date = Date()) throws -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["metric,unit,start,min,max,mean,count,resolution_seconds"]
        for metric in metrics {
            let (resolution, points) = try series(metric, in: interval, now: now)
            for point in points {
                lines.append([
                    metric.rawValue, metric.unit.rawValue, iso.string(from: point.start),
                    String(point.min), String(point.max), String(point.mean), String(point.count),
                    String(resolution.rawValue),
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    private static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private func watermark(_ key: String) throws -> Int64? {
        let statement = try database.prepare("SELECT value FROM meta WHERE key = ?").bind(key)
        return try statement.step() ? statement.int64(0) : nil
    }

    private func setWatermark(_ key: String, _ value: Int64) throws {
        try database.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)").bind(key, value).run()
    }

    private func sizeBytesLocked() throws -> Int64 {
        let pages = try database.prepare("PRAGMA page_count")
        let size = try database.prepare("PRAGMA page_size")
        guard try pages.step(), try size.step() else { return 0 }
        return pages.int64(0) * size.int64(0)
    }
}
