import Foundation

/// 修复助手的体检项。对齐 Windows 端 PageRepair：
/// 逐项展示状态 + 给出修复建议。只做"安全可自动"的动作，不碰存档与账号数据。
struct DiagnosticItem: Identifiable {
    enum Status: String {
        case ok
        case warning
        case failed
    }

    let id: String
    let title: String
    let detail: String
    let status: Status
    /// 可自动执行的修复动作；nil 表示只能跳转或需要用户手动处理。
    let fixAction: FixAction?

    enum FixAction: Equatable {
        case clearDownloadCache
        case resetSourceHealth
        case openAccount
        case openJavaSettings
        case openMobileCompat
        case openDownloadPage

        /// 是否可在修复助手内直接执行（其余为跳转到对应页面）。
        var isAutoFix: Bool {
            switch self {
            case .clearDownloadCache, .resetSourceHealth: return true
            default: return false
            }
        }

        var buttonTitle: String {
            switch self {
            case .clearDownloadCache: return "清理"
            case .resetSourceHealth: return "重置"
            case .openAccount: return "去登录"
            case .openJavaSettings: return "去管理"
            case .openMobileCompat: return "去处理"
            case .openDownloadPage: return "去安装"
            }
        }
    }
}

/// 修复助手：汇总当前可自动检测的项，并执行安全修复。
enum DiagnosticsService {
    @MainActor
    static func run(appState: AppState) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        // 账号
        let hasAccount = appState.hasAnyAccount
        items.append(DiagnosticItem(
            id: "account",
            title: "账号",
            detail: hasAccount ? "已选择账号：\(appState.activeAccountKindText)" : "没有可用账号，无法启动在线游戏。",
            status: hasAccount ? .ok : .warning,
            fixAction: hasAccount ? nil : .openAccount
        ))

        // 游戏版本
        let versionCount = appState.installedVersions.count
        items.append(DiagnosticItem(
            id: "version",
            title: "游戏版本",
            detail: versionCount > 0 ? "已安装 \(versionCount) 个版本" : "尚未安装任何游戏版本。",
            status: versionCount > 0 ? .ok : .warning,
            fixAction: versionCount > 0 ? nil : .openDownloadPage
        ))

        // Java：用与启动自检同一套 selection 判定，避免"体检通过但启动失败"。
        let requiredJava = requiredJavaMajor(for: appState.selectedVersion)
        let javaSelection = JavaEnvironment.selection(for: requiredJava)
        let (javaDetail, javaStatus): (String, DiagnosticItem.Status) = {
            switch javaSelection {
            case .exact(let runtime):
                return ("Java \(runtime.major)，与版本要求一致", .ok)
            case .fallback(let runtime, let need):
                return ("需要 Java \(need)，当前 \(runtime.major)（向后兼容，建议装匹配包）", .warning)
            case .missing(let need, let available):
                let list = available.isEmpty ? "无" : available.map(String.init).joined(separator: " / ")
                return ("缺少 Java \(need)，当前可用：\(list)", .failed)
            }
        }()
        items.append(DiagnosticItem(
            id: "java", title: "Java 运行时", detail: javaDetail,
            status: javaStatus,
            fixAction: javaStatus == .ok ? nil : .openJavaSettings
        ))

        // 引擎
        items.append(DiagnosticItem(
            id: "engine", title: "启动内核",
            detail: appState.engineStatus.title,
            status: appState.engineStatus.isReady ? .ok : .failed,
            fixAction: nil
        ))

        // 性能模式（JIT）
        switch appState.jitStatus {
        case .enabled:
            items.append(DiagnosticItem(id: "jit", title: "性能模式", detail: "已开启", status: .ok, fixAction: nil))
        default:
            items.append(DiagnosticItem(
                id: "jit", title: "性能模式", detail: appState.jitStatus.title,
                status: .warning, fixAction: nil
            ))
        }

