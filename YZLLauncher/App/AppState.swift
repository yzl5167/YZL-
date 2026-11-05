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

    /// 主页「下载游戏」把用户送到版本页后，用这个 id 自动开始安装。
    @Published var pendingInstallVersionID: String?

    let downloads = DownloadManager()
    let installQueue = DownloadQueue()

    private let sessionStore = AuthSessionStore()
    private(set) var session: StoredSession?
    private let installedStore = InstalledVersionStore()
    /// M2 接缝：未注入 EngineBridge 时 isAvailable = false，自检会如实标红。
    private let engine: LauncherEngine = AmethystEngine()

    private var authTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?

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

        engineStatus = engine.isAvailable ? .ready(engine.name) : .notInstalled
        detectJavaRuntime()

        // 离线账号与当前选中账号都从本机持久化恢复。
        offlineAccounts = OfflineAccountStore().load()
        restoreActiveAccount()

        guard let stored = sessionStore.load() else { return }
        session = stored

        if stored.expiresAt > Date() {
            account = stored.account
            restoreActiveAccount()
            return
        }

        guard let refresh = stored.refreshToken else { return }
        let service = MicrosoftAuthService(clientId: MicrosoftAuth.clientId)
        restoreTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let token = try await service.refresh(refreshToken: refresh)
                let renewed = try await service.makeSession(from: token)
                self.sessionStore.save(renewed)
                self.session = renewed
                self.account = renewed.account
                self.restoreActiveAccount()
            } catch {
                // 续期失败时保持未登录，用户仍可手动登录。
            }
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
        authPhase = .requestingCode
        isAuthSheetVisible = true

        let service = MicrosoftAuthService(clientId: MicrosoftAuth.clientId)
        authTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let code = try await service.requestDeviceCode()
                self.authPhase = .awaitingUser(code)

                let token = try await service.waitForToken(deviceCode: code)
                self.authPhase = .exchanging

                let session = try await service.makeSession(from: token)
                self.sessionStore.save(session)
                self.session = session
                self.account = session.account
                self.activeAccountID = session.account.id
                self.persistActiveAccount()
                self.authPhase = .idle
                self.isAuthSheetVisible = false
            } catch is CancellationError {
                self.authPhase = .idle
            } catch {
                self.authPhase = .failed(error.localizedDescription)
            }
            self.authTask = nil
        }
    }

    func cancelSignIn() {
        authTask?.cancel()
        authTask = nil
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
        // 退出正版后若当前正用它启动，则自动退到离线账号（若有）。
        if activeAccountID == microsoftID {
            activeAccountID = offlineAccounts.first?.id
            persistActiveAccount()
        }
    }

    // MARK: - 统一账号（正版 / 离线）

    /// 把 `activeAccountID` 解析成具体的正版或离线档案；解析不到返回 nil。
    private func accountInfo(for id: String?) -> (microsoft: MicrosoftAccount?, offline: OfflineAccount?)? {
        guard let id else { return nil }
        if let acc = account, acc.id == id { return (acc, nil) }
        if let off = offlineAccounts.first(where: { $0.id == id }) { return (nil, off) }
        return nil
    }

    /// 用于头像 / 名字展示：正版优先，否则退到离线账号。
    var displayAccount: MicrosoftAccount? {
        guard let info = accountInfo(for: activeAccountID) else { return nil }
        return info.microsoft ?? info.offline?.asMicrosoftAccount
    }

    /// 当前选中的离线账号（若有）。
    var activeOfflineAccount: OfflineAccount? {
        accountInfo(for: activeAccountID)?.offline
    }

    /// 启动用的统一档案：正版直接取，离线则套一层 MicrosoftAccount。
    var launchAccount: MicrosoftAccount? { displayAccount }

    /// 是否处于离线（伪正版）启动模式。
    var isOfflineLaunch: Bool {
        accountInfo(for: activeAccountID)?.offline != nil
    }

    /// 是否存在任何可用于启动的账号（正版或离线）。
    var hasAnyAccount: Bool {
        accountInfo(for: activeAccountID) != nil
    }

    private func restoreActiveAccount() {
        let saved = UserDefaults.standard.string(forKey: Self.activeAccountKey)
        if let saved, accountInfo(for: saved) != nil {
            activeAccountID = saved
        } else if account != nil {
            activeAccountID = account?.id
        } else {
            activeAccountID = offlineAccounts.first?.id
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
            activeAccountID = offlineAccounts.first?.id ?? account?.id
            persistActiveAccount()
        }
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
        if launchPhase == .checking {
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

    private func performLaunch(_ plan: LaunchPlan) async {
        launchPhase = .launching
        try? FileManager.default.createDirectory(
            at: plan.gameDirectory,
            withIntermediateDirectories: true
        )
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
            detail: "\(launchAccount.name) · \(isOfflineLaunch ? "离线（伪正版）" : "微软正版")",
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
        var validSession: StoredSession?
        if isOffline {
            // 离线（伪正版）模式根本不碰微软令牌：用固定离线 UUID 直接进入单机 / LAN。
            checks.append(LaunchCheck(
                id: "session",
                title: "登录令牌",
                detail: "离线（伪正版）模式：无需微软令牌，单机 / 局域网可用。在线正版服务器会拒绝，属预期。",
                status: .ok
            ))
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
            checks.append(LaunchCheck(
                id: "engine",
                title: "启动内核",
                detail: "Amethyst 内核尚未接入（M2）。安装和启动参数已经准备好，接入后即可拉起 JVM。",
                status: .failed
            ))
        }

        // 通用策略：同一个二进制在所有设备上按运行时可用内存自动收敛，
        // 不为具体机型出包，也不让用户把堆设到会被 jetsam 杀掉的值。
        let cap = DeviceCapabilities.maxSafeHeapMB
        let preferredMemory = Int(UserDefaults.standard.double(forKey: "memoryMB"))
        let preferred = preferredMemory > 0 ? preferredMemory : DeviceCapabilities.recommendedHeapMB
        let memory = min(preferred, cap)
        let recommended = DeviceCapabilities.recommendedHeapMB
        let overRecommended = memory > recommended + 512
        checks.append(LaunchCheck(
            id: "memory",
            title: "内存",
            detail: preferred > cap
                ? "设置 \(preferred) MB，本机安全上限 \(cap) MB，已自动夹到 \(memory) MB。"
                : (overRecommended
                    ? "\(memory) MB，高于建议的 \(recommended) MB，可能被系统终止。"
                    : "\(memory) MB（建议 \(recommended) MB · 上限 \(cap) MB）"),
            status: (preferred > cap || overRecommended) ? .warning : .ok
        ))

        var plan: LaunchPlan?
        let offlineToken = "offline"
        let accessToken = isOffline ? offlineToken : (validSession?.accessToken ?? "")
        let userType = isOffline ? "mojang" : "msa"
        if isOffline || validSession != nil {
            do {
                plan = try LaunchPlanBuilder.build(
                    detail: detail,
                    version: version,
                    layout: layout,
                    account: launchAccount,
                    accessToken: accessToken,
                    memoryMB: memory,
                    maxHeapMB: cap,
                    userType: userType
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
            account = renewed.account
            return renewed
        } catch {
            launchErrorMessage = "登录续期失败：\(error.localizedDescription)"
            return nil
        }
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
