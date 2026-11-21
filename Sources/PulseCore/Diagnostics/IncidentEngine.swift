import Foundation

/// Inputs available to a rule at evaluation time.
public struct RuleContext: Sendable {
    public var now: Date
    public var history: any MetricHistoryReading
    /// Latest process sample (may be nil when process collection is off).
    public var processes: [ProcessSample]?

    public init(now: Date, history: any MetricHistoryReading, processes: [ProcessSample]?) {
        self.now = now
        self.history = history
        self.processes = processes
    }
}

/// Result of one evaluation.
public enum RuleSignal: Equatable, Sendable {
    /// Above the trigger threshold. `value` is the reading that crossed it.
    case triggered(value: Double)
    /// Below the clear threshold.
    case clear
    /// Inside the hysteresis band: keeps an active incident open, never starts one.
    case holding
    /// Not enough data (gap, metric unavailable). Never starts or resolves an incident.
    case unknown
}

public struct IncidentContent: Sendable {
    public var title: String
    public var summary: String
    public var severity: Severity
    public var evidence: [Evidence]
    public var contributors: [Contributor]
    public var nextStep: String

    public init(
        title: String, summary: String, severity: Severity, evidence: [Evidence],
        contributors: [Contributor], nextStep: String
    ) {
        self.title = title
        self.summary = summary
        self.severity = severity
        self.evidence = evidence
        self.contributors = contributors
        self.nextStep = nextStep
    }
}

/// An explainable diagnostic rule. Every rule defines its trigger, clear condition
/// (hysteresis), minimum observation window, clear duration and cooldown.
/// See docs/architecture/architecture.md § Diagnostics.
public protocol DiagnosticRule: Sendable {
    var id: String { get }
    var primaryMetric: MetricID { get }
    /// Condition must hold continuously this long before an incident opens.
    var minimumObservation: TimeInterval { get }
    /// Condition must be clear continuously this long before an incident resolves.
    var clearDuration: TimeInterval { get }
    /// After resolving, a re-trigger within this period reopens the same incident (dedup).
    var cooldown: TimeInterval { get }

    func evaluate(_ context: RuleContext) -> RuleSignal
    func content(_ context: RuleContext, startedAt: Date, peak: Double?) -> IncidentContent
}

/// Stateful evaluator. Not thread-safe; owned by the sampling coordinator actor.
public final class IncidentEngine {
    private enum Phase {
        case idle
        case pending(since: Date)
        case active(incidentID: UUID, clearingSince: Date?)
        case cooldown(incidentID: UUID, until: Date)
    }

    public private(set) var rules: [any DiagnosticRule]
    private var phases: [String: Phase] = [:]
    private var incidents: [UUID: Incident] = [:]
    private var order: [UUID] = []
    public let maximumRetained: Int

    public init(rules: [any DiagnosticRule] = BuiltInRules.all, maximumRetained: Int = 200) {
        self.rules = rules
        self.maximumRetained = maximumRetained
    }

    /// Evaluates all rules. Returns incidents that changed during this evaluation.
    @discardableResult
    public func evaluate(_ context: RuleContext) -> [Incident] {
        var changed: [Incident] = []
        for rule in rules {
            if let incident = step(rule, context) { changed.append(incident) }
        }
        return changed
    }

    /// Call on sleep/wake or when monitoring was paused. Pending observations are discarded
    /// (the condition was not observed continuously) and clear timers restart.
    public func noteDiscontinuity() {
        for (key, phase) in phases {
            switch phase {
            case .pending: phases[key] = .idle
            case let .active(id, _): phases[key] = .active(incidentID: id, clearingSince: nil)
            default: break
            }
        }
    }

    public var allIncidents: [Incident] { order.compactMap { incidents[$0] } }
    public var activeIncidents: [Incident] { allIncidents.filter(\.isActive) }

    public func incident(_ id: UUID) -> Incident? { incidents[id] }

    public func setUserState(_ state: IncidentUserState, for id: UUID) {
        incidents[id]?.userState = state
    }

    public func setNotes(_ notes: String, for id: UUID) {
        incidents[id]?.notes = notes
    }

