import PulseCore
import SwiftUI

enum TimeRange: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m", fifteenMinutes = "15m", hour = "1h", sixHours = "6h", day = "24h", week = "7d"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        }
    }
    /// Gap threshold for charts at this range (matches stored resolution).
    var maximumGap: TimeInterval { seconds <= 900 ? 15 : (seconds <= 6 * 3600 ? 180 : 1800) }
}

/// Consistent detail layout for every domain: header readings → explanation → charts →
/// related processes → limitations.
@MainActor
struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    var route: DetailRoute
    @State private var range: TimeRange = .fifteenMinutes
    @State private var cursor: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HStack {
                    Button { model.detailRoute = nil } label: { Label("Overview", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("[", modifiers: .command)
                    Spacer()
                    Picker("Range", selection: $range) {
                        ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .labelsHidden()
                }
                Text(route.title).font(.largeTitle.weight(.semibold))
                switch route {
                case .cpu: CPUDetail(range: range, cursor: $cursor)
                case .memory: MemoryDetail(range: range, cursor: $cursor)
                case .network: NetworkDetail(range: range, cursor: $cursor)
                case .disk: DiskDetail(range: range, cursor: $cursor)
                case .gpu: GPUDetail(range: range, cursor: $cursor)
                case .power: PowerDetail(range: range, cursor: $cursor)
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 1200, alignment: .leading)
        }
        .navigationTitle(route.title)
    }
}

/// Chart card for one metric over the selected range.
@MainActor
struct MetricChartCard: View {
    @Environment(AppModel.self) private var model
    var metric: MetricID
    var range: TimeRange
    @Binding var cursor: Date?
    var tint: Color = Palette.accent
    var height: CGFloat = 160

    var body: some View {
        let end = model.snapshot?.timestamp ?? Date()
        let interval = DateInterval(start: end.addingTimeInterval(-range.seconds), end: end)
        let samples = range.seconds <= 900 ? model.series(metric, last: range.seconds) : model.timeline(metric, in: interval)
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text(metric.displayName).font(.headline)
                    InfoButton(metric: metric)
                    Spacer()
                    if let last = samples.last {
                        Text(Format.value(last.value, unit: metric.unit)).font(.headline).monospacedDigit()
                    }
                }
                TimeSeriesChart(
                    metric: metric, samples: samples, tint: tint, cursor: $cursor,
                    annotations: model.allIncidents.filter { $0.primaryMetric == metric }, height: height,
                    maximumGap: range.maximumGap, domain: interval.start...interval.end
                )
            }
        }
    }
}

/// Grouped processes ranked by one resource.
@MainActor
struct RelatedProcesses: View {
    @Environment(AppModel.self) private var model
    var title: String
    var value: (ProcessGroup) -> Double?
    var format: (Double) -> String

