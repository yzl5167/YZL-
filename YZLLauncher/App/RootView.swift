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
        .background(YZLTheme.page)
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
        VStack(spacing: 0) {
            brand
                .padding(.top, 16)
                .padding(.bottom, 18)

            VStack(spacing: 4) {
                railButton(icon: "house.fill", label: "首页", tab: .home)
                railButton(icon: "square.stack.3d.up.fill", label: "版本", tab: .versions)
                railButton(icon: "person.circle.fill", label: "皮肤", tab: .skin)
                railButton(icon: "gearshape.fill", label: "设置", tab: .settings)
            }

            Spacer(minLength: 12)

            accountButton
                .padding(.bottom, 8)

            Button {
                appState.overlay = .about
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 30)
                    Text("关于")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(appState.overlay == .about ? YZLTheme.accent : YZLTheme.muted)
                .frame(width: 64)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(appState.overlay == .about ? YZLTheme.accentSoft : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
        }
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea(edges: [.top, .bottom]))
    }

    private var brand: some View {
        VStack(spacing: 5) {
            YzlLogoMark(size: 42)
            Text("YZL")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(YZLTheme.muted)
        }
    }

    private func railButton(icon: String, label: String, tab: AppTab) -> some View {
        let selected = appState.selectedTab == tab && appState.overlay == nil
        return Button {
            appState.overlay = nil
            appState.selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 30)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(selected ? YZLTheme.accent : YZLTheme.muted)
            .frame(width: 64)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? YZLTheme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var accountButton: some View {
        Button {
            appState.overlay = .account
        } label: {
            VStack(spacing: 4) {
                AvatarView(size: 38, account: appState.displayAccount)

                Text(appState.displayAccount?.name ?? "未登录")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(appState.overlay == .account ? YZLTheme.accentText : YZLTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 64)
            }
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appState.overlay == .account ? YZLTheme.accentSoft : Color.clear)
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
