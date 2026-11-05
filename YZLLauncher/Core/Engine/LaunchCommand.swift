import Foundation

/// 交给启动内核的完整命令行。
///
/// `gameArguments` 里含微软/Minecraft 访问令牌，因此本结构体：
/// - 只存在于内存，不落盘、不进 UserDefaults；
/// - 对外展示必须走 `redactedArguments` / `redactedDescription`；
/// - `environment` 只放非敏感路径，不复制任何令牌。
struct LaunchCommand: Equatable {
    let javaHome: URL?
    let arguments: [String]
    let environment: [String: String]
    let mainClass: String
    let memoryMB: Int

    /// 日志与 UI 专用的脱敏参数副本。
    var redactedArguments: [String] {
        LaunchCommand.redact(arguments)
    }

    /// 可以安全显示的一行摘要，刻意不包含完整命令行。
    var redactedDescription: String {
        "\(arguments.count) 项参数 · 主类 \(mainClass) · 堆 \(memoryMB) MB"
    }

    /// JVM 参数顺序是固定的：先 JVM 选项，再 -cp + 主类，最后游戏参数。
    /// Amethyst 的 JLI_Launch 层按同一顺序读取 argv，颠倒会导致主类被当成 JVM 选项。
    static func make(plan: LaunchPlan, javaHome: URL? = nil) -> LaunchCommand {
        var arguments = plan.jvmArguments
        arguments.append("-cp")
        arguments.append(plan.classpathString)
        arguments.append(plan.mainClass)
        arguments.append(contentsOf: plan.gameArguments)

        var environment = [
            "YZL_GAME_DIR": plan.gameDirectory.path,
            "YZL_NATIVES_DIR": plan.nativesDirectory.path
        ]
        if let javaHome {
            environment["JAVA_HOME"] = javaHome.path
        }

        return LaunchCommand(
            javaHome: javaHome,
            arguments: arguments,
            environment: environment,
            mainClass: plan.mainClass,
            memoryMB: plan.memoryMB
        )
    }

    /// 先找出所有 `--accessToken` 的值，再全局替换，防止令牌在别处重复出现时漏脱敏。
    static func redact(_ arguments: [String]) -> [String] {
        var secrets = Set<String>()
        var index = 0
        while index + 1 < arguments.count {
            if arguments[index] == "--accessToken" {
                secrets.insert(arguments[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        guard !secrets.isEmpty else { return arguments }
        return arguments.map { secrets.contains($0) ? "<redacted>" : $0 }
    }
}