    var body: some View {
        let groups = AppGrouping.group(model.snapshot?.processes ?? [])
            .compactMap { group in value(group).map { (group, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(title).font(.headline)
                if groups.isEmpty { Text("No readable process data yet.").foregroundStyle(.secondary) }
                ForEach(Array(groups), id: \.0.id) { group, reading in
                    Button {
                        model.inspectedProcess = group.members.first?.identity
                        model.selection = .processes
                    } label: {
                        HStack {
                            Text(group.name).lineLimit(1)
                            if group.members.count > 1 {
                                Text("\(group.members.count) processes").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(format(reading)).monospacedDigit()
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if model.capability(.processCPUOtherUsers) != .available {
                    UnavailableNotice(title: "System and other users' processes", status: model.capability(.processCPUOtherUsers))
                        .padding(.top, Spacing.xs)
                }
            }
        }
    }
}

@MainActor
struct ExplanationCard: View {
    var title: String
    var text: String
    var style: StatusStyle = .calm

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                StatusLabel(style: style, text: title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Domains

@MainActor
private struct CPUDetail: View {
    @Environment(AppModel.self) private var model
    var range: TimeRange
    @Binding var cursor: Date?

    var body: some View {
        let topology = model.topology
        let cpu = model.snapshot?.cpu
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(spacing: Spacing.xxl) {
                ReadingView(value: cpu.map { String(format: "%.0f", $0.total) } ?? "—", unit: "%", caption: "of total capacity")
                ReadingView(value: cpu.map { Format.percent($0.user) } ?? "—", unit: nil, caption: "User", small: true)
                ReadingView(value: cpu.map { Format.percent($0.system) } ?? "—", unit: nil, caption: "System", small: true)
                ReadingView(value: model.snapshot?.loadAverage.map { String(format: "%.2f", $0) } ?? "—", unit: nil, caption: "Load avg (1 min) vs \(topology.logicalCores) cores", small: true)
            }
            ExplanationCard(
                title: "How to read CPU numbers",
                text: "100% here means every one of the \(topology.logicalCores) cores is busy. In process lists, PulseMac uses Activity Monitor's convention: 100% is one full core, so a process can show up to \(topology.logicalCores * 100)%. Short spikes are normal; sustained load for minutes is what slows a Mac down."
            )
            MetricChartCard(metric: .cpuTotal, range: range, cursor: $cursor)
            if let perCore = cpu?.perCore, !perCore.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        HStack {
                            Text("Per core").font(.headline)
                            Spacer()
                            if let p = topology.performanceCores, let e = topology.efficiencyCores {
                                Text("\(p) performance + \(e) efficiency cores").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: min(perCore.count, 12)), spacing: Spacing.s) {
                            ForEach(Array(perCore.enumerated()), id: \.offset) { index, value in
                                VStack(spacing: Spacing.xxs) {
                                    GeometryReader { proxy in
                                        ZStack(alignment: .bottom) {
                                            RoundedRectangle(cornerRadius: 3).fill(Palette.subtleFill)
                                            RoundedRectangle(cornerRadius: 3).fill(Palette.accent).frame(height: proxy.size.height * value / 100)
                                        }
                                    }
                                    .frame(height: 48)
                                    Text("\(index)").font(.caption2).foregroundStyle(.secondary)
                                }
                                .accessibilityElement()
                                .accessibilityLabel("Core \(index)")
                                .accessibilityValue(Format.percent(value))
                            }
                        }
                        Text("Core numbering follows macOS's order. PulseMac does not label individual cores as performance or efficiency because that mapping is not documented.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            RelatedProcesses(title: "Highest CPU (% of one core)", value: \.cpuPercent, format: { Format.percent($0) })
        }
    }
}

@MainActor
private struct MemoryDetail: View {
    @Environment(AppModel.self) private var model
    var range: TimeRange
    @Binding var cursor: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if let memory = model.snapshot?.memory {
                let swap = model.series(.swapUsedBytes, last: 600)
                let growth = (swap.last?.value ?? 0) - (swap.first?.value ?? 0)
                let assessment = MemoryInterpreter.assess(memory, swapGrowthBytes: swap.count > 1 ? growth : nil, pageOutsPerSecond: model.snapshot?.pageOutsPerSecond)
                ExplanationCard(title: assessment.headline, text: assessment.detail + " High memory usage alone is not a problem; pressure and swap activity are the useful signals.", style: style(assessment.status))
                Card {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text("Where memory is").font(.headline)
                        MemoryBreakdownBar(memory: memory)
                        Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xs) {
                            row("App memory", memory.appMemory, "Memory used by apps and processes.")
                            row("Wired", memory.wired, MetricID.memoryWiredBytes.explanation)
                            row("Compressed", memory.compressed, MetricID.memoryCompressedBytes.explanation)
                            row("Cached files", memory.cachedFiles, MetricID.memoryCachedFilesBytes.explanation)
                            row("Swap used", memory.swapUsed, MetricID.swapUsedBytes.explanation)
                            row("Physical memory", memory.physical, "Installed unified memory, shared by CPU and GPU on Apple silicon.")
                        }
                    }
                }
            }
            MetricChartCard(metric: .memoryPressureLevel, range: range, cursor: $cursor, height: 90)
            MetricChartCard(metric: .swapUsedBytes, range: range, cursor: $cursor, tint: Palette.series[2], height: 120)
            MetricChartCard(metric: .memoryCompressedBytes, range: range, cursor: $cursor, tint: Palette.series[1], height: 120)
            RelatedProcesses(title: "Largest memory footprints", value: { $0.memoryFootprint.map(Double.init) }, format: Format.bytes)
        }
    }

    private func style(_ status: MemoryInterpreter.Assessment.Status) -> StatusStyle {
        switch status {
        case .healthy: return .calm
        case .watch: return .attention
        case .constrained: return .urgent
        case .unknown: return .unknown
        }
    }

    private func row(_ title: String, _ bytes: UInt64, _ help: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).font(.callout).help(help)
            Text(Format.bytes(Double(bytes))).monospacedDigit().font(.callout)
        }
    }
}

/// Stacked bar: app, wired, compressed, cached, free.
@MainActor
struct MemoryBreakdownBar: View {
    var memory: MemorySnapshot

