import Foundation
import UIKit
import ObjectiveC
import Darwin

/// M2-b 运行时桥：在 Amethyst fork 进程内，由 YZL UI（YZLUI.framework）
/// 驱动引擎启动。
///
/// 设计前提（见 docs/M2B-ENGINE.md）：
/// - fork 的主二进制里才有 `launchJVM` 符号——纯外壳构建里 dlsym 找不到，
///   本桥如实报 `notIntegrated`，不会假装可用；
/// - 启动契约（mainClass / classpath / gameArgs）通过 `YZL_LAUNCH_PLAN.json`
///   交给 fork 内打了补丁的 `PojavLauncher` Java 主类；
/// - 游戏画面由 fork 的 `SurfaceViewController` 承载，这里用运行时类查找呈现，
///   编译期不依赖任何 Amethyst 源码——纯外壳构建保持全绿。
/// Darwin 的 dlsym 句柄常量与可靠符号查找。
///
/// 真机反馈（2026-11-08）：装完整引擎包后仍提示「没有启动内核」。
/// 根因不是缺内核——主二进制的 dyld 导出表里确实有 `_launchJVM`——
/// 而是 `YZLUI.framework` 由 SceneDelegate `dlopen` 加载，从 framework 内部
/// 用 `dlsym(nil, ...)` 查主程序符号查不到：
///   · NULL 不是 RTLD_DEFAULT（Darwin 上 RTLD_DEFAULT = (void *)-2，
///     JITProbe 也是用 -2 而不是 nil）；
///   · 即便用 RTLD_DEFAULT(-2)，语义也是「从调用者依赖链开始查」，
///     dlopen 进来的 framework 依赖链里不含主可执行文件。
/// 因此必须显式用 RTLD_MAIN_ONLY(-5) 查主程序，并保留全局查与显式
/// dlopen 主可执行文件两条兜底，覆盖不同签名形态 / 系统版本。
enum EngineSymbolResolver {
    static func resolve(_ symbol: String) -> UnsafeMutableRawPointer? {
        let mainOnly = UnsafeMutableRawPointer(bitPattern: -5)   // RTLD_MAIN_ONLY
        let global = UnsafeMutableRawPointer(bitPattern: -2)     // RTLD_DEFAULT
        if let pointer = dlsym(mainOnly, symbol) { return pointer }
        if let pointer = dlsym(global, symbol) { return pointer }
        if let executable = Bundle.main.executableURL?.path,
           let handle = dlopen(executable, Int32(RTLD_NOW | RTLD_LOCAL)) {
            return dlsym(handle, symbol)
        }
        return nil
    }
}

struct YZLEngineHost: LauncherEngine {
    /// 参数是「该游戏版本需要的 Java 大版本」，不是随便拿第一个 JRE。
    typealias JavaHomeProvider = (Int) -> URL?
    typealias SymbolResolver = (String) -> UnsafeMutableRawPointer?

    let name = "Amethyst 引擎（fork，YZL UI 注入）"

    private let payload: EnginePayloadLocator.Payload
    private let javaHomeProvider: JavaHomeProvider
    private let probe: JITProbe.Probe
    private let resolveSymbol: SymbolResolver
    private let classLookup: (String) -> AnyClass?

    init(payload: EnginePayloadLocator.Payload? = nil,
         javaHome: @escaping JavaHomeProvider = { JavaEnvironment.home(for: $0) },
         probe: @escaping JITProbe.Probe = JITProbe.systemProbe,
         resolveSymbol: @escaping SymbolResolver = { symbol in
             EngineSymbolResolver.resolve(symbol)
         },
         classLookup: @escaping (String) -> AnyClass? = { NSClassFromString($0) }) {
        self.payload = payload ?? EnginePayloadLocator.scan()
        self.javaHomeProvider = javaHome
        self.probe = probe
        self.resolveSymbol = resolveSymbol
        self.classLookup = classLookup
    }

    /// 机型标识（hw.machine，如 iPhone14,3 / iPad14,5）。写进启动日志，
    /// 让「某个具体机型启动崩溃」的反馈能直接对上架构/内存档位，不必再猜。
    static var deviceModel: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    /// fork 进程内能在主程序里查到 `launchJVM` 才算桥接就绪。
    /// 只打一次诊断日志，方便真机抓 `[YZL]` 定位「提示没内核」的问题。
    private static var bridgeLogEmitted = false

