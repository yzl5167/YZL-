import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    avatar
                        .padding(.top, 14)

                    Text(appState.account?.name ?? "未登录")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(YZLTheme.text)
                        .padding(.top, 10)

                    Text(appState.account == nil ? "微软账户 · 点击头像登录" : "微软正版账号")
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                        .padding(.top, 3)

                    versionRow
                        .padding(.top, 13)

                    launchButton
                        .padding(.top, 11)

                    HStack(spacing: 12) {
                        secondaryButton("版本管理", icon: "square.stack.3d.up.fill") {
                            appState.selectedTab = .versions
                        }
                        secondaryButton(
                            appState.currentInstall == nil ? "下载游戏" : "启动自检",
                            icon: appState.currentInstall == nil ? "arrow.down.circle.fill" : "checkmark.shield.fill"
                        ) {
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
                    .padding(.top, 10)

                    installBanner
                        .padding(.top, 10)

                    statusRow
                        .padding(.top, 12)

                    Spacer(minLength: 24)
                }
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var avatar: some View {
        Button {
            appState.overlay = .account
        } label: {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(size: 120, account: appState.account)

                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 20))
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
            HStack(spacing: 10) {
                Image("GrassBlock")
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 34, height: 34)

                Text("当前版本")
                    .font(.system(size: 13))
                    .foregroundStyle(YZLTheme.muted)

                Text(appState.selectedVersion?.id ?? "未选择")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                    .lineLimit(1)

                if let version = appState.selectedVersion {
                    StatusBadge(
                        text: appState.isInstalled(version.id) ? "已安装" : "未安装",
                        tone: appState.isInstalled(version.id) ? .success : .warning
                    )
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(YZLTheme.lightMuted)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(YZLTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(YZLTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var launchButton: some View {
        Button {
            appState.handleLaunchTap()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: appState.launchButtonIcon)
                    .font(.system(size: 18, weight: .semibold))
                Text(appState.launchButtonTitle)
                    .font(.system(size: 18, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(YZLTheme.accent)
            )
            .shadow(color: YZLTheme.accent.opacity(0.22), radius: 12, x: 0, y: 5)
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(YZLTheme.accentText)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(YZLTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(YZLTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var installBanner: some View {
        InstallProgressBanner(queue: appState.installQueue) {
            appState.selectedTab = .versions
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusPill("版本", value: appState.currentInstall == nil ? "未安装" : "已安装")
            statusPill("JIT", value: appState.jitStatus.title)
            statusPill("Java", value: appState.javaStatus.title)
            statusPill("引擎", value: appState.engineStatus.title)
        }
    }

    private func statusPill(_ title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(YZLTheme.lightMuted)
            Text(value)
                .foregroundStyle(YZLTheme.muted)
        }
        .font(.system(size: 9.5, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(YZLTheme.field))
    }
}

/// 主页上的安装进度条。单独拆出来是为了让 `@ObservedObject` 订阅队列，
/// 否则只读 `appState.installQueue.state` 不会随进度刷新。
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