    var body: some View {
        let total = Double(max(memory.physical, 1))
        let parts: [(String, Double, Color)] = [
            ("App", Double(memory.appMemory), Palette.accent),
            ("Wired", Double(memory.wired), Palette.series[1]),
            ("Compressed", Double(memory.compressed), Palette.series[2]),
            ("Cached", Double(memory.cachedFiles), Palette.series[3].opacity(0.6)),
        ]
        VStack(alignment: .leading, spacing: Spacing.xs) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2).frame(width: max(proxy.size.width * min(part.1 / total, 1), 0))
                    }
                    Spacer(minLength: 0)
                }
                .background(Palette.subtleFill)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            HStack(spacing: Spacing.m) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: Spacing.xxs) {
                        RoundedRectangle(cornerRadius: 2).fill(part.2).frame(width: 8, height: 8)
                        Text(part.0).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { "\($0.0) \(Format.bytes($0.1))" }.joined(separator: ", "))
    }
}

@MainActor
private struct NetworkDetail: View {
    @Environment(AppModel.self) private var model
    var range: TimeRange
    @Binding var cursor: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ExplanationCard(
                title: "This is traffic, not internet speed",
                text: "PulseMac measures bytes moving through your network interfaces. Low numbers can simply mean nothing is downloading. Per-app traffic is not available through public macOS APIs."
            )
            MetricChartCard(metric: .networkReceiveRate, range: range, cursor: $cursor)
            MetricChartCard(metric: .networkSendRate, range: range, cursor: $cursor, tint: Palette.series[1])
            if let interfaces = model.snapshot?.network?.interfaces {
                Card {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Interfaces").font(.headline)
                        Table(interfaces.filter { $0.kind != .loopback }) {
                            TableColumn("Name", value: \.name)
                            TableColumn("Kind") { Text(kindLabel($0.kind)) }
                            TableColumn("State") { Text($0.isUp ? "Up" : "Down") }
                            TableColumn("Download") { Text($0.receiveRate.map(Format.bytesPerSecond) ?? "—").monospacedDigit() }
                            TableColumn("Upload") { Text($0.sendRate.map(Format.bytesPerSecond) ?? "—").monospacedDigit() }
                            TableColumn("Total received") { Text(Format.bytes(Double($0.totalReceived))).monospacedDigit() }
                        }
                        .frame(height: 200)
                        Text("VPN tunnels and peer-to-peer links (AirDrop) are listed but excluded from totals to avoid counting traffic twice.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            UnavailableNotice(title: CapabilityID.perProcessNetwork.title, status: model.capability(.perProcessNetwork))
        }
    }

    private func kindLabel(_ kind: NetworkInterfaceReading.Kind) -> String {
        switch kind {
        case .wifiOrEthernet: return "Wi-Fi / Ethernet"
        case .cellular: return "Cellular"
        case .loopback: return "Loopback"
        case .virtual: return "Virtual / VPN"
        case .other: return "Other"
        }
    }
}

@MainActor
private struct DiskDetail: View {
    @Environment(AppModel.self) private var model
    var range: TimeRange
    @Binding var cursor: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if let volumes = model.snapshot?.volumes {
                Card {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text("Volumes").font(.headline)
                        ForEach(volumes) { volume in
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                HStack {
                                    Text(volume.name).font(.callout.weight(.medium))
                                    if volume.isBoot { Text("Startup disk").font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text("\(Format.bytes(Double(volume.available))) available of \(Format.bytes(Double(volume.totalBytes)))")
                                        .font(.callout).monospacedDigit()
                                }
                                UsageBar(fraction: volume.usedFraction)
                            }
                        }
                        Text("“Available” includes purgeable space (caches, local snapshots) that macOS frees automatically when needed, matching Finder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            MetricChartCard(metric: .diskWriteRate, range: range, cursor: $cursor)
            MetricChartCard(metric: .diskReadRate, range: range, cursor: $cursor, tint: Palette.series[1])
            RelatedProcesses(title: "Highest disk writes (your processes)", value: \.diskWriteRate, format: Format.bytesPerSecond)
            Button("Find large folders and rebuildable caches…") { model.selection = .storage }
        }
    }
}

@MainActor
private struct GPUDetail: View {
    @Environment(AppModel.self) private var model
    var range: TimeRange
    @Binding var cursor: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ExplanationCard(
                title: "Unified memory",
                text: "On Apple silicon the GPU shares the Mac's memory with the CPU; there is no separate video memory to measure. GPU memory use is part of the memory figures on the Memory page."
            )
            if model.capability(.gpuUtilization).isUsable {
                MetricChartCard(metric: .gpuUtilization, range: range, cursor: $cursor, tint: Palette.series[1])
            }
            Card {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    UnavailableNotice(title: CapabilityID.gpuUtilization.title, status: model.capability(.gpuUtilization))
                    UnavailableNotice(title: CapabilityID.perProcessGPU.title, status: model.capability(.perProcessGPU))
                    UnavailableNotice(title: CapabilityID.neuralEngine.title, status: model.capability(.neuralEngine))
                }
            }
        }
    }
}