    var isRuntimeLinked: Bool {
        let linked = resolveSymbol("launchJVM") != nil
        if !Self.bridgeLogEmitted {
            Self.bridgeLogEmitted = true
            let executable = Bundle.main.executableURL?.path ?? "(nil)"
            NSLog("[YZL] launchJVM \(linked ? "FOUND" : "NOT FOUND") | main=\(executable) | bundle=\(Bundle.main.bundleURL.lastPathComponent)")
        }
        return linked
    }

    var isAvailable: Bool {
        payload.isLaunchable && isRuntimeLinked
    }

    func launch(_ plan: LaunchPlan) async throws {
        // 启动全链路落盘（真机无 Xcode 时唯一现场证据）。用户反馈过
        // 「Java 17 版本一启动启动器瞬间崩溃」——进程级 abort 拿不到 Swift 异常，
        // 必须在每一步写盘，崩溃后从「文件」App 取 YZL-boot.log 才能定位卡在哪。
        YZLBootLog.write("launch BEGIN | version=\(plan.version.id) mem=\(plan.memoryMB)MB lockedJava=\(plan.lockedJavaMajor.map(String.init) ?? "auto")")

        // 先确定该游戏版本需要哪个 Java，再据此挑 JRE 写进 JAVA_HOME。
        // 旧实现用 RuntimeLocator.javaHome() 拿「第一个有效目录」，
        // 1.16（要 Java 8）可能被塞 Java 17、1.21（要 Java 21）可能被塞 8，
        // 这正是 PC 端「按版本自动选 Java」要解决的问题。
        // 版本设置页锁定的 Java 大版本优先于自动推荐。
        let requiredMajor = plan.lockedJavaMajor
            ?? JavaEnvironment.recommendedMajor(
                gameVersion: plan.version.id,
                declaredMajor: plan.detail.javaVersion?.majorVersion
            )
        YZLBootLog.write("launch requiredJava=\(requiredMajor) declared=\((plan.detail.javaVersion?.majorVersion).map(String.init) ?? "nil")")
        guard let javaHome = javaHomeProvider(requiredMajor) else {
            let hint = JavaEnvironment.missingHint(
                required: requiredMajor,
                available: JavaEnvironment.availableMajors()
            )
            YZLBootLog.write("launch ABORT javaHome missing | \(hint)")
            throw EngineError.launchFailed(hint)
        }
        YZLBootLog.write("launch javaHome=\(javaHome.path)")

        guard JITProbe.detect(using: probe) == .enabled else {
            YZLBootLog.write("launch ABORT JIT disabled")
            throw EngineError.jitDisabled
        }
        YZLBootLog.write("launch JIT enabled")
        guard payload.isLaunchable else {
            YZLBootLog.write("launch ABORT payload: \(payload.summary)")
            throw EngineLaunchFailure.payloadMissing(payload.summary)
        }
        guard let launchSymbol = resolveSymbol("launchJVM") else {
            YZLBootLog.write("launch ABORT launchJVM symbol not found")
            throw EngineError.notIntegrated
        }
        YZLBootLog.write("launch payload OK + launchJVM FOUND")

        // 1. 写启动契约（含令牌，只落应用沙箱内的 YZLEngineHome）。
        let accessToken = Self.accessTokenFromPlan(plan)
        guard !accessToken.isEmpty else {
            throw EngineError.launchFailed("启动计划缺少访问令牌，无法写入启动契约。")
        }
        let home = EngineLaunchContract.homeDirectory
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let document = try EngineLaunchContract.document(from: plan, accessToken: accessToken)
        try EngineLaunchContract.write(document, homeDirectory: home)
        YZLBootLog.write("launch contract written | javaMajor=\(document.javaMajor) mainClass=\(document.mainClass) cpEntries=\(document.classpath.count) gameArgs=\(document.gameArguments.count)")
        YZLBootLog.write("launch device | model=\(Self.deviceModel) ios=\(ProcessInfo.processInfo.operatingSystemVersionString) physMB=\(DeviceCapabilities.physicalMemoryMB) procLimitMB=\(DeviceCapabilities.processMemoryLimitMB)")

        // 1.5 移动端适配 + 真实堆大小。
        // 这两步都必须在 JVM 起来之前完成：Amethyst 的 -Xmx 是在 launchJVM 里读偏好算的，
        // 偏好写晚了就还是按「物理内存 25%」跑——几百个模组的整合包会在加载地形时 GC 到死。
        let compat = MobileCompat.Settings.load()
        if compat.enabled {
            let report = try? MobileCompat.apply(to: plan.gameDirectory, aggressive: compat.aggressive)
            if let report = report, !report.isEmpty {
                print("[YZL] 移动端适配：\n\(report.summary)")
            }
        }
        try AmethystPreferences.apply(heapMB: plan.memoryMB, homeDirectory: home)

        // 1.6 默认虚拟键位（FCL 同款）：引擎 main() 把 default.json 生成到它自己的
        // AME_HOME，而紧接着我们要把 AME_HOME 换成 YZLEngineHome。若不在切换前把
        // 布局复制到 YZLEngineHome/controlmap/，游戏里就不会有任何悬浮按键/摇杆。
        // 已有布局（玩家自定义过）一律保留，绝不被覆盖。
        let controlSource = AmethystPreferences.ensureDefaultControlLayout(homeDirectory: home)
        YZLBootLog.write("launch control layout: \(controlSource)")

        // 2. 环境变量：AME_HOME（fork 主目录约定）与契约路径。
        setenv("AME_HOME", home.path, 1)
        setenv("YZL_LAUNCH_PLAN", home.appendingPathComponent("yzl-launch-plan.json").path, 1)
        setenv("GAME_DIR", plan.gameDirectory.path, 1)
        setenv("JAVA_HOME", javaHome.path, 1)
        YZLBootLog.write("launch env ready | JAVA_HOME=\(javaHome.path) heap=\(plan.memoryMB)MB")

        // 一致性硬校验：JAVA_HOME 指向的 JRE 大版本必须等于契约 javaMajor。
        // 不一致会让 fork 侧按一个版本、JVM 参数按另一个版本，是潜在的瞬间崩溃源。
        let scannedMajor = JavaEnvironment.major(of: javaHome, fileManager: .default)
        if let scannedMajor, scannedMajor != requiredMajor {
            YZLBootLog.write("WARN javaHome major=\(scannedMajor) != required=\(requiredMajor)（按实际 \(scannedMajor) 继续）")
        }

        // JVM 参数与 launchTarget 必须在呈现画面**之前**备好。
        // jvm_processed 是 Amethyst 唯一开放给我们追加 JVM 参数的入口（拼在它自己的
        // -Xmx 之后，最后一条生效）。堆与 GC 由 EngineJVMArguments 生成；
        // 版本设置页「额外 JVM 参数」+ 皮肤站 authlib 参数经 sanitize 去掉路径类后一并转发
        // （sanitize 会丢弃 -Djava.library.path / -cp / -jar，避免把 Windows natives 指给 iOS）。
        let baseArguments = EngineJVMArguments.build(heapMB: plan.memoryMB, javaMajor: document.javaMajor)
        let forwardedArguments = EngineJVMArguments.sanitized(from: plan.jvmArguments)
        let jvmArguments = baseArguments + forwardedArguments
        // 单一份完整 target，同时给 SurfaceViewController 的 metadata 和 launchJVM。
        // 旧实现只给 surface 传了 {"javaVersion":...}，却让其 viewDidLoad 自动 launchMinecraft
        // ——那条路径的 launchTarget 缺 id，[nil UTF8String] 把 NULL 塞进 JVM argv；
        // 加上 YZL 自己又调一次 launchJVM，同一进程两次 JLI_Launch 直接原生崩溃。
        // fork 补丁④已在有 YZL_LAUNCH_PLAN 时禁掉自动启动；这里再用完整字典兜底。
        let target = EngineLaunchContract.launchTarget(
            versionID: plan.version.id,
            javaMajor: document.javaMajor,
            jvmArguments: jvmArguments
        )
        let minJava = Int32(document.javaMajor)

        // 3. 呈现游戏画面（fork 的 SurfaceViewController，运行时 msgSend
        //    `initWithMetadata:`——真签名见 Natives/SurfaceViewController.m:66；
        //    随后按 Amethyst 桥 UIKit_launchMinecraftSurfaceVC 的模式替换
        //    keyWindow 根控制器）。必须在 JVM 启动之前完成。
        await presentGameSurface(metadata: target)
        YZLBootLog.write("launch surface presented | minJava=\(minJava) | targetKeys=\(target.allKeys.count)")

        // 4. launchJVM(username, launchTarget, width, height, minVersion)。
        //    JLI_Launch 阻塞当前线程直到游戏退出——必须离开主线程
        //    （Amethyst 原生流程同样从后台线程调用）。
        //    launchTarget 走字典（profile 模式）；fork 的 PojavLauncher 补丁读
        //    YZL_LAUNCH_PLAN，这里带版本 id 与真正要生效的 JVM 参数。
        typealias LaunchJVM = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int32, Int32, Int32) -> Int32
        let launch = unsafeBitCast(launchSymbol, to: LaunchJVM.self)
        let username = plan.accountName
        YZLBootLog.write("launch CALL launchJVM | jvmArgs=\(jvmArguments.joined(separator: " "))")
        YZLBootLog.write("launch JVM START (blocking) — 若下次日志停在这里，崩溃点在 JVM 内部")

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let nsName = username as NSString
                let code = launch(
                    Unmanaged.passUnretained(nsName).toOpaque(),
                    Unmanaged.passUnretained(target).toOpaque(),
                    0, 0, minJava
                )
                continuation.resume(returning: code)
            }
        }
        YZLBootLog.write("launch JVM RETURNED exitCode=\(exitCode)")

        // 5. 契约文件含令牌，启动流程已交接即删。
        EngineLaunchContract.remove(homeDirectory: home)

        if exitCode != 0 {
            throw EngineLaunchFailure.engineExit(exitCode)
        }
    }

    // MARK: - 游戏画面

    /// fork 的 SurfaceViewController 是 ObjC 类，编译期不引用。
    /// 运行时 objc_msgSend 调 `initWithMetadata:`（真签名），随后替换
    /// keyWindow 根控制器——与 Amethyst 桥 UIKit_launchMinecraftSurfaceVC
    /// 的模式一致（游戏退出由其 returnToSplitView 恢复）。
    @MainActor
    private func presentGameSurface(metadata: NSDictionary) async {
        guard let surfaceClass = classLookup("SurfaceViewController") else {
            return
        }
        // classLookup 返回 AnyClass（any AnyObject.Type），不能强转 NSObject.Type，
        // 也不存在 NSObject.Type.alloc()。改用 ObjC 动态派发发 alloc / initWithMetadata:
        // 两条消息，保留 fork 的真实初始化签名，编译期仍零依赖 Amethyst 源码。
        guard let allocator = (surfaceClass as AnyObject)
            .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return }
        guard let surface = allocator
            .perform(NSSelectorFromString("initWithMetadata:"), with: metadata)?
            .takeRetainedValue() else { return }
        guard let surfaceVC = surface as? UIViewController else { return }

        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        keyWindow?.rootViewController = surfaceVC
    }

    // MARK: - 令牌传递

    /// LaunchPlan 不携带独立令牌字段（游戏参数里已内联 --accessToken），
    /// 契约需要独立令牌值：从游戏参数里取回，避免第二条持久化路径。
    static func accessTokenFromPlan(_ plan: LaunchPlan) -> String {
        let arguments = plan.gameArguments
        if let index = arguments.firstIndex(of: "--accessToken"),
           index + 1 < arguments.count {
            return arguments[index + 1]
        }
        // 离线（伪正版）账号没有微软令牌：userType=mojang 时用固定占位值，
        // 否则契约会因空令牌被拒，离线账号根本起不来。
        // 旧实现找字面量 "offline"，但命令行里只有 "mojang"，永远命中不了。
        if let typeIndex = arguments.firstIndex(of: "--userType"),
           typeIndex + 1 < arguments.count,
           arguments[typeIndex + 1].lowercased() == "mojang" {
            return "offline"
        }
        return ""
    }
}

/// M2-b 桥专属错误：比 EngineError.notIntegrated 更细的失败定位。
enum EngineLaunchFailure: LocalizedError, Equatable {
    case payloadMissing(String)
    case engineExit(Int32)

    var errorDescription: String? {
        switch self {
        case .payloadMissing(let summary):
            return "引擎件不完整：\(summary)"
        case .engineExit(let code):
            return "引擎启动进程退出，代码 \(code)。请查看 fork 引擎日志。"
        }
    }
}

/// 工厂：fork 环境（dlsym 命中）用真引擎桥，纯外壳构建维持 M2 接缝实现。
enum LauncherEngineFactory {
    static func make() -> LauncherEngine {
        let host = YZLEngineHost()
        return host.isRuntimeLinked ? host : AmethystEngine()
    }
}
