import SwiftUI
import PhotosUI

struct SkinView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showPhotoPicker = false
    @State private var skinErrorMessage: String?
    /// 相册选图的去向：离线账号本地导入，或皮肤站上传。
    @State private var pickerTarget: PhotoTarget = .offlineImport
    @State private var uploadModel = "classic"
    @State private var isYggdrasilBusy = false
    @State private var yggdrasilMessage: String?
    /// 微软账号的皮肤上传 / 披风管理状态。
    @State private var microsoftVariant = "classic"
    @State private var microsoftCapes: [MinecraftCape] = []
    @State private var isLoadingCapes = false
    @State private var isMicrosoftBusy = false
    @State private var microsoftMessage: String?

    /// 相册选图的三条去向。
    private enum PhotoTarget {
        case offlineImport
        case yggdrasilUpload
        case microsoftUpload
    }

    var body: some View {
        ZStack {
            PageBackground()

            VStack(spacing: 0) {
                pageHeader

                ScrollView {
                    VStack(spacing: 14) {
                        if let account = appState.displayAccount {
                            accountCard(account)
                            if appState.activeYggdrasilAccount != nil {
                                yggdrasilSkinCard
                            }
                            if appState.account != nil,
                               appState.activeYggdrasilAccount == nil,
                               appState.activeOfflineAccount == nil {
                                microsoftSkinCard
                            }
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
                handlePickedImage(image)
            }
            .ignoresSafeArea()
        }
    }

    /// 相册选图按入口分流：皮肤站卡发起 → 上传皮肤站；微软卡发起 → 上传微软；
    /// 离线卡发起 → 本地导入。
    private func handlePickedImage(_ image: UIImage) {
        switch pickerTarget {
        case .yggdrasilUpload:
            uploadSkinToYggdrasil(image)
        case .microsoftUpload:
            uploadSkinToMicrosoft(image)
        case .offlineImport:
            importSkin(image)
        }
    }

    // MARK: - 微软账号（Mojang 官方皮肤 / 披风，对照 Windows 端 MinecraftSkinService）

    private var microsoftSkinCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("微软皮肤与披风")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                Text("直接上传皮肤到 Mojang 官方档案、恢复默认皮肤，或更换披风；改动会同步到所有平台。")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                Picker("模型", selection: $microsoftVariant) {
                    Text("Steve（经典）").tag("classic")
                    Text("Alex（纤细）").tag("slim")
                }
                .pickerStyle(.segmented)
                .disabled(isMicrosoftBusy)

                HStack(spacing: 10) {
                    Button {
                        pickerTarget = .microsoftUpload
                        skinErrorMessage = nil
                        microsoftMessage = nil
                        showPhotoPicker = true
                    } label: {
                        Label("上传皮肤", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: true))
                    .disabled(isMicrosoftBusy)

                    Button {
                        resetMicrosoftSkin()
                    } label: {
                        Text("恢复默认")
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                    .disabled(isMicrosoftBusy)
                }

                capeSection

                if let message = microsoftMessage {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(YZLTheme.text)
                        .lineSpacing(3)
                }
            }
        }
        .task {
            await loadMicrosoftProfile()
        }
    }

    @ViewBuilder
    private var capeSection: some View {
        if isLoadingCapes {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在读取披风列表…")
                    .font(.system(size: 11))
                    .foregroundStyle(YZLTheme.muted)
            }
        } else if microsoftCapes.isEmpty {
            Text("这个账号还没有披风。")
                .font(.system(size: 11))
                .foregroundStyle(YZLTheme.lightMuted)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("披风")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)
                ForEach(microsoftCapes) { cape in
                    capeRow(cape)
                }
            }
        }
    }

    private func capeRow(_ cape: MinecraftCape) -> some View {
        HStack(spacing: 10) {
            if let url = cape.url.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    // phase.image 是 SwiftUI.Image，直接用（AvatarView 的踩坑记录）。
                    if let image = phase.image {
                        image
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(height: 40)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
                .frame(width: 32)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(cape.alias ?? cape.id)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(YZLTheme.text)
                Text(cape.isActive ? "正在装备" : "未装备")
                    .font(.system(size: 10))
                    .foregroundStyle(YZLTheme.muted)
            }

            Spacer()

            Button(cape.isActive ? "取消装备" : "装备") {
                toggleCape(cape)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(cape.isActive ? YZLTheme.danger : YZLTheme.accentText)
            .buttonStyle(.plain)
            .disabled(isMicrosoftBusy)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(YZLTheme.field)
        )
    }

    private func loadMicrosoftProfile() async {
        guard let token = await appState.microsoftTokenForProfileActions() else {
            microsoftMessage = "登录已过期，请到「账号」重新登录。"
            return
        }
        isLoadingCapes = true
        defer { isLoadingCapes = false }
        do {
            let profile = try await MicrosoftProfileService().fetchProfile(token: token)
            microsoftCapes = profile.capes
            appState.applyMicrosoftProfile(skinURL: profile.skinURL)
        } catch {
            microsoftMessage = error.localizedDescription
        }
    }

    private func uploadSkinToMicrosoft(_ image: UIImage) {
        guard let png = image.pngData() else {
            microsoftMessage = "无法把所选图片转成 PNG。"
            return
        }
        runMicrosoftAction("皮肤已上传到 Mojang 档案。") { token, service in
            try await service.uploadSkin(token: token, pngData: png, variant: microsoftVariant)
        }
    }

    private func resetMicrosoftSkin() {
        runMicrosoftAction("已恢复为微软默认皮肤。") { token, service in
            try await service.resetSkin(token: token)
        }
    }

    private func toggleCape(_ cape: MinecraftCape) {
        runMicrosoftAction(cape.isActive ? "已隐藏披风。" : "已装备披风 \(cape.alias ?? cape.id)。") { token, service in
            if cape.isActive {
                try await service.hideCape(token: token)
            } else {
                try await service.equipCape(token: token, capeID: cape.id)
            }
        }
    }

    /// 微软档案操作的统一骨架：拿保活令牌 → 执行 → 刷新档案（皮肤 URL + 披风列表）。
    private func runMicrosoftAction(_ successMessage: String,
                                    _ action: @escaping (String, MicrosoftProfileService) async throws -> Void) {
        guard !isMicrosoftBusy else { return }
        isMicrosoftBusy = true
        microsoftMessage = nil
        Task { @MainActor in
            defer { isMicrosoftBusy = false }
            guard let token = await appState.microsoftTokenForProfileActions() else {
                microsoftMessage = "登录已过期，请到「账号」重新登录。"
                return
            }
            let service = MicrosoftProfileService()
            do {
                try await action(token, service)
                let profile = try await service.fetchProfile(token: token)
                microsoftCapes = profile.capes
                appState.applyMicrosoftProfile(skinURL: profile.skinURL)
                microsoftMessage = successMessage
            } catch {
                microsoftMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 皮肤站账号（Yggdrasil 上传 / 重置 / 披风）

    private var yggdrasilSkinCard: some View {
        YZLCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("皮肤站皮肤")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YZLTheme.text)

                if let skin = appState.activeYggdrasilAccount {
                    Text("当前皮肤站账号：\(skin.name) · \(skin.serverHost)。皮肤与披风从皮肤站 sessionserver 同步，也可以在这里上传或重置。")
                        .font(.system(size: 11))
                        .foregroundStyle(YZLTheme.muted)
                        .lineSpacing(3)

                    HStack(spacing: 10) {
                        Button {
                            pickerTarget = .yggdrasilUpload
                            skinErrorMessage = nil
                            yggdrasilMessage = nil
                            showPhotoPicker = true
                        } label: {
                            Label("上传皮肤", systemImage: "photo.on.rectangle.angled")
                        }
                        .buttonStyle(PrimaryButtonStyle(prominent: true))
                        .disabled(isYggdrasilBusy)

                        Button {
                            resetYggdrasilSkin()
                        } label: {
                            Text("重置默认")
                        }
                        .buttonStyle(PrimaryButtonStyle(prominent: false))
                        .disabled(isYggdrasilBusy)
                    }

                    Picker("模型", selection: $uploadModel) {
                        Text("Steve（经典）").tag("classic")
                        Text("Alex（纤细）").tag("slim")
                    }
                    .pickerStyle(.segmented)
                    .disabled(isYggdrasilBusy)

                    if let cape = skin.capeURL, let url = URL(string: cape) {
                        HStack(spacing: 10) {
                            Text("披风")
                                .font(.system(size: 12))
                                .foregroundStyle(YZLTheme.text)
                            Spacer()
                            AsyncImage(url: url) { phase in
                                // phase.image 是 SwiftUI.Image，直接用（AvatarView 的踩坑记录）。
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .interpolation(.none)
                                        .scaledToFit()
                                        .frame(height: 64)
                                } else {
                                    ProgressView()
                                        .frame(height: 64)
                                }
                            }
                            .frame(width: 52)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(YZLTheme.field)
                        )
                    }

                    if let message = yggdrasilMessage {
                        Text(message)
                            .font(.system(size: 10.5))
                            .foregroundStyle(YZLTheme.text)
                            .lineSpacing(3)
                    }
                }
            }
        }
    }

    private func uploadSkinToYggdrasil(_ image: UIImage) {
        guard let skin = appState.activeYggdrasilAccount else {
            yggdrasilMessage = "请先在账号里选择一个皮肤站账号。"
            return
        }
        guard let token = YggdrasilSessionStore().load(accountID: skin.id)?.accessToken, !token.isEmpty else {
            yggdrasilMessage = "皮肤站登录已失效，请到「账号」重新登录。"
            return
        }
        guard let png = image.pngData() else {
            yggdrasilMessage = "无法把所选图片转成 PNG。"
            return
        }

        isYggdrasilBusy = true
        yggdrasilMessage = nil
        let service = YggdrasilAuthService()
        Task { @MainActor in
            do {
                try await service.uploadSkin(
                    server: skin.serverURL,
                    rawUUID: skin.rawUUID,
                    accessToken: token,
                    model: uploadModel,
                    imageData: png
                )
                if let textures = await service.fetchTextures(server: skin.serverURL, rawUUID: skin.rawUUID) {
                    appState.updateYggdrasilAccount(skin.updatingTextures(textures))
                }
                yggdrasilMessage = "皮肤已上传并重新同步。"
            } catch {
                yggdrasilMessage = error.localizedDescription
            }
            isYggdrasilBusy = false
        }
    }

    private func resetYggdrasilSkin() {
        guard let skin = appState.activeYggdrasilAccount else { return }
        guard let token = YggdrasilSessionStore().load(accountID: skin.id)?.accessToken, !token.isEmpty else {
            yggdrasilMessage = "皮肤站登录已失效，请到「账号」重新登录。"
            return
        }

        isYggdrasilBusy = true
        yggdrasilMessage = nil
        let service = YggdrasilAuthService()
        Task { @MainActor in
            do {
                try await service.resetSkin(server: skin.serverURL, rawUUID: skin.rawUUID, accessToken: token)
                if let textures = await service.fetchTextures(server: skin.serverURL, rawUUID: skin.rawUUID) {
                    appState.updateYggdrasilAccount(skin.updatingTextures(textures))
                }
                yggdrasilMessage = "已重置为皮肤站默认皮肤。"
            } catch {
                yggdrasilMessage = error.localizedDescription
            }
            isYggdrasilBusy = false
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
                    pickerTarget = .offlineImport
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
                Text(noticeText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(YZLTheme.muted)
                    .lineSpacing(3)

                if appState.activeOfflineAccount == nil, appState.activeYggdrasilAccount == nil,
                   appState.displayAccount != nil {
                    Link(destination: URL(string: "https://www.minecraft.net/profile")!) {
                        Text("打开 minecraft.net 皮肤设置")
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                }
            }
        }
    }

    private var noticeText: String {
        if appState.activeYggdrasilAccount != nil {
            return "皮肤站账号的皮肤从皮肤站 sessionserver 同步，可在这里上传 / 重置；联机时由 authlib 认证服务器读取。"
        }
        if appState.activeOfflineAccount != nil {
            return "皮肤只在 Mojang 档案或本机里读取；离线账号的本地皮肤不会上传。"
        }
        return "皮肤与披风从 Mojang 档案读取，也可以直接在这里上传 / 更换，改动对所有平台生效。"
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

    /// 按当前账号类型说明皮肤来源（与账号页三源一一对应）。
    private func skinSourceText(for account: MicrosoftAccount) -> String {
        if appState.activeYggdrasilAccount != nil { return "皮肤来源：皮肤站 sessionserver" }
        if appState.activeOfflineAccount != nil { return "皮肤来源：本机导入或默认占位" }
        return "皮肤来源：Mojang 档案"
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
                    Text(skinSourceText(for: account))
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

    // 3D 皮肤预览已按需求移除；皮肤效果直接看主页大头像（PCL 风格 2D）。

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
