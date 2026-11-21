import PulseCore
import SwiftUI

/// Standard surface for grouped content.
@MainActor
struct Card<Content: View>: View {
    var padding: CGFloat = Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.separator.opacity(0.6)))
    }
}

@MainActor
struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var trailing: AnyView?

    init(_ title: String, subtitle: String? = nil, trailing: AnyView? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

/// Icon + colour + text, so status never relies on colour alone.
@MainActor
struct StatusLabel: View {
    var style: StatusStyle
    var text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: style.symbol).foregroundStyle(style.color)
        }
        .accessibilityLabel("\(style.accessibilityLabel): \(text)")
    }
}

/// Small "i" button that explains a metric: meaning, source and sampling.
@MainActor
struct InfoButton: View {
    var title: String
    var explanation: String
    var source: String?
    var interval: String?
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(explanation)
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(title).font(.headline)
                Text(explanation).fixedSize(horizontal: false, vertical: true)
                if source != nil || interval != nil { Divider() }
                if let source { LabeledContent("Source", value: source).font(.caption) }
                if let interval { LabeledContent("Sampling", value: interval).font(.caption) }
            }
            .padding(Spacing.l)
            .frame(width: 320)
        }
    }
}

extension InfoButton {
    init(metric: MetricID, source: String? = nil, interval: String? = nil) {
        self.init(title: metric.displayName, explanation: metric.explanation, source: source, interval: interval)
    }
}

/// Honest rendering of a capability that is not usable (acceptance G): never a zero.
@MainActor
struct UnavailableNotice: View {
    var title: String
    var status: CapabilityStatus

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("\(title) · \(status.shortLabel)").font(.callout.weight(.medium))
                if let reason = status.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch status {
        case .needsPermission: return "lock"
        case .unsupported: return "nosign"
        case .deferred: return "clock"
        case .failed: return "exclamationmark.circle"
        case .experimental: return "flask"
        case .available: return "checkmark"
        }
    }
}

/// Persistent banner shown whenever synthetic data is displayed.
@MainActor
struct FixtureBanner: View {
    var scenario: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "testtube.2")
            Text("FIXTURE DATA — \(scenario). These numbers are simulated, not measured from this Mac.")
                .font(.caption.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .foregroundStyle(Palette.warning)
        .background(Palette.warning.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

/// Primary reading with unit and caption, using monospaced digits.
@MainActor
struct ReadingView: View {
    var value: String
    var unit: String?
    var caption: String?
    var small = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(value).font(small ? .metricValueSmall : .metricValue).contentTransition(.numericText())
                if let unit { Text(unit).font(.metricUnit).foregroundStyle(.secondary) }
            }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct KeyValueRow: View {
    var key: String
    var value: String
    var help: String?

    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
        .font(.callout)
        .help(help ?? "")
    }
}

/// Labels evidence by strength so facts, correlations and hypotheses are distinguishable.
@MainActor
struct EvidenceRow: View {
    var evidence: Evidence

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 1)
                .background(tint.opacity(0.14), in: Capsule())
                .foregroundStyle(tint)
                .frame(width: 92, alignment: .leading)
            Text(evidence.statement).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch evidence.kind {
        case .observation: return "MEASURED"
        case .correlation: return "AT THE SAME TIME"
        case .hypothesis: return "POSSIBLE CAUSE"
        case .limitation: return "NOT VISIBLE"
        }
    }

    private var tint: Color {
        switch evidence.kind {
        case .observation: return Palette.accent
        case .correlation: return Palette.series[1]
        case .hypothesis: return Palette.warning
        case .limitation: return Palette.neutral
        }
    }
}

/// Thin horizontal usage bar (capacity, share).
@MainActor
struct UsageBar: View {
    var fraction: Double
    var tint: Color = Palette.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.subtleFill)
                Capsule().fill(tint).frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 2))
            }
        }
        .frame(height: 6)
        .accessibilityValue(Format.percent(fraction * 100))
    }
}

@MainActor
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}
