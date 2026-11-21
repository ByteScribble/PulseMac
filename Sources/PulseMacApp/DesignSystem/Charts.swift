import Charts
import PulseCore
import SwiftUI

/// Indexed point used by charts; `segment` breaks lines at data gaps.
struct ChartPoint: Identifiable {
    var id: Date { time }
    var time: Date
    var value: Double
    var segment: Int
}

extension Array where Element == Sample {
    /// Splits into gap-separated segments so charts never draw a line across missing data.
    func chartPoints(maximumGap: TimeInterval, transform: (Double) -> Double = { $0 }) -> [ChartPoint] {
        Downsampler.segments(self, maximumGap: maximumGap).enumerated().flatMap { index, segment in
            segment.map { ChartPoint(time: $0.time, value: transform($0.value), segment: index) }
        }
    }
}

/// Compact trend line for cards and the menu bar popover. Not interactive.
@MainActor
struct Sparkline: View {
    var samples: [Sample]
    var tint: Color = Palette.accent
    /// Fixed upper bound (e.g. 100 for percentages); nil = auto.
    var ceiling: Double?

    var body: some View {
        let points = samples.chartPoints(maximumGap: 15)
        Chart(points) { point in
            AreaMark(x: .value("Time", point.time), y: .value("Value", point.value), series: .value("Segment", point.segment))
                .foregroundStyle(tint.opacity(0.12))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.time), y: .value("Value", point.value), series: .value("Segment", point.segment))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.4))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(ceiling ?? Swift.max(points.map(\.value).max() ?? 1, 1) * 1.1))
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

/// Full time-series chart with hover inspection, linked cursor, units and gap handling.
@MainActor
struct TimeSeriesChart: View {
    var metric: MetricID
    var samples: [Sample]
    var tint: Color = Palette.accent
    /// Shared cursor: charts bound to the same binding show a linked crosshair.
    @Binding var cursor: Date?
    var annotations: [Incident] = []
    var height: CGFloat = 160
    var maximumGap: TimeInterval = 15
    var domain: ClosedRange<Date>?
    /// Fixed y-axis maximum; defaults to 100 for percentages, automatic otherwise.
    var yMaximum: Double?

    private var isPercent: Bool { metric.unit == .percent }

    var body: some View {
        let points = samples.chartPoints(maximumGap: maximumGap)
        Group {
            if points.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.small).fill(Palette.subtleFill.opacity(0.4))
                    Text("No data recorded for this period").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                chart(points)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(metric.displayName) chart")
        .accessibilityValue(summary(points))
    }

    private func chart(_ points: [ChartPoint]) -> some View {
        Chart {
            ForEach(annotations) { incident in
                RectangleMark(
                    xStart: .value("Start", incident.startedAt),
                    xEnd: .value("End", incident.resolvedAt ?? incident.lastObservedAt)
                )
                .foregroundStyle(StatusStyle(incident.severity).color.opacity(0.08))
            }
            ForEach(points) { point in
                LineMark(x: .value("Time", point.time), y: .value(metric.displayName, point.value), series: .value("Segment", point.segment))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Time", point.time), y: .value(metric.displayName, point.value), series: .value("Segment", point.segment))
                    .foregroundStyle(tint.opacity(0.08))
                    .interpolationMethod(.monotone)
            }
            if let cursor, let nearest = nearest(to: cursor, in: points) {
                RuleMark(x: .value("Cursor", nearest.time))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Format.value(nearest.value, unit: metric.unit)).font(.caption.weight(.semibold)).monospacedDigit()
                            Text(nearest.time, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                PointMark(x: .value("Time", nearest.time), y: .value(metric.displayName, nearest.value))
                    .foregroundStyle(tint)
                    .symbolSize(24)
            }
        }
        .chartXSelection(value: $cursor)
        .chartYScale(domain: 0...(yMaximum ?? (isPercent ? 100 : Swift.max((points.map(\.value).max() ?? 1) * 1.15, 1e-9))))
        .chartXScale(domain: domain ?? (points.first!.time...points.last!.time))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Palette.separator.opacity(0.5))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Format.value(number, unit: metric.unit)).font(.caption2).monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Palette.separator.opacity(0.3))
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false).font(.caption2)
            }
        }
        .transaction { $0.animation = nil } // live data: no per-point animation
    }

    private func nearest(to date: Date, in points: [ChartPoint]) -> ChartPoint? {
        points.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    private func summary(_ points: [ChartPoint]) -> String {
        guard let last = points.last else { return "No data" }
        let values = points.map(\.value)
        let mean = values.reduce(0, +) / Double(values.count)
        return "Latest \(Format.value(last.value, unit: metric.unit)), average \(Format.value(mean, unit: metric.unit)), maximum \(Format.value(values.max() ?? 0, unit: metric.unit))."
    }
}
