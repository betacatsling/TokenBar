import SwiftUI

/// One day of the trend, split by CLI.
struct DayStack: Identifiable {
    let day: String
    let parts: [CLIKind: Int]

    var id: String { day }
    var total: Int { parts.values.reduce(0, +) }
}

extension UsageSnapshot {
    /// Per-CLI daily totals for the trend chart, oldest first. Like
    /// `dailySeries`, this ignores the selected range.
    func dailyStacks(days: Int = 14) -> [DayStack] {
        let wanted = DayFormatter.recentDays(days)
        let window = Set(wanted)
        var acc: [String: [CLIKind: Int]] = [:]
        for b in buckets where window.contains(b.day) {
            acc[b.day, default: [:]][b.cli, default: 0] += b.tokens.total
        }
        return wanted.map { DayStack(day: $0, parts: acc[$0] ?? [:]) }
    }
}

/// The 14-day trend: one column per day, stacked by CLI.
///
/// Drawn with `Canvas` rather than Swift Charts so the app builds against the
/// Command Line Tools SDK without extra frameworks. Hovering a column reads that
/// day out in the header and legend. The days the selected range covers sit on
/// a faint band, so it is clear which part of the chart the numbers above sum.
struct TrendChart: View {
    let days: [DayStack]
    let inRange: (String) -> Bool
    var height: CGFloat = 56

    @State private var hovered: Int?
    @Environment(\.colorScheme) private var scheme

    /// Horizontal air between columns.
    private static let columnGap: CGFloat = 4
    /// 1 pt = 2 px on Retina: the surface gap between stacked segments.
    private static let segmentGap: CGFloat = 1
    private static let corner: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            plot
            axis
            if presentCLIs.count >= 2 { legend }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近 \(days.count) 天用量，日均 \(Fmt.compact(average)) token")
    }

    // MARK: - Derived

    private var hoveredDay: DayStack? { hovered.flatMap { days.indices.contains($0) ? days[$0] : nil } }
    private var peak: Int { max(days.map(\.total).max() ?? 0, 1) }
    private var average: Int { days.isEmpty ? 0 : days.reduce(0) { $0 + $1.total } / days.count }

    /// CLIs with any usage in the window, in stacking order. The legend only
    /// lists these; colors stay fixed per CLI, so nothing repaints when one drops out.
    private var presentCLIs: [CLIKind] {
        CLIKind.ordered.filter { cli in days.contains { ($0.parts[cli] ?? 0) > 0 } }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(hoveredDay.map { Fmt.dayTitle($0.day) } ?? "近 \(days.count) 天")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let day = hoveredDay {
                Text("\(Fmt.compact(day.total)) tokens")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            } else if average > 0 {
                // An empty window (or a first scan still running) has no
                // average worth stating; the stubs already say it.
                Text("日均 \(Fmt.compact(average))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var plot: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let slot = geo.size.width / CGFloat(max(days.count, 1))
                    let index = Int(point.x / slot)
                    hovered = days.indices.contains(index) ? index : nil
                case .ended:
                    hovered = nil
                }
            }
        }
        .frame(height: height)
    }

    private var axis: some View {
        HStack {
            Text(days.first.map { Fmt.shortDay($0.day) } ?? "")
            Spacer()
            Text("今天")
        }
        .font(.system(size: 9))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
    }

    /// Doubles as the hover readout: while a column is hovered each entry
    /// carries that day's value, so the numbers appear in a fixed slot instead
    /// of a tooltip covering the columns next to it.
    private var legend: some View {
        // Four names plus four values is close to the panel width; step down
        // rather than truncate a name.
        ViewThatFits(in: .horizontal) {
            legendRow(spacing: 12, fontSize: 10)
            legendRow(spacing: 7, fontSize: 9)
        }
    }

    private func legendRow(spacing: CGFloat, fontSize: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(presentCLIs, id: \.self) { cli in
                HStack(spacing: 4) {
                    SeriesDot(cli: cli, size: 6)
                    Text(cli.shortName)
                        .foregroundStyle(.secondary)
                    if let day = hoveredDay {
                        let value = day.parts[cli] ?? 0
                        Text(value > 0 ? Fmt.compact(value) : "–")
                            .monospacedDigit()
                    }
                }
                .fixedSize()
            }
        }
        .font(.system(size: fontSize))
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !days.isEmpty else { return }
        let slot = size.width / CGFloat(days.count)
        let barWidth = max(2, slot - Self.columnGap)

        // The range band: one rounded wash behind the run of in-range days,
        // left out when the range covers the whole window.
        let covered = days.indices.filter { inRange(days[$0].day) }
        if let first = covered.first, let last = covered.last, covered.count < days.count {
            let band = CGRect(x: CGFloat(first) * slot, y: 0,
                              width: CGFloat(last - first + 1) * slot, height: size.height)
            context.fill(Path(roundedRect: band, cornerRadius: 4),
                         with: .color(.primary.opacity(0.05)))
        }
        if let h = hovered {
            let column = CGRect(x: CGFloat(h) * slot, y: 0, width: slot, height: size.height)
            context.fill(Path(roundedRect: column, cornerRadius: 4),
                         with: .color(.primary.opacity(0.08)))
        }

        // Leave a little headroom so the tallest column does not touch the band's top.
        let plotHeight = size.height - 3
        for (i, day) in days.enumerated() {
            let x = CGFloat(i) * slot + (slot - barWidth) / 2
            let opacity = hovered == nil || hovered == i ? 1.0 : 0.45

            guard day.total > 0 else {
                // A stub keeps idle days on the time axis instead of leaving holes.
                let stub = CGRect(x: x, y: size.height - 2, width: barWidth, height: 2)
                context.fill(Path(roundedRect: stub, cornerRadius: 1), with: .color(Theme.track))
                continue
            }

            let columnHeight = max(2, plotHeight * CGFloat(day.total) / CGFloat(peak))
            let parts = CLIKind.ordered.compactMap { cli -> (CLIKind, Int)? in
                let value = day.parts[cli] ?? 0
                return value > 0 ? (cli, value) : nil
            }
            var bottom = size.height
            for (k, part) in parts.enumerated() {
                let h = columnHeight * CGFloat(part.1) / CGFloat(day.total)
                let isTop = k == parts.count - 1
                // The gap is cut from the top of every segment but the last. A
                // segment too thin to give up a point keeps its full height.
                let gap: CGFloat = (isTop || h < 2) ? 0 : Self.segmentGap
                let rect = CGRect(x: x, y: bottom - h + gap, width: barWidth, height: h - gap)
                let path = isTop ? Self.topRounded(rect, radius: Self.corner) : Path(rect)
                context.fill(path, with: .color(part.0.color(scheme).opacity(opacity)))
                bottom -= h
            }
        }
    }

    /// A rectangle rounded only at the data end, square on the baseline.
    private static func topRounded(_ r: CGRect, radius: CGFloat) -> Path {
        let rad = min(radius, r.width / 2, r.height)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY),
                 tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: rad)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY),
                 tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: rad)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
