import AppKit
import PulseCore
import PulseMonitoring
import SwiftUI

@MainActor
struct ProcessInspectorView: View {
    @Environment(AppModel.self) private var model
    var identity: ProcessIdentity
    @State private var pendingAction: RemediationKind?
    @State private var resultMessage: String?
    @State private var showArguments = false
    @State private var cursor: Date?

    var body: some View {
        if let process = model.process(identity) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header(process)
                    readings(process)
                    history(process)
                    details(process)
                    actions(process)
                }
                .padding(Spacing.l)
            }
            .confirmationDialog(
                confirmationTitle(process), isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                presenting: pendingAction
            ) { kind in
                Button(buttonTitle(kind), role: kind == .forceQuit ? .destructive : nil) {
                    resultMessage = model.perform(kind, on: process, incident: model.visibleIncidents.first)
                }
                Button("Cancel", role: .cancel) {}
            } message: { kind in
                if case let .allowed(_, warning) = decision(kind, process) {
                    Text(warning ?? "\(process.name) will be asked to exit. PulseMac will compare measurements before and after.")
                }
            }
        } else {
            EmptyStateView(symbol: "xmark.circle", title: "Process has exited", message: "It is no longer running. Its activity is still included in recorded history summaries.")
        }
    }

    private func header(_ process: ProcessSample) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                if let bundle = process.appBundlePath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: bundle)).resizable().frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading) {
                    Text(process.name).font(.title3.weight(.semibold)).lineLimit(2)
                    Text("PID \(process.pid) · \(process.userName ?? "uid \(process.userID)")").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let match = WorkloadClassifier.classify(process) {
                Text(match.runtime ?? match.kind.displayName).font(.caption.weight(.medium)).foregroundStyle(Palette.accent)
                if let note = match.kind.note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if process.access == .limited {
                UnavailableNotice(title: "Resource usage", status: model.capability(.processCPUOtherUsers))
            }
        }
    }

    private func readings(_ process: ProcessSample) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xs) {
            GridRow {
                ReadingView(value: process.cpuPercent.map { String(format: "%.1f", $0) } ?? "—", unit: "% CPU", caption: "of one core", small: true)
                ReadingView(value: process.memoryFootprint.map { Format.bytes(Double($0)) } ?? "—", unit: nil, caption: "Memory footprint", small: true)
            }
            GridRow {
                ReadingView(value: process.diskWriteRate.map(Format.bytesPerSecond) ?? "—", unit: nil, caption: "Disk writes", small: true)
                ReadingView(value: process.threadCount.map(String.init) ?? "—", unit: nil, caption: "Threads", small: true)
            }
        }
    }

    @ViewBuilder
    private func history(_ process: ProcessSample) -> some View {
        let memory = model.processMemoryHistory(identity)
        let cpu = model.processCPUHistory(identity)
        if !memory.isEmpty || !cpu.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Since PulseMac started observing").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("CPU (% of one core)").font(.caption)
                TimeSeriesChart(
                    metric: .cpuTotal, samples: cpu, cursor: $cursor, height: 80,
                    yMaximum: max(100, (cpu.map(\.value).max() ?? 0) * 1.1)
                )
                Text("Memory footprint").font(.caption)
                TimeSeriesChart(metric: .memoryUsedBytes, samples: memory, tint: Palette.series[1], cursor: $cursor, height: 80)
                let growth = MemoryGrowthAnalyzer.assess(memory)
                Label(growth.explanation, systemImage: growth.isSuspicious ? "chart.line.uptrend.xyaxis" : "chart.line.flattrend.xyaxis")
                    .font(.caption)
                    .foregroundStyle(growth.isSuspicious ? Palette.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func details(_ process: ProcessSample) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Details").font(.headline)
            KeyValueRow(key: "Started", value: process.identity.startTime.formatted(date: .abbreviated, time: .standard))
            KeyValueRow(key: "Running for", value: Format.duration(Date().timeIntervalSince(process.identity.startTime)))
            KeyValueRow(key: "Parent PID", value: String(process.parentPID))
            if let parent = model.snapshot?.processes?.first(where: { $0.pid == process.parentPID }) {
                KeyValueRow(key: "Parent", value: parent.name)
            }
            if let path = process.executablePath {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            }
            if process.access == .full {
                DisclosureGroup("Command line", isExpanded: $showArguments) {
                    if let arguments = ProcessDetails.arguments(pid: process.pid) {
                        Text(model.redactor.redact(arguments.joined(separator: " ")))
                            .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("Secrets that look like tokens or passwords are hidden.").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Not available for this process.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func actions(_ process: ProcessSample) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Actions").font(.headline)
            HStack {
                if process.appBundlePath != nil { actionButton(.quitApp, process) }
                actionButton(.terminateProcess, process)
                actionButton(.forceQuit, process)
            }
            HStack {
                actionButton(.revealInFinder, process)
                Button("Copy Details") { copyDiagnostics(process) }
                Button("Activity Monitor") { ActionExecutor.openActivityMonitor() }
            }
            .controlSize(.small)
            if let reason = deniedReason(process) {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let resultMessage { Text(resultMessage).font(.caption).fixedSize(horizontal: false, vertical: true) }
            ForEach(model.actionLog.filter { $0.targetDescription == process.name }.suffix(3)) { record in
                ActionStatusRow(record: record)
            }
        }
    }

    private func actionButton(_ kind: RemediationKind, _ process: ProcessSample) -> some View {
        let allowed = decision(kind, process).isAllowed
        return Button(buttonTitle(kind)) {
            if kind.isDestructive {
                pendingAction = kind
            } else {
                resultMessage = model.perform(kind, on: process, incident: nil)
            }
        }
        .disabled(!allowed)
        .help(allowed ? "" : (deniedText(decision(kind, process)) ?? ""))
    }

    private func decision(_ kind: RemediationKind, _ process: ProcessSample) -> ProcessActionPolicy.Decision {
        ProcessActionPolicy.decide(kind, process: process, currentUserID: getuid(), ownPID: getpid())
    }

    private func deniedText(_ decision: ProcessActionPolicy.Decision) -> String? {
        if case let .denied(reason) = decision { return reason }
        return nil
    }

    private func deniedReason(_ process: ProcessSample) -> String? {
        deniedText(decision(.terminateProcess, process))
    }

    private func buttonTitle(_ kind: RemediationKind) -> String {
        switch kind {
        case .quitApp: return "Quit App"
        case .terminateProcess: return "End Process"
        case .forceQuit: return "Force Quit"
        case .revealInFinder: return "Show in Finder"
        case .openActivityMonitor: return "Activity Monitor"
        case .moveToTrash: return "Move to Trash"
        }
    }

    private func confirmationTitle(_ process: ProcessSample) -> String {
        "\(buttonTitle(pendingAction ?? .terminateProcess)) “\(process.name)”?"
    }

    private func copyDiagnostics(_ process: ProcessSample) {
        let text = """
        \(process.name) (PID \(process.pid))
        Path: \(process.executablePath ?? "unavailable")
        Started: \(process.identity.startTime.formatted(.iso8601))
        CPU: \(process.cpuPercent.map { String(format: "%.1f%% of one core", $0) } ?? "unavailable")
        Memory footprint: \(process.memoryFootprint.map { Format.bytes(Double($0)) } ?? "unavailable")
        Threads: \(process.threadCount.map(String.init) ?? "unavailable")
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.redactor.redact(text), forType: .string)
        resultMessage = "Copied (personal paths redacted)."
    }
}

/// Shows an action's lifecycle and, once enough data exists, its measured effect.
@MainActor
struct ActionStatusRow: View {
    @Environment(AppModel.self) private var model
    var record: ActionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(record.kind.rawValue).font(.caption.weight(.semibold))
                Text(phaseLabel).font(.caption).foregroundStyle(record.phase == .failed ? Palette.urgent : .secondary)
                Spacer()
                Text(record.requestedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            if let metric = record.verificationMetric, let verdict = model.verification(for: record) {
                let style: StatusStyle = {
                    if case .improved = verdict { return .verified }
                    return .unknown
                }()
                StatusLabel(style: style, text: EffectVerifier.describe(verdict, metric: metric)).font(.caption)
            } else if record.phase == .attempted {
                Text("Effect not yet verified.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var phaseLabel: String {
        switch record.phase {
        case .suggested: return "Suggested"
        case .requested: return "Requested"
        case .attempted: return "Request sent"
        case .succeeded: return "Done"
        case .failed: return "Failed — \(record.message ?? "")"
        case .effectUnverified: return "Effect not yet verified"
        case .effectVerified: return "Effect measured"
        case .effectNotObserved: return "No measurable effect"
        }
    }
}
