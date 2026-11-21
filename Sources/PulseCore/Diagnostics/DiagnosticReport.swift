import Foundation

/// Local, user-reviewed diagnostic report. Generated as Markdown so it is readable without
/// PulseMac; redacted before display so what the user reviews is exactly what is exported.
public struct DiagnosticReport: Sendable {
    public var generatedAt: Date
    public var machine: String
    public var osVersion: String
    public var incident: Incident?
    public var window: DateInterval
    public var metricSummaries: [(MetricID, WindowStats)]
    public var actions: [ActionRecord]
    public var notes: String

    public init(
        generatedAt: Date, machine: String, osVersion: String, incident: Incident?, window: DateInterval,
        metricSummaries: [(MetricID, WindowStats)], actions: [ActionRecord], notes: String
    ) {
        self.generatedAt = generatedAt
        self.machine = machine
        self.osVersion = osVersion
        self.incident = incident
        self.window = window
        self.metricSummaries = metricSummaries
        self.actions = actions
        self.notes = notes
    }

    public func markdown(redactor: Redactor) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = [
            "# PulseMac diagnostic report",
            "",
            "- Generated: \(iso.string(from: generatedAt))",
            "- Mac: \(machine)",
            "- macOS: \(osVersion)",
            "- Window: \(iso.string(from: window.start)) → \(iso.string(from: window.end)) (\(Format.duration(window.duration)))",
            "",
        ]
        if let incident {
            lines += [
                "## \(incident.title)",
                "",
                incident.summary,
                "",
                "Status: \(incident.isActive ? "ongoing" : "resolved") · Started \(iso.string(from: incident.startedAt)) · Duration \(Format.duration(incident.duration))",
                "",
                "### Evidence",
                "",
            ]
            for item in incident.evidence {
                lines.append("- **\(item.kind.rawValue.capitalized):** \(item.statement)")
            }
            lines += ["", "Suggested next step: \(incident.nextStep)", ""]
        }
        if !metricSummaries.isEmpty {
            lines += ["## Measurements", "", "| Metric | Mean | Min | Max | Samples |", "|---|---:|---:|---:|---:|"]
            for (metric, stats) in metricSummaries {
                let unit = metric.unit
                lines.append(
                    "| \(metric.displayName) | \(Format.value(stats.mean, unit: unit)) | \(Format.value(stats.min, unit: unit)) | \(Format.value(stats.max, unit: unit)) | \(stats.count) |"
                )
            }
            lines.append("")
        }
        if !actions.isEmpty {
            lines += ["## Actions", ""]
            for action in actions {
                lines.append("- \(iso.string(from: action.requestedAt)) — \(action.kind.rawValue) \(action.targetDescription): \(action.phase.rawValue)\(action.message.map { " — \($0)" } ?? "")")
            }
            lines.append("")
        }
        if !notes.isEmpty { lines += ["## Notes", "", notes, ""] }
        lines.append("_Correlations are not causes. Values come from public macOS interfaces; see PulseMac's capability matrix for sources and limitations._")
        return redactor.redact(lines.joined(separator: "\n"))
    }
}
