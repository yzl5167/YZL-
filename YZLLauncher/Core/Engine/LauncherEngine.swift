import Foundation

enum JITStatus: String, Equatable {
    case unknown
    case enabled
    case disabled

    var title: String {
        switch self {
        case .unknown: return "未知"
        case .enabled: return "已启用"
        case .disabled: return "未启用"
        }
    }
}

enum JavaRuntimeStatus {
    case missing
    case ready(String)

    var title: String {
        switch self {
        case .missing: return "未安装"
        case .ready(let version): return version
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum EngineStatus {
    case notInstalled
    case ready(String)

    var title: String {
        switch self {
        case .notInstalled: return "未接入"
        case .ready(let version): return version
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// 启动内核只接收已经拼好的 LaunchPlan。外壳负责账户、文件、JRE 与参数校验，
/// 内核负责真正的 JLI_Launch / SurfaceViewController 挂载。
protocol LauncherEngine {
    var name: String { get }
    var isAvailable: Bool { get }
    func launch(_ plan: LaunchPlan) async throws
}

enum EngineError: LocalizedError, Equatable {
    case notIntegrated
    case runtimeMissing
    case jitDisabled
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notIntegrated:
            return "没找到启动内核的 launchJVM 入口。若已装 fork 引擎单包，请把设备日志里 [YZL] launchJVM 一行反馈；若装的是 1.1MB 外壳 IPA，请改装 YZL-engine-sideload-unsigned.ipa 或 .tipa。"
        case .runtimeMissing:
            return "没有找到可用的 iOS JRE。"
        case .jitDisabled:
            return "JIT 未开启，Java 运行时无法启动。"
        case .launchFailed(let message):
            return "内核启动失败：\(message)"
        }
    }
}

/// M2 之前的占位实现：明确报告未接入，不假装启动成功。
struct PlaceholderEngine: LauncherEngine {
    let name = "Amethyst / Pojav 系（待接入）"
    let isAvailable = false

    func launch(_ plan: LaunchPlan) async throws {
        throw EngineError.notIntegrated
    }
}
