import AppKit
import PulseCore
import PulseMonitoring
import SwiftUI

/// Row model for the process table. Sort keys are non-optional; unreadable values sort last
/// and render as "—" (never as zero).
struct ProcessRow: Identifiable, Hashable {
    var id: String
    var name: String
    var pidText: String
    var pidSort: Int32
    var cpu: Double?
    var memory: Double?
    var diskWrite: Double?
    var threads: Int?
    var user: String
    var workload: String?
    var identity: ProcessIdentity?
    var limited: Bool
    var children: [ProcessRow]?

    var cpuSort: Double { cpu ?? -1 }
    var memorySort: Double { memory ?? -1 }
    var writeSort: Double { diskWrite ?? -1 }
    var threadSort: Int { threads ?? -1 }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(process: ProcessSample) {
        id = "\(process.pid)-\(process.identity.startTime.timeIntervalSince1970)"
        name = process.name
        pidText = String(process.pid)
        pidSort = process.pid
        cpu = process.cpuPercent
        memory = process.memoryFootprint.map(Double.init)
        diskWrite = process.diskWriteRate
        threads = process.threadCount
        user = process.userName ?? String(process.userID)
        workload = WorkloadClassifier.classify(process).map { $0.runtime ?? $0.kind.displayName }
        identity = process.identity
        limited = process.access == .limited
        children = nil
    }

    /// Single-member groups render as a plain process row.
    static func make(_ group: ProcessGroup) -> ProcessRow {
        if group.members.count == 1, let only = group.members.first {
            var row = ProcessRow(process: only)
            row.name = group.name
            return row
        }
        return ProcessRow(group: group)
    }

    private init(group: ProcessGroup) {
        id = group.id
        name = group.name
        pidText = "\(group.members.count) processes"
        pidSort = group.members.map(\.pid).min() ?? 0
        cpu = group.cpuPercent
        memory = group.memoryFootprint.map(Double.init)
        diskWrite = group.diskWriteRate
        let threadCounts = group.members.compactMap(\.threadCount)
        threads = threadCounts.isEmpty ? nil : threadCounts.reduce(0, +)
        user = Set(group.members.map { $0.userName ?? String($0.userID) }).sorted().joined(separator: ", ")
        workload = group.members.lazy.compactMap { WorkloadClassifier.classify($0) }.first.map { $0.runtime ?? $0.kind.displayName }
        identity = group.members.min { $0.pid < $1.pid }?.identity
        limited = group.members.allSatisfy { $0.access == .limited }
        children = group.members.map(ProcessRow.init(process:))
    }
}

enum ProcessFilter: String, CaseIterable, Identifiable {
    case all = "All processes", mine = "My processes", developer = "Developer workloads", apps = "Apps only"
    var id: String { rawValue }
}

