import Foundation

/// 真正拉起 JVM 的桥，由 M2 的 ObjC / Swift 混编层（JLI_Launch + SurfaceViewController）实现。
/// 外壳不直接依赖 Amethyst 源码，只依赖这个协议，便于先在 CI 里验证参数链路。
protocol EngineBridge {
    var isAvailable: Bool { get }
    func launch(_ command: LaunchCommand) async throws
}

/// M2 接缝实现：把「运行时校验 → JIT 校验 → 命令组装 → 交给内核」串成一条可测的链路。
///
/// 没有桥时明确抛 `.notIntegrated`，绝不假装启动成功；
/// 桥接层补齐后只需提供 `EngineBridge` 实现，外壳与启动面板都不用改。
struct AmethystEngine: LauncherEngine {
    typealias JavaHomeProvider = () -> URL?

    let name = "Amethyst / Pojav 系（M2 接缝）"

    private let bridge: EngineBridge?
    private let javaHomeProvider: JavaHomeProvider
    private let probe: JITProbe.Probe

    init(bridge: EngineBridge? = nil,
         javaHome: @escaping JavaHomeProvider = { RuntimeLocator.javaHome() },
         probe: @escaping JITProbe.Probe = JITProbe.systemProbe) {
        self.bridge = bridge
        self.javaHomeProvider = javaHome
        self.probe = probe
    }

    /// 只有桥就绪才算可用；JRE / natives 齐备但桥没接时，自检仍会如实标红。
    var isAvailable: Bool { bridge?.isAvailable == true }

    func launch(_ plan: LaunchPlan) async throws {
        guard let javaHome = javaHomeProvider() else {
            throw EngineError.runtimeMissing
        }
        guard JITProbe.detect(using: probe) == .enabled else {
            throw EngineError.jitDisabled
        }
        guard let bridge, bridge.isAvailable else {
            throw EngineError.notIntegrated
        }
        try await bridge.launch(LaunchCommand.make(plan: plan, javaHome: javaHome))
    }
}
