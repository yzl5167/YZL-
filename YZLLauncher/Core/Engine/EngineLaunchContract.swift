import Foundation

/// M2-b fork 桥的启动契约：把 YZL 已解析好的启动计划序列化成
/// `YZL_LAUNCH_PLAN.json`，交给 fork 内打了补丁的 `PojavLauncher` Java 主类。
///
/// 契约（与 fork 补丁 `engine/fork-patches/PojavLauncher.java` 一一对应）：
/// fork 的 `launchMinecraft` 分支读这个文件，走 Amethyst 既有的
/// PojavClassLoader + 反射 main 流程在进程内拉起游戏，
/// 绕开它自己的版本布局 / 安装器 / 参数组装（那些 YZL 都已经做完了）。
enum EngineLaunchContract {
    struct LaunchPlanDocument: Codable, Equatable {
        let mainClass: String
        /// 完整 classpath（客户端 jar + 全部依赖库），绝对路径。
        let classpath: [String]
        /// 游戏参数（占位符已替换；含访问令牌，只在内存与临时文件间传递）。
        let gameArguments: [String]
        /// 账号字段（fork 的 arg 组装需要）。
        let accountName: String
        let accountUUID: String
        let accessToken: String
        let xuid: String
        /// 版本与路径。
        let versionID: String
        let versionType: String
        let gameDirectory: String
        let assetsDirectory: String
        /// Java 主版本，fork 据此选 java_runtimes 里的运行时。
        let javaMajor: Int
        /// 堆大小（MB）；fork 在 jvm_processed 里追加 -Xmx 覆盖自己的默认值。
        let memoryMB: Int
    }

    enum ContractError: LocalizedError {
        case missingAccessToken

        var errorDescription: String? {
            switch self {
            case .missingAccessToken:
                return "启动计划缺少访问令牌（离线模式应为固定占位值），无法写入启动契约。"
            }
        }
    }

    /// 从 YZL 的 LaunchPlan 生成契约文档。
    static func document(from plan: LaunchPlan, accessToken: String, xuid: String = "") throws -> LaunchPlanDocument {
        guard !accessToken.isEmpty else {
            throw ContractError.missingAccessToken
        }
        return LaunchPlanDocument(
            mainClass: plan.mainClass,
            classpath: plan.classpath.map(\.path),
            gameArguments: plan.gameArguments,
            accountName: plan.accountName,
            accountUUID: plan.uuid,
            accessToken: accessToken,
            xuid: xuid,
            versionID: plan.version.id,
            versionType: plan.version.type,
            gameDirectory: plan.gameDirectory.path,
            assetsDirectory: plan.layout.assetsDirectory.path,
            javaMajor: plan.detail.javaVersion?.majorVersion ?? 8,
            memoryMB: plan.memoryMB
        )
    }

    /// 序列化到 Amethyst 主目录（fork 侧约定：`$AME_HOME/yzl-launch-plan.json`）。
    /// 返回写入路径，供环境变量 `YZL_LAUNCH_PLAN` 使用。
    @discardableResult
    static func write(_ document: LaunchPlanDocument, homeDirectory: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let url = homeDirectory.appendingPathComponent("yzl-launch-plan.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 清理已消费的契约文件（令牌不残留磁盘）。
    static func remove(homeDirectory: URL) {
        try? FileManager.default.removeItem(
            at: homeDirectory.appendingPathComponent("yzl-launch-plan.json")
        )
    }

    /// 临时挂载点：Amethyst fork 用 AME_HOME 作为主目录；
    /// YZL 侧用 Documents/YZLEngineHome 承接（fork 构建时 ObjC 入口会把 AME_HOME 指到这里）。
    static var homeDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("YZLEngineHome", isDirectory: true)
    }
}
