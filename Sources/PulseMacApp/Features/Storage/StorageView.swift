import AppKit
import PulseCore
import PulseMonitoring
import SwiftUI

extension FolderSize {
    var childrenOrNil: [FolderSize]? { children.isEmpty ? nil : children }
}

/// Storage capacity, folder sizes and developer-cache cleanup.
/// Everything here is preview-first: nothing is removed without explicit review, items go to
/// the Trash (recoverable), and PulseMac never promises freed space it has not observed.
@MainActor
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var scanTask: Task<Void, Never>?
    @State private var scanWorker: Task<FolderSize, any Error>?
    @State private var scanned: FolderSize?
    @State private var scannedAt: Date?
    @State private var progress = 0
    @State private var scanError: String?
    @State private var plan: CleanupPlan?
    @State private var outcomes: [CleanupPlan.Outcome] = []
    @State private var confirmTrash = false

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                volumesSection
                scanSection
                if let scanned { resultsSection(scanned) }
                if let plan, !plan.items.isEmpty { cleanupSection(plan) }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 1200, alignment: .leading)
        }
        .navigationTitle("Storage")
        .onDisappear { scanWorker?.cancel() }
        .confirmationDialog("Move \(plan?.items.filter(\.selected).count ?? 0) items to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { runCleanup(dryRun: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("About \(Format.bytes(Double(plan?.selectedBytes ?? 0))) (estimated). You can restore items from the Trash. Space is freed when the Trash is emptied.")
        }
    }

    // MARK: - Sections

    private var volumesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Capacity", subtitle: "“Available” includes purgeable space macOS frees automatically, matching Finder.")
            Card {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if let volumes = model.snapshot?.volumes, !volumes.isEmpty {
                        ForEach(volumes) { volume in
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                HStack {
                                    Text(volume.name).font(.callout.weight(.medium))
                                    if let fs = volume.fileSystem { Text(fs).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text("\(Format.bytes(Double(volume.available))) available of \(Format.bytes(Double(volume.totalBytes)))").monospacedDigit()
                                }
                                UsageBar(fraction: volume.usedFraction, tint: volume.available < 15_000_000_000 ? Palette.warning : Palette.accent)
                            }
                        }
                    } else {
                        Text("Reading volumes…").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Find what uses space", subtitle: "Scanning is read-only. Folders protected by macOS are counted as unreadable unless you grant Full Disk Access.")
            HStack {
                Button("Scan Home Folder") { scan(home) }
                Button("Scan Developer Data") { scan(home.appendingPathComponent("Library/Developer")) }
                Button("Choose Folder…") { chooseFolder() }
                Spacer()
                if scanTask != nil {
                    ProgressView().controlSize(.small)
                    Text("\(progress) files").monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel") { scanWorker?.cancel() }
                }
            }
            if let scanError { Text(scanError).foregroundStyle(Palette.urgent).font(.callout) }
        }
    }

    private func resultsSection(_ tree: FolderSize) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text("\(tree.name) — \(Format.bytes(Double(tree.allocatedBytes)))").font(.headline)
                    Spacer()
                    if let scannedAt { Text("Scanned \(scannedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                }
                if tree.unreadableCount > 0 {
                    Text("\(tree.unreadableCount) items could not be read; totals are a lower bound.").font(.caption).foregroundStyle(.secondary)
                }
                List {
                    OutlineGroup(tree.children, children: \.childrenOrNil) { folder in
                        FolderRow(folder: folder, total: tree.allocatedBytes)
                    }
                }
                .frame(height: 320)
            }
        }
    }

    private func cleanupSection(_ plan: CleanupPlan) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Rebuildable developer data", subtitle: "Only recognised build outputs and caches are listed. Rebuildable items are preselected; dependencies need your explicit choice.")
            Card {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ForEach(plan.items.indices, id: \.self) { index in
                        let item = plan.items[index]
                        if let rule = DevArtifactRule.rule(item.artifactID) {
                            HStack(alignment: .top, spacing: Spacing.m) {
                                Toggle("", isOn: Binding(
                                    get: { self.plan?.items[index].selected ?? false },
                                    set: { self.plan?.items[index].selected = $0 }
                                ))
                                .labelsHidden()
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    HStack {
                                        Text(rule.title).font(.callout.weight(.medium))
                                        SafetyBadge(safety: rule.safety)
                                        Spacer()
                                        Text(Format.bytes(Double(item.estimatedBytes))).monospacedDigit()
                                    }
                                    Text(model.redactor.redact(item.path)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(rule.why + " " + rule.impact).font(.caption).fixedSize(horizontal: false, vertical: true)
                                    Text("To regenerate: \(rule.regenerate)").font(.caption).foregroundStyle(.secondary)
                                }
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                            }
                            Divider()
                        }
                    }
                    HStack {
                        Text("Selected: about \(Format.bytes(Double(plan.selectedBytes)))").monospacedDigit()
                        Spacer()
                        Button("Preview (Dry Run)") { runCleanup(dryRun: true) }
                        Button("Move Selected to Trash…") { confirmTrash = true }
                            .disabled(plan.selectedBytes == 0 || model.isFixture)
                    }
                    if !outcomes.isEmpty { OutcomeList(outcomes: outcomes) }
                }
            }
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = home
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    private func scan(_ url: URL) {
        scanWorker?.cancel()
        scanError = nil
        outcomes = []
        progress = 0
        var options = ScanOptions()
        options.detailDepth = 6
        let scanner = StorageScanner(options: options)
        let worker = Task.detached(priority: .utility) { () throws -> FolderSize in
            try scanner.scan(url) { count in Task { @MainActor in progress = count } }
        }
        scanWorker = worker
        scanTask = Task {
            do {
                let tree = try await worker.value
                scanned = tree
                scannedAt = Date()
                plan = CleanupPlan(findings: StorageScanner.artifacts(in: tree))
            } catch is CancellationError {
                scanError = "Scan cancelled."
            } catch {
                scanError = "Scan failed: \(error.localizedDescription)"
            }
            scanTask = nil
            scanWorker = nil
        }
    }

    private func runCleanup(dryRun: Bool) {
        guard let plan else { return }
        outcomes = plan.execute(dryRun: dryRun) { url in try ActionExecutor.moveToTrash(url) }
        if !dryRun {
            for outcome in outcomes {
                if case let .moved(path, _) = outcome {
                    model.recordCleanup(path: path)
                }
            }
            self.plan?.items.removeAll { item in
                outcomes.contains { if case let .moved(path, _) = $0 { return path == item.path } else { return false } }
            }
        }
    }
}

