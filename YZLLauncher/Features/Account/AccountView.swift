import SwiftUI
import UIKit

struct AccountView: View {
    @EnvironmentObject private var appState: AppState
    let onBack: () -> Void
    @State private var showSignOutConfirm = false
    @State private var showOfflineCreate = false

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
                        offlineSection
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
        .sheet(isPresented: $showOfflineCreate) {
            OfflineCreateSheet()
                .environmentObject(appState)
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
                if microsoftIsActive {
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
                } else {
                    Button {
                        if let id = appState.account?.id {
                            appState.selectActiveAccount(id: id)
                        }
                    } label: {
                        Text("设为当前启动")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(YZLTheme.accentText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(YZLTheme.accentSoft)
                            )
                    }
                    .buttonStyle(.plain)
                }

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
                    Text("登录微软账户后，启动器会读取 Minecraft: Java Edition 档案。没有正版账号也能玩：在下方「离线账号」里添加一个，即可下载并单机启动。")
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

    private var microsoftIsActive: Bool {
        guard let id = appState.account?.id else { return false }
        return appState.activeAccountID == id
    }

    private var offlineSection: some View {
        YZLCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("离线账号（伪正版）")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(YZLTheme.text)
                    Spacer()
                    Button {
                        showOfflineCreate = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                    .frame(height: 32)
                }

                Text("不需要微软账号，用固定离线 UUID 直接进入单机 / 局域网。在线正版服务器会拒绝，属预期。")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(4)

                if appState.offlineAccounts.isEmpty {
                    Text("还没有离线账号。点「添加」创建一个，例如 Steve、Alex。")
                        .font(.system(size: 12))
                        .foregroundStyle(YZLTheme.lightMuted)
                        .padding(.vertical, 4)
                } else {
                    ForEach(appState.offlineAccounts) { off in
                        offlineRow(off)
                    }
                }
            }
        }
    }

    private func offlineRow(_ off: OfflineAccount) -> some View {
        let isActive = appState.activeAccountID == off.id
        return HStack(spacing: 12) {
            AvatarView(size: 42, account: off.asMicrosoftAccount)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(off.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                    if isActive {
                        StatusBadge(text: "当前", tone: .success)
                    }
                }
                Text(off.skinModel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            if !isActive {
                Button {
                    appState.selectActiveAccount(id: off.id)
                } label: {
                    Text("使用")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
                .frame(width: 64, height: 34)
            }
            Button {
                appState.removeOfflineAccount(id: off.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(YZLTheme.danger)
            }
            .buttonStyle(.plain)
            .frame(width: 34, height: 34)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(YZLTheme.field)
        )
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

// MARK: - 离线账号创建

private struct OfflineCreateSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var skinModel = "steve"
    @State private var customSkinURL = ""

    private let models = ["steve", "alex", "custom"]

    var body: some View {
        NavigationView {
            Form {
                Section("角色名") {
                    TextField("例如 Steve / Alex / 你的名字", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("皮肤模型") {
                    Picker("皮肤模型", selection: $skinModel) {
                        ForEach(models, id: \.self) { model in
                            Text(modelLabel(model)).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)
                    if skinModel == "custom" {
                        TextField("皮肤贴图 URL（可选）", text: $customSkinURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                Section {
                    Text("离线账号用固定算法从角色名算出 UUID，单机 / 局域网直接进入。无需微软账号，但无法进入在线正版服务器。")
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                        .lineSpacing(4)
                }
            }
            .navigationTitle("添加离线账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func modelLabel(_ model: String) -> String {
        switch model {
        case "steve": return "Steve"
        case "alex": return "Alex"
        default: return "自定义"
        }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let url: String? = skinModel == "custom" ? customSkinURL.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        appState.createOfflineAccount(name: trimmedName, skinModel: skinModel, skinURL: url)
        dismiss()
    }
}
