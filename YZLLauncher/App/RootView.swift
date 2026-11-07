import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            YZLSidebar()
                .zIndex(1)

            Rectangle()
                .fill(YZLTheme.border)
                .frame(width: 1)
                .zIndex(1)

            ZStack {
                content
                overlayContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(appState.selectedTab == .home && appState.overlay == nil ? Color.white : YZLTheme.page)
            .animation(.easeInOut(duration: 0.22), value: appState.overlay)
            .animation(.easeInOut(duration: 0.18), value: appState.selectedTab)
        }
        // 只让背景延伸到屏幕边缘；HStack 的内容仍留在安全区内，
        // 避免横屏下刘海侧的图标被遮住。
        .background(YZLTheme.page.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sheet(isPresented: $appState.isLaunchSheetVisible, onDismiss: {
            if appState.launchPhase != .running {
                appState.launchPhase = .idle
            }
        }) {
            LaunchSheet()
                .environmentObject(appState)
                .yzlLargeSheet()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.selectedTab {
        case .home:
            HomeView()
        case .versions:
            VersionsView()
        case .skin:
            SkinView()
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch appState.overlay {
        case .account:
            AccountView {
                appState.overlay = nil
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        case .about:
            VStack(spacing: 0) {
                OverlayHeader(title: "关于", subtitle: "YZL Launcher iOS") {
                    appState.overlay = nil
                }
                AboutView()
            }
            .background(PageBackground())
            .transition(.move(edge: .trailing).combined(with: .opacity))
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Sidebar

private struct YZLSidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { proxy in
            // iPhone 横屏可用高度只有 320–390pt：品牌 + 4 个导航 + 账号 + 关于
            // 一共接近 470pt，旧布局会把最上面的「YZL」挤出屏幕。
            // 小屏切紧凑尺寸，中间导航改成可滚动，品牌和底部入口永远可见。
            let compact = proxy.size.height < 430

            VStack(spacing: 0) {
                brand(compact: compact)
                    .padding(.top, compact ? 8 : 14)
                    .padding(.bottom, compact ? 8 : 14)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: compact ? 2 : 4) {
                        railButton(icon: "house.fill", label: "首页", tab: .home, compact: compact)
                        railButton(icon: "square.stack.3d.up.fill", label: "版本", tab: .versions, compact: compact)
                        railButton(icon: "person.circle.fill", label: "皮肤", tab: .skin, compact: compact)
                        railButton(icon: "gearshape.fill", label: "设置", tab: .settings, compact: compact)
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: .infinity)

                accountButton(compact: compact)
                    .padding(.bottom, compact ? 2 : 6)

                aboutButton(compact: compact)
                    .padding(.bottom, compact ? 8 : 14)
            }
            .frame(width: 84)
            .frame(maxHeight: .infinity)
        }
        .frame(width: 84)
        // 固定横屏时 safe area 主要落在 leading/trailing（刘海侧）与 bottom，
        // 只忽略 top/bottom 会让白色侧栏铺不到左右边缘，露出一条底色。
        .background(Color.white.ignoresSafeArea())
    }

    private func brand(compact: Bool) -> some View {
        VStack(spacing: compact ? 3 : 5) {
            YzlLogoMark(size: compact ? 34 : 42)
            Text("YZL")
                .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(YZLTheme.text.opacity(0.72))
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityLabel("YZL Launcher")
    }

    private func railButton(icon: String, label: String, tab: AppTab, compact: Bool) -> some View {
        let selected = appState.selectedTab == tab && appState.overlay == nil
        return Button {
            appState.overlay = nil
            appState.selectedTab = tab
        } label: {
            VStack(spacing: compact ? 3 : 4) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 18 : 20, weight: .medium))
                    .frame(width: 44, height: compact ? 26 : 30)
                Text(label)
                    .font(.system(size: compact ? 9.5 : 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? YZLTheme.accent : YZLTheme.muted)
            .frame(width: 64)
            .padding(.vertical, compact ? 4 : 5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? YZLTheme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func accountButton(compact: Bool) -> some View {
        Button {
            appState.overlay = .account
        } label: {
            VStack(spacing: compact ? 3 : 4) {
                AvatarView(size: compact ? 32 : 38, account: appState.displayAccount)

                Text(appState.displayAccount?.name ?? "未登录")
                    .font(.system(size: compact ? 9 : 9.5, weight: .medium))
                    .foregroundStyle(appState.overlay == .account ? YZLTheme.accentText : YZLTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.8)
                    .frame(width: 64)
            }
            .padding(.vertical, compact ? 4 : 5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appState.overlay == .account ? YZLTheme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func aboutButton(compact: Bool) -> some View {
        Button {
            appState.overlay = .about
        } label: {
            VStack(spacing: compact ? 3 : 4) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: compact ? 18 : 20, weight: .medium))
                    .frame(width: 44, height: compact ? 26 : 30)
                Text("关于")
                    .font(.system(size: compact ? 9.5 : 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(appState.overlay == .about ? YZLTheme.accent : YZLTheme.muted)
            .frame(width: 64)
            .padding(.vertical, compact ? 4 : 5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appState.overlay == .about ? YZLTheme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Overlay header

struct OverlayHeader: View {
    let title: String
    var subtitle: String?
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}