@MainActor
private struct FolderRow: View {
    var folder: FolderSize
    var total: UInt64

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: folder.artifactID != nil ? "hammer" : "folder").foregroundStyle(.secondary)
            Text(folder.name).lineLimit(1)
            if let rule = folder.artifact { SafetyBadge(safety: rule.safety) }
            Spacer()
            UsageBar(fraction: total > 0 ? Double(folder.allocatedBytes) / Double(total) : 0).frame(width: 80)
            Text(Format.bytes(Double(folder.allocatedBytes))).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)]) }
        }
    }
}

@MainActor
struct SafetyBadge: View {
    var safety: CleanupSafety

    private var text: String {
        switch safety {
        case .rebuildable: return "Rebuildable"
        case .recreatable: return "Re-downloadable"
        case .reviewOnly: return "Review only"
        }
    }

    private var color: Color {
        switch safety {
        case .rebuildable: return Palette.accent
        case .recreatable: return Palette.warning
        case .reviewOnly: return Palette.neutral
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

@MainActor
private struct OutcomeList: View {
    var outcomes: [CleanupPlan.Outcome]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Result").font(.caption.weight(.semibold))
            ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                Text(describe(outcome)).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Text("Freed space is shown by macOS after the Trash is emptied; PulseMac does not estimate it in advance.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func describe(_ outcome: CleanupPlan.Outcome) -> String {
        let name: (String) -> String = { ($0 as NSString).abbreviatingWithTildeInPath }
        switch outcome {
        case let .wouldMove(path, bytes): return "Would move \(name(path)) (about \(Format.bytes(Double(bytes))))"
        case let .moved(path, _): return "Moved to Trash: \(name(path))"
        case let .skipped(path, reason): return "Skipped \(name(path)): \(reason)"
        case let .failed(path, reason): return "Failed \(name(path)): \(reason)"
        }
    }
}
