import PulseCore
import SwiftUI

@main
struct PulseMacApp: App {
    @State private var model = AppModel()
    @AppStorage(PreferenceKey.menuBarPreset) private var preset: MenuBarPreset = .balanced

    var body: some Scene {
        WindowGroup("PulseMac", id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 780)
        .commands { PulseCommands(model: model) }

        Window("Investigation", id: "investigation") {
            InvestigationView(standalone: true)
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 720)

        MenuBarExtra {
            MenuBarPopover()
                .environment(model)
        } label: {
            MenuBarLabel(preset: preset)
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
struct PulseCommands: Commands {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(SidebarItem.allCases) { item in
                Button(item.title) {
                    model.selection = item
                    model.detailRoute = nil
                }
                .keyboardShortcut(item.shortcut, modifiers: .command)
            }
            Divider()
            Button("Open Investigation Window") { openWindow(id: "investigation") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appSettings) {
            Button(model.isPaused ? "Resume Monitoring" : "Pause Monitoring") { model.setPaused(!model.isPaused) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

/// Sidebar + content shell.
@MainActor
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PreferenceKey.onboardingDone) private var onboardingDone = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        Label(item.title, systemImage: item.symbol)
                            .badge(item == .overview ? model.visibleIncidents.count : 0)
                            .tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            VStack(spacing: 0) {
                if let title = model.fixtureTitle { FixtureBanner(scenario: title) }
                if let error = model.storeError {
                    Text(error).font(.caption).foregroundStyle(.secondary).padding(Spacing.s)
                }
                content
            }
        }
        .onAppear { model.surfaceAppeared(.dashboard) }
        .onDisappear { model.surfaceDisappeared(.dashboard) }
        .sheet(isPresented: Binding(get: { !onboardingDone }, set: { onboardingDone = !$0 })) {
            OnboardingView { onboardingDone = true }
        }
        .onChange(of: model.selection) { model.detailRoute = nil }
    }

    @ViewBuilder private var content: some View {
        switch model.selection ?? .overview {
        case .overview:
            if let route = model.detailRoute {
                MetricDetailView(route: route)
            } else {
                OverviewView()
            }
        case .processes: ProcessExplorerView()
        case .investigate: InvestigationView(standalone: false)
        case .storage: StorageView()
        case .insights: InsightsView()
        case .developer: DeveloperView()
        }
    }
}

@MainActor
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Divider().padding(.bottom, Spacing.xs)
            HStack(spacing: Spacing.xs) {
                Circle().fill(model.isPaused ? Palette.neutral : Palette.accent).frame(width: 6, height: 6)
                Text(model.isPaused ? "Monitoring paused" : "Monitoring").font(.caption)
            }
            if let cpu = model.overhead.processCPUPercent {
                Text("PulseMac uses \(Format.percent(cpu, fractionDigits: 1)) of a core").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.s)
        .accessibilityElement(children: .combine)
    }
}
