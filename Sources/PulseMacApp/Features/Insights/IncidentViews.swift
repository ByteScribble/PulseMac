import PulseCore
import SwiftUI

/// Compact incident summary used on Overview, the popover and Insights.
@MainActor
struct IncidentCard: View {
    @Environment(AppModel.self) private var model
    var incident: Incident
    var compact = false

    var body: some View {
        let style = StatusStyle(incident.severity)
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                StatusLabel(style: style, text: incident.title).font(.callout.weight(.semibold))
                Spacer()
                Text(timing).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(incident.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !compact, let first = incident.evidence.first { EvidenceRow(evidence: first) }
            if !compact, !incident.contributors.isEmpty {
                Text("Active at the same time: " + incident.contributors.prefix(3).map { "\($0.name) (\($0.unitLabel))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Investigate") {
                    model.investigationFocus = incident
                    model.selection = .investigate
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                if incident.isActive {
                    Menu("Snooze") {
                        Button("For 1 hour") { model.setUserState(.snoozed(until: Date().addingTimeInterval(3600)), for: incident) }
                        Button("Until tomorrow") { model.setUserState(.snoozed(until: Date().addingTimeInterval(86_400)), for: incident) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .controlSize(.small)
                }
                Button("Dismiss") { model.setUserState(.dismissed, for: incident) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(Spacing.m)
        .background(style.color.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(style.color).frame(width: 3).padding(.vertical, Spacing.s)
        }
        .accessibilityElement(children: .contain)
    }

    private var timing: String {
        let started = incident.startedAt.formatted(date: .omitted, time: .shortened)
        if incident.isActive { return "Since \(started) · \(Format.duration(incident.duration))" }
        return "\(started) · lasted \(Format.duration(incident.duration))"
    }
}

/// Full evidence breakdown, used in Investigation and Insights.
@MainActor
struct IncidentEvidenceView: View {
    var incident: Incident

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(incident.evidence.enumerated()), id: \.offset) { _, item in
                EvidenceRow(evidence: item)
            }
            if !incident.contributors.isEmpty {
                Divider()
                Text("Processes with high use during this period").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(incident.contributors) { contributor in
                    HStack {
                        Text(contributor.name)
                        Spacer()
                        Text(contributor.unitLabel).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            Divider()
            Label(incident.nextStep, systemImage: "arrow.forward.circle").font(.callout)
        }
    }
}

@MainActor
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Incident.ID?

    var body: some View {
        let incidents = model.allIncidents.sorted { $0.startedAt > $1.startedAt }
        HSplitView {
            List(incidents, selection: $selected) { incident in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    StatusLabel(style: StatusStyle(incident.severity), text: incident.title).font(.callout)
                    Text("\(incident.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Format.duration(incident.duration))\(incident.isActive ? " · ongoing" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .opacity(incident.userState == .dismissed ? 0.55 : 1)
                .tag(incident.id)
            }
            .frame(minWidth: 280, idealWidth: 320)
            .overlay {
                if incidents.isEmpty {
                    EmptyStateView(symbol: "clock.arrow.circlepath", title: "No incidents yet", message: "PulseMac records sustained CPU load, memory pressure, heavy disk writes, low disk space, thermal pressure and rapid battery drain here.")
                }
            }

            Group {
                if let incident = incidents.first(where: { $0.id == selected }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.l) {
                            IncidentCard(incident: incident, compact: true)
                            Card { IncidentEvidenceView(incident: incident) }
                        }
                        .padding(Spacing.xl)
                    }
                } else {
                    EmptyStateView(symbol: "sidebar.left", title: "Select an incident", message: "Choose an entry to see the evidence and what was running.")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Insights")
    }
}
