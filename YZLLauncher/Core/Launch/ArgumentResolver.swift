import Foundation

/// 把版本 JSON 里的 `arguments`（1.13+）或 `minecraftArguments`（1.12.2 及更早）
/// 展开成最终命令行参数，替换 `${...}` 占位符，并按平台 / feature 规则过滤。
///
/// iOS 不在 Mojang 官方那套 os.name（osx / windows / linux）里，因此任何带 `os` 规则的
/// 参数或库都会被过滤掉——这正好符合「iOS 是自定义平台」的事实，不会把桌面专有参数带进来。
enum ArgumentResolver {
    /// 启动时的可变上下文，用于替换占位符。
    struct Context {
        let accountName: String
        let uuid: String
        let accessToken: String
        let xuid: String
        let versionID: String
        let versionType: String
        let assetsDir: String
        let gameDir: String
        let nativesDir: String
        let launcherName: String
        let launcherVersion: String
        let classpath: String
        let assetsIndexName: String
        let width: Int?
        let height: Int?
        /// 账号类型：正版走 `"msa"`，离线（伪正版）走 `"mojang"`。
        /// 默认值保持旧行为，调用方不显式传也能编译。
        /// 注：用 `var` + 构造后赋值，因为本工程 Swift 工具链的合成成员初始化器
        /// 不会把带默认值的属性列为可显式传参的标签参数。
        var userType: String = "msa"
    }

    /// 解析游戏参数。优先用 `arguments.game`；否则用旧式 `minecraftArguments` 字符串；
    /// 两者皆无（自定义 / 精简版本）回退到启动器内置的安全参数集。
    static func gameArguments(version: VersionDetail, context: Context) -> [String] {
        // 继承 profile 的 `game: []` 语义是「不追加」而不是「清空」；
        // 为空时继续回退到旧式参数串 / 内置兜底集，避免生成没有账号信息的命令行。
        if let game = version.arguments?.game, !game.isEmpty {
            return cleanup(expand(tokens: game, context: context))
        }
        if let legacy = version.minecraftArguments, !legacy.isEmpty {
            return cleanup(legacy
                .split(separator: " ")
                .map { substitute(String($0), context) })
        }
        return fallbackGameArguments(context: context)
    }

    /// 解析 JVM 参数。版本可能用 `arguments.jvm` 提供 `-Xss`、`-Djava.library.path` 等；
    /// 其中的 `${classpath}` 由启动命令统一用 `-cp` 注入，这里主动剥离，避免重复或主类被吞。
    static func jvmArguments(version: VersionDetail, context: Context) -> [String] {
        guard let jvm = version.arguments?.jvm else {
            return []
        }
        // 必须在占位符替换「之前」按原始 token 剥离：expand 会把 ${classpath}
        // 换成真实路径，之后再按字面量查找永远命中不了，命令行会出现第二组 -cp。
        return expand(tokens: stripClasspathTokens(jvm), context: context)
    }

    // MARK: - 占位符

    private static func substitute(_ raw: String, _ context: Context) -> String {
        var result = raw
        let pairs: [(String, String)] = [
            ("${auth_player_name}", context.accountName),
            ("${auth_uuid}", context.uuid),
            ("${auth_access_token}", context.accessToken),
            ("${auth_session}", context.accessToken),
            ("${auth_xuid}", context.xuid),
            ("${user_type}", context.userType),
            ("${clientid}", ""),
            ("${user_properties}", "{}"),
            ("${version_name}", context.versionID),
            ("${version_type}", context.versionType),
            ("${assets_root}", context.assetsDir),
            ("${game_directory}", context.gameDir),
            ("${assets_index_name}", context.assetsIndexName),
            ("${natives_directory}", context.nativesDir),
            ("${launcher_name}", context.launcherName),
            ("${launcher_version}", context.launcherVersion),
            ("${resolution_width}", context.width.map { String($0) } ?? ""),
            ("${resolution_height}", context.height.map { String($0) } ?? ""),
            ("${classpath}", context.classpath),
            ("${quickPlayPath}", ""),
            ("${quickPlaySingleplayer}", ""),
            ("${quickPlayMultiplayer}", ""),
            ("${quickPlayRealms}", "")
        ]
        for (placeholder, value) in pairs {
            result = result.replacingOccurrences(of: placeholder, with: value)
        }
        return result
    }

