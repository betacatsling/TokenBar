import SwiftUI

/// One line of a breakdown list: key, name, share, tokens, cost, and a bar.
struct ShareRow<Key: View>: View {
    let title: String
    var subtitle: String? = nil
    let tokens: Int
    let cost: CostEstimate
    /// This row's part of the range total, 0...1.
    let share: Double
    let barColor: Color
    /// nil when the row does not expand; otherwise whether it is expanded.
    var expanded: Bool? = nil
    @ViewBuilder var key: () -> Key

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                key()
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(title)
                        Text(Fmt.percent(share))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Text(Fmt.compact(tokens))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .fixedSize()

                CostLabel(cost: cost)
                    .frame(width: 62, alignment: .trailing)

                if let expanded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                }
            }

            ShareBar(fraction: share, color: barColor)
                .padding(.leading, 22)
                .padding(.trailing, expanded == nil ? 0 : 18)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }
}

/// A cost figure that distinguishes "free", "unknown" and "inferred".
///
/// Rendering an unpriced row as `$0` claims it cost nothing — Devin's
/// `compactor` has no published rate at all, so its row would read as free while
/// accounting for real usage. Where nothing could be priced the number is
/// replaced outright; where only some of it could, the figure is marked as the
/// lower bound it is.
///
/// A third case sits between the two: `swe-2-*` is priced at kimi-k3's rate
/// because it is post-trained from kimi-k3, which is a reasoned guess and not a
/// published price. Those rows are marked `~` so the panel never presents an
/// inference with the same confidence as a list price.
struct CostLabel: View {
    let cost: CostEstimate
    var size: CGFloat = 11

    var body: some View {
        if cost.totalTokens > 0 && cost.coverage == 0 {
            Text("无公开价")
                .font(.system(size: max(9, size - 1)))
                .foregroundStyle(.tertiary)
                .fixedSize()
        } else {
            HStack(spacing: 1) {
                Text(Fmt.usd(cost.usd))
                    .font(.system(size: size))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                if cost.isPartial {
                    // Some of this row's tokens had no price, so the figure is a
                    // floor, not an estimate of the whole.
                    marker("+", help: "含 \(Fmt.compact(cost.unpricedTokens)) 无公开价 token，实际更高")
                }
                if cost.hasInferred {
                    marker("~", help: "含 \(Fmt.compact(cost.inferredTokens)) token 无官方定价，"
                           + "按 kimi-k3 费率估算（swe-2 由 kimi-k3 后训练而来）")
                }
            }
        }
    }

    private func marker(_ glyph: String, help: String) -> some View {
        Text(glyph)
            .font(.system(size: max(9, size - 1), weight: .semibold))
            .foregroundStyle(.tertiary)
            .help(help)
    }
}

/// A proportion bar showing this row's share of the range total.
struct ShareBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}
