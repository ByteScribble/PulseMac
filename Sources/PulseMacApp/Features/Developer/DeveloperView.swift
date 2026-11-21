import PulseCore
import SwiftUI

/// Developer workloads: processes grouped by recognised toolchain/runtime.
/// Optional module; the rest of the app does not depend on it.
@MainActor
struct DeveloperView: View {
    @Environment(AppModel.self) private var model

    private struct Workload: Identifiable {
        var id: String
        var kind: WorkloadKind
        var runtime: String?
        var processes: [ProcessSample]
        var cpu: Double? {
            let values = processes.compactMap(\.cpuPercent)
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        var memory: Double? {
            let values = processes.compactMap(\.memoryFootprint)
            return values.isEmpty ? nil : Double(values.reduce(0, +))
        }
    }

    var body: some View {
        let workloads = makeWorkloads()
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                SectionHeader(
                    "Developer workloads",
                    subtitle: "Processes recognised from their executable path or name. Underlying processes are always listed."
                )
                if workloads.isEmpty {
                    EmptyStateView(symbol: "hammer", title: "No developer workloads running", message: "Xcode, simulators, IDEs, Docker, JVMs, Node.js, Python, local databases and local AI runtimes appear here when they run.")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Spacing.l, alignment: .top)], spacing: Spacing.l) {
                    ForEach(workloads) { workload in
                        Card {
                            VStack(alignment: .leading, spacing: Spacing.s) {
                                HStack {
                                    Text(workload.runtime ?? workload.kind.displayName).font(.headline)
                                    Spacer()
                                    Text("\(workload.processes.count) process\(workload.processes.count == 1 ? "" : "es")").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack(spacing: Spacing.xl) {
                                    ReadingView(value: workload.cpu.map { Format.percent($0) } ?? "—", unit: nil, caption: "CPU (of one core)", small: true)
                                    ReadingView(value: workload.memory.map(Format.bytes) ?? "—", unit: nil, caption: "Memory footprint", small: true)
                                }
                                if let note = workload.kind.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                DisclosureGroup("Processes") {
                                    ForEach(workload.processes) { process in
                                        Button {
                                            model.inspectedProcess = process.identity
                                            model.selection = .processes
                                        } label: {
                                            HStack {
                                                Text(process.name).lineLimit(1)
                                                Text("\(process.pid)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                                Spacer()
                                                Text(process.memoryFootprint.map { Format.bytes(Double($0)) } ?? "—").monospacedDigit()
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Planned for this module").font(.headline)
                        UnavailableNotice(title: CapabilityID.listeningPorts.title, status: model.capability(.listeningPorts))
                        UnavailableNotice(title: "Docker containers", status: .deferred("Optional adapter that talks to the Docker socket only when Docker is installed and you enable it."))
                        UnavailableNotice(title: "Endpoint monitor", status: .deferred("Bounded checks of localhost or remote URLs you choose; response bodies are never stored."))
                    }
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 1300, alignment: .leading)
        }
        .navigationTitle("Developer")
    }

    private func makeWorkloads() -> [Workload] {
        var buckets: [String: Workload] = [:]
        for process in model.snapshot?.processes ?? [] {
            guard let match = WorkloadClassifier.classify(process), match.kind != .browser else { continue }
            let key = match.runtime.map { "\(match.kind.rawValue):\($0)" } ?? match.kind.rawValue
            buckets[key, default: Workload(id: key, kind: match.kind, runtime: match.runtime, processes: [])].processes.append(process)
        }
        return buckets.values.sorted { ($0.memory ?? 0) > ($1.memory ?? 0) }
    }
}
