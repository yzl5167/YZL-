import SwiftUI

/// 启动自检面板：把“启动”拆成可核对的检查项，而不是弹一个“还不能启动”。
/// 内核接入后，这里会在全部通过时真正把 LaunchPlan 交给 Amethyst。
struct LaunchSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            PageBackground()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 14) {
                        summaryCard
                        statusBanner
                        checksCard
                        requirementCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }

                footer
            }
        }
        .interactiveDismissDisabled(isBusy)
        .onDisappear {
            appState.closeLaunchSheet()
        }
    }

    private var isBusy: Bool {
        appState.launchPhase == .launching
            || appState.launchPhase == .running
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("启动游戏")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text(appState.selectedVersion.map { "\($0.id) · 启动前自检" } ?? "启动前自检")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }

            Spacer()

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YZLTheme.muted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(isBusy ? 0.45 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var summaryCard: some View {
        YZLCard {
            HStack(spacing: 14) {
                AvatarView(size: 54, account: appState.displayAccount)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.displayAccount?.name ?? "未登录")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(YZLTheme.text)
                    Text(appState.launchPlanSummary ?? "正在生成启动参数…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                        .lineLimit(2)
                }

                Spacer()

                if appState.launchPhase == .running {
                    StatusBadge(text: "运行中", tone: .success)
                } else if appState.launchPhase == .checking {
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch appState.launchPhase {
        case .idle:
            EmptyView()
        case .checking:
            banner(
                icon: "hourglass",
                title: "正在检查",
                message: "账户、版本文件、运行时和启动参数正在逐项核对。",
                tint: YZLTheme.accent,
                background: YZLTheme.accentSoft
            )
        case .ready, .launching:
            banner(
                icon: "arrow.right.circle.fill",
                title: "正在移交启动内核",
                message: "全部检查通过，正在把 LaunchPlan 交给引擎。",
                tint: YZLTheme.accent,
                background: YZLTheme.accentSoft
            )
        case .running:
            banner(
                icon: "checkmark.circle.fill",
                title: "游戏已启动",
                message: "启动内核已接管，切回游戏画面即可。",
                tint: YZLTheme.success,
                background: YZLTheme.successSoft
            )
        case .failed(let message):
            banner(
                icon: "exclamationmark.triangle.fill",
                title: appState.displayAccount == nil ? "需要先选择账号" : "启动条件未满足",
                message: appState.launchErrorMessage ?? message,
                tint: YZLTheme.danger,
                background: Color(red: 0.996, green: 0.925, blue: 0.925)
            )
        }
    }

    private func banner(icon: String, title: String, message: String, tint: Color, background: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.text.opacity(0.82))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(background)
        )
    }

    private var checksCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("检查项")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                VStack(spacing: 0) {
                    ForEach(appState.launchChecks) { check in
                        checkRow(check)
                        if check.id != appState.launchChecks.last?.id {
                            Divider()
                                .background(YZLTheme.border)
                        }
                    }
                }
            }
        }
    }

    private func checkRow(_ check: LaunchCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: check.status))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color(for: check.status))
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text(check.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private func icon(for status: LaunchCheck.Status) -> String {
        switch status {
        case .pending: return "circle.dotted"
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for status: LaunchCheck.Status) -> Color {
        switch status {
        case .pending: return YZLTheme.lightMuted
        case .ok: return YZLTheme.success
        case .warning: return YZLTheme.warningText
        case .failed: return YZLTheme.danger
        }
    }

    private var requirementCard: some View {
        YZLCard(padding: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("启动需要什么")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text("微软正版账户 · 已安装的版本文件 · iOS JRE · Amethyst 启动内核 · 已开启的 JIT。前两项由本仓库完成，后三项属于 M2 引擎侧。")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                if appState.jitStatus != .enabled {
                    Button(appState.jitActionTitle) {
                        appState.enableJIT()
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(YZLTheme.accentText)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                if needsLogin {
                    close()
                    appState.overlay = .account
                } else {
                    appState.requestLaunch()
                }
            } label: {
                Text(needsLogin ? "去登录" : "重新检查")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: true))

            Button("关闭") {
                close()
            }
            .buttonStyle(PrimaryButtonStyle(prominent: false))
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(YZLTheme.page.opacity(0.96))
    }

    private var needsLogin: Bool {
        appState.displayAccount == nil || appState.launchChecks.contains {
            $0.id == "session" && $0.status == .failed
        }
    }

    private func close() {
        appState.closeLaunchSheet()
        dismiss()
    }
}