    /// Restores persisted incidents (e.g. at launch). Active ones are marked resolved at their
    /// last observation because the app was not running to observe them continuously.
    public func restore(_ restored: [Incident]) {
        for var incident in restored where incidents[incident.id] == nil {
            if incident.resolvedAt == nil { incident.resolvedAt = incident.lastObservedAt }
            incidents[incident.id] = incident
            order.append(incident.id)
        }
        order.sort { (incidents[$0]?.startedAt ?? .distantPast) < (incidents[$1]?.startedAt ?? .distantPast) }
        trim()
    }

    // MARK: - State machine

    private func step(_ rule: any DiagnosticRule, _ context: RuleContext) -> Incident? {
        let signal = rule.evaluate(context)
        let now = context.now
        let phase = phases[rule.id] ?? .idle

        switch phase {
        case .idle:
            guard case .triggered = signal else { return nil }
            if rule.minimumObservation <= 0 {
                return open(rule, context, since: now, signal: signal)
            }
            phases[rule.id] = .pending(since: now)
            return nil

        case let .pending(since):
            guard case .triggered = signal else {
                phases[rule.id] = .idle
                return nil
            }
            if now.timeIntervalSince(since) >= rule.minimumObservation {
                return open(rule, context, since: since, signal: signal)
            }
            return nil

        case let .active(id, clearingSince):
            switch signal {
            case let .triggered(value):
                phases[rule.id] = .active(incidentID: id, clearingSince: nil)
                return update(id, rule, context, value: value)
            case .holding, .unknown:
                phases[rule.id] = .active(incidentID: id, clearingSince: signal == .holding ? nil : clearingSince)
                return nil
            case .clear:
                let start = clearingSince ?? now
                if now.timeIntervalSince(start) >= rule.clearDuration {
                    incidents[id]?.resolvedAt = start
                    phases[rule.id] = .cooldown(incidentID: id, until: now.addingTimeInterval(rule.cooldown))
                    return incidents[id]
                }
                phases[rule.id] = .active(incidentID: id, clearingSince: start)
                return nil
            }

        case let .cooldown(id, until):
            if case let .triggered(value) = signal {
                // Dedup: reopen the recent incident instead of creating a new one.
                incidents[id]?.resolvedAt = nil
                phases[rule.id] = .active(incidentID: id, clearingSince: nil)
                return update(id, rule, context, value: value)
            }
            if now >= until { phases[rule.id] = .idle }
            return nil
        }
    }

    private func open(_ rule: any DiagnosticRule, _ context: RuleContext, since: Date, signal: RuleSignal) -> Incident {
        let peak: Double? = { if case let .triggered(value) = signal { return value } else { return nil } }()
        let content = rule.content(context, startedAt: since, peak: peak)
        let incident = Incident(
            ruleID: rule.id, title: content.title, summary: content.summary, severity: content.severity,
            startedAt: since, lastObservedAt: context.now, peakValue: peak, primaryMetric: rule.primaryMetric,
            evidence: content.evidence, contributors: content.contributors, nextStep: content.nextStep
        )
        incidents[incident.id] = incident
        order.append(incident.id)
        phases[rule.id] = .active(incidentID: incident.id, clearingSince: nil)
        trim()
        return incident
    }

    private func update(_ id: UUID, _ rule: any DiagnosticRule, _ context: RuleContext, value: Double) -> Incident? {
        guard var incident = incidents[id] else { return nil }
        let peak = max(incident.peakValue ?? value, value)
        let content = rule.content(context, startedAt: incident.startedAt, peak: peak)
        incident.peakValue = peak
        incident.lastObservedAt = context.now
        incident.title = content.title
        incident.summary = content.summary
        incident.severity = max(incident.severity, content.severity)
        incident.evidence = content.evidence
        // Keep contributors observed earlier in the incident; refresh values for those seen now.
        var merged = Dictionary(uniqueKeysWithValues: incident.contributors.map { ($0.id, $0) })
        for contributor in content.contributors {
            if let existing = merged[contributor.id], existing.value > contributor.value { continue }
            merged[contributor.id] = contributor
        }
        incident.contributors = merged.values.sorted { $0.value > $1.value }.prefix(5).map { $0 }
        incident.nextStep = content.nextStep
        incidents[id] = incident
        return incident
    }

    private func trim() {
        while order.count > maximumRetained {
            let candidate = order.firstIndex { incidents[$0]?.isActive == false } ?? 0
            incidents[order[candidate]] = nil
            order.remove(at: candidate)
        }
    }
}