@MainActor
private struct PowerDetail: View {
    @Environment(AppModel.self) private var model
    var range: TimeRange
    @Binding var cursor: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if let power = model.snapshot?.power, power.hasBattery {
                Card {
                    Grid(alignment: .leading, horizontalSpacing: Spacing.xxl, verticalSpacing: Spacing.s) {
                        GridRow { Text("Charge").foregroundStyle(.secondary); Text(power.chargePercent.map { Format.percent($0) } ?? "—") }
                        GridRow { Text("Power source").foregroundStyle(.secondary); Text(power.source == .adapter ? "Power adapter" : (power.source == .battery ? "Battery" : "Unknown")) }
                        GridRow { Text("Charging").foregroundStyle(.secondary); Text(power.isCharging.map { $0 ? "Yes" : "No" } ?? "—") }
                        GridRow { Text("Time remaining").foregroundStyle(.secondary); Text(power.minutesRemaining.map { Format.duration(Double($0) * 60) } ?? "Not estimated").help("Shown only when macOS provides an estimate; it changes quickly with workload.") }
                        GridRow { Text("Cycle count").foregroundStyle(.secondary); Text(power.cycleCount.map(String.init) ?? "—") }
                        GridRow { Text("Capacity vs. new").foregroundStyle(.secondary); Text(power.healthFraction.map { Format.percent($0 * 100) } ?? "Not reported") }
                        GridRow { Text("Condition").foregroundStyle(.secondary); Text(power.condition ?? "—") }
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
                MetricChartCard(metric: .batteryChargePercent, range: range, cursor: $cursor, tint: Palette.series[3])
                ExplanationCard(
                    title: "About battery attribution",
                    text: "macOS does not let other apps measure exact energy use per app. To investigate drain, PulseMac shows the measured discharge rate alongside CPU activity recorded at the same time."
                )
            } else {
                UnavailableNotice(title: "Battery", status: model.capability(.battery))
            }
            if let thermal = model.snapshot?.thermal {
                ExplanationCard(title: "Thermal state: \(thermal.label)", text: thermal.explanation + " Temperature is how hot a component is; thermal state is whether macOS is limiting performance because of it.", style: thermal >= .serious ? .attention : .calm)
            }
            MetricChartCard(metric: .thermalStateLevel, range: range, cursor: $cursor, tint: Palette.warning, height: 90)
            UnavailableNotice(title: CapabilityID.temperatureSensors.title, status: model.capability(.temperatureSensors))
            UnavailableNotice(title: CapabilityID.fans.title, status: model.capability(.fans))
        }
    }
}
