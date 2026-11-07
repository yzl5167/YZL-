import Foundation

/// 运行时部署档位：同一个二进制按系统版本自动决定「用哪个包、要不要电脑」。
///
/// 这是"通用 + 尽量免电脑"的落点 —— 不为具体机型出包，也不让用户自己查兼容表。
/// 覆盖全部 iOS 15+；「完全零电脑」只有 TrollStore 兼容区能做到，
/// 新系统最多做到「首次配对一次电脑，之后手机自维持」。
enum DeploymentProfile: String, Equatable {
    /// iOS 14.0 – 15.4.1：TrollHelperOTA 纯手机装 TrollStore，永久签名、自动 JIT、全程零电脑
    case permanentNoComputer
    /// iOS 15.5+ / 16.x / 16.7 RC / 17.0：TrollStore 永久签，但装它时需要电脑侧载一次；之后永久免维护
    case oneTimeComputerThenPermanent
    /// iOS 17.4 – 18.x：首次用电脑生成配对文件，之后 SideStore 续签 + StikDebug 开 JIT 全在手机
    case oneTimePairing
    /// iOS 26+：同上，但 JIT 改为 App 需显式适配的新方式，StikDebug 支持有限
    case appJITAdaptation
    /// 17.0.1 – 17.3.x / 16.7.x 非 RC：StikDebug 不支持，JIT 需电脑持续附加
    case computerAttached
    /// 低于 iOS 15：本 App 不支持
    case unsupportedOld

    var title: String {
        switch self {
        case .permanentNoComputer: return "永久签名 · 全程零电脑"
        case .oneTimeComputerThenPermanent: return "永久签名 · 首次电脑一次"
        case .oneTimePairing: return "一次配对 · 之后免电脑"
        case .appJITAdaptation: return "一次配对 · JIT 需适配"
        case .computerAttached: return "需电脑附加 JIT"
        case .unsupportedOld: return "系统版本过低"
        }
    }

    var computerRequirement: String {
        switch self {
        case .permanentNoComputer:
            return "完全不需要；手机 Safari 走 TrollHelperOTA，连首次都不用"
        case .oneTimeComputerThenPermanent:
            return "仅首次：电脑侧载 TrollInstallerX / TrollRestore 装好 TrollStore；之后永久免维护"
        case .oneTimePairing:
            return "仅首次：电脑生成配对文件 + 装 SideStore；之后手机自行续签、开 JIT"
        case .appJITAdaptation:
            return "仅首次配对；但 iOS 26+ 的 JIT 需 App 适配，M2 阶段处理"
        case .computerAttached:
            return "续签与 JIT 都需电脑参与（AltServer / SideJITServer）"
        case .unsupportedOld:
            return "请升级到 iOS 15.0 或更高"
        }
    }

    /// 设置完成后能否脱离电脑日常使用。
    var unattendedAfterSetup: Bool {
        switch self {
        case .permanentNoComputer, .oneTimeComputerThenPermanent, .oneTimePairing: return true
        case .appJITAdaptation, .computerAttached, .unsupportedOld: return false
        }
    }

    /// 该档位该发哪个包给用户。
    var packageName: String {
        switch self {
        case .permanentNoComputer, .oneTimeComputerThenPermanent:
            return "com.yzl.launcher.tipa"
        default:
            return "YZLLauncher-unsigned.ipa（需自签）"
        }
    }
}

extension DeviceCapabilities {
    static func deploymentProfile(major: Int, minor: Int, build: String) -> DeploymentProfile {
        switch installRoute(major: major, minor: minor, build: build) {
        case .unsupportedOld:
            return .unsupportedOld
        case .trollStore:
            // 14.0–15.4.1 可用 TrollHelperOTA 纯手机安装；
            // 15.5/15.6 正式版及 16.x / 17.0 要 TrollInstallerX / TrollRestore，首次需电脑一次。
            if major >= 16 || (major == 15 && minor >= 5) {
                return .oneTimeComputerThenPermanent
            }
            return .permanentNoComputer
        case .computerSign:
            // StikDebug 从 17.4 起才支持「配对一次、之后手机端开 JIT」。
            if major >= 26 { return .appJITAdaptation }
            if major > 17 || (major == 17 && minor >= 4) { return .oneTimePairing }
            return .computerAttached
        }
    }

    static var deploymentProfile: DeploymentProfile {
        let version = systemMajorMinor
        return deploymentProfile(major: version.major, minor: version.minor, build: osBuild)
    }
}
