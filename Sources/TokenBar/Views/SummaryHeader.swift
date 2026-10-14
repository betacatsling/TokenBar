import SwiftUI

/// The headline: total tokens for the active range, with the cost estimate
/// beside it at a lower rank. Tokens are what this app counts; cost is a
/// derived, partly-inferred figure, so it does not compete for the eye.
struct SummaryHeader: View {
    let tokens: Int
    let cost: CostEstimate
    let range: TimeRange
    /// The first scan is still running. Zeros would read as "no usage", so the
    /// figures hold a dash until there is something to show.
    var loading = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                label(range.displayName + "用量")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(loading ? "—" : Fmt.compact(tokens))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(loading ? HierarchicalShapeStyle.tertiary : .primary)
                    Text("tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // A blank line rather than none, so nothing shifts when data lands.
                fine(loading ? " " : Fmt.grouped(tokens))
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                label("估算费用")
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if !loading {
                        Text("≈")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Text(loading ? "—" : Fmt.usd(cost.usd))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(loading ? HierarchicalShapeStyle.tertiary : .primary)
                }
                // Make the uncertainty explicit rather than hiding it.
                fine(loading ? " " : costDetail)
            }
            .help(costHelp)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func fine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    /// The cost column's fine print. Two distinct kinds of uncertainty: usage
    /// nothing could price, and usage priced from an inferred rate.
    ///
    /// Kept terse because the column is narrow: "其中 2% 为估算费率" truncates
    /// to "其中 2% 为…", losing the one word that carries the meaning. The full
    /// sentence is in the tooltip.
    private var costDetail: String {
        var parts: [String] = []
        parts.append(cost.isPartial ? "\(Int(cost.coverage * 100))% 已计价" : "均已计价")
        if cost.hasInferred, cost.totalTokens > 0 {
            let share = Int((Double(cost.inferredTokens) / Double(cost.totalTokens) * 100).rounded())
            // Below 1% the rounded share reads "0%", which looks like a bug.
            parts.append(share >= 1 ? "\(share)% 估算费率" : "含估算费率")
        }
        return parts.joined(separator: " · ")
    }

    /// Spelled out where there is room for it.
    private var costHelp: String {
        var text = "费用按可用的模型／供应商价格估算，不等于实际账单。计价比例仅针对已采集用量，不代表所有工具都已覆盖。"
        if cost.isPartial {
            text += "\n\(Fmt.compact(cost.unpricedTokens)) token 的模型无公开价，未计入。"
        }
        if cost.hasInferred {
            text += "\n\(Fmt.compact(cost.inferredTokens)) token 无官方定价，"
                + "按 kimi-k3 费率估算（swe-2 由 kimi-k3 后训练而来）。"
        }
        return text
    }
}
