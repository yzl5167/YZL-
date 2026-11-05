import Foundation

/// 启动前的完整参数。只存在于内存里，`gameArguments` 含访问令牌，禁止写日志或落盘。
struct LaunchPlan {
    let version: MinecraftVersion
    let detail: VersionDetail
    let layout: InstallLayout
    let classpath: [URL]
    let assetIndexName: String
    let mainClass: String
    let memoryMB: Int
    let jvmArguments: [String]
    let gameArguments: [String]
    let accountName: String
    let uuid: String

    /// 可以展示给用户的摘要，刻意不包含令牌和完整命令行。
    var summary: String {
        let java = detail.javaVersion?.majorVersion ?? 8
        return "\(version.id) · Java \(java) · \(classpath.count) 个 classpath 项 · \(memoryMB) MB 堆"
    }

    /// Amethyst / JVM 侧使用的 classpath 字符串（iOS 用冒号分隔）。
    var classpathString: String {
        classpath.map(\.path).joined(separator: ":")
    }

    var gameDirectory: URL { layout.gameDirectory }
    var nativesDirectory: URL { layout.nativesDirectory }
}

enum LaunchPlanError: LocalizedError {
    case missingMainClass
    case missingAccessToken
    case missingGameFile(String)

    var errorDescription: String? {
        switch self {
        case .missingMainClass:
            return "版本 JSON 里没有 mainClass，无法确定游戏入口。"
        case .missingAccessToken:
            return "登录会话缺少访问令牌，请重新登录微软账户。"
        case .missingGameFile(let path):
            return "启动所需文件缺失：\(path)"
        }
    }
}

enum LaunchPlanBuilder {
    /// 客户端 jar 在前，随后是按 Mojang 规则过滤后的依赖库；路径去重顺序与安装器一致。
    static func classpath(detail: VersionDetail, layout: InstallLayout) -> [URL] {
        var classpath = [layout.clientJar]
        var seenPaths = Set<String>()

        for library in detail.libraries ?? [] {
            guard InstallPlanner.isAllowed(rules: library.rules, osName: "ios") else { continue }
            guard let path = library.downloads?.artifact?.path,
                  !path.isEmpty,
                  !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            classpath.append(layout.libraryURL(path: path))
        }
        return classpath
    }

    static func build(detail: VersionDetail,
                      version: MinecraftVersion,
                      layout: InstallLayout,
                      account: MicrosoftAccount,
                      accessToken: String,
                      memoryMB: Int,
                      maxHeapMB: Int = 4096,
                      userType: String = "msa") throws -> LaunchPlan {
        guard let rawMainClass = detail.mainClass?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawMainClass.isEmpty else {
            throw LaunchPlanError.missingMainClass
        }
        guard !accessToken.isEmpty else {
            throw LaunchPlanError.missingAccessToken
        }

        let classpath = Self.classpath(detail: detail, layout: layout)

        let classpathString = classpath.map(\.path).joined(separator: ":")

        let javaMajor = detail.javaVersion?.majorVersion ?? 8
        // 通用包：堆上限由设备运行时可用内存给出，默认 4096 MB 保持旧行为与单测稳定。
        // 低内存设备（老 iPhone）不会因为在设置里拖到 4096 就被 jetsam 杀掉。
        let ceiling = max(512, maxHeapMB)
        let heap = max(512, min(memoryMB, ceiling))

        var resolverContext = ArgumentResolver.Context(
            accountName: account.name,
            uuid: account.id,
            accessToken: accessToken,
            xuid: "",
            versionID: version.id,
            versionType: version.type,
            assetsDir: layout.assetsDirectory.path,
            gameDir: layout.gameDirectory.path,
            nativesDir: layout.nativesDirectory.path,
            launcherName: "YZL Launcher",
            launcherVersion: DeviceInfo.appVersion,
            classpath: classpathString,
            assetsIndexName: detail.assetIndexName,
            width: nil,
            height: nil
        )
        // 离线（伪正版）账号走 mojang，正版走 msa；合成初始化器不收此标签参数，故构造后赋值。
        resolverContext.userType = userType

        var jvmArguments = [
            "-Xmx\(heap)M",
            "-Xms\(max(256, heap / 2))M",
            "-Djava.library.path=\(layout.nativesDirectory.path)",
            "-Dminecraft.launcher.brand=YZL Launcher",
            "-Dminecraft.launcher.version=\(DeviceInfo.appVersion)",
            "-Duser.home=\(layout.root.path)",
            "-Dlog4j2.formatMsgNoLookups=true"
        ]
        if javaMajor >= 9 {
            jvmArguments.append("-XX:+UseG1GC")
        }
        // 版本自带的 JVM 参数（如 -Xss1M、-Djava.library.path 等）追加在堆参数之后，
        // 其中的 ${classpath} 由 ArgumentResolver 剥离，最终由 LaunchCommand 用 -cp 统一注入。
        jvmArguments.append(contentsOf: ArgumentResolver.jvmArguments(version: detail, context: resolverContext))

        // 游戏参数优先用版本 JSON 自带的 arguments / minecraftArguments；都没有则回退到内置集。
        let gameArguments = ArgumentResolver.gameArguments(version: detail, context: resolverContext)

        return LaunchPlan(
            version: version,
            detail: detail,
            layout: layout,
            classpath: classpath,
            assetIndexName: detail.assetIndexName,
            mainClass: rawMainClass,
            memoryMB: heap,
            jvmArguments: jvmArguments,
            gameArguments: gameArguments,
            accountName: account.name,
            uuid: account.id
        )
    }
}

struct LaunchCheck: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case ok
        case warning
        case failed
    }

    let id: String
    let title: String
    let detail: String
    let status: Status
}

struct LaunchReadiness {
    let checks: [LaunchCheck]
    let plan: LaunchPlan?

    var canLaunch: Bool {
        plan != nil && !checks.contains { $0.status == .failed }
    }

    var blocker: String? {
        checks.first { $0.status == .failed }?.detail
    }
}
