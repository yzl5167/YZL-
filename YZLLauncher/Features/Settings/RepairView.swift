import SwiftUI

/// 修复助手（对齐 Windows 端 PageRepair）：体检列表 + 一键修复 + 日志入口。
/// 只做安全可自动的动作；导航类动作由本视图处理跳转，不碰游戏存档与账号。
struct RepairView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var items: [DiagnosticItem] = []
    @State private var resultMessage: String?
    @State private var showFixResult = false
    @State private var consoleSource: GameLogService.Source = .boot
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

                            if items.isEmpty {
                                Text("没有发现问题。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(YZLTheme.muted)
                            } else {
                                ForEach(items) { item in
                                    diagnosticRow(item)
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button { fixAll() } label: {
                            Text("一键修复")
                        }
                        .buttonStyle(PrimaryButtonStyle(prominent: true))

                        Button {
                            consoleSource = .boot
                            showConsole = true
                        } label: {
                            Text("启动器日志")
                        }
                        .buttonStyle(PrimaryButtonStyle(prominent: false))

                        Button {
                            consoleSource = .game
                            showConsole = true
                        } label: {
                            Text("游戏日志")
                        }
                        .buttonStyle(PrimaryButtonStyle(prominent: false))
                    }

                    if let message = resultMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(YZLTheme.success)
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(YZLTheme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("一键修复只清理可再生的缓存与源健康记录，不会删除游戏版本、模组、存档、账号或皮肤。启动内核与 Java 需要安装对应的引擎包，工具无法自动补齐。")
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
            ConsoleView(initialSource: consoleSource)
        }
        .alert("修复完成", isPresented: $showFixResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
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
            if let action = item.fixAction {
                Button(action.buttonTitle) { handle(action) }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    /// 自动修复直接执行；导航类动作关闭本页并切到对应界面。
    @MainActor
    private func handle(_ action: DiagnosticItem.FixAction) {
        if action.isAutoFix {
            resultMessage = DiagnosticsService.perform(action)
            runChecks()
            showFixResult = true
            return
        }
        switch action {
        case .openAccount:
            dismiss()
            appState.overlay = .account
        case .openJavaSettings:
            // 设置页的 Java 管理是 sheet，无法从外部直接唤起；回到设置 tab 由用户点「管理」。
            dismiss()
            appState.selectedTab = .settings
            resultMessage = "已回到设置页，请点「Java 环境 → 管理」。"
        case .openMobileCompat:
            dismiss()
            appState.selectedTab = .settings
            resultMessage = "已回到设置页，请在「iPhone 兼容」里点「恢复原样」。"
        case .openDownloadPage:
            dismiss()
            appState.selectedTab = .download
        case .clearDownloadCache, .resetSourceHealth:
            break
        }
    }

    @MainActor
    private func runChecks() {
        items = DiagnosticsService.run(appState: appState)
    }

    @MainActor
    private func fixAll() {
        YZLBootLog.separator("一键修复开始")
        var messages: [String] = []
        for item in items {
            if let action = item.fixAction, action.isAutoFix {
                messages.append(DiagnosticsService.perform(action))
            }
        }
        resultMessage = messages.isEmpty ? "没有需要自动修复的项目。" : messages.joined(separator: "\n")
        YZLBootLog.write("fixAll | \(messages.joined(separator: " | "))")
        showFixResult = true
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
