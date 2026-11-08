import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// JIT 可用性探测——逻辑对齐引擎本体 Amethyst 的 `isJITEnabled`（Natives/utils.m）。
///
/// 真实具备 JIT 的两条路径：
/// 1. 进程带 `dynamic-codesigning` entitlement（TrollStore CoreTrust 绕过时生效）；
/// 2. `csops` 查到 `CS_DEBUGGED`（调试器附加 / TrollStore 启动）。
/// 普通侧载（免费/企业证书）两者皆无 → 显示"未启用"，如实反映。
///
/// 刻意不做的事：
/// - 不用 mmap/mprotect 探测（惰性分配在侧载环境假成功）；
/// - 不用 @_silgen_name 绑定 dyld 符号（黑屏排查后移除，降低崩溃面）；
/// - 不做越狱检测（对 JIT 判定无增量贡献，反而增加崩溃面）。
enum JITProbe {
    typealias Probe = () -> Bool

    private static let CS_DEBUGGED: UInt32 = 0x1000_0000

    static func detect(using probe: Probe = JITProbe.systemProbe) -> JITStatus {
        probe() ? .enabled : .disabled
    }

    static func systemProbe() -> Bool {
        #if canImport(Darwin)
        return hasDynamicCodesigningEntitlement() || hasCSDebuggedFlag()
        #else
        return false
        #endif
    }

    // MARK: - csops 查 CS_DEBUGGED

    private static func hasCSDebuggedFlag() -> Bool {
        guard let csops = findSymbol("csops") else { return false }
        typealias CSOpsFn = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer, Int) -> Int32
        let fn = unsafeBitCast(csops, to: CSOpsFn.self)
        var flags: UInt32 = 0
        guard fn(getpid(), 0, &flags, MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & CS_DEBUGGED != 0
    }

    // MARK: - SecTask 查 entitlement

    private static func hasDynamicCodesigningEntitlement() -> Bool {
        guard let createSym = findSymbol("SecTaskCreateFromSelf"),
              let copySym = findSymbol("SecTaskCopyValueForEntitlement"),
              let releaseSym = findSymbol("CFRelease") else {
            return false
        }

        typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        typealias CopyFn = @convention(c) (UnsafeMutableRawPointer?, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> Unmanaged<CFTypeRef>?
        typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let copy = unsafeBitCast(copySym, to: CopyFn.self)
        let release = unsafeBitCast(releaseSym, to: ReleaseFn.self)

        guard let task = create(nil) else { return false }
        defer { release(task) }

        var out: Unmanaged<CFTypeRef>?
        guard let retained = copy(task, "dynamic-codesigning" as CFString, &out) else { return false }
        let value = retained.takeRetainedValue()
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return true
    }

    // MARK: - 安全符号查找

    /// RTLD_DEFAULT(-2) 查符号，查不到返回 nil，绝不崩。
    private static func findSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }
}
