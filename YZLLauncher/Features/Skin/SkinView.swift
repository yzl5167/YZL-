import SwiftUI
import PhotosUI

struct SkinView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showPhotoPicker = false
    @State private var skinErrorMessage: String?

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
                            if appState.activeOfflineAccount != nil {
                                offlineSkinCard(account)
                            }
                            noticeCard
                        } else {
                            emptyCard
                        }
                        if let message = skinErrorMessage {
                            Text(message)
                                .font(.system(size: 10.5))
                                .foregroundStyle(YZLTheme.danger)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: 1000, alignment: .leading)
                                .padding(.horizontal, 26)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            SkinPhotoPicker { image in
                importSkin(image)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - 离线皮肤导入（对照 Android 端 SkinScreen 的本地导入）

    private func offlineSkinCard(_ account: MicrosoftAccount) -> some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("离线皮肤（本地导入）")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(YZLTheme.text)
                    Spacer()
                    if hasLocalSkin(account) {
                        Button("恢复默认") {
                            removeLocalSkin(account)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(YZLTheme.danger)
                        .buttonStyle(.plain)
                    }
                }

                Text("从相册选一张皮肤贴图（64×32 / 64×64 / 128×64 / 128×128），只保存在本机，启动离线游戏时生效。皮肤站 / 微软账号的皮肤请走对应渠道。")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                Button {
                    skinErrorMessage = nil
                    showPhotoPicker = true
                } label: {
                    Label("从相册导入皮肤", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var hasLocalSkin: (MicrosoftAccount) -> Bool {
        { account in
            guard let raw = account.skinURL,
                  let url = URL(string: raw),
                  url.scheme?.lowercased() == LocalSkinStore.scheme else { return false }
            return LocalSkinStore().load(from: url) != nil
        }
    }

    private func importSkin(_ image: UIImage) {
        guard let offline = appState.activeOfflineAccount else {
            skinErrorMessage = "请先在账号里选择一个离线账号。"
            return
        }
        do {
            let reference = try LocalSkinStore().save(image: image, accountID: offline.id)
            appState.setOfflineSkin(accountID: offline.id, skinURL: reference)
            skinErrorMessage = nil
        } catch {
            skinErrorMessage = error.localizedDescription
        }
    }

    private func removeLocalSkin(_ account: MicrosoftAccount) {
        guard let offline = appState.activeOfflineAccount else { return }
        LocalSkinStore().remove(accountID: offline.id)
        appState.setOfflineSkin(accountID: offline.id, skinURL: nil)
    }

    // MARK: - 微软账号官方引导

    private var noticeCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(appState.activeOfflineAccount != nil
                     ? "皮肤只在 Mojang 档案或本机里读取；离线账号的本地皮肤不会上传。"
                     : "皮肤只在 Mojang 档案里读取；启动器本身不上传或修改皮肤。微软账号请到官网更换。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                if appState.activeOfflineAccount == nil, appState.displayAccount != nil {
                    Link(destination: URL(string: "https://www.minecraft.net/profile")!) {
                        Text("打开 minecraft.net 皮肤设置")
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
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
                        Text(appState.activeOfflineAccount != nil
                             ? "这是当前离线账号的皮肤贴图（本地导入或默认占位）。"
                             : "这是从 Mojang 档案里读到的 64×64 皮肤贴图。")
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

// MARK: - 相册选图（PHPicker 包装）

/// 单选皮肤贴图的相册选择器。授权由系统 PHPicker 处理，无需 Info.plist 相册权限。
private struct SkinPhotoPicker: UIViewControllerRepresentable {
    var onPicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (UIImage) -> Void

        init(onPicked: @escaping (UIImage) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { [onPicked] object, _ in
                guard let image = object as? UIImage else { return }
                Task { @MainActor in
                    onPicked(image)
                }
            }
        }
    }
}
