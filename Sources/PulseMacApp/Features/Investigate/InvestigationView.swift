import AppKit
import PulseCore
import PulsePersistence
import SwiftUI
import UniformTypeIdentifiers

/// Focused workspace for performance incidents: linked timelines, what was running,
/// evidence, notes, before/after comparison and a reviewable local report.
@MainActor
struct InvestigationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var standalone: Bool

    @State private var range: TimeRange = .hour
    @State private var cursor: Date?
    @State private var comparePoint: Date?
    @State private var notes = ""
    @State private var reportText: String?
    @State private var focusID: Incident.ID?

    private var focus: Incident? { model.allIncidents.first { $0.id == focusID } }

    private var interval: DateInterval {
        let now = model.snapshot?.timestamp ?? Date()
        if let focus {
            let start = focus.startedAt.addingTimeInterval(-600)
            let end = min((focus.resolvedAt ?? now).addingTimeInterval(600), now)
            return DateInterval(start: start, end: max(end, start.addingTimeInterval(60)))
        }
        return DateInterval(start: now.addingTimeInterval(-range.seconds), end: now)
    }

    private var metrics: [MetricID] {
        var list: [MetricID] = [.cpuTotal, .memoryPressureLevel, .swapUsedBytes, .diskWriteRate, .networkReceiveRate]
        if model.capability(.gpuUtilization).isUsable { list.append(.gpuUtilization) }
        if model.snapshot?.power?.hasBattery == true { list.append(.batteryChargePercent) }
        list.append(.thermalStateLevel)
        return list
    }

    var body: some View {
        HSplitView {
            incidentList.frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    toolbar
                    if let focus { focusHeader(focus) }
                    timelines
                    if let comparePoint { BeforeAfterView(point: comparePoint, metrics: metrics) }
                    WhatWasRunning(interval: interval)
                    notesSection
                }
                .padding(Spacing.xl)
            }
            .frame(minWidth: 560, maxWidth: .infinity)
        }
        .navigationTitle(standalone ? "Investigation" : "Investigate")
        .onAppear {
            model.surfaceAppeared(.investigation)
            if let incoming = model.investigationFocus {
                focusID = incoming.id
                notes = incoming.notes
                model.investigationFocus = nil
            }
        }
        .onDisappear { model.surfaceDisappeared(.investigation) }
        .onChange(of: model.investigationFocus) {
            if let incoming = model.investigationFocus {
                focusID = incoming.id
                notes = incoming.notes
                model.investigationFocus = nil
            }
        }
        .sheet(isPresented: Binding(get: { reportText != nil }, set: { if !$0 { reportText = nil } })) {
            ReportSheet(text: reportText ?? "")
        }
    }

    // MARK: - Sections

    private var incidentList: some View {
        let incidents = model.allIncidents.sorted { $0.startedAt > $1.startedAt }
        return List(selection: $focusID) {
            Section("Incidents") {
                if incidents.isEmpty {
                    Text("None recorded. You can still explore any time range.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(incidents) { incident in
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLabel(style: StatusStyle(incident.severity), text: incident.title).font(.callout).lineLimit(2)
                        Text(incident.startedAt.formatted(date: .abbreviated, time: .shortened) + (incident.isActive ? " · ongoing" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(incident.id)
                }
            }
        }
        .onChange(of: focusID) { notes = focus?.notes ?? "" }
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.m) {
            if focus != nil {
                Button { focusID = nil } label: { Label("All activity", systemImage: "xmark.circle") }
                    .buttonStyle(.borderless)
            } else {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases.filter { $0 != .fiveMinutes }) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            Text("\(interval.start.formatted(date: .abbreviated, time: .shortened)) – \(interval.end.formatted(date: .omitted, time: .shortened))")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button {
                comparePoint = cursor ?? comparePoint
            } label: { Label("Compare before/after", systemImage: "arrow.left.and.right") }
                .disabled(cursor == nil)
                .help("Hover a chart to pick a moment, then compare the 5 minutes before and after it.")
            Button {
                reportText = model.report(for: focus, interval: interval, notes: notes)
            } label: { Label("Report…", systemImage: "doc.text") }
            if !standalone {
                Button { openWindow(id: "investigation") } label: { Label("Open in Window", systemImage: "macwindow.on.rectangle") }
                    .help("Open a separate investigation window for side-by-side comparison")
            }
        }
    }

    private func focusHeader(_ incident: Incident) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                IncidentCard(incident: incident, compact: true)
                IncidentEvidenceView(incident: incident)
            }
        }
    }

    private var timelines: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text("Timeline").font(.headline)
                    Spacer()
                    if let cursor {
                        Text(cursor.formatted(date: .omitted, time: .standard)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(metrics.enumerated()), id: \.element) { index, metric in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(spacing: Spacing.xs) {
                            Text(metric.displayName).font(.caption.weight(.semibold))
                            InfoButton(metric: metric)
                        }
                        TimeSeriesChart(
                            metric: metric, samples: model.timeline(metric, in: interval),
                            tint: Palette.series[index % Palette.series.count], cursor: $cursor,
                            annotations: model.allIncidents.filter { $0.primaryMetric == metric },
                            height: metric.unit == .level ? 56 : 90,
                            maximumGap: interval.duration <= 900 ? 15 : (interval.duration <= 6 * 3600 ? 180 : 1800),
                            domain: interval.start...interval.end
                        )
                    }
                }
                Text("Hover any chart to move a shared cursor across all of them. Shaded areas are recorded incidents. Gaps mean PulseMac was not running or the Mac was asleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notesSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Notes").font(.headline)
                TextEditor(text: $notes)
                    .font(.callout)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .background(Palette.subtleFill.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.small))
                HStack {
                    if let focus {
                        Button("Save Notes to Incident") { model.setNotes(notes, for: focus) }
                    }
                    Text("Notes stay on this Mac and are included in reports you export.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// "What was running?" for an interval: recorded per-minute process summaries.
@MainActor
private struct WhatWasRunning: View {
    @Environment(AppModel.self) private var model
    var interval: DateInterval
    @State private var ranking: HistoryStore.ProcessRanking = .cpu

    var body: some View {
        let groups = model.topProcessGroups(in: interval, by: ranking)
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text("What was running").font(.headline)
                    Spacer()
                    Picker("Rank by", selection: $ranking) {
                        Text("CPU").tag(HistoryStore.ProcessRanking.cpu)
                        Text("Memory").tag(HistoryStore.ProcessRanking.memory)
                        Text("Disk writes").tag(HistoryStore.ProcessRanking.diskWrite)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .labelsHidden()
                }
                if groups.isEmpty {
                    Text(model.isFixture
                         ? "Process history is not recorded in fixture mode."
                         : "No process summaries recorded for this period yet. PulseMac stores one summary per minute while it runs.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xs) {
                        GridRow {
                            Text("App or process"); Text("Avg CPU"); Text("Peak CPU"); Text("Peak memory"); Text("Avg writes")
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(groups, id: \.groupKey) { group in
                            GridRow {
                                Text(group.name).lineLimit(1)
                                Text(group.cpuMean.map { Format.percent($0) } ?? "—")
                                Text(group.cpuMax.map { Format.percent($0) } ?? "—")
                                Text(group.memoryMax.map(Format.bytes) ?? "—")
                                Text(group.diskWriteMean.map(Format.bytesPerSecond) ?? "—")
                            }
                            .font(.callout).monospacedDigit()
                        }
                    }
                    Text("These apps were busy during the selected period. Being busy at the same time does not prove they caused a slowdown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Compares 5 minutes before and after a chosen moment for each metric.
@MainActor
private struct BeforeAfterView: View {
    @Environment(AppModel.self) private var model
    var point: Date

    var metrics: [MetricID]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Before / after \(point.formatted(date: .omitted, time: .standard))").font(.headline)
                ForEach(metrics, id: \.self) { metric in
                    let before = model.timeline(metric, in: DateInterval(start: point.addingTimeInterval(-300), end: point))
                    let after = model.timeline(metric, in: DateInterval(start: point.addingTimeInterval(15), end: point.addingTimeInterval(315)))
                    let verdict = EffectVerifier.compare(baseline: before, after: after, lowerIsBetter: metric != .batteryChargePercent)
                    HStack(alignment: .top) {
                        Text(metric.displayName).frame(width: 140, alignment: .leading)
                        Text(EffectVerifier.describe(verdict, metric: metric)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// Shows exactly what will be exported (already redacted) before saving.
@MainActor
struct ReportSheet: View {
    var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Diagnostic report").font(.title3.weight(.semibold))
            Text("Review before sharing. Your home folder, user name, computer name, IP addresses and secret-looking values have been replaced.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Spacing.s)
            .background(Palette.subtleFill.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.small))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save…") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 640, height: 560)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PulseMac Report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            dismiss()
        }
    }
}
