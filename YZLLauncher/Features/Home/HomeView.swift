import SwiftUI

/// 主页：仿 PC 端「安卓式主页」——白底、内容垂直居中，只有大头像、当前版本和启动按钮。
/// 结构与 PC `MainWindow.xaml` 的活跃主页、安卓 `HomeScreen` 完全一致。
struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            YZLTheme.card
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                centered
                Spacer()
                bottomBanner
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private var centered: some View {
        VStack(spacing: 0) {
            avatar
                .padding(.top, 4)

            Text(appState.displayAccount?.name ?? "未登录")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(YZLTheme.text)
                .lineLimit(1)
                .padding(.top, 6)

            Text(appState.displayAccount == nil ? "点击头像选择账号" : (appState.isOfflineLaunch ? "离线（伪正版）账号" : "微软正版账号"))
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.muted)
                .padding(.top, 2)

            versionRow
                .padding(.top, 20)

            launchButton
                .padding(.top, 18)

            statusLine
                .padding(.top, 10)

            HStack(spacing: 10) {
                ghostButton("版本管理") { appState.selectedTab = .versions }
                ghostButton(appState.currentInstall == nil ? "下载游戏" : "启动自检") {
                    if appState.currentInstall == nil {
                        if let version = appState.selectedVersion {
                            appState.pendingInstallVersionID = version.id
                        }
                        appState.selectedTab = .versions
                    } else {
                        appState.requestLaunch()
                    }
                }
            }
            .frame(width: 300)
            .padding(.top, 14)
        }
    }

    private var bottomBanner: some View {
        Group {
            if showBanner {
                InstallProgressBanner(queue: appState.installQueue) {
                    appState.selectedTab = .versions
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 12)
            }
        }
    }

    private var showBanner: Bool {
        switch appState.installQueue.state.phase {
        case .running, .failed, .cancelled: return true
        case .idle, .finished: return false
        }
    }

    private var avatar: some View {
        Button {
            appState.overlay = .account
        } label: {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(size: 140, account: appState.displayAccount)
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(YZLTheme.accent)
                    .background(Circle().fill(Color.white))
                    .offset(x: 4, y: 4)
            }
        }
        .buttonStyle(.plain)
    }

    private var versionRow: some View {
        Button {
            appState.selectedTab = .versions
            appState.overlay = nil
        } label: {
            HStack(spacing: 9) {
                GrassBlockIcon(size: 26)
                Text("当前版本")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)
                Text(appState.selectedVersion?.id ?? "还没有安装版本")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(appState.selectedVersion == nil ? YZLTheme.muted : YZLTheme.text)
                    .lineLimit(1)
                if let version = appState.selectedVersion {
                    StatusBadge(
                        text: appState.isInstalled(version.id) ? "已安装" : "未安装",
                        tone: appState.isInstalled(version.id) ? .success : .warning
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var launchButton: some View {
        Button {
            appState.handleLaunchTap()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: appState.launchButtonIcon)
                    .font(.system(size: 19, weight: .semibold))
                Text(appState.launchButtonTitle)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 320)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(YZLTheme.accent)
            )
            .shadow(color: YZLTheme.accent.opacity(0.25), radius: 12, x: 0, y: 5)
        }
        .buttonStyle(.plain)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(YZLTheme.success)
                .frame(width: 7, height: 7)
            Text("\(appState.jitStatus.title) · Java \(appState.javaStatus.title) · 引擎 \(appState.engineStatus.title)")
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.muted)
                .lineLimit(1)
        }
    }

    private func ghostButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(YZLTheme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(YZLTheme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(YZLTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// 主页底部安装进度条（仅在安装/失败/取消态显示，保持主页干净）。
    private struct InstallProgressBanner: View {
        @ObservedObject var queue: DownloadQueue
        var openVersions: () -> Void

        var body: some View {
            switch queue.state.phase {
            case .running:
                YZLCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("正在安装 \(queue.state.batchID ?? "版本")")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(YZLTheme.text)
                            Spacer()
                            Text("\(queue.state.doneFiles)/\(queue.state.totalFiles)")
                                .font(.system(size: 10))
                                .foregroundStyle(YZLTheme.muted)
                        }
                        ProgressView(value: queue.state.progress)
                            .tint(YZLTheme.accent)
                        HStack(spacing: 6) {
                            Text("\(InstallFormats.bytes(queue.state.doneBytes)) / \(InstallFormats.bytes(queue.state.totalBytes))")
                            Text("·")
                            Text(InstallFormats.speed(queue.state.speedBytesPerSecond))
                            Spacer()
                            Button("取消") {
                                queue.cancel()
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(YZLTheme.danger)
                            .buttonStyle(.plain)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(YZLTheme.muted)
                    }
                }
            case .failed(let message):
                YZLCard(padding: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(YZLTheme.danger)
                        Text("安装失败：\(message)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(YZLTheme.danger)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("去重试", action: openVersions)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(YZLTheme.accentText)
                            .buttonStyle(.plain)
                    }
                }
            case .cancelled:
                YZLCard(padding: 12) {
                    HStack(spacing: 10) {
                        Text("安装已暂停，已下载的分片会保留。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(YZLTheme.muted)
                        Spacer(minLength: 4)
                        Button("去继续", action: openVersions)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(YZLTheme.accentText)
                            .buttonStyle(.plain)
                    }
                }
            case .idle, .finished:
                EmptyView()
            }
        }
    }
}
