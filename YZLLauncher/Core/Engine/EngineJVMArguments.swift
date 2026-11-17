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
        // 上限保护：iOS 设备（含 iPad Pro）给 JVM 的连续堆实际很难超过 6 GB，
        // 传更大的 -Xmx 会让 HotSpot 在初始化时直接 abort（瞬间闪退，无 Swift 异常）。
        // 下限 512MB 保证 JVM 起得来。2026-11-17 加，针对「Java 17 一启动就崩」。
        let heap = min(6144, max(512, heapMB))
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
    ///
    /// 2026-11-17 加固（Java 17 启动瞬间崩溃）：用户「额外 JVM 参数」里若带
    /// 与 build() 矛盾的 GC 开关（如 `-XX:-UseG1GC` vs 我们注入的 `-XX:+UseG1GC`），
    /// HotSpot 会在初始化阶段直接 abort，整个 App 进程随之退出——表现就是
    /// 「一启动就闪退」，且 Swift 侧 try/catch 接不到。这里统一丢弃用户侧的
    /// GC 选择权（交给引擎默认 + build()），并对转发参数去重。
    static func sanitized(from arguments: [String]) -> [String] {
        let blockedPrefixes = ["-Djava.library.path", "-Djava.class.path", "-jar"]
        let blockedWithSeparateValue: Set<String> = ["-cp", "-classpath"]
        // GC 选择类：build() 已统一注入，用户侧一律忽略，避免 +UseG1GC / -UseG1GC 互相打架
        let gcKeys = ["UseG1GC", "UseSerialGC", "UseParallelGC", "UseZGC",
                      "UseShenandoahGC", "UseConcMarkSweepGC", "UseEpsilonGC"]
        func isGCFlag(_ arg: String) -> Bool {
            guard arg.hasPrefix("-XX:") else { return false }
            return gcKeys.contains { key in
                arg.contains("+\(key)") || arg.contains("-\(key)")
            }
        }
        var result: [String] = []
        var seen = Set<String>()
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
            if blockedPrefixes.contains(where: { argument.hasPrefix($0) }) { continue }
            if isGCFlag(argument) { continue }
            // 去重：完全相同的参数只保留一条，避免重复 -Xmx/-XX 引发解析歧义
            guard seen.insert(argument).inserted else { continue }
            result.append(argument)
        }
        return result
    }
}
