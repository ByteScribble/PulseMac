import PulseCore
import SwiftUI

/// "How is my Mac performing right now, and is anything worth investigating?"
@MainActor
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: Spacing.l, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HealthHeader()
                if !model.visibleIncidents.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        SectionHeader("Needs attention")
                        ForEach(model.visibleIncidents) { IncidentCard(incident: $0) }
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.l) {
                    CPUCard()
                    MemoryCard()
                    NetworkCard()
                    DiskCard()
                    GPUCard()
                    PowerCard()
                }
                TopConsumersSection()
                RecentActivitySection()
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 1400, alignment: .leading)
        }
        .navigationTitle("Overview")
    }
}

@MainActor
private struct HealthHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let health = model.health
        let style = StatusStyle(health.status)
        HStack(alignment: .center, spacing: Spacing.l) {
            Image(systemName: style.symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(style.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(health.headline).font(.title2.weight(.semibold))
                Text(health.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.isPaused {
                Button("Resume Monitoring") { model.setPaused(false) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.accessibilityLabel). \(health.headline). \(health.detail)")
    }
}

/// Shared card chrome: title, info, content, trend, click-through to the detail page.
@MainActor
private struct MetricCard<Content: View>: View {
    @Environment(AppModel.self) private var model
    var title: String
    var route: DetailRoute
    var info: InfoButton?
    @ViewBuilder var content: Content

    var body: some View {
        Button {
            model.detailRoute = route
        } label: {
            Card {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack {
                        Text(title.uppercased()).font(.cardTitle).foregroundStyle(.secondary).tracking(0.5)
                        Spacer()
                        info
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    content
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(title) details")
    }
}

@MainActor
private struct CPUCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cpu = model.snapshot?.cpu
        MetricCard(title: "CPU", route: .cpu, info: InfoButton(metric: .cpuTotal, source: model.source(of: .cpu), interval: "1 s while visible, 5 s in background")) {
            if let cpu {
                ReadingView(value: String(format: "%.0f", cpu.total), unit: "%", caption: "User \(Format.percent(cpu.user)) · System \(Format.percent(cpu.system))")
            } else {
                ReadingView(value: "—", unit: nil, caption: "Measuring…")
            }
            Sparkline(samples: model.series(.cpuTotal, last: 300), ceiling: 100).frame(height: 40)
            if let top = topCPU { Text("Highest: \(top)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private var topCPU: String? {
        guard let processes = model.snapshot?.processes else { return nil }
        return AppGrouping.group(processes).filter { ($0.cpuPercent ?? 0) > 5 }
            .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(2)
            .map { "\($0.name) \(Format.percent($0.cpuPercent ?? 0))" }.joined(separator: ", ").nilIfEmpty
    }
}

@MainActor
private struct MemoryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MetricCard(title: "Memory", route: .memory, info: InfoButton(metric: .memoryPressureLevel, source: model.source(of: .memory))) {
            if let memory = model.snapshot?.memory {
                let assessment = MemoryInterpreter.assess(memory, swapGrowthBytes: swapGrowth, pageOutsPerSecond: model.snapshot?.pageOutsPerSecond)
                HStack(alignment: .firstTextBaseline) {
                    ReadingView(value: memory.pressure?.label ?? "Unknown", unit: "pressure", caption: nil)
                }
                Text(assessment.headline).font(.callout)
                UsageBar(fraction: memory.usedFraction, tint: memory.pressure.map { $0 >= .warning ? Palette.warning : Palette.accent } ?? Palette.neutral)
                Text("\(Format.bytes(Double(memory.used))) of \(Format.bytes(Double(memory.physical))) used · Swap \(Format.bytes(Double(memory.swapUsed)))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                ReadingView(value: "—", unit: nil, caption: "Measuring…")
            }
        }
    }

    private var swapGrowth: Double? {
        let swap = model.series(.swapUsedBytes, last: 600)
        guard let first = swap.first, let last = swap.last else { return nil }
        return last.value - first.value
    }
}

@MainActor
private struct NetworkCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MetricCard(title: "Network", route: .network, info: InfoButton(metric: .networkReceiveRate, source: model.source(of: .network))) {
            let network = model.snapshot?.network
            HStack(spacing: Spacing.l) {
                ReadingView(value: network?.receiveRate.map(Format.bytesPerSecond) ?? "—", unit: nil, caption: "↓ Download", small: true)
                ReadingView(value: network?.sendRate.map(Format.bytesPerSecond) ?? "—", unit: nil, caption: "↑ Upload", small: true)
            }
            Sparkline(samples: model.series(.networkReceiveRate, last: 300)).frame(height: 32)
            Text(network?.primaryInterface.map { "Most active interface: \($0)" } ?? "No active interface")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct DiskCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MetricCard(title: "Disk", route: .disk, info: InfoButton(metric: .bootVolumeAvailableBytes, source: model.source(of: .volumes))) {
            if let boot = model.snapshot?.volumes?.first(where: \.isBoot) {
                ReadingView(value: Format.bytes(Double(boot.available)), unit: "available", caption: "of \(Format.bytes(Double(boot.totalBytes))) on \(boot.name)")
                UsageBar(fraction: boot.usedFraction, tint: boot.available < 15_000_000_000 ? Palette.warning : Palette.accent)
            } else {
                ReadingView(value: "—", unit: nil, caption: "Reading volumes…")
            }
            let disk = model.snapshot?.disk
            Text("Read \(disk?.readRate.map(Format.bytesPerSecond) ?? "—") · Write \(disk?.writeRate.map(Format.bytesPerSecond) ?? "—")")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

@MainActor
private struct GPUCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MetricCard(title: "GPU", route: .gpu, info: InfoButton(metric: .gpuUtilization, source: model.source(of: .gpuUtilization))) {
            let status = model.capability(.gpuUtilization)
            if status.isUsable, let gpu = model.snapshot?.gpu, let utilization = gpu.utilization {
                ReadingView(value: String(format: "%.0f", utilization), unit: "%", caption: gpu.name)
                Sparkline(samples: model.series(.gpuUtilization, last: 300), tint: Palette.series[1], ceiling: 100).frame(height: 32)
                if case .experimental = status { Text("Experimental source").font(.caption2).foregroundStyle(.secondary) }
            } else {
                UnavailableNotice(title: "GPU utilization", status: status)
            }
        }
    }
}

@MainActor
private struct PowerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MetricCard(title: "Battery & Thermal", route: .power, info: InfoButton(metric: .thermalStateLevel, source: "ProcessInfo.thermalState · IOKit power sources")) {
            if let power = model.snapshot?.power, power.hasBattery, let charge = power.chargePercent {
                ReadingView(
                    value: String(format: "%.0f", charge), unit: "%",
                    caption: power.isCharging == true ? "Charging" : (power.source == .adapter ? "On power adapter" : "On battery")
                )
            } else if model.capability(.battery) != .available {
                UnavailableNotice(title: "Battery", status: model.capability(.battery))
            }
            if let thermal = model.snapshot?.thermal {
                StatusLabel(style: thermal >= .serious ? .attention : .calm, text: "Thermal state: \(thermal.label)").font(.callout)
            }
        }
    }
}

@MainActor
private struct TopConsumersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = AppGrouping.group(model.snapshot?.processes ?? [])
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Top resource consumers", subtitle: "Apps are grouped with their helper processes.")
            HStack(alignment: .top, spacing: Spacing.l) {
                Card { consumerList(title: "CPU (% of one core)", groups.filter { $0.cpuPercent != nil }.sorted { $0.cpuPercent! > $1.cpuPercent! }) { Format.percent($0.cpuPercent ?? 0) } }
                Card { consumerList(title: "Memory", groups.filter { $0.memoryFootprint != nil }.sorted { $0.memoryFootprint! > $1.memoryFootprint! }) { Format.bytes(Double($0.memoryFootprint ?? 0)) } }
            }
        }
    }

    private func consumerList(title: String, _ groups: [ProcessGroup], value: @escaping (ProcessGroup) -> String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title.uppercased()).font(.cardTitle).foregroundStyle(.secondary)
            if groups.isEmpty {
                Text("Collecting process data…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(groups.prefix(5)) { group in
                Button {
                    model.selection = .processes
                    model.inspectedProcess = group.members.first?.identity
                } label: {
                    HStack {
                        Text(group.name).lineLimit(1)
                        if group.members.count > 1 { Text("\(group.members.count)").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text(value(group)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@MainActor
private struct RecentActivitySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recent = model.allIncidents.filter { !$0.isActive }.sorted { $0.startedAt > $1.startedAt }.prefix(5)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader("Recent activity", trailing: AnyView(Button("All insights") { model.selection = .insights }.buttonStyle(.link)))
                Card {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(Array(recent)) { incident in
                            HStack {
                                StatusLabel(style: StatusStyle(incident.severity), text: incident.title)
                                Spacer()
                                Text("\(incident.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Format.duration(incident.duration))")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
