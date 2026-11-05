import SwiftUI

struct SkinView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            PageBackground()

            VStack(spacing: 0) {
                pageHeader

                ScrollView {
                    VStack(spacing: 14) {
                        if let account = appState.displayAccount {
                            accountCard(account)
                            skinCard(account)
                            noticeCard
                        } else {
                            emptyCard
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("皮肤")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(YZLTheme.text)
                Text("读取当前账号的皮肤与纹理 URL")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
            Spacer()
            Button {
                appState.overlay = .account
            } label: {
                Text("账号")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: false))
            .frame(width: 74)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(YZLTheme.page.opacity(0.96))
    }

    private func accountCard(_ account: MicrosoftAccount) -> some View {
        YZLCard {
            HStack(spacing: 14) {
                AvatarView(size: 58, account: account)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(account.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(YZLTheme.text)
                        StatusBadge(text: "当前", tone: .success)
                    }
                    Text("皮肤来源：Mojang 档案")
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.muted)
                    Text(account.skinURL ?? "当前账号没有皮肤 URL")
                        .font(.system(size: 10))
                        .foregroundStyle(YZLTheme.lightMuted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
            }
        }
    }

    private func skinCard(_ account: MicrosoftAccount) -> some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("皮肤预览")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                HStack(alignment: .top, spacing: 20) {
                    SkinBodyView(size: 156, account: account)
                        .frame(width: 156, height: 156)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(YZLTheme.border, lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.045), radius: 8, x: 0, y: 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("这是从 Mojang 档案里读到的 64×64 皮肤贴图。")
                            .font(.system(size: 11))
                            .foregroundStyle(YZLTheme.muted)
                            .lineSpacing(3)
                        Text("启动内核接入后，M2 会把它用到 Amethyst 的皮肤渲染层。")
                            .font(.system(size: 10))
                            .foregroundStyle(YZLTheme.lightMuted)
                            .lineSpacing(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var noticeCard: some View {
        YZLCard {
            Text("皮肤只在 Mojang 档案里读取；启动器本身不上传或修改皮肤。")
                .font(.system(size: 10.5))
                .foregroundStyle(YZLTheme.muted)
                .lineSpacing(3)
        }
    }

    private var emptyCard: some View {
        YZLCard(padding: 22) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(YZLTheme.accentSoft)
                    Image(systemName: "person.crop.rectangle.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(YZLTheme.accent.opacity(0.6))
                }
                .frame(width: 68, height: 68)

                VStack(alignment: .leading, spacing: 5) {
                    Text("还没有登录账号")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(YZLTheme.text)
                    Text("登录微软账号后，皮肤页会显示每个账号的皮肤贴图。")
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                }

                Spacer()

                Button {
                    appState.overlay = .account
                } label: {
                    Text("打开账号管理")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                .frame(width: 150)
            }
        }
    }
}