@MainActor
struct ProcessExplorerView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var grouped = true
    @State private var filter: ProcessFilter = .all
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuSort, order: .reverse)]
    @State private var selection: ProcessRow.ID?
    @State private var showInspector = true
    @AppStorage("favoriteProcessNames") private var favoritesRaw = ""

    var body: some View {
        let rows = makeRows()
        VStack(spacing: 0) {
            Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: Spacing.xs) {
                        if favorites.contains(row.name) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.warning) }
                        Text(row.name).lineLimit(1)
                        if let workload = row.workload {
                            Text(workload).font(.caption2).padding(.horizontal, 4).background(Palette.accentSoft, in: Capsule()).foregroundStyle(Palette.accent)
                        }
                        if row.limited {
                            Image(systemName: "lock").font(.caption2).foregroundStyle(.tertiary)
                                .help("Resource usage of this process is only visible to administrator tools.")
                        }
                    }
                }
                .width(min: 220, ideal: 300)
                TableColumn("PID", value: \.pidSort) { Text($0.pidText).monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 90)
                TableColumn("CPU %", value: \.cpuSort) { row in
                    Text(row.cpu.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
                }
                .width(min: 60, ideal: 70)
                TableColumn("Memory", value: \.memorySort) { Text($0.memory.map(Format.bytes) ?? "—").monospacedDigit() }
                    .width(min: 70, ideal: 90)
                TableColumn("Disk writes", value: \.writeSort) { Text($0.diskWrite.map(Format.bytesPerSecond) ?? "—").monospacedDigit() }
                    .width(min: 80, ideal: 100)
                TableColumn("Threads", value: \.threadSort) { Text($0.threads.map(String.init) ?? "—").monospacedDigit() }
                    .width(min: 50, ideal: 60)
                TableColumn("User", value: \.user) { Text($0.user).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 80)
            }
            .contextMenu(forSelectionType: ProcessRow.ID.self) { ids in
                if let id = ids.first, let row = find(id, in: rows) { contextMenu(for: row) }
            } primaryAction: { ids in
                if let id = ids.first, let row = find(id, in: rows) { model.inspectedProcess = row.identity; showInspector = true }
            }
            Divider()
            footer(rows: rows)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name, PID or path")
        .toolbar {
            ToolbarItemGroup {
                Picker("Filter", selection: $filter) {
                    ForEach(ProcessFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("Filter processes")
                Toggle(isOn: $grouped) { Label("Group by app", systemImage: "square.stack.3d.up") }
                    .help("Group helper processes under their app")
                Toggle(isOn: $showInspector) { Label("Inspector", systemImage: "sidebar.right") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let identity = model.inspectedProcess {
                    ProcessInspectorView(identity: identity)
                } else {
                    EmptyStateView(symbol: "sidebar.right", title: "No process selected", message: "Select a process to see its history, details and available actions.")
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
        }
        .onChange(of: selection) {
            if let id = selection, let row = find(id, in: rows) { model.inspectedProcess = row.identity }
        }
        .navigationTitle("Processes")
    }

    private var favorites: Set<String> { Set(favoritesRaw.split(separator: "\n").map(String.init)) }

    private func toggleFavorite(_ name: String) {
        var set = favorites
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
        favoritesRaw = set.sorted().joined(separator: "\n")
    }

    private func makeRows() -> [ProcessRow] {
        var processes = model.snapshot?.processes ?? []
        let uid = getuid()
        switch filter {
        case .all: break
        case .mine: processes = processes.filter { $0.userID == uid }
        case .developer: processes = processes.filter { WorkloadClassifier.classify($0) != nil }
        case .apps: processes = processes.filter { $0.appBundlePath != nil }
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            processes = processes.filter {
                $0.name.lowercased().contains(query) || String($0.pid) == query || ($0.executablePath?.lowercased().contains(query) ?? false)
            }
        }
        var rows = grouped ? AppGrouping.group(processes).map(ProcessRow.make) : processes.map(ProcessRow.init(process:))
        rows.sort(using: sortOrder)
        for index in rows.indices { rows[index].children?.sort(using: sortOrder) }
        // Favorites float to the top, preserving sort within each partition.
        let favs = favorites
        return rows.filter { favs.contains($0.name) } + rows.filter { !favs.contains($0.name) }
    }

    private func find(_ id: ProcessRow.ID, in rows: [ProcessRow]) -> ProcessRow? {
        for row in rows {
            if row.id == id { return row }
            if let child = row.children?.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    @ViewBuilder
    private func contextMenu(for row: ProcessRow) -> some View {
        Button("Inspect") { model.inspectedProcess = row.identity; showInspector = true }
        Button(favorites.contains(row.name) ? "Remove from Favorites" : "Add to Favorites") { toggleFavorite(row.name) }
        Divider()
        if let identity = row.identity {
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(identity.pid), forType: .string)
            }
        }
        Button("Open Activity Monitor") { ActionExecutor.openActivityMonitor() }
    }

    private func footer(rows: [ProcessRow]) -> some View {
        let all = model.snapshot?.processes ?? []
        let limited = all.filter { $0.access == .limited }.count
        return HStack {
            Text("\(all.count) processes").monospacedDigit()
            if limited > 0 {
                Text("· \(limited) without resource figures (system or other users)").help(model.capability(.processCPUOtherUsers).reason ?? "")
            }
            Spacer()
            Text("CPU % is relative to one core (\(model.topology.logicalCores * 100)% = all cores).")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
    }
}
