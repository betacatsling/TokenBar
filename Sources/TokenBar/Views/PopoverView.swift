import SwiftUI

/// Which breakdown the panel is showing.
enum BreakdownTab: String, CaseIterable, Identifiable {
    case cli, model, origin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cli: return "按 CLI"
        case .model: return "按模型"
        case .origin: return "按机器"
        }
    }
}

/// The dropdown panel shown when the menu bar item is clicked.
///
/// Top to bottom: the range filter (it scopes everything under it), the
/// headline, the trend, then the breakdown. Housekeeping lives in a footer.
struct PopoverView: View {
    @ObservedObject var model: AppModel
    @State private var tab: BreakdownTab
    @State private var expandedCLI: CLIKind?
    @State private var showSettings = false
    @Environment(\.colorScheme) private var scheme

    /// `initialTab` and `initialExpanded` exist so the render harness can
    /// screenshot states other than the default; the panel itself always
    /// opens on 按 CLI with nothing expanded.
    init(model: AppModel, initialTab: BreakdownTab = .cli, initialExpanded: CLIKind? = nil) {
        self.model = model
        _tab = State(initialValue: initialTab)
        _expandedCLI = State(initialValue: initialExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PillPicker(options: TimeRange.allCases,
                           selection: Binding(get: { model.range }, set: { model.setRange($0) }),
                           title: \.displayName)

                SummaryHeader(tokens: model.snapshot.totalTokens,
                              cost: model.snapshot.totalCost,
                              range: model.range,
                              loading: awaitingFirstScan)

                if model.snapshot.totalCost.reportedTokens > 0 {
                    HStack {
                        Text("日志记录费用（部分）")
                        Spacer()
                        Text("≈ " + Fmt.usd(model.snapshot.totalCost.reportedUSD)).monospacedDigit()
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("仅汇总日志中非零费用记录，可能是客户端估算；不与上方估算重复相加，也不代表账单。")
                }
                if !model.snapshot.billing.charges(in: model.range).isEmpty {
                    HStack {
                        Text("已导入账单")
                        Spacer()
                        Text(Fmt.usd(model.snapshot.billing.usd(in: model.range))).monospacedDigit()
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("来自 billing.json 的订阅、API 或工具收费，按账单日期统计；与 token 等价估算分开显示。")
                }

                TrendChart(days: model.snapshot.dailyStacks(days: 14),
                           inRange: { model.range.contains(day: $0, today: DayFormatter.today()) })
            }
            .padding(Theme.inset)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                PillPicker(options: BreakdownTab.allCases, selection: $tab, title: \.displayName)
                    .padding(.horizontal, Theme.inset)

                breakdownSection
                    .padding(.horizontal, Theme.inset - 6)
            }
            .padding(.vertical, 12)

            // Remote health is shown on every tab, not just the machine one: an
            // offline server1 means every total on screen is short by whatever it
            // contributed, which matters most when the machine list is not visible.
            remoteStatusLine
            if !model.snapshot.coverage.issues.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("部分用量尚未覆盖 · 设置中查看").lineLimit(1)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, Theme.inset).padding(.bottom, 8)
                .help(model.snapshot.coverage.issues.joined(separator: "\n"))
            }

