import SwiftUI
import UIKit

struct AccountView: View {
    @EnvironmentObject private var appState: AppState
    let onBack: () -> Void
    @State private var showSignOutConfirm = false

    var body: some View {
        ZStack {
            PageBackground()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 14) {
                        if appState.account != nil {
                            accountCard
                        } else {
                            emptyCard
                        }
                        privacyCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $appState.isAuthSheetVisible, onDismiss: {
            appState.cancelSignIn()
        }) {
            LoginSheet()
                .environmentObject(appState)
        }
        .alert("退出登录？", isPresented: $showSignOutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) {
                appState.signOut()
            }
        } message: {
            Text("本机 Keychain 中保存的微软登录令牌会被删除。")
        }
    }

    private var header: some View {
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
                Text("账号管理")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text("微软正版账号 · 设备码登录")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }

            Spacer()

            if appState.account == nil {
                Button {
                    appState.startSignIn()
                } label: {
                    Text("登录账号")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                .frame(width: 118)
            } else {
                Button {
                    showSignOutConfirm = true
                } label: {
                    Text("退出登录")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
                .frame(width: 100)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var accountCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AvatarView(size: 58, account: appState.account)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(appState.account?.name ?? "")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(YZLTheme.text)
                        StatusBadge(text: "当前", tone: .success)
                    }
                    HStack(spacing: 8) {
                        Text("微软正版账号")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(YZLTheme.accentText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(YZLTheme.accentSoft))
                        Text(shortUUID)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(YZLTheme.lightMuted)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(16)

            Rectangle()
                .fill(YZLTheme.border)
                .frame(height: 1)
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                    Text("正在使用")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(YZLTheme.success)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(YZLTheme.successSoft)
                )

                Button {
                    showSignOutConfirm = true
                } label: {
                    Text("退出")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YZLTheme.danger)
                        .frame(width: 78, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(red: 0.996, green: 0.925, blue: 0.925))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(YZLTheme.danger.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(YZLTheme.accent.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 8, x: 0, y: 2)
    }

    private var emptyCard: some View {
        YZLCard(padding: 22) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(YZLTheme.accentSoft)
                    Image(systemName: "person.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(YZLTheme.accent.opacity(0.6))
                }
                .frame(width: 68, height: 68)

                VStack(alignment: .leading, spacing: 5) {
                    Text("还没有登录账号")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(YZLTheme.text)
                    Text("登录微软账户后，启动器会读取 Minecraft: Java Edition 档案。")
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                }

                Spacer()

                Button {
                    appState.startSignIn()
                } label: {
                    Text("登录微软账户")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                .frame(width: 150)
            }
        }
    }

    private var privacyCard: some View {
        YZLCard {
            Text("微软密码不会交给启动器：设备码登录在微软网页完成，只保存 Minecraft 令牌和刷新令牌，均存放在本机 Keychain。")
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.muted)
                .lineSpacing(4)
        }
    }

    private var shortUUID: String {
        guard let id = appState.account?.id, id.count > 13 else {
            return appState.account?.id ?? ""
        }
        return String(id.prefix(13)) + "…"
    }
}

// MARK: - Device code sheet

private struct LoginSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            PageBackground()
            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(YZLTheme.border)
                    .frame(height: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .yzlLargeSheet()
        .interactiveDismissDisabled(appState.authPhase != .idle)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("登录微软账户")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text("设备代码授权 · 不经过第三方服务器")
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            Button {
                appState.cancelSignIn()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YZLTheme.muted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().stroke(YZLTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch appState.authPhase {
        case .requestingCode:
            centeredProgress("正在向微软请求登录代码…")
        case .awaitingUser(let code):
            codeView(code)
        case .exchanging:
            centeredProgress("正在验证 Xbox Live 与 Minecraft 档案…")
        case .failed(let message):
            failureView(message)
        case .idle:
            centeredProgress("准备登录…")
        }
    }

    private func centeredProgress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(YZLTheme.muted)
        }
        .padding(40)
    }

    private func codeView(_ code: DeviceCode) -> some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                Text("在浏览器中完成授权")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                Text("用手机或电脑打开下面的链接，输入右侧代码，并登录你自己的微软账户。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(4)

                Button {
                    if let url = URL(string: code.verificationUri) {
                        openURL(url)
                    }
                } label: {
                    Text("打开浏览器授权")
                }
                .buttonStyle(PrimaryButtonStyle())

                Text(code.verificationUri)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(YZLTheme.accentText)
                    .textSelection(.enabled)

                Spacer(minLength: 0)

                Text("登录完成后会自动返回账号页。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(YZLTheme.lightMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                VStack(spacing: 6) {
                    Text("登录代码")
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                    Text(code.userCode)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(YZLTheme.text)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(YZLTheme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(YZLTheme.border, lineWidth: 1)
                )

                Button {
                    UIPasteboard.general.string = code.userCode
                } label: {
                    Text("复制代码")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))

                HStack(spacing: 7) {
                    ProgressView()
                    Text("等待你在浏览器中完成授权…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(YZLTheme.warningText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(YZLTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button("重试") {
                    appState.startSignIn()
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("关闭") {
                    appState.cancelSignIn()
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
            .frame(maxWidth: 380)
        }
        .padding(32)
    }
}
