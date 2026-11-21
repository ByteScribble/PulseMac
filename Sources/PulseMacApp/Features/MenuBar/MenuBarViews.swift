import AppKit
import PulseCore
import SwiftUI

/// Compact menu bar label. Kept short for notched displays: at most three readings.
@MainActor
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    var preset: MenuBarPreset

    var body: some View {
        let style = StatusStyle(model.health.status)
        let cpu = model.snapshot?.cpu.map { String(format: "%.0f%%", $0.total) } ?? "–"
        let icon = Image(systemName: model.visibleIncidents.isEmpty ? "waveform.path.ecg" : style.symbol)
        // MenuBarExtra labels reliably render a single Text (images interpolated inline).
        Text("\(icon) \(readings(cpu: cpu))")
            .monospacedDigit()
        .accessibilityLabel("PulseMac: \(model.health.headline)")
    }

    private func readings(cpu: String) -> String {
        switch preset {
        case .minimal: return cpu
        case .balanced: return "\(cpu) \(memoryText) \(networkText)"
        case .developer: return "\(cpu) \(memoryText) W\(diskText)"
        }
    }

    private var memoryText: String {
        guard let pressure = model.snapshot?.memory?.pressure else { return "M–" }
        switch pressure {
        case .normal: return "M●"
        case .warning: return "M▲"
        case .critical: return "M■"
        }
    }

    private var networkText: String {
        guard let rx = model.snapshot?.network?.receiveRate else { return "↓–" }
        return "↓" + compact(rx)
    }

    private var diskText: String {
        guard let write = model.snapshot?.disk?.writeRate else { return "–" }
        return compact(write)
    }

    /// 3–4 character rate: "12K", "3.4M", "120M".
    private func compact(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1000: return "0K"
        case ..<1_000_000: return "\(Int(bytesPerSecond / 1000))K"
        case ..<10_000_000: return String(format: "%.1fM", bytesPerSecond / 1_000_000)
        case ..<1_000_000_000: return "\(Int(bytesPerSecond / 1_000_000))M"
        default: return String(format: "%.1fG", bytesPerSecond / 1_000_000_000)
        }
    }
}

/// Popover: useful on its own without opening the dashboard.
@MainActor
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let health = model.health
        let style = StatusStyle(health.status)
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let title = model.fixtureTitle {
                Text("FIXTURE DATA — \(title)").font(.caption2.weight(.bold)).foregroundStyle(Palette.warning)
            }
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: style.symbol).foregroundStyle(style.color).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(health.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(health.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            Grid(horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
                trendRow("CPU", value: model.snapshot?.cpu.map { Format.percent($0.total) } ?? "—", metric: .cpuTotal, ceiling: 100)
                trendRow("Memory", value: model.snapshot?.memory?.pressure?.label ?? "—", metric: .memoryUsedBytes, ceiling: model.snapshot?.memory.map { Double($0.physical) })
                trendRow("Network ↓", value: model.snapshot?.network?.receiveRate.map(Format.bytesPerSecond) ?? "—", metric: .networkReceiveRate, ceiling: nil)
            }

            if let incident = model.visibleIncidents.first {
                Divider()
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    StatusLabel(style: StatusStyle(incident.severity), text: incident.title).font(.callout.weight(.medium))
                    Text(incident.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Button("Investigate") {
                        model.investigationFocus = incident
                        model.selection = .investigate
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .controlSize(.small)
                }
            }

            Divider()
            Text("TOP APPS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(topGroups) { group in
                HStack {
                    Text(group.name).lineLimit(1)
                    Spacer()
                    Text(group.cpuPercent.map { Format.percent($0) } ?? "—").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    Text(group.memoryFootprint.map { Format.bytes(Double($0)) } ?? "—").monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                }
                .font(.callout)
            }

            Divider()
            HStack {
                Button("Open Dashboard") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("d")
                Spacer()
                Menu {
                    Button("Settings…") { openSettings() }
                    Button(model.isPaused ? "Resume Monitoring" : "Pause Monitoring") { model.setPaused(!model.isPaused) }
                    Divider()
                    Button("Quit PulseMac") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(Spacing.l)
        .frame(width: 340)
        .onAppear { model.surfaceAppeared(.popover) }
        .onDisappear { model.surfaceDisappeared(.popover) }
    }

    private var topGroups: [ProcessGroup] {
        Array(AppGrouping.group(model.snapshot?.processes ?? [])
            .filter { $0.cpuPercent != nil }
            .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
            .prefix(5))
    }

    private func trendRow(_ title: String, value: String, metric: MetricID, ceiling: Double?) -> some View {
        GridRow {
            Text(title).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Sparkline(samples: model.series(metric, last: 120), ceiling: ceiling).frame(width: 120, height: 22)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }
}
