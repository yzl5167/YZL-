import Foundation

/// 交给 fork 引擎的 `jvm_processed` 参数。
///
/// Amethyst 的 `launchJVM` 在 JLI_Launch 之前就把参数拼好了（`-Xmx` 由偏好算出来），
/// 之后才把 `launchTarget[@"arguments"][@"jvm_processed"]` 追加进来。HotSpot 对重复的
/// `-Xmx` 取最后一个，所以这里补上的堆大小才真正生效——这是启动器 UI 上那个
/// 「游戏内存」滑块唯一能落到 JVM 上的路径。
///
/// 注意：**不要**把 `LaunchPlan.jvmArguments` 整份塞进来。那份里带着
/// `-Djava.library.path=<实例>/natives`，而整合包自带的 natives 是 Windows 的
/// `lwjgl.dll` / `glfw.dll`；在 iOS 上指过去会让 LWJGL 去 dlopen PE 文件，游戏连
/// 主界面都出不来。iOS 的 native 路径由 Amethyst 自己指向 App 内的 Frameworks。
enum EngineJVMArguments {
    /// 只放「确定安全且真的有用」的参数。
    static func build(heapMB: Int, javaMajor: Int = 17) -> [String] {
        let heap = max(512, heapMB)
        var arguments = [
            "-Xmx\(heap)M",
            // 初始堆保持小：iOS 的虚拟内存要连续，-Xms 跟着 -Xmx 一起涨容易被 jetsam 盯上。
            "-Xms\(min(512, max(256, heap / 3)))M"
        ]
        if javaMajor >= 9 {
            arguments.append("-XX:+UseG1GC")
        }
        arguments.append("-Dlog4j2.formatMsgNoLookups=true")
        arguments.append("-Dfml.earlyprogresswindow=false")
        return arguments
    }

    /// 从启动计划里过滤出可以安全转发的参数：只留 `-Xmx/-Xms/-XX:` 这类，
    /// 路径类（`-Djava.library.path`）与产品标识类一律丢弃。
    /// `-cp` / `-classpath` 是两段式参数，值（jar 路径）也要一并丢掉。
    static func sanitized(from arguments: [String]) -> [String] {
        let blockedPrefixes = ["-Djava.library.path", "-Djava.class.path", "-jar"]
        let blockedWithSeparateValue: Set<String> = ["-cp", "-classpath"]
        var result: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if blockedWithSeparateValue.contains(argument) {
                skipNext = true
                continue
            }
            if blockedPrefixes.contains(where: { argument.hasPrefix($0) }) {
                continue
            }
            result.append(argument)
        }
        return result
    }
}