        // 下载源健康：用清单 URL 的镜像/官方两个候选查失败记录。
        let manifest = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!
        let candidates = [MirrorPolicy.rewrite(manifest, source: .mirror),
                          MirrorPolicy.rewrite(manifest, source: .official)]
        let badCount = candidates.filter { SourceHealth.shared.failureCount(for: $0) > 0 }.count
        items.append(DiagnosticItem(
            id: "sources", title: "下载源",
            detail: badCount > 0 ? "\(badCount) 个源本次会话失败过，已自动排到候选末尾" : "下载源健康",
            status: badCount > 0 ? .warning : .ok,
            fixAction: badCount > 0 ? .resetSourceHealth : nil
        ))

        // 下载缓存：安装进行中禁止清理，否则会删掉正在写入的分片导致安装失败。
        let cacheBytes = DownloadCache.pendingBytes()
        let installBusy = appState.installQueue.state.phase == .running
        items.append(DiagnosticItem(
            id: "cache",
            title: "下载缓存",
            detail: installBusy
                ? "正有安装任务进行，暂不可清理缓存"
                : (cacheBytes > 0 ? "有 \(InstallFormats.bytes(cacheBytes)) 临时分片可清理" : "无残留缓存"),
            status: cacheBytes > 0 ? .warning : .ok,
            fixAction: (cacheBytes > 0 && !installBusy) ? .clearDownloadCache : nil
        ))

        // 移动端兼容（模组中转换区）：遍历已安装版本统计被隔离的模组。
        let quarantined = appState.installedVersions.reduce(0) { total, installed in
            let gameDir = InstallLayout.forVersion(installed.id).gameDirectory
            return total + MobileCompat.listMods(in: gameDir).filter { !$0.isEnabled }.count
        }
        items.append(DiagnosticItem(
            id: "compat", title: "模组兼容",
            detail: quarantined > 0 ? "有 \(quarantined) 个模组被移出 mods（mods-ios-off）" : "无隔离模组",
            status: quarantined > 0 ? .warning : .ok,
            fixAction: quarantined > 0 ? .openMobileCompat : nil
        ))

        // 启动日志：无日志给 warning 提示先启动一次。
        let logBytes = YZLBootLog.byteCount
        items.append(DiagnosticItem(
            id: "log", title: "启动日志",
            detail: logBytes > 0 ? "\(InstallFormats.bytes(logBytes))，可在控制台查看" : "暂无日志，先启动一次游戏",
            status: logBytes > 0 ? .ok : .warning,
            fixAction: nil
        ))

        return items
    }

    /// 与 AppState.buildReadiness 一致的 Java 大版本推导。
    private static func requiredJavaMajor(for version: MinecraftVersion?) -> Int {
        guard let version else { return JavaEnvironment.recommendedMajor(gameVersion: nil) }
        let locked = VersionSettingsStore().settings(for: version.id).lockedJavaMajor
        return locked ?? JavaEnvironment.recommendedMajor(gameVersion: version.id)
    }

    /// 执行一个自动修复动作，返回人话结果。导航类动作由 View 处理，不走这里。
    @discardableResult
    static func perform(_ action: DiagnosticItem.FixAction) -> String {
        switch action {
        case .clearDownloadCache:
            let result = DownloadCache.clear()
            return "已清理 \(InstallFormats.bytes(result.bytesRemoved)) 缓存。"
        case .resetSourceHealth:
            SourceHealth.shared.reset()
            return "已清空下载源健康记录，后续会重新测速排序。"
        case .openAccount:
            return "请登录或创建离线账号。"
        case .openJavaSettings:
            return "请在「设置 → Java 环境」里安装匹配版本的 JRE。"
        case .openMobileCompat:
            return "请在「设置 → iPhone 兼容」里点「恢复原样」。"
        case .openDownloadPage:
            return "请在「下载」页安装一个游戏版本。"
        }
    }
}
