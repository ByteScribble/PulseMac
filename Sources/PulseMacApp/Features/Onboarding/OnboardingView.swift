import SwiftUI

/// First-run sheet: what PulseMac does, what it does not do, and that no permission is needed.
@MainActor
struct OnboardingView: View {
    var onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Welcome to PulseMac").font(.largeTitle.weight(.semibold))
            Text("Know what your Mac is doing. Understand why. Fix what matters.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.m) {
                point("waveform.path.ecg", "Watches quietly", "Lives in the menu bar and samples every few seconds in the background, more often when you're looking.")
                point("text.magnifyingglass", "Explains, with evidence", "When something is wrong, PulseMac tells you what it measured, what was happening at the same time, and what it couldn't see.")
                point("hand.raised", "Safe by default", "Actions always ask first. Nothing is deleted permanently. No administrator access is used.")
                point("lock.shield", "Private", "Everything stays on this Mac. No account, no cloud, no telemetry.")
            }
            Text("No permissions are needed to start. Folder scans of protected locations can optionally use Full Disk Access later.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Get Started", action: onFinish).keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(Spacing.xxl)
        .frame(width: 560)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Palette.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
