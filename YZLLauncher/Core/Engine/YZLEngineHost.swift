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
    typealias JavaHomeProvider = () -> URL?
    typealias SymbolResolver = (String) -> UnsafeMutableRawPointer?

    let name = "Amethyst 引擎（fork，YZL UI 注入）"

    private let payload: EnginePayloadLocator.Payload
    private let javaHomeProvider: JavaHomeProvider
    private let probe: JITProbe.Probe
    private let resolveSymbol: SymbolResolver
    private let classLookup: (String) -> AnyClass?

    init(payload: EnginePayloadLocator.Payload? = nil,
         javaHome: @escaping JavaHomeProvider = { RuntimeLocator.javaHome() },
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
        guard let javaHome = javaHomeProvider() else {
            throw EngineError.runtimeMissing
        }
        guard JITProbe.detect(using: probe) == .enabled else {
            throw EngineError.jitDisabled
        }
        guard payload.isLaunchable else {
            throw EngineLaunchFailure.payloadMissing(payload.summary)
        }
        guard let launchSymbol = resolveSymbol("launchJVM") else {
            throw EngineError.notIntegrated
        }

        // 1. 写启动契约（含令牌，只落应用沙箱内的 YZLEngineHome）。
        let accessToken = Self.accessTokenFromPlan(plan)
        guard !accessToken.isEmpty else {
            throw EngineError.launchFailed("启动计划缺少访问令牌，无法写入启动契约。")
        }
        let home = EngineLaunchContract.homeDirectory
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let document = try EngineLaunchContract.document(from: plan, accessToken: accessToken)
        try EngineLaunchContract.write(document, homeDirectory: home)

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

        // 2. 环境变量：AME_HOME（fork 主目录约定）与契约路径。
        setenv("AME_HOME", home.path, 1)
        setenv("YZL_LAUNCH_PLAN", home.appendingPathComponent("yzl-launch-plan.json").path, 1)
        setenv("GAME_DIR", plan.gameDirectory.path, 1)
        setenv("JAVA_HOME", javaHome.path, 1)

        // 3. 呈现游戏画面（fork 的 SurfaceViewController，运行时 msgSend
        //    `initWithMetadata:`——真签名见 Natives/SurfaceViewController.m:66；
        //    随后按 Amethyst 桥 UIKit_launchMinecraftSurfaceVC 的模式替换
        //    keyWindow 根控制器）。必须在 JVM 启动之前完成。
        let minJava = Int32(document.javaMajor)
        let metadata: NSDictionary = [
            "javaVersion": ["majorVersion": document.javaMajor]
        ]
        await presentGameSurface(metadata: metadata)

        // 4. launchJVM(username, launchTarget, width, height, minVersion)。
        //    JLI_Launch 阻塞当前线程直到游戏退出——必须离开主线程
        //    （Amethyst 原生流程同样从后台线程调用）。
        //    launchTarget 走字典（profile 模式）；fork 的 PojavLauncher 补丁读
        //    YZL_LAUNCH_PLAN，这里带版本 id 与真正要生效的 JVM 参数。
        typealias LaunchJVM = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int32, Int32, Int32) -> Int32
        let launch = unsafeBitCast(launchSymbol, to: LaunchJVM.self)
        let username = plan.accountName
        // jvm_processed 是 Amethyst 唯一开放给我们追加 JVM 参数的入口（拼在它自己的
        // -Xmx 之后，最后一条生效）。只放堆与 GC，不转发实例里那份 Windows natives 路径。
        let jvmArguments = EngineJVMArguments.build(heapMB: plan.memoryMB, javaMajor: document.javaMajor)
        // 皮肤站账号的 authlib-injector 参数要进 fork 引擎：从 LaunchPlan 的 jvmArguments
        // 里显式挑出注入相关的两条（EngineJVMArguments 黑名单不含 -javaagent，
        // 这里按前缀过滤转发，其余参数照旧不转发）。
        let authlibArguments = plan.jvmArguments.filter(AuthlibInjector.isInjectorArgument)

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let nsName = username as NSString
                let target: NSDictionary = [
                    "id": plan.version.id,
                    "arguments": ["jvm_processed": jvmArguments + authlibArguments]
                ]
                let code = launch(
                    Unmanaged.passUnretained(nsName).toOpaque(),
                    Unmanaged.passUnretained(target).toOpaque(),
                    0, 0, minJava
                )
                continuation.resume(returning: code)
            }
        }

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