            Divider()
            footer
        }
        .frame(width: Theme.panelWidth)
    }

    // MARK: - Breakdowns

    @ViewBuilder
    private var breakdownSection: some View {
        switch tab {
        case .cli:    cliSection
        case .model:  modelSection
        case .origin: originSection
        }
    }

    private var rangeTotal: Int { max(model.snapshot.totalTokens, 1) }

    /// Nothing has been scanned yet, so the zeros on screen are not a reading.
    /// A later rescan keeps the previous snapshot until it finishes.
    private var awaitingFirstScan: Bool {
        model.isScanning && model.snapshot.buckets.isEmpty
    }

    private func share(_ row: BreakdownRow) -> Double {
        Double(row.total) / Double(rangeTotal)
    }

    private var cliSection: some View {
        let rows = model.snapshot.byCLI

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                let isExpanded = row.cli != nil && expandedCLI == row.cli
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        toggle(row.cli)
                    } label: {
                        ShareRow(title: row.title, tokens: row.total, cost: row.cost,
                                 share: share(row),
                                 barColor: row.cli?.color(scheme) ?? Theme.neutralBar,
                                 expanded: isExpanded) {
                            SeriesDot(cli: row.cli)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()

                    // Model detail, expanded on click. The dedicated 按模型 tab
                    // merges across CLIs; this stays scoped to one CLI.
                    if let cli = row.cli, isExpanded {
                        modelDetail(for: cli, cliTotal: row.total)
                            .transition(.opacity)
                    }
                }
            }

            if rows.isEmpty { emptyState }
        }
    }

    /// The expanded list under a CLI row: its models, with each one's share of
    /// that CLI rather than of the whole range.
    private func modelDetail(for cli: CLIKind, cliTotal: Int) -> some View {
        let models = model.snapshot.byModel(cli: cli)
        return VStack(alignment: .leading, spacing: 5) {
            if models.isEmpty {
                Text("无数据")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(models) { m in
                    HStack(spacing: 6) {
                        Text(m.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(m.title)
                        Text(Fmt.percent(Double(m.total) / Double(max(cliTotal, 1))))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                        Spacer(minLength: 4)
                        Text(Fmt.compact(m.total))
                            .fixedSize()
                        CostLabel(cost: m.cost, size: 10)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 24)
        .padding(.top, 1)
        .padding(.bottom, 8)
    }

    /// Every model that ran in the selected range, merged across CLIs.
    ///
    /// This is the one place a model with no published price is called out as
    /// such. Elsewhere an unpriced model just contributes $0, which reads as
    /// "free" rather than "unknown" — and 458.8M of this machine's tokens are
    /// unpriced, so the distinction is worth the row space.
    private var modelSection: some View {
        let rows = model.snapshot.byModel()
        let visible = min(rows.count, Self.visibleModelRows)

        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            ShareRow(title: row.title,
                                     // No single owning CLI means several share this model.
                                     subtitle: row.subtitle ?? "多个 CLI",
                                     tokens: row.total, cost: row.cost, share: share(row),
                                     // A model used by one CLI takes that CLI's color, so
                                     // it reads back to the trend; shared ones stay neutral.
                                     barColor: row.cli?.color(scheme) ?? Theme.neutralBar) {
                                SeriesDot(cli: row.cli)
                            }
                            // Fixed so the viewport can be sized to a whole
                            // number of rows: a maxHeight picked by eye slices
                            // the last row through its text.
                            .frame(height: Self.modelRowHeight, alignment: .top)
                            .hoverHighlight()
                        }
                    }
                }
                .frame(height: Self.modelRowHeight * CGFloat(visible))

                VStack(alignment: .leading, spacing: 2) {
                    if rows.count > visible {
                        footnote("下滑查看其余 \(rows.count - visible) 个模型")
                    }
                    let unpriced = rows.filter { $0.cost.coverage == 0 }
                    if !unpriced.isEmpty {
                        footnote("\(unpriced.count) 个模型无公开价，未计入费用")
                    }
                    if rows.contains(where: { $0.cost.hasInferred }) {
                        footnote("~ 表示无官方定价，按 kimi-k3 费率估算")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }
        }
    }

    /// Name + subtitle + share bar + breathing room.
    private static let modelRowHeight: CGFloat = 44
    private static let visibleModelRows = 6

    private var originSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.snapshot.byOrigin) { row in
                ShareRow(title: row.title, tokens: row.total, cost: row.cost,
                         share: share(row), barColor: Theme.neutralBar) {
                    Image(systemName: (Origin(rawValue: row.id) ?? .local).symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .hoverHighlight()
            }

            if model.snapshot.byOrigin.isEmpty { emptyState }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.isScanning ? "hourglass" : "tray")
                .font(.system(size: 18, weight: .light))
            Text(model.isScanning ? "正在扫描日志…" : "\(model.range.displayName)暂无用量")
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }

    private func toggle(_ cli: CLIKind?) {
        guard let cli else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedCLI = (expandedCLI == cli) ? nil : cli
        }
    }

    // MARK: - Status & footer

    /// Says plainly whether server1's numbers are live, cached, or missing.
    @ViewBuilder
    private var remoteStatusLine: some View {
        if model.settings.remoteEnabled, case .offline(let reason) = model.snapshot.remoteStatus {
            // Only claim a cached result is being shown when one actually exists.
            let hasRemoteData = model.snapshot.buckets.contains { $0.origin == .server1 }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.serious)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hasRemoteData ? "server1 离线，显示上次结果" : "server1 离线，本次未统计")
                        .foregroundStyle(.primary)
                    Text(reason)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(reason)
                }
            }
            .font(.system(size: 10))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.serious.opacity(0.12)))
            .padding(.horizontal, Theme.inset)
            .padding(.bottom, 12)
        }
    }

    /// The healthy states are routine, so they sit in the footer's fine print
    /// instead of taking a line of their own.
    private var statusSummary: String {
        let local = model.isScanning ? "扫描中…" : "更新于 \(Fmt.relative(model.snapshot.scannedAt))"
        guard model.settings.remoteEnabled else { return local + " · server1 已关闭" }
        switch model.snapshot.remoteStatus {
        case .ok(let date):
            // One timestamp is enough when both sources refreshed together.
            let remote = Fmt.relative(date)
            return remote == Fmt.relative(model.snapshot.scannedAt) || model.isScanning
                ? local + " · 含 server1"
                : local + " · server1 \(remote)"
        case .fetching: return local + " · 正在连接 server1"
        case .offline, .idle: return local
        }
    }

    private var statusHelp: String {
        var text = "本机扫描耗时 \(Fmt.duration(model.snapshot.scanDuration))"
        if model.snapshot.allTimeTokens > 0 {
            text += "\n历史累计 \(Fmt.grouped(model.snapshot.allTimeTokens)) token"
        }
        return text
    }

    private var footer: some View {
        HStack(spacing: 2) {
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }
            Text(statusSummary)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(statusHelp)

            Spacer(minLength: 8)

            // Incremental, and forces the server1 fetch past its TTL. The
            // cold rescan (≈15 s over the full log tree) stays in settings.
            Button {
                model.refresh(forceRemote: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(model.isScanning)
            .help("刷新")

            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsView(settings: model.settings, model: model)
            }
            .help("设置")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help("退出 TokenBar")
        }
        .padding(.leading, Theme.inset)
        .padding(.trailing, Theme.inset - 6)
        .padding(.vertical, 6)
    }
}
