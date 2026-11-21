import PulseCore
import SwiftUI

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettings().tabItem { Label("Data & Privacy", systemImage: "hand.raised") }
            CapabilitySettings().tabItem { Label("Capabilities", systemImage: "checklist") }
            DiagnosticsSettings().tabItem { Label("About PulseMac", systemImage: "speedometer") }
        }
        .frame(width: 620, height: 480)
    }
}

@MainActor
private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PreferenceKey.menuBarPreset) private var preset: MenuBarPreset = .balanced
    @AppStorage(PreferenceKey.showAdvanced) private var showAdvanced = false

    var body: some View {
        Form {
            Picker("Menu bar shows", selection: $preset) {
                ForEach(MenuBarPreset.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show advanced metrics", isOn: $showAdvanced)
            Toggle("Pause monitoring", isOn: Binding(get: { model.isPaused }, set: { model.setPaused($0) }))
            Section("Sampling") {
                LabeledContent("Dashboard or menu open", value: "Every 1 second")
                LabeledContent("In the background", value: "Every 5 seconds; processes every 15 seconds")
                LabeledContent("Low Power Mode", value: "Intervals doubled")
            }
            Section("Data source") {
                Picker("Source", selection: Binding(get: { model.source }, set: { model.switchSource($0) })) {
                    Text(DataSourceKind.live.label).tag(DataSourceKind.live)
                    ForEach(FixtureScenario.allCases, id: \.self) { scenario in
                        Text(DataSourceKind.fixture(scenario).label).tag(DataSourceKind.fixture(scenario))
                    }
                }
                Text("Fixture scenarios are simulated data for demos and testing. A banner is always shown while they are active, and nothing is written to your history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    @State private var databaseSize: Int64?

    var body: some View {
        Form {
            Section {
                Label("All measurements stay on this Mac. PulseMac has no account, no cloud service and no telemetry.", systemImage: "lock.shield")
                Label("Reports are created only when you ask, and you review them before saving.", systemImage: "doc.text.magnifyingglass")
                Label("PulseMac never runs administrator commands and never deletes files permanently.", systemImage: "hand.raised")
            }
            Section("History") {
                LabeledContent("Detailed samples", value: "6 hours")
                LabeledContent("Per-minute summaries", value: "7 days")
                LabeledContent("15-minute summaries", value: "90 days")
                LabeledContent("Storage used", value: databaseSize.map { Format.bytes(Double($0)) } ?? "—")
                LabeledContent("Location", value: "~/Library/Application Support/PulseMac")
                Button("Clear All History…", role: .destructive) { confirmClear = true }
            }
            Section("Permissions") {
                Text("PulseMac works without special permissions. Full Disk Access is optional and only improves folder-size scans of protected locations (Mail, Messages, other apps' data). You can grant or revoke it in System Settings › Privacy & Security › Full Disk Access.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { databaseSize = try? model.store?.sizeBytes() }
        .confirmationDialog("Clear all recorded history, incidents and action logs?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                model.clearHistory()
                databaseSize = try? model.store?.sizeBytes()
            }
        } message: {
            Text("This cannot be undone. Live monitoring continues.")
        }
    }
}

@MainActor
private struct CapabilitySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(CapabilityID.allCases, id: \.self) { id in
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                UnavailableNotice(title: id.title, status: model.capability(id))
                if let source = model.source(of: id) {
                    Text("Source: \(source)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, Spacing.xxs)
        }
    }
}

@MainActor
private struct DiagnosticsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("PulseMac's own overhead") {
                LabeledContent("CPU (last minute)", value: model.overhead.processCPUPercent.map { Format.percent($0, fractionDigits: 2) + " of one core" } ?? "Measuring…")
                LabeledContent("Average sampling time", value: String(format: "%.2f ms", model.overhead.averageTickMilliseconds))
                LabeledContent("Last sampling time", value: String(format: "%.2f ms", model.overhead.lastTickMilliseconds))
                LabeledContent("Samples taken", value: "\(model.overhead.ticks)")
            }
            Section("This Mac") {
                LabeledContent("Processor", value: model.topology.brand)
                LabeledContent("Cores", value: coresText)
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            Section {
                Text("PulseMac — know what your Mac is doing, understand why, fix what matters.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var coresText: String {
        let topology = model.topology
        if let p = topology.performanceCores, let e = topology.efficiencyCores {
            return "\(topology.logicalCores) (\(p) performance, \(e) efficiency)"
        }
        return "\(topology.logicalCores)"
    }
}
