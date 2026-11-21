import SwiftUI

/// 修复助手（对齐 Windows 端 PageRepair）：体检列表 + 一键修复 + 打开控制台。
/// 只做安全可自动的动作，不碰游戏存档与账号。
struct RepairView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var items: [DiagnosticItem] = []
    @State private var resultMessage: String?
    @State private var showConsole = false

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: "修复助手", subtitle: "体检与一键修复") {
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    YZLCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("体检结果")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(YZLTheme.text)
                                Spacer()
                                Button("重新体检") { runChecks() }
                                    .font(.system(size: 12, weight: .semibold))
                            }

                            ForEach(items) { item in
                                diagnosticRow(item)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button { fixAll() } label: {
                            Text("一键修复")
                        }
                        .buttonStyle(PrimaryButtonStyle(prominent: true))

                        Button { showConsole = true } label: {
                            Text("查看日志")
                        }
                        .buttonStyle(PrimaryButtonStyle(prominent: false))
                    }

                    if let message = resultMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(YZLTheme.accentText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(3)
                    }

                    Text("一键修复只清理可再生的缓存与记录，不会删除游戏版本、模组、存档、账号或皮肤。启动内核与 Java 需要安装对应的引擎包，工具无法自动补齐。")
                        .font(.system(size: 10))
                        .foregroundStyle(YZLTheme.muted)
                        .lineSpacing(3)
                }
                .padding(20)
            }
        }
        .background(PageBackground())
        .task { runChecks() }
        .sheet(isPresented: $showConsole) {
            ConsoleView()
        }
    }

    private func diagnosticRow(_ item: DiagnosticItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon(item.status))
                .font(.system(size: 14))
                .foregroundStyle(statusColor(item.status))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text(item.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action = item.fixAction, action == .clearDownloadCache || action == .resetDownloadSourcesHealth {
                Button("修复") {
                    resultMessage = DiagnosticsService.perform(action)
                    runChecks()
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func runChecks() {
        items = DiagnosticsService.run(appState: appState)
    }

    private func fixAll() {
        YZLBootLog.separator("一键修复开始")
        var messages: [String] = []
        for item in items {
            if let action = item.fixAction,
               action == .clearDownloadCache || action == .resetDownloadSourcesHealth {
                messages.append(DiagnosticsService.perform(action))
            }
        }
        resultMessage = messages.isEmpty ? "没有需要自动修复的项目。" : messages.joined(separator: "\n")
        YZLBootLog.write("fixAll | \(messages.joined(separator: " | "))")
        runChecks()
    }

    private func statusIcon(_ status: DiagnosticItem.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func statusColor(_ status: DiagnosticItem.Status) -> Color {
        switch status {
        case .ok: return YZLTheme.success
        case .warning: return YZLTheme.warningText
        case .failed: return YZLTheme.danger
        }
    }
}
