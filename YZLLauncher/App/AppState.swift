import SwiftUI
import Combine
import Foundation
import UIKit

enum AppTab: Hashable {
    case home
    case versions
    case skin
    case settings
}

enum AppOverlay: Equatable {
    case account
    case about
}

enum AuthPhase: Equatable {
    case idle
    case requestingCode
    case awaitingUser(DeviceCode)
    /// 默认公共客户端走 v1.0 授权码流，需要在 WebView 里完成微软登录。
    case browser(URL)
    case exchanging
    case failed(String)
}

enum LaunchPhase: Equatable {
    case idle
    case checking
    case ready
    case launching
    case running
    case failed(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var overlay: AppOverlay?
    @Published var selectedVersion: MinecraftVersion? {
        didSet { persistSelectedVersion() }
    }
    @Published var account: MicrosoftAccount?

    /// 离线（伪正版）账号列表：不需要微软令牌，单人 / LAN 直接进入游戏。
    @Published var offlineAccounts: [OfflineAccount] = []
    /// 皮肤站账号列表（Yggdrasil 协议，对照 Android 端 littleskin 类型）：
    /// 档案存磁盘 JSON，accessToken / clientToken 按账号 id 存 Keychain。
    @Published var yggdrasilAccounts: [YggdrasilAccount] = []
    /// 当前用于显示与启动的账号 id（正版或离线）。nil 表示未选择任何账号。
    @Published var activeAccountID: String?
    @Published var jitStatus: JITStatus = .unknown
    @Published var javaStatus: JavaRuntimeStatus = .missing
    @Published var engineStatus: EngineStatus = .notInstalled

    @Published var authPhase: AuthPhase = .idle
    @Published var isAuthSheetVisible = false

    @Published private(set) var installedVersions: [InstalledVersion] = []

    @Published var isLaunchSheetVisible = false
    @Published var launchPhase: LaunchPhase = .idle
    @Published var launchChecks: [LaunchCheck] = []
    @Published var launchPlanSummary: String?
    @Published var launchErrorMessage: String?
    /// 最近一次移动端适配的结果（设置页展示，逐条人话）。
    @Published var compatStatus: String = ""

    /// 主页「下载游戏」把用户送到版本页后，用这个 id 自动开始安装。
    @Published var pendingInstallVersionID: String?

    let downloads = DownloadManager()
    let installQueue = DownloadQueue()

    private let sessionStore = AuthSessionStore()
    private(set) var session: StoredSession?
    private let installedStore = InstalledVersionStore()
    /// 引擎选择：fork 环境（dlsym 命中 launchJVM）用 YZLEngineHost 真启动；
    /// 纯外壳构建维持 M2 接缝实现（AmethystEngine，如实报未接入）。
    private let engine: LauncherEngine = LauncherEngineFactory.make()

    private var authTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    /// 浏览器授权码流的 PKCE 校验对：发起登录时生成，换令牌时消费。
    private var pendingCodeVerifier: String?

    private static let selectedVersionKey = "yzl.selectedVersion"
    private static let activeAccountKey = "yzl.activeAccount"

    init() {
        installedVersions = installedStore.load()
        if let data = UserDefaults.standard.data(forKey: Self.selectedVersionKey),
           let saved = try? JSONDecoder().decode(MinecraftVersion.self, from: data) {
            selectedVersion = saved
        }
        if selectedVersion == nil, let latest = installedVersions.first {
            selectedVersion = latest.minecraftVersion
        }

        // 首次启动把下载源默认设成国内 BMCLAPI 镜像（官方 CDN 直连通常极慢）。
        // 只在「从未设置过」时写入，用户显式选过（含选回官方）后不再覆盖。
        if UserDefaults.standard.string(forKey: MirrorPolicy.storageKey) == nil {
            UserDefaults.standard.set(DownloadSource.mirror.rawValue, forKey: MirrorPolicy.storageKey)
        }

        engineStatus = engine.isAvailable ? .ready(engine.name) : .notInstalled
        detectJavaRuntime()

        // 离线账号先加载。当前选中账号必须等微软会话恢复完再解析：
        // 若在 account 仍为 nil 时调用 restoreActiveAccount()，持久化的正版 id
        // 会被误判为无效并覆盖成第一个离线账号，冷启动后正版选择就丢了。
        offlineAccounts = OfflineAccountStore().load()
        yggdrasilAccounts = YggdrasilAccountStore().load()

        guard let stored = sessionStore.load() else {
            restoreActiveAccount()
            return
        }
        session = stored

        if stored.expiresAt > Date() {
            account = stored.account
            restoreActiveAccount()
            return
        }

        guard let refresh = stored.refreshToken else {
            restoreActiveAccount()
            return
        }
        let service = MicrosoftAuthService(clientId: MicrosoftAuth.clientId)
        restoreTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let token = try await service.refresh(refreshToken: refresh)
                try Task.checkCancellation()
                let renewed = try await service.makeSession(from: token)
                try Task.checkCancellation()
                self.sessionStore.save(renewed)
                self.session = renewed
                self.account = renewed.account
            } catch is CancellationError {
                // signOut() 已取消续期，不写回会话、不让已退出的账号复活。
            } catch {
                // 续期失败时保持未登录，用户仍可手动登录。
            }
            self.restoreActiveAccount()
            self.restoreTask = nil
        }
    }

    // MARK: - Account

    func startSignIn() {
        guard MicrosoftAuth.isConfigured else {
            authPhase = .failed(MicrosoftAuthError.notConfigured.localizedDescription)
            isAuthSheetVisible = true
            return
        }

        restoreTask?.cancel()
        restoreTask = nil
        authTask?.cancel()
        isAuthSheetVisible = true

        let service = MicrosoftAuthService(clientId: MicrosoftAuth.clientId)
        if service.usesBrowserSignIn {
            // `00000000402b5328` 是 MSA v1.0 原生客户端，不在 Azure AAD 目录，
            // 设备码端点虽能发 code，但用户授权后 token 端点会返回
            // interaction_required。默认客户端必须走 v1.0 授权码 + 网页登录。
            // 参数对齐 Windows 端实测可用流程（PKCE + prompt=select_account）。
            guard let login = service.makeBrowserLogin() else {
                authPhase = .failed("无法生成微软登录页地址，请检查设置里的客户端 ID。")
                return
            }
            pendingCodeVerifier = login.codeVerifier
            authPhase = .browser(login.url)
            return
        }

        authPhase = .requestingCode
        authTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            // 记录失败发生在哪一段，否则用户只看到一句「登录失败」无从排查。
            var stage = "请求登录代码"
            do {
                let code = try await service.requestDeviceCode()
                self.authPhase = .awaitingUser(code)

                stage = "等待你在微软网页完成授权"
                let token = try await service.waitForToken(deviceCode: code)
                self.authPhase = .exchanging

                stage = "换取 Xbox / Minecraft 令牌"
                let session = try await service.makeSession(from: token)
                self.applySession(session)
                self.authPhase = .idle
                self.isAuthSheetVisible = false
            } catch is CancellationError {
                self.authPhase = .idle
            } catch {
                self.authPhase = .failed("\(stage)：\(error.localizedDescription)\n登录分支：Azure v2.0（自定义客户端）")
            }
            self.authTask = nil
        }
    }

    /// WebView 拦到 `oauth20_desktop.srf?code=...` 后进入这里。
    func completeBrowserSignIn(code: String) {
        guard !code.isEmpty else { return }
        guard let verifier = pendingCodeVerifier else {
            authPhase = .failed("登录会话状态丢失（没有找到 PKCE 校验对），请关闭本页重新发起登录。\n登录分支：Live Connect v1.0（网页授权码）")
            return
        }
        authPhase = .exchanging
        let service = MicrosoftAuthService(clientId: MicrosoftAuth.clientId)
        authTask?.cancel()
        authTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var stage = "换取微软访问令牌"
            do {
                let token = try await service.exchangeAuthorizationCode(code, codeVerifier: verifier)
                stage = "换取 Xbox / Minecraft 令牌"
                let session = try await service.makeSession(from: token)
                try Task.checkCancellation()
                self.applySession(session)
                self.authPhase = .idle
                self.isAuthSheetVisible = false
            } catch is CancellationError {
                self.authPhase = .idle
            } catch {
                self.authPhase = .failed("\(stage)：\(error.localizedDescription)\n登录分支：Live Connect v1.0（网页授权码）")
            }
            self.pendingCodeVerifier = nil
            self.authTask = nil
        }
    }

    func failBrowserSignIn(message: String) {
        authPhase = .failed("微软网页授权：\(message)\n登录分支：Live Connect v1.0（网页授权码）")
    }

    private func applySession(_ session: StoredSession) {
        sessionStore.save(session)
        self.session = session
        account = session.account
        activeAccountID = session.account.id
        persistActiveAccount()
    }

    func cancelSignIn() {
        authTask?.cancel()
        authTask = nil
        pendingCodeVerifier = nil
        authPhase = .idle
        isAuthSheetVisible = false
    }

    func signOut() {
        restoreTask?.cancel()
        restoreTask = nil
        let microsoftID = session?.account.id ?? account?.id
        sessionStore.clear()
        session = nil
        account = nil
        authPhase = .idle
        // 退出正版后若当前正用它启动，则自动退到其它账号（离线 / 皮肤站）。
        if activeAccountID == microsoftID {
            activeAccountID = offlineAccounts.first?.id ?? yggdrasilAccounts.first?.id
            persistActiveAccount()
        }
    }

    // MARK: - 统一账号（正版 / 皮肤站 / 离线）

    /// 把 `activeAccountID` 解析成具体的正版 / 皮肤站 / 离线档案；解析不到返回 nil。
    private func accountInfo(for id: String?) -> (microsoft: MicrosoftAccount?, yggdrasil: YggdrasilAccount?, offline: OfflineAccount?)? {
        guard let id else { return nil }
        if let acc = account, acc.id == id { return (acc, nil, nil) }
        if let skin = yggdrasilAccounts.first(where: { $0.id == id }) { return (nil, skin, nil) }
        if let off = offlineAccounts.first(where: { $0.id == id }) { return (nil, nil, off) }
        return nil
    }

    /// 用于头像 / 名字展示：正版优先，其次皮肤站，再退到离线账号。
    var displayAccount: MicrosoftAccount? {
        guard let info = accountInfo(for: activeAccountID) else { return nil }
        return info.microsoft ?? info.yggdrasil?.asMicrosoftAccount ?? info.offline?.asMicrosoftAccount
    }

    /// 当前选中的皮肤站账号（若有）。
    var activeYggdrasilAccount: YggdrasilAccount? {
        accountInfo(for: activeAccountID)?.yggdrasil
    }

    /// 当前选中的离线账号（若有）。
    var activeOfflineAccount: OfflineAccount? {
        accountInfo(for: activeAccountID)?.offline
    }

    /// 启动用的统一档案：正版 / 皮肤站 / 离线统一套进 MicrosoftAccount。
    var launchAccount: MicrosoftAccount? { displayAccount }

    /// 是否处于离线（伪正版）启动模式。
    var isOfflineLaunch: Bool {
        accountInfo(for: activeAccountID)?.offline != nil
    }

    /// 是否处于皮肤站启动模式（Yggdrasil 令牌进 accessToken，联机皮肤站服务器可用）。
    var isYggdrasilLaunch: Bool {
        activeYggdrasilAccount != nil
    }

    /// 是否存在任何可用于启动的账号（正版 / 皮肤站 / 离线）。
    var hasAnyAccount: Bool {
        accountInfo(for: activeAccountID) != nil
    }

    /// 账号检查行与卡片上的人话类型文案。
    var activeAccountKindText: String {
        if isOfflineLaunch { return "离线（伪正版）" }
        if let skin = activeYggdrasilAccount { return "皮肤站 · \(skin.serverHost)" }
        return "微软正版"
    }

    private func restoreActiveAccount() {
        let saved = UserDefaults.standard.string(forKey: Self.activeAccountKey)
        if let saved, accountInfo(for: saved) != nil {
            activeAccountID = saved
        } else if account != nil {
            activeAccountID = account?.id
        } else {
            activeAccountID = offlineAccounts.first?.id ?? yggdrasilAccounts.first?.id
        }
        persistActiveAccount()
    }

    private func persistActiveAccount() {
        UserDefaults.standard.set(activeAccountID, forKey: Self.activeAccountKey)
    }

    // MARK: - 离线（伪正版）账号管理

    /// 新增一个离线账号，并设为当前启动账号。
    func createOfflineAccount(name: String, skinModel: String = "steve", skinURL: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newAccount = OfflineAccount(name: trimmed, skinModel: skinModel, skinURL: skinURL)
        if !offlineAccounts.contains(where: { $0.id == newAccount.id }) {
            offlineAccounts.append(newAccount)
        }
        OfflineAccountStore().save(offlineAccounts)
        activeAccountID = newAccount.id
        persistActiveAccount()
    }

    /// 选择某个账号（正版 id 或离线 id）作为当前启动账号。
    func selectActiveAccount(id: String) {
        guard accountInfo(for: id) != nil else { return }
        activeAccountID = id
        persistActiveAccount()
    }

    /// 删除一个离线账号；若它正被使用则回退到其它账号。
    func removeOfflineAccount(id: String) {
        offlineAccounts.removeAll { $0.id == id }
        OfflineAccountStore().save(offlineAccounts)
        if activeAccountID == id {
            activeAccountID = offlineAccounts.first?.id ?? yggdrasilAccounts.first?.id ?? account?.id
            persistActiveAccount()
        }
    }

    /// 设置 / 清除离线账号的本地皮肤（对照 Android 端 SkinScreen 的本地导入）。
    /// `skinURL` 传 LocalSkinStore 生成的 `yzl-local-skin://` 引用，传 nil 恢复默认。
    func setOfflineSkin(accountID: String, skinURL: String?) {
        guard let index = offlineAccounts.firstIndex(where: { $0.id == accountID }) else { return }
        offlineAccounts[index].skinURL = skinURL
        OfflineAccountStore().save(offlineAccounts)
    }

    // MARK: - 皮肤站账号管理（Yggdrasil，对照 Android 端 littleskin）

    /// 皮肤站登录：authenticate 成功后保存 Keychain 令牌、同步一次材质、
    /// upsert 档案并设为当前账号。抛错时由调用方直接展示 errorDescription。
    @discardableResult
    func loginYggdrasil(server: String, username: String, password: String) async throws -> YggdrasilAccount {
        let service = YggdrasilAuthService()
        let result = try await service.authenticate(server: server, username: username, password: password)

        var account = YggdrasilAccount(
            id: result.profileID,
            name: result.profileName,
            serverURL: YggdrasilAuth.normalizeServer(server),
            skinURL: nil,
            skinModel: "steve",
            capeURL: nil
        )
        YggdrasilSessionStore().save(
            YggdrasilSession(accessToken: result.accessToken,
                             clientToken: result.clientToken,
                             updatedAt: Date()),
            accountID: account.id
        )

        // 登录成功立刻同步材质；失败静默保留默认（进皮肤页或下次登录再拉）。
        if let textures = await service.fetchTextures(server: account.serverURL, rawUUID: account.rawUUID) {
            account = account.updatingTextures(textures)
        }

        upsertYggdrasilAccount(account)
        activeAccountID = account.id
        persistActiveAccount()
        return account
    }

    /// 覆盖保存一份皮肤站档案（材质同步 / 上传皮肤后调用）。
    func updateYggdrasilAccount(_ account: YggdrasilAccount) {
        upsertYggdrasilAccount(account)
    }

    /// 删除皮肤站账号：档案与 Keychain 令牌一起清；正被使用则回退到其它账号。
    func removeYggdrasilAccount(id: String) {
        yggdrasilAccounts.removeAll { $0.id == id }
        YggdrasilAccountStore().save(yggdrasilAccounts)
        YggdrasilSessionStore().clear(accountID: id)
        if activeAccountID == id {
            activeAccountID = account?.id ?? offlineAccounts.first?.id
            persistActiveAccount()
        }
    }

    private func upsertYggdrasilAccount(_ account: YggdrasilAccount) {
        if let index = yggdrasilAccounts.firstIndex(where: { $0.id == account.id }) {
            yggdrasilAccounts[index] = account
        } else {
            yggdrasilAccounts.append(account)
        }
        YggdrasilAccountStore().save(yggdrasilAccounts)
    }

    // MARK: - Installed versions

    func installedVersion(for id: String) -> InstalledVersion? {
        installedVersions.first { $0.id == id }
    }

    func isInstalled(_ id: String) -> Bool {
        installedVersion(for: id) != nil
    }

    var currentInstall: InstalledVersion? {
        guard let selectedVersion else { return nil }
        return installedVersion(for: selectedVersion.id)
    }

    func recordInstall(detail: VersionDetail,
                       version: MinecraftVersion,
                       fileCount: Int,
                       totalBytes: Int64) {
        let record = InstalledVersion(
            id: version.id,
            type: version.type,
            releaseTime: version.releaseTime,
            detailURL: version.url,
            javaMajor: detail.javaVersion?.majorVersion ?? 8,
            assetIndex: detail.assetIndexName,
            installedAt: Date(),
            fileCount: fileCount,
            totalBytes: totalBytes
        )

        var next = installedVersions.filter { $0.id != record.id }
        next.append(record)
        installedVersions = next.sorted { $0.installedAt > $1.installedAt }
        installedStore.save(installedVersions)
        selectedVersion = version
        if pendingInstallVersionID == version.id {
            pendingInstallVersionID = nil
        }
    }

    func removeInstalledVersion(id: String) {
        installedVersions.removeAll { $0.id == id }
        installedStore.save(installedVersions)
        try? FileManager.default.removeItem(at: InstallLayout.forVersion(id).root)
        if selectedVersion?.id == id {
            selectedVersion = installedVersions.first?.minecraftVersion
        }
    }

    // MARK: - Launch

    var launchButtonTitle: String {
        guard let selectedVersion else { return "下载游戏" }
        guard isInstalled(selectedVersion.id) else { return "下载游戏" }
        return hasAnyAccount ? "启动游戏" : "登录 / 离线账号"
    }

    var launchButtonIcon: String {
        guard let selectedVersion else { return "arrow.down.circle.fill" }
        guard isInstalled(selectedVersion.id) else { return "arrow.down.circle.fill" }
        return hasAnyAccount ? "play.fill" : "person.crop.circle.fill"
    }

    /// 主页大按钮的统一入口：没选版本先去版本页；版本没装好直接开始下载；
    /// 已安装但没登录才去登录；条件齐了才打开启动自检。
    func handleLaunchTap() {
        guard let version = selectedVersion else {
            selectedTab = .versions
            return
        }
        guard isInstalled(version.id) else {
            pendingInstallVersionID = version.id
            selectedTab = .versions
            return
        }
        guard hasAnyAccount else {
            overlay = .account
            return
        }
        requestLaunch(version: version)
    }

    func requestLaunch(version: MinecraftVersion? = nil) {
        if let version {
            selectedVersion = version
        }
        pendingInstallVersionID = nil
        isLaunchSheetVisible = true
        launchErrorMessage = nil
        launchPlanSummary = nil
        launchChecks = [
            LaunchCheck(id: "preflight", title: "启动自检", detail: "正在检查账户、文件和运行时…", status: .pending)
        ]
        launchPhase = .checking

        launchTask?.cancel()
        launchTask = Task { @MainActor in
            let readiness = await self.buildReadiness()
            guard !Task.isCancelled else { return }

            self.launchChecks = readiness.checks
            self.launchPlanSummary = readiness.plan?.summary ?? "启动参数未生成，请查看下方检查项。"

            if readiness.canLaunch, let plan = readiness.plan {
                self.launchPhase = .ready
                await self.performLaunch(plan)
            } else {
                self.launchPhase = .failed(readiness.blocker ?? "启动条件不满足。")
            }
            self.launchTask = nil
        }
    }

    func closeLaunchSheet() {
        if launchPhase == .checking || launchPhase == .launching {
            launchTask?.cancel()
            launchTask = nil
        }
        if launchPhase != .running {
            launchPhase = .idle
        }
        isLaunchSheetVisible = false
    }

    /// 按本机部署档位自动选「最省电脑」的 JIT 开启方式：
    /// 能用免电脑方法的系统版本一律用免电脑方法，只有不支持的才退回电脑方案。
    var jitActionTitle: String {
        switch DeviceCapabilities.deploymentProfile {
        case .permanentNoComputer, .oneTimeComputerThenPermanent:
            return "通过 TrollStore 开启 JIT（免电脑）"
        case .oneTimePairing, .appJITAdaptation:
            return "查看手机端开启 JIT 的方法"
        case .computerAttached:
            return "查看电脑附加 JIT 的方法"
        case .unsupportedOld:
            return "系统版本过低"
        }
    }

    func enableJIT() {
        switch DeviceCapabilities.deploymentProfile {
        case .permanentNoComputer, .oneTimeComputerThenPermanent:
            openTrollStoreJIT()
        case .oneTimePairing, .appJITAdaptation:
            launchErrorMessage = "iOS 17.4+ 可在手机上开 JIT：先连上 LocalDevVPN 本地回环，再打开 StikDebug 选中 YZL Launcher 点 Enable JIT。配对文件只需电脑生成一次，之后不用电脑。注意每次重开 App 都要重新点一次。"
            launchPhase = .failed("请按提示开启 JIT")
        case .computerAttached:
            launchErrorMessage = "这个系统版本 StikDebug 不支持，需要电脑附加：AltServer → Enable JIT，或 SideJITServer / Jitterbug。续签同样需要电脑。"
            launchPhase = .failed("需要电脑附加 JIT")
        case .unsupportedOld:
            launchErrorMessage = "系统低于 iOS 15.0，本启动器无法运行。"
            launchPhase = .failed("系统版本过低")
        }
    }

    private func openTrollStoreJIT() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let url = URL(string: "apple-magnifier://enable-jit?bundle-id=\(bundleID)") else {
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.launchErrorMessage = "没有检测到 TrollStore，或它的 URL Scheme 没开。请在 TrollStore → Settings 里开启 URL Scheme Enabled 后重试。"
                self?.launchPhase = .failed("JIT 未开启")
            }
        }
    }

    /// 设置页「立即处理」：对当前选中的版本做一次移动端适配，并把结果回显出来。
    func applyMobileCompatNow() {
        guard let version = selectedVersion else {
            compatStatus = "先在「版本」里选中一个已安装的版本。"
            return
        }
        let layout = InstallLayout.forVersion(version.id)
        let settings = MobileCompat.Settings.load()
        do {
            let report = try MobileCompat.apply(to: layout.gameDirectory, aggressive: settings.aggressive)
            compatStatus = report.isEmpty
                ? "已经是移动端适配状态，无需改动。"
                : report.lines.joined(separator: "\n")
        } catch {
            compatStatus = "处理失败：\(error.localizedDescription)"
        }
    }

    /// 把被兼容层移出 mods 的模组全部搬回来（想恢复整合包原状时用）。
    func restoreMobileCompat() {
        guard let version = selectedVersion else {
            compatStatus = "先在「版本」里选中一个已安装的版本。"
            return
        }
        let layout = InstallLayout.forVersion(version.id)
        do {
            let restored = try MobileCompat.restoreAll(in: layout.gameDirectory)
            compatStatus = restored.isEmpty
                ? "中转目录里没有可恢复的模组。"
                : "已恢复：" + restored.joined(separator: "、")
        } catch {
            compatStatus = "恢复失败：\(error.localizedDescription)"
        }
    }

    private func performLaunch(_ plan: LaunchPlan) async {
        launchPhase = .launching
        try? FileManager.default.createDirectory(
            at: plan.gameDirectory,
            withIntermediateDirectories: true
        )
        // 启动前再兜一次：用户可能在设置里改了档位，而引擎层那一次是在 launch 里执行的，
        // 这里提前做能让「画质/光影」在刚装完包、还没进过设置页时也生效。
        let compat = MobileCompat.Settings.load()
        if compat.enabled {
            _ = try? MobileCompat.apply(to: plan.gameDirectory, aggressive: compat.aggressive)
        }
        try? FileManager.default.createDirectory(
            at: plan.nativesDirectory,
            withIntermediateDirectories: true
        )
        do {
            try await engine.launch(plan)
            launchPhase = .running
        } catch {
            launchPhase = .failed(error.localizedDescription)
        }
    }

    private func buildReadiness() async -> LaunchReadiness {
        var checks: [LaunchCheck] = []
        detectJavaRuntime()
        detectJIT()
        engineStatus = engine.isAvailable ? .ready(engine.name) : .notInstalled

        guard let launchAccount else {
            checks.append(LaunchCheck(
                id: "account",
                title: "账号",
                detail: "尚未选择账号，请到「账号」里登录正版或添加离线账号。",
                status: .failed
            ))
            return LaunchReadiness(checks: checks, plan: nil)
        }
        checks.append(LaunchCheck(
            id: "account",
            title: "账号",
            detail: "\(launchAccount.name) · \(activeAccountKindText)",
            status: .ok
        ))

        guard let version = selectedVersion else {
            checks.append(LaunchCheck(
                id: "version",
                title: "游戏版本",
                detail: "还没有选择版本，请到「版本」里安装一个。",
                status: .failed
            ))
            return LaunchReadiness(checks: checks, plan: nil)
        }

        guard let record = installedVersion(for: version.id) else {
            checks.append(LaunchCheck(
                id: "install",
                title: "版本安装",
                detail: "\(version.id) 还没有完成安装。",
                status: .failed
            ))
            return LaunchReadiness(checks: checks, plan: nil)
        }
        checks.append(LaunchCheck(
            id: "install",
            title: "版本安装",
            detail: "\(record.fileCount) 个文件 · \(record.sizeText)",
            status: .ok
        ))

        let layout = InstallLayout.forVersion(version.id)
        var detail: VersionDetail
        do {
            let data = try Data(contentsOf: layout.versionJSON)
            detail = try JSONDecoder().decode(VersionDetail.self, from: data)
            // Forge / Fabric / Quilt 等通过 inheritsFrom 继承父版本（例如官方 1.20.1）。
            // 运行时把继承链递归拍平成本地自包含版本，父版本的库 / 客户端 / 参数都会带下来。
            if detail.inheritsFrom != nil {
                detail = VersionMerger.merge(root: detail) { parentID in
                    let parentLayout = InstallLayout.forVersion(parentID)
                    guard FileManager.default.fileExists(atPath: parentLayout.versionJSON.path),
                          let parentData = try? Data(contentsOf: parentLayout.versionJSON),
                          let parent = try? JSONDecoder().decode(VersionDetail.self, from: parentData) else {
                        return nil
                    }
                    return parent
                }
            }
            checks.append(LaunchCheck(
                id: "metadata",
                title: "版本元数据",
                detail: "资源索引 \(detail.assetIndexName) · Java \(detail.javaVersion?.majorVersion ?? 8)",
                status: .ok
            ))
        } catch {
            checks.append(LaunchCheck(
                id: "metadata",
                title: "版本元数据",
                detail: "版本 JSON 缺失或损坏，请重新安装。",
                status: .failed
            ))
            return LaunchReadiness(checks: checks, plan: nil)
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: layout.clientJar.path) {
            let attributes = try? fileManager.attributesOfItem(atPath: layout.clientJar.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            checks.append(LaunchCheck(
                id: "client",
                title: "客户端 jar",
                detail: InstallFormats.bytes(size),
                status: size > 0 ? .ok : .failed
            ))
        } else {
            checks.append(LaunchCheck(
                id: "client",
                title: "客户端 jar",
                detail: "缺少 \(layout.clientJar.lastPathComponent)，请重新安装。",
                status: .failed
            ))
        }

        let classpath = LaunchPlanBuilder.classpath(detail: detail, layout: layout)
        let missingLibraries = classpath.dropFirst().filter {
            !fileManager.fileExists(atPath: $0.path)
        }
        if missingLibraries.isEmpty {
            checks.append(LaunchCheck(
                id: "libraries",
                title: "依赖库",
                detail: "\(classpath.count) 个 classpath 项齐全",
                status: .ok
            ))
        } else {
            checks.append(LaunchCheck(
                id: "libraries",
                title: "依赖库",
                detail: "缺少 \(missingLibraries.count) 个依赖库，请重新安装补全。",
                status: .failed
            ))
        }

        if let index = detail.assetIndex {
            let indexURL = layout.assetIndexURL(id: index.id)
            checks.append(LaunchCheck(
                id: "assets",
                title: "资源索引",
                detail: fileManager.fileExists(atPath: indexURL.path)
                    ? "indexes/\(index.id).json 已就绪"
                    : "缺少资源索引 \(index.id).json，请重新安装。",
                status: fileManager.fileExists(atPath: indexURL.path) ? .ok : .failed
            ))
        } else {
            checks.append(LaunchCheck(
                id: "assets",
                title: "资源索引",
                detail: "该版本没有资源索引记录。",
                status: .warning
            ))
        }

        let isOffline = isOfflineLaunch
        let isYggdrasil = isYggdrasilLaunch
        var validSession: StoredSession?
        var yggdrasilToken = ""

        // 皮肤站账号：authlib-injector 注入（游戏内显示皮肤站皮肤、进皮肤站认证服务器）。
        // jar 拿不到不挡启动（与 Windows 端同语义），只降级为警告。
        var authlibArguments: [String] = []
        if let skinAccount = activeYggdrasilAccount, isYggdrasil {
            do {
                let injector = try await AuthlibInjectorService().ensureJar()
                authlibArguments = AuthlibInjector.jvmArguments(
                    jarPath: injector.jarPath,
                    serverURL: skinAccount.serverURL
                )
                checks.append(LaunchCheck(
                    id: "authlib",
                    title: "皮肤站注入",
                    detail: "authlib-injector \(injector.version) 就绪，游戏内将显示皮肤站皮肤。",
                    status: .ok
                ))
            } catch {
                checks.append(LaunchCheck(
                    id: "authlib",
                    title: "皮肤站注入",
                    detail: "authlib-injector 获取失败（\(error.localizedDescription)）。本次启动游戏内可能不显示皮肤站皮肤，不影响进入游戏。",
                    status: .warning
                ))
            }
        }

        if isOffline {
            // 离线（伪正版）模式根本不碰微软令牌：用固定离线 UUID 直接进入单机 / LAN。
            checks.append(LaunchCheck(
                id: "session",
                title: "登录令牌",
                detail: "离线（伪正版）模式：无需微软令牌，单机 / 局域网可用。在线正版服务器会拒绝，属预期。",
                status: .ok
            ))
        } else if let skinAccount = activeYggdrasilAccount, isYggdrasil {
            // 皮肤站：Yggdrasil accessToken 直接进 --accessToken；
            // 进皮肤站架设的认证服务器（authlib-injector）时即为正版身份。
            if let token = await freshYggdrasilToken(for: skinAccount) {
                yggdrasilToken = token
                checks.append(LaunchCheck(
                    id: "session",
                    title: "登录令牌",
                    detail: "皮肤站令牌有效（\(skinAccount.serverHost)）",
                    status: .ok
                ))
            } else {
                checks.append(LaunchCheck(
                    id: "session",
                    title: "登录令牌",
                    detail: "皮肤站登录已失效，请到「账号」重新登录。",
                    status: .failed
                ))
            }
        } else {
            validSession = await freshSession()
            if let validSession {
                checks.append(LaunchCheck(
                    id: "session",
                    title: "登录令牌",
                    detail: "有效，Minecraft 令牌到期时间 \(Self.timeText(validSession.expiresAt))",
                    status: .ok
                ))
            } else {
                checks.append(LaunchCheck(
                    id: "session",
                    title: "登录令牌",
                    detail: "访问令牌已过期且续期失败，请重新登录。",
                    status: .failed
                ))
            }
        }

        if javaStatus.isReady {
            checks.append(LaunchCheck(
                id: "java",
                title: "Java 运行时",
                detail: javaStatus.title,
                status: .ok
            ))
        } else {
            checks.append(LaunchCheck(
                id: "java",
                title: "Java 运行时",
                detail: "没有找到 iOS JRE。M2 会随引擎放入 java_runtimes 目录。",
                status: .failed
            ))
        }

        switch jitStatus {
        case .enabled:
            checks.append(LaunchCheck(id: "jit", title: "JIT", detail: "已启用", status: .ok))
        case .disabled:
            checks.append(LaunchCheck(
                id: "jit",
                title: "JIT",
                detail: "未启用。请用 TrollStore 或调试器附加开启 JIT 后重试。",
                status: .failed
            ))
        case .unknown:
            checks.append(LaunchCheck(
                id: "jit",
                title: "JIT",
                detail: "当前外壳无法检测；接入内核后会由引擎实际探测。",
                status: .warning
            ))
        }

        if engine.isAvailable {
            checks.append(LaunchCheck(
                id: "engine",
                title: "启动内核",
                detail: engine.name,
                status: .ok
            ))
        } else {
            // 按 payload 逐件诊断：缺 JRE / 图形 dylib / Java 桥 jar / cacio，
            // 与「桥未接入」是不同的问题，提示文案分开。
            let payload = EnginePayloadLocator.scan()
            if payload.isLaunchable {
                checks.append(LaunchCheck(
                    id: "engine",
                    title: "启动内核",
                    detail: "引擎件齐备，但启动桥未接入（当前为纯外壳构建）。安装 fork 引擎构建后即可拉起 JVM。",
                    status: .failed
                ))
            } else {
                checks.append(LaunchCheck(
                    id: "engine",
                    title: "启动内核",
                    detail: "Amethyst 内核尚未安装（\(payload.summary)）。安装与启动参数已就绪，接入后即可拉起 JVM。",
                    status: .failed
                ))
            }
        }

        // 整合包规模自检：几百个模组的包能不能进得去，堆大小和光影开关起决定作用。
        let modCount = MobileCompat.modCount(in: layout.gameDirectory)
        let compat = MobileCompat.Settings.load()
        if modCount > 0 {
            // 渲染器决定 Sodium 能不能用：auto / gl4es 这一档上 Sodium 0.5 的
            // 地形优化路径本来就跑不通，这里提前说清楚，别让用户在加载地形上反复等。
            let renderer = AmethystPreferences.rendererName(homeDirectory: EngineLaunchContract.homeDirectory)
            let sodiumRisk = !compat.aggressive && AmethystPreferences.isSodiumUnsafe(renderer: renderer)
            let detail: String
            var status: LaunchCheck.Status = compat.enabled ? .ok : .warning
            if !compat.enabled {
                detail = "\(modCount) 个模组 · 移动端适配已关闭；Iris 光影在 iOS 上会卡在「正在加载地形」"
            } else if sodiumRisk {
                detail = "\(modCount) 个模组 · 光影已关 · 渲染器 \(renderer ?? "auto") 与 Sodium 0.5 不匹配，仍卡加载地形就打开「极端兼容」"
                status = .warning
            } else {
                detail = "\(modCount) 个模组 · 移动端适配已开启（光影关闭、Sodium staging 降级）"
            }
            checks.append(LaunchCheck(id: "compat", title: "整合包", detail: detail, status: status))
        }

        // 通用策略：同一个二进制在所有设备上按运行时可用内存自动收敛，
        // 不为具体机型出包，也不让用户把堆设到会被 jetsam 杀掉的值。
        let cap = DeviceCapabilities.maxSafeHeapMB
        let preferredMemory = Int(UserDefaults.standard.double(forKey: "memoryMB"))
        let preferred = preferredMemory > 0 ? preferredMemory : DeviceCapabilities.recommendedHeapMB
        let memory = min(preferred, cap)
        let recommended = DeviceCapabilities.recommendedHeapMB
        let overRecommended = memory > recommended + 512
        // 手机上「能启动」和「能进世界」是两道关：整合包越大，后者越吃堆。
        let memoryTooLow = modCount >= 150 && memory < 3072
        let memoryAtCap = memory >= cap
        checks.append(LaunchCheck(
            id: "memory",
            title: "内存",
            detail: memoryTooLow
                ? (memoryAtCap
                    ? "\(memory) MB 已是本机上限，对 \(modCount) 个模组仍偏小：建议打开「极端兼容」、视图距离降到 2，或换更小的整合包。"
                    : "\(memory) MB 对 \(modCount) 个模组的整合包偏小（建议 3072–4096 MB），加载地形时会一直 GC 像卡死。")
                : (preferred > cap
                    ? "设置 \(preferred) MB，本机安全上限 \(cap) MB，已自动夹到 \(memory) MB。"
                    : (overRecommended
                        ? "\(memory) MB，高于建议的 \(recommended) MB，可能被系统终止。"
                        : "\(memory) MB（建议 \(recommended) MB · 上限 \(cap) MB）")),
            status: (preferred > cap || overRecommended || memoryTooLow) ? .warning : .ok
        ))

        var plan: LaunchPlan?
        let offlineToken = "offline"
        // 皮肤站账号的 Yggdrasil 令牌同样走 accessToken 通道（userType 用 mojang，
        // 现代版本里该字段只影响展示，真正鉴权的是令牌本身）。
        let accessToken = isOffline
            ? offlineToken
            : (isYggdrasil ? yggdrasilToken : (validSession?.accessToken ?? ""))
        let userType = (isOffline || isYggdrasil) ? "mojang" : "msa"
        if isOffline || validSession != nil || !yggdrasilToken.isEmpty {
            do {
                plan = try LaunchPlanBuilder.build(
                    detail: detail,
                    version: version,
                    layout: layout,
                    account: launchAccount,
                    accessToken: accessToken,
                    memoryMB: memory,
                    maxHeapMB: cap,
                    userType: userType,
                    authlibArguments: authlibArguments
                )
            } catch {
                checks.append(LaunchCheck(
                    id: "plan",
                    title: "启动参数",
                    detail: error.localizedDescription,
                    status: .failed
                ))
            }
        }

        // 即使内核还没接上，也把已生成的命令行作为可见产物展示（令牌脱敏）。
        if let plan {
            let command = LaunchCommand.make(plan: plan, javaHome: RuntimeLocator.javaHome())
            checks.append(LaunchCheck(
                id: "command",
                title: "启动命令",
                detail: "\(command.redactedDescription) · 令牌仅在内存中传递",
                status: .ok
            ))
        }

        return LaunchReadiness(checks: checks, plan: plan)
    }

    /// 启动前确保访问令牌至少还有一分钟有效期；过期就用刷新令牌重新走一遍档案接口。
    private func freshSession() async -> StoredSession? {
        guard let current = session else { return nil }
        if current.expiresAt > Date().addingTimeInterval(60) {
            return current
        }
        guard let refresh = current.refreshToken else { return nil }

        do {
            let service = MicrosoftAuthService(clientId: MicrosoftAuth.clientId)
            let token = try await service.refresh(refreshToken: refresh)
            let renewed = try await service.makeSession(from: token)
            sessionStore.save(renewed)
            session = renewed
            // 档案 id 变化时把当前选中账号跟上，否则 accountInfo(for:) 解析不到，
            // 启动自检的「账号」项会失败。只做旧 id → 新 id 的映射，不切换账号类型。
            if activeAccountID == current.account.id, activeAccountID != renewed.account.id {
                activeAccountID = renewed.account.id
                persistActiveAccount()
            }
            account = renewed.account
            return renewed
        } catch {
            launchErrorMessage = "登录续期失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 皮肤站令牌保活：Yggdrasil 令牌不带回有效期，每次启动前用 clientToken
    /// refresh 一次。refresh 因网络抖动失败时保留旧令牌（可能仍然有效，只是
    /// 这次 refresh 没成功）；服务器明确拒绝才判失效。
    private func freshYggdrasilToken(for account: YggdrasilAccount) async -> String? {
        let store = YggdrasilSessionStore()
        guard let stored = store.load(accountID: account.id), !stored.accessToken.isEmpty else {
            return nil
        }

        let service = YggdrasilAuthService()
        do {
            let renewed = try await service.refresh(
                server: account.serverURL,
                accessToken: stored.accessToken,
                clientToken: stored.clientToken
            )
            store.save(renewed, accountID: account.id)
            return renewed.accessToken
        } catch is URLError {
            // 网络抖动：旧令牌大概率还有效，别挡启动。
            return stored.accessToken
        } catch {
            return nil
        }
    }

    /// 皮肤上传 / 披风管理用的 Minecraft Services 令牌（顺带完成保活续期）。
    func microsoftTokenForProfileActions() async -> String? {
        guard let session = await freshSession() else { return nil }
        return session.accessToken
    }

    /// 上传皮肤 / 换披风成功后同步 Mojang 档案到本地会话，头像立即跟着变。
    /// 令牌与过期时间保持不变，只更新档案里的皮肤 URL。
    func applyMicrosoftProfile(skinURL: String?) {
        guard let current = session else { return }
        let updatedAccount = MicrosoftAccount(
            id: current.account.id,
            name: current.account.name,
            skinURL: skinURL ?? current.account.skinURL
        )
        let stored = StoredSession(
            account: updatedAccount,
            accessToken: current.accessToken,
            refreshToken: current.refreshToken,
            expiresAt: current.expiresAt
        )
        sessionStore.save(stored)
        session = stored
        account = updatedAccount
    }

    // MARK: - Persistence / runtime detection

    private func persistSelectedVersion() {
        guard let selectedVersion else {
            UserDefaults.standard.removeObject(forKey: Self.selectedVersionKey)
            return
        }
        if let data = try? JSONEncoder().encode(selectedVersion) {
            UserDefaults.standard.set(data, forKey: Self.selectedVersionKey)
        }
    }

    /// 兼容两种放置方式：打进 App 包的 `java_runtimes/`，或用户目录里的 `YZLJavaRuntimes/`。
    /// 判定统一收在 RuntimeLocator，避免 UI 与引擎各写一套、把空目录误判成可用 JRE。
    private func detectJavaRuntime() {
        javaStatus = RuntimeLocator.javaRuntime()
    }

    /// 模拟器是 macOS 进程，RWX 页探测恒真，不能代表真机 JIT 状态，所以只在真机上探测。
    private func detectJIT() {
        #if !targetEnvironment(simulator)
        jitStatus = JITProbe.detect()
        #endif
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
