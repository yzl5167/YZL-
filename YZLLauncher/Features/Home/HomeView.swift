import SwiftUI

/// 主页：仿 PC 端「安卓式主页」——白底、内容垂直居中，只有大头像、当前版本和启动按钮。
/// 结构与 PC `MainWindow.xaml` 的活跃主页、安卓 `HomeScreen` 完全一致：
/// PCL 风格 2D 大头像（无底板灰描边）→ 玩家名 → 账号类型 → 当前版本行 →
/// 大启动按钮 → 状态行 → 「版本管理 / 下载游戏」两枚幽灵按钮（宽 300）。
/// 安装进度已统一交给全局 InstallOverlay，这里不再放横幅。
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingServers = false
    @State private var homeServers: [MinecraftServer] = []

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                YZLTheme.card
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 12)
                        centered
                        Spacer(minLength: 12)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var centered: some View {
        VStack(spacing: 0) {
            avatar
                .padding(.top, 4)

            Text(appState.displayAccount?.name ?? "未登录")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(YZLTheme.text)
                .lineLimit(1)
                .padding(.top, 4)

            Text(accountTypeText)
                .font(.system(size: 10))
                .foregroundStyle(YZLTheme.muted)
                .padding(.top, 1)

            versionRow
                .padding(.top, 16)

            launchButton
                .padding(.top, 12)

            statusLine
                .padding(.top, 10)

            HStack(spacing: 10) {
                ghostButton("版本管理") {
                    appState.overlay = nil
                    appState.selectedTab = .versions
                }
                ghostButton("下载游戏") {
                    appState.overlay = nil
                    appState.selectedTab = .download
                }
            }
            .frame(width: 300)
            .padding(.top, 10)

            serverSection
                .padding(.top, 14)
        }
        .sheet(isPresented: $showingServers) {
            ServerListView()
        }
    }

    /// 账号类型文案（对齐 Android 端 typeText：微软账号 / 皮肤站账号 / 离线账号）。
    private var accountTypeText: String {
        guard appState.displayAccount != nil else { return "点击头像登录账号" }
        if appState.isOfflineLaunch { return "离线账号" }
        if appState.isYggdrasilLaunch { return "皮肤站账号" }
        return "微软账号"
    }

    private var avatar: some View {
        Button {
            appState.overlay = .account
        } label: {
            ZStack(alignment: .bottomTrailing) {
                // 微软账号没皮肤时按 PC 端规则借用同名皮肤站账号的材质；
                // 离线账号的默认皮肤按创建时选的模型（Steve / Alex）。
                PclAvatarView(
                    size: 140,
                    account: appState.displayAccountWithSkinFallback,
                    defaultModel: appState.activeOfflineAccount?.skinModel ?? "steve"
                )
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
                    .font(.system(size: 11))
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
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 300)
            .frame(height: 52)
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

    /// 联机：首页服务器收藏卡片（对齐 PC 端 MainWindow.Multiplayer 的服务器列表入口）。
    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .foregroundStyle(YZLTheme.accent)
                Text("联机")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Spacer()
                Button {
                    showingServers = true
                } label: {
                    Text("管理")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(YZLTheme.accentText)
                }
            }
            if homeServers.isEmpty {
                Text("还没有收藏服务器，点「管理」添加。")
                    .font(.system(size: 12))
                    .foregroundStyle(YZLTheme.muted)
            } else {
                ForEach(homeServers.prefix(3)) { server in
                    HStack(spacing: 8) {
                        Image(systemName: server.isFavorite ? "star.fill" : "server.rack")
                            .foregroundStyle(server.isFavorite ? YZLTheme.warningText : YZLTheme.muted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(YZLTheme.text)
                            Text(server.connectAddress)
                                .font(.system(size: 11))
                                .foregroundStyle(YZLTheme.muted)
                        }
                        Spacer()
                        Button {
                            appState.joinServer(server)
                        } label: {
                            Text("加入")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(YZLTheme.accent)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: YZLTheme.cardCorner, style: .continuous)
                .fill(YZLTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: YZLTheme.cardCorner, style: .continuous)
                .stroke(YZLTheme.border, lineWidth: 1)
        )
        .onAppear { homeServers = ServerListStore().load() }
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
}
