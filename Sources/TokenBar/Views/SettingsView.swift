import SwiftUI

/// Preferences, reachable from the gear in the popover footer.
///
/// Grouped rows in the manner of System Settings, on the panel's type scale:
/// 12 pt for what a setting is, 10 pt tertiary for what it does.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var model: AppModel

    /// The host as typed. Committed on return, on leaving the field, or when
    /// the popover closes, not per keystroke: every committed change starts a
    /// rescan with an SSH attempt, and a pause halfway through typing is not a host.
    @State private var hostDraft: String
    @FocusState private var hostFocused: Bool

    init(settings: Settings, model: AppModel) {
        self.settings = settings
        self.model = model
        _hostDraft = State(initialValue: settings.remoteHost)
    }

    private static let intervals: [TimeInterval] = [30, 60, 300, 900]
    private static let rowPadding = EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.system(size: 13, weight: .semibold))

            section("通用") {
                toggleRow("在菜单栏显示今日用量", detail: "关闭后只显示图标",
                          isOn: $settings.showCountInMenuBar)
                rowDivider
                toggleRow("统计子代理 (subagent) 用量", detail: "Claude Code 的 sidechain 会话",
                          isOn: $settings.includeSidechain)
                    .help("关闭时只统计主会话。")
                rowDivider
                VStack(alignment: .leading, spacing: 6) {
                    rowTitle("自动刷新间隔")
                    PillPicker(options: Self.intervals, selection: $settings.refreshInterval,
                               title: Self.intervalName)
                }
                .padding(Self.rowPadding)
            }

            section("远端") {
                toggleRow("统计 server1", detail: "经 SSH 在远端汇总后回传",
                          isOn: $settings.remoteEnabled)
                rowDivider
                hostRow
            }

            section("数据") {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle("清空缓存并重扫")
                        rowDetail(model.isScanning ? "正在扫描…" : "从头解析全部日志，较慢")
                    }
                    Spacer(minLength: 8)
                    Button("重扫") {
                        model.clearCacheAndRescan()
                    }
                    .controlSize(.small)
                    // A click mid-scan would clear the cache but lose the
                    // rescan: `refresh` drops calls while one is running.
                    .disabled(model.isScanning)
                }
                .padding(Self.rowPadding)
            }

            Text("数据均为只读扫描，不会修改任何 CLI 的日志。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
        .padding(Theme.inset)
        .frame(width: 300)
        .onDisappear(perform: commitHost)
    }

    private var hostRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                rowTitle("主机")
                // Same line either way, so the row does not jump while typing.
                rowDetail(hostDraft == settings.remoteHost ? "SSH 连接用的主机名" : "按回车应用")
            }
            Spacer(minLength: 8)
            TextField("server1", text: $hostDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 130)
                .focused($hostFocused)
                .onSubmit(commitHost)
                .onChange(of: hostFocused) { focused in
                    if !focused { commitHost() }
                }
        }
        .padding(Self.rowPadding)
        .disabled(!settings.remoteEnabled)
        .opacity(settings.remoteEnabled ? 1 : 0.5)
    }

    private func commitHost() {
        let host = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            hostDraft = settings.remoteHost
            return
        }
        hostDraft = host
        if host != settings.remoteHost {
            settings.remoteHost = host
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.groupFill))
        }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                rowTitle(title)
                rowDetail(detail)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(Self.rowPadding)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 10)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
    }

    private func rowDetail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private static func intervalName(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) 秒" : "\(Int(seconds / 60)) 分钟"
    }
}