    // MARK: - token 展开与规则过滤

    private static func expand(tokens: [VersionDetail.ArgumentToken], context: Context) -> [String] {
        var result: [String] = []
        for token in tokens {
            switch token {
            case .string(let value):
                result.append(substitute(value, context))
            case .ruled(let values, let rules):
                guard isArgumentAllowed(rules: rules, context: context) else { continue }
                for value in values {
                    result.append(substitute(value, context))
                }
            }
        }
        return result
    }

    /// 同时评估 `os` 与 `features` 两条规则（库的 `InstallPlanner.isAllowed` 只看 os）。
    /// 最后一条匹配的 `allow` / `disallow` 规则决定该项是否保留。
    private static func isArgumentAllowed(rules: [VersionDetail.Library.Rule]?, context: Context) -> Bool {
        guard let rules, !rules.isEmpty else { return true }
        var allowed = false
        for rule in rules {
            let osMatches: Bool
            if let os = rule.os {
                // iOS 不是官方三平台，任何带 os.name 的规则在 iOS 上都不匹配（除非显式 "ios"）。
                osMatches = (os.name == nil || os.name == "ios")
            } else {
                osMatches = true
            }
            guard osMatches else { continue }
            let featuresMatch: Bool
            if let features = rule.features {
                featuresMatch = evaluateFeatures(features, context: context)
            } else {
                featuresMatch = true
            }
            guard featuresMatch else { continue }
            allowed = rule.action == "allow"
        }
        return allowed
    }

    private static func evaluateFeatures(_ features: VersionDetail.Library.Rule.Features, context: Context) -> Bool {
        if let demo = features.isDemoUser, demo {
            // 我们始终使用正版账户，不是 demo 用户，因此这条 allow 规则不满足。
            return false
        }
        if let custom = features.hasCustomResolution, custom {
            return context.width != nil && context.height != nil
        }
        return true
    }

    /// 移除版本 jvm 参数里由 `${classpath}` 占位符衍生出的 token，
    /// 让启动命令的 `-cp` 成为唯一权威来源。必须在 `expand` 之前调用。
    private static func stripClasspathTokens(_ tokens: [VersionDetail.ArgumentToken]) -> [VersionDetail.ArgumentToken] {
        var result: [VersionDetail.ArgumentToken] = []
        for token in tokens {
            if case .string(let value) = token, value.contains("${classpath}") {
                // 形如 `-Djava.class.path=${classpath}`，连同紧邻的 `-cp` 一起丢弃。
                if let last = result.last,
                   case .string(let previous) = last,
                   previous == "-cp" {
                    result.removeLast()
                }
                continue
            }
            result.append(token)
        }
        return result
    }

    /// quickPlay 系列 feature 启动器不实现，占位符已替换为空值；
    /// 把这些 flag 连同它后面的值一起删掉，避免孤立参数混进命令行。
    private static func cleanup(_ args: [String]) -> [String] {
        let unsupported: Set<String> = [
            "--quickPlayPath", "--quickPlaySingleplayer",
            "--quickPlayMultiplayer", "--quickPlayRealms"
        ]
        var result: [String] = []
        var index = 0
        while index < args.count {
            let value = args[index]
            if unsupported.contains(value) {
                index += (index + 1 < args.count) ? 2 : 1
                continue
            }
            result.append(value)
            index += 1
        }
        return result
    }

    // MARK: - 兜底参数集

    /// 版本 JSON 未提供任何参数时使用的保守启动参数，覆盖最常用字段，
    /// 与 1.12.2 的 `minecraftArguments` 等价展开，保证精简 / 自定义版本仍能进入游戏。
    private static func fallbackGameArguments(context: Context) -> [String] {
        var args: [String] = [
            "--username", context.accountName,
            "--version", context.versionID,
            "--gameDir", context.gameDir,
            "--assetsDir", context.assetsDir,
            "--assetIndex", context.assetsIndexName,
            "--uuid", context.uuid,
            "--accessToken", context.accessToken,
            "--userType", context.userType,
            "--versionType", context.versionType
        ]
        if let width = context.width, let height = context.height {
            args += ["--width", "\(width)", "--height", "\(height)"]
        }
        return args
    }
}
