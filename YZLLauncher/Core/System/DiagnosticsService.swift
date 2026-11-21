import Foundation

/// 修复助手的体检项。对齐 Windows 端 PageRepair：
/// 逐项展示状态 + 给出修复建议，一键修复只做"安全可自动"的动作。
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
    /// 是否能自动修复（nil 表示只能给建议，用户手动处理）。
    let fixAction: FixAction?

    enum FixAction: String {
        case clearDownloadCache
        case restoreMods
        case resetDownloadSourcesHealth
        case openSettings
    }
}

/// 修复助手：汇总当前可自动检测的项，并执行安全修复。
/// 不碰游戏存档与账号数据——和 Windows 端"只删启动器配置、保留游戏"一致。
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
            fixAction: hasAccount ? nil : .openSettings
        ))

        // 游戏版本
        let versionCount = appState.installedVersions.count
        items.append(DiagnosticItem(
            id: "version",
            title: "游戏版本",
            detail: versionCount > 0 ? "已安装 \(versionCount) 个版本" : "尚未安装任何游戏版本。",
            status: versionCount > 0 ? .ok : .warning,
            fixAction: nil
        ))

        // Java
        items.append(DiagnosticItem(
            id: "java", title: "Java 运行时",
            detail: appState.javaStatus.title,
            status: appState.javaStatus.isReady ? .ok : .failed,
            fixAction: appState.javaStatus.isReady ? nil : .openSettings
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

        // 下载缓存
        let cacheBytes = DownloadCache.pendingBytes()
        items.append(DiagnosticItem(
            id: "cache",
            title: "下载缓存",
            detail: cacheBytes > 0
                ? "有 \(InstallFormats.bytes(cacheBytes)) 临时分片可清理"
                : "无残留缓存",
            status: cacheBytes > 0 ? .warning : .ok,
            fixAction: cacheBytes > 0 ? .clearDownloadCache : nil
        ))

        // 启动日志
        let logBytes = YZLBootLog.byteCount
        items.append(DiagnosticItem(
            id: "log",
            title: "启动日志",
            detail: logBytes > 0 ? "\(InstallFormats.bytes(logBytes))，可在控制台查看" : "暂无日志",
            status: .ok,
            fixAction: nil
        ))

        return items
    }

    /// 执行一个自动修复动作，返回人话结果。
    @discardableResult
    static func perform(_ action: DiagnosticItem.FixAction) -> String {
        switch action {
        case .clearDownloadCache:
            let result = DownloadCache.clear()
            return "已清理 \(InstallFormats.bytes(result.bytesRemoved)) 缓存：\(result.lines.joined(separator: "；"))"
        case .restoreMods:
            // 由调用方带版本上下文执行；这里不直接做，返回提示。
            return "请在「版本 → 移动端兼容」里点「恢复原样」。"
        case .resetDownloadSourcesHealth:
            SourceHealth.shared.reset()
            return "已清空下载源健康记录。"
        case .openSettings:
            return "请在「设置」里检查对应项。"
        }
    }
}
