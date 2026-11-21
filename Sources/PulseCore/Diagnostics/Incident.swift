import Foundation

public enum Severity: Int, Codable, Sendable, Comparable {
    case info = 0, warning = 1, urgent = 2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How strongly a statement is supported. The UI labels each kind differently so users can
/// tell measured facts from correlations and hypotheses (product principle 2.3).
public enum EvidenceKind: String, Codable, Sendable {
    /// Directly measured.
    case observation
    /// Co-occurred in time; not a cause.
    case correlation
    /// Plausible explanation that has not been confirmed.
    case hypothesis
    /// What PulseMac could not see.
    case limitation
}

public struct Evidence: Equatable, Sendable, Codable {
    public var kind: EvidenceKind
    public var statement: String
    /// Metric that backs the statement — the UI links to its chart for the window.
    public var metric: MetricID?

    public init(_ kind: EvidenceKind, _ statement: String, metric: MetricID? = nil) {
        self.kind = kind
        self.statement = statement
        self.metric = metric
    }
}

/// A process or group whose resource use was high during an incident window.
/// Always presented as a correlation, never as the cause.
public struct Contributor: Equatable, Sendable, Codable, Identifiable {
    public var id: String { "\(pid ?? -1)-\(name)" }
    public var name: String
    public var pid: Int32?
    public var metric: MetricID
    public var value: Double
    public var unitLabel: String

    public init(name: String, pid: Int32?, metric: MetricID, value: Double, unitLabel: String) {
        self.name = name
        self.pid = pid
        self.metric = metric
        self.value = value
        self.unitLabel = unitLabel
    }
}

public enum IncidentUserState: Equatable, Sendable, Codable {
    case open
    case dismissed
    case snoozed(until: Date)
}

public struct Incident: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var ruleID: String
    public var title: String
    public var summary: String
    public var severity: Severity
    /// When the condition first met its trigger (start of the observation window).
    public var startedAt: Date
    public var lastObservedAt: Date
    public var resolvedAt: Date?
    public var peakValue: Double?
    public var primaryMetric: MetricID
    public var evidence: [Evidence]
    public var contributors: [Contributor]
    public var nextStep: String
    public var userState: IncidentUserState
    public var notes: String

    public init(
        id: UUID = UUID(), ruleID: String, title: String, summary: String, severity: Severity, startedAt: Date,
        lastObservedAt: Date, resolvedAt: Date? = nil, peakValue: Double?, primaryMetric: MetricID,
        evidence: [Evidence], contributors: [Contributor], nextStep: String,
        userState: IncidentUserState = .open, notes: String = ""
    ) {
        self.id = id
        self.ruleID = ruleID
        self.title = title
        self.summary = summary
        self.severity = severity
        self.startedAt = startedAt
        self.lastObservedAt = lastObservedAt
        self.resolvedAt = resolvedAt
        self.peakValue = peakValue
        self.primaryMetric = primaryMetric
        self.evidence = evidence
        self.contributors = contributors
        self.nextStep = nextStep
        self.userState = userState
        self.notes = notes
    }

    public var isActive: Bool { resolvedAt == nil }

    public func isVisible(at date: Date) -> Bool {
        switch userState {
        case .open: return true
        case .dismissed: return false
        case let .snoozed(until): return date >= until
        }
    }

    public var duration: TimeInterval { (resolvedAt ?? lastObservedAt).timeIntervalSince(startedAt) }
}
